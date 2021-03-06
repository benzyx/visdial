require 'model_utils.MaskSoftMax'

local encoderNet = {}

function encoderNet.model(params)

    local inputs = {}
    local outputs = {}

    table.insert(inputs, nn.Identity()()) -- question
    table.insert(inputs, nn.Identity()()) -- img feats
    table.insert(inputs, nn.Identity()()) -- history
    table.insert(inputs, nn.Identity()()) -- 10x10 mask

    local ques = inputs[1]
    local img_feats = inputs[2]
    local hist = inputs[3]
    local mask = inputs[4]

    -- word embed layer
    wordEmbed = nn.LookupTableMaskZero(params.vocabSize, params.embedSize);

    -- make clones for embed layer
    local qEmbed = nn.Dropout(0.5)(wordEmbed:clone('weight', 'bias', 'gradWeight', 'gradBias')(ques));
    local hEmbed = nn.Dropout(0.5)(wordEmbed:clone('weight', 'bias', 'gradWeight', 'gradBias')(hist));

    local lst1 = nn.SeqLSTM(params.embedSize, params.rnnHiddenSize)
    lst1:maskZero()

    local lst2 = nn.SeqLSTM(params.rnnHiddenSize, params.rnnHiddenSize)
    lst2:maskZero()

    local h1 = lst1(hEmbed)
    local h2 = lst2(h1)
    local h3 = nn.Select(1, -1)(h2)

    local lst3 = nn.SeqLSTM(params.embedSize, params.rnnHiddenSize)
    lst3:maskZero()

    local lst4 = nn.SeqLSTM(params.rnnHiddenSize, params.rnnHiddenSize)
    lst4:maskZero()

    local q1 = lst3(qEmbed)
    local q2 = lst4(q1)
    local q3 = nn.Select(1, -1)(q2)

    -- View as batch x rounds
    local qEmbedView = nn.View(-1, params.maxQuesCount, params.rnnHiddenSize)(q3)
    local hEmbedView = nn.View(-1, params.maxQuesCount, params.rnnHiddenSize)(h3)

    -- Inner product
    -- q is Bx10xE, h is Bx10xE
    -- qh is Bx10x10, rows correspond to questions, columns to facts
    local qh = nn.MM(false, true)({qEmbedView, hEmbedView})
    local qhView = nn.View(-1, params.maxQuesCount)(qh)
    local qhprobs = nn.MaskSoftMax(){qhView, mask}
    local qhView2 = nn.View(-1, params.maxQuesCount, params.maxQuesCount)(qhprobs)

    -- Weighted sum of h features
    -- h is Bx10xE, qhView2 is Bx10x10
    local hAtt = nn.MM(){qhView2, hEmbedView}
    local hAttView = nn.View(-1, params.rnnHiddenSize)(hAtt)

    local hAttTr = nn.Tanh()(nn.Linear(params.rnnHiddenSize, params.rnnHiddenSize)(nn.Dropout(0.5)(hAttView)))
    local qh2 = nn.Tanh()(nn.Linear(params.rnnHiddenSize, params.rnnHiddenSize)(nn.CAddTable(){hAttTr, nn.View(-1, params.rnnHiddenSize)(qEmbedView)}))

    -- image attention (inspired by SAN, Yang et al., CVPR16)
    local img_tr_size = params.rnnHiddenSize
    local rnn_size = params.rnnHiddenSize
    local common_embedding_size = params.commonEmbeddingSize or 512
    local num_attention_layer = params.numAttentionLayers or 1

    local u = qh2
    local img_tr = nn.Dropout(0.5)(
                    nn.Tanh()(
                        nn.View(-1, params.imgSpatialSize * params.imgSpatialSize, img_tr_size)(
                            nn.Linear(params.imgFeatureSize, img_tr_size)(
                                nn.View(params.imgFeatureSize):setNumInputDims(2)(img_feats)))))

    for i = 1, num_attention_layer do

        -- linear layer: 14x14x1024 -> 14x14x512
        local img_common = nn.View(-1, params.imgSpatialSize * params.imgSpatialSize, common_embedding_size)(
                            nn.Linear(img_tr_size, common_embedding_size)(
                                nn.View(-1, img_tr_size)(img_tr)))

        -- replicate lstm state 196 times
        local ques_common = nn.Linear(rnn_size, common_embedding_size)(u)
        local ques_repl = nn.Replicate(params.imgSpatialSize * params.imgSpatialSize, 2)(ques_common)

        -- add image and question features (both 196x512)
        local img_ques_common = nn.Dropout(0.5)(nn.Tanh()(nn.CAddTable()({img_common, ques_repl})))
        local h = nn.Linear(common_embedding_size, 1)(nn.View(-1, common_embedding_size)(img_ques_common))
        local p = nn.SoftMax()(nn.View(-1, params.imgSpatialSize * params.imgSpatialSize)(h))

        -- weighted sum of image features
        local p_att = nn.View(1, -1):setNumInputDims(1)(p)
        local img_tr_att = nn.MM(false, false)({p_att, img_tr})
        local img_tr_att_feat = nn.View(-1, img_tr_size)(img_tr_att)

        -- add image feature vector and question vector
        u = nn.CAddTable()({img_tr_att_feat, u})

    end

    local o = nn.Tanh()(nn.Linear(rnn_size, rnn_size)(nn.Dropout(0.5)(u)))
    -- SAN stuff ends

    table.insert(outputs, o)

    local enc = nn.gModule(inputs, outputs)
    enc.wordEmbed = wordEmbed

    return enc;
end

return encoderNet
