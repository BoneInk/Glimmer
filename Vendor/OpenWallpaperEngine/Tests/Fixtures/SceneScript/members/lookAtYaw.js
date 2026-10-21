// ILayer.lookAtYaw(center, up?): only the heading about `up` turns towards `center`.
(function () {
    var group = thisScene.getLayer('group');
    group.origin = new Vec3(0, 0, 0);
    group.lookAtYaw(new Vec3(0, -5, 5));
    if (Math.round(group.angles.x) !== 0) return 'pitched';
    group.lookAtYaw(new Vec3(-5, 5, 0));
    return Math.round(group.angles.y) === -90 ? 'ok' : 'heading ' + group.angles.y;
})()
