// ILayer.setParent(parent, adjustTransforms?): the layer moves under `parent`; undefined makes it a root.
(function () {
    var clock = thisScene.getLayer('clock'), group = thisScene.getLayer('group');
    clock.setParent(group);
    if (clock.getParent() !== group) return 'not under the group';
    if (group.getChildren().indexOf(clock) < 0) return 'missing from the group\'s children';
    group.setParent(clock);
    if (group.getParent() !== undefined) return 'a layer became its own ancestor';
    clock.setParent(undefined);
    if (clock.getParent() !== undefined) return 'still parented';
    return 'ok';
})()
