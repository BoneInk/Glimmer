// ILayer.rotateObjectSpace(angles): turns about the layer's own axes.
(function () {
    var group = thisScene.getLayer('group');
    group.angles = new Vec3(0, 0, 90);
    group.rotateObjectSpace(new Vec3(90, 0, 0));
    var a = group.angles;
    return [Math.round(a.x), Math.round(a.y), Math.round(a.z)].join() === '90,0,90' ? 'ok' : 'angles ' + a.toString();
})()
