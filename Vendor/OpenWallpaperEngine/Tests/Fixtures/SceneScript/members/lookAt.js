// ILayer.lookAt(center, up?): the layer's +z points at `center`, seen from its origin.
(function () {
    var group = thisScene.getLayer('group');
    group.origin = new Vec3(0, 0, 0);
    group.lookAt(new Vec3(0, -5, 5));
    var a = group.angles;
    return [Math.round(a.x), Math.round(a.y), Math.round(a.z)].join() === '45,0,0' ? 'ok' : 'angles ' + a.toString();
})()
