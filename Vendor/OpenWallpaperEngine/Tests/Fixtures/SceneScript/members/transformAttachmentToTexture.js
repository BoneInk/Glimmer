// IEffectLayer.transformAttachmentToTexture(layer, attachment): the attachment in this layer's
// texture space (u right, v down). The host put 'plain' 50 left of and 25 below the puppet's grip.
(function () {
    var plain = thisScene.getLayer('plain');
    var m = plain.transformAttachmentToTexture('puppet', 'grip').m;
    if (Math.abs(m[6] - 0.75) > 1e-5 || Math.abs(m[7] - 0.25) > 1e-5) return 'at ' + m[6] + ',' + m[7];
    if (plain.transformAttachmentToTexture('puppet', 'nope').m[6] !== 0) return 'a missing attachment is not identity';
    return 'ok';
})()
