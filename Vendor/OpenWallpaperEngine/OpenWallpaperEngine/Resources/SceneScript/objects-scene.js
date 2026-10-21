'use strict';
// SceneScript object model, part 6 of 6: `thisScene` (IScene), the layer registry in draw order,
// `thisLayer`/`thisObject` for each script (`__rt.hooks.scope`), and the deferred structure changes.
// Builds the scene's layers from the records SceneScriptObjectModel placed at install.
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    const native = rt.native.objects;
    const OP = objects.OP;
    const sceneBuffer = objects.sceneBuffer;
    const SETTINGS_DIRTY = 0, CAMERA_DIRTY = 1;

    // Every live layer in draw order; slot → layer; scene.json id → layer.
    objects.order = [];
    objects.bySlot = new Map();
    objects.byID = new Map();
    const pendingDestroy = [];

    function register(record) {
        const layer = objects.makeLayer(record);
        objects.bySlot.set(record.slot, layer);
        objects.byID.set(record.id, layer);
        return layer;
    }

    // A layer from `name|index|ILayer` (IScene's argument forms): a number is a draw-order index; a
    // string is a name, then an id.
    function resolve(target) {
        if (target instanceof objects.Layer) return target._dead ? null : target;
        if (typeof target === 'number') {
            const layer = objects.order[Math.floor(target)];
            return layer === undefined ? null : layer;
        }
        if (typeof target === 'string') {
            const layer = objects.order.find(function (candidate) { return candidate._name === target; });
            if (layer !== undefined) return layer;
            return objects.order.find(function (candidate) { return String(candidate._id) === target; }) || null;
        }
        return null;
    }

    function cameraVector(t, offset) { return objects.vec3(t[offset], t[offset + 1], t[offset + 2]); }

    // The `__workshopId` a script exports ('' without one): WE's editor inserts it so the script's
    // asset paths resolve under its Workshop item (RF1). Read when used, since a module body that
    // calls `registerAsset` runs before its exports exist.
    function workshopIDOf(record) {
        if (record === undefined || record === null) return '';
        const id = rt.exports(record, '__workshopId');
        return id === undefined || id === null ? '' : String(id);
    }

    function callerWorkshopID() {
        return rt.current === null ? '' : workshopIDOf(rt.byId.get(rt.current));
    }

    class Scene {
        getLayer(nameOrIndex) { return resolve(nameOrIndex); }

        getLayerByID(id) {
            const key = String(id);
            return objects.order.find(function (layer) { return String(layer._id) === key; }) || null;
        }

        getLayerCount() { return objects.order.length; }

        enumerateLayers() { return objects.order.slice(); }

        getLayerIndex(layer) {
            const found = typeof layer === 'number' ? null : resolve(layer);
            return found === null ? -1 : objects.order.indexOf(found);
        }

        getInitialLayerConfig(layer) {
            const found = resolve(layer);
            if (found === null || typeof found._record.config !== 'string') return null;
            return JSON.parse(found._record.config);
        }

        // "The layer is removed after all scripts on that frame updated." Its children go with it
        // (best guess: WE's editor removes a parent's children with it).
        destroyLayer(layer) {
            const found = resolve(layer);
            if (found === null || pendingDestroy.indexOf(found) >= 0) return false;
            pendingDestroy.push(found);
            return true;
        }

        // A layer from an asset path or IAssetHandle, a configuration object in scene.json form
        // (serialized with WE's `_Internal.stringifyConfig`), or another layer as starting point.
        createLayer(configuration) {
            let kind, payload = '', source = -1, workshopID = callerWorkshopID();
            if (typeof configuration === 'string') {
                kind = 'asset';
                payload = configuration;
            } else if (configuration instanceof objects.Layer) {
                if (configuration._dead) return null;
                kind = 'copy';
                source = configuration._slot;
            } else if (typeof IModelData === 'function' && configuration instanceof IModelData) {
                // "or just pass IModelData as a single argument": a model layer showing it
                // (objects-modeldata.js), its token as the configuration's `model`.
                kind = 'configuration';
                payload = JSON.stringify({ model: configuration.toConfigString() });
            } else if (configuration !== null && typeof configuration === 'object') {
                // An IAssetHandle names its file through `toConfigString`, like WE's other handles
                // (IModelData); a configuration object in scene.json form has no such method.
                if (typeof configuration.toConfigString === 'function') {
                    kind = 'asset';
                    payload = String(configuration.toConfigString());
                    if (configuration instanceof AssetHandle) workshopID = configuration._workshopID();
                } else {
                    kind = 'configuration';
                    payload = global._Internal ? global._Internal.stringifyConfig(configuration) : JSON.stringify(configuration);
                }
            } else {
                return null;
            }
            const record = native.create(kind, payload, source, workshopID);
            if (record === null || record === undefined) return null;
            const layer = register(record);
            objects.order.push(layer);
            objects.push(OP.create, record.slot);
            return layer;
        }

        // Moves `layer` to `index` in draw order at once; the renderer follows in the same frame.
        sortLayer(layer, index) {
            const found = resolve(layer);
            if (found === null || typeof index !== 'number' || index !== index) return false;
            const order = objects.order;
            const target = Math.max(0, Math.min(order.length - 1, Math.floor(index)));
            order.splice(order.indexOf(found), 1);
            order.splice(target, 0, found);
            objects.push(OP.sort, found._slot, [target]);
            return true;
        }

        getCameraTransforms() {
            const t = sceneBuffer.values;
            return {
                eye: cameraVector(t, fieldOffset.cameraEye),
                center: cameraVector(t, fieldOffset.cameraCenter),
                up: cameraVector(t, fieldOffset.cameraUp),
                zoom: t[fieldOffset.cameraZoom],
            };
        }

        setCameraTransforms(transforms) {
            if (transforms === null || typeof transforms !== 'object') return;
            const t = sceneBuffer.values;
            let changed = false;
            ['eye', 'center', 'up'].forEach(function (key) {
                const c = objects.components(transforms[key], 3);
                if (c === undefined || typeof transforms[key] === 'number') return;
                const offset = fieldOffset['camera' + key[0].toUpperCase() + key.slice(1)];
                for (let k = 0; k < 3; k++) t[offset + k] = c[k];
                changed = true;
            });
            if (typeof transforms.zoom === 'number') {
                t[fieldOffset.cameraZoom] = transforms.zoom;
                changed = true;
            }
            if (changed) sceneBuffer.dirty[CAMERA_DIRTY] = 1;
        }

        getAnimation(name) { return objects.findAnimation(name, sceneAnimations); }
    }

    // Scene settings (bloom, clearcolor, camerashake, …), generated from SceneScriptSceneField.
    const fieldOffset = {};
    // Settings `IScene` doesn't declare (`bloomhdr*`): only a script bound to one reads and sets it.
    const sceneBoundOnly = {};
    native.sceneFields.forEach(function (field) {
        fieldOffset[field.name] = field.offset;
        if (field.camera) return;
        if (!field.member) {
            sceneBoundOnly[field.name] = field;
            return;
        }
        objects.defineField(Scene.prototype, field.name, field.offset, field.type, false);
    });

    const thisScene = new Scene();
    objects.attach(thisScene, sceneBuffer.values, 0, sceneBuffer.dirty, SETTINGS_DIRTY);

    // The property binding's access to bound-only fields: the scene's own, else a layer's
    // (objects-layers.js).
    const layerIsBoundOnly = objects.isBoundOnly, layerReadBound = objects.readBound;
    const layerWriteBound = objects.writeBound;
    const sceneField = function (name) {
        return Object.prototype.hasOwnProperty.call(sceneBoundOnly, name) ? sceneBoundOnly[name] : undefined;
    };
    objects.isBoundOnly = function (name, target) {
        return target === thisScene ? sceneField(name) !== undefined : layerIsBoundOnly(name);
    };
    objects.readBound = function (target, name) {
        if (target !== thisScene) return layerReadBound(target, name);
        const field = sceneField(name);
        return field === undefined ? undefined : objects.read(field.type, target._t, target._base + field.offset);
    };
    objects.writeBound = function (target, name, value) {
        if (target !== thisScene) return layerWriteBound(target, name, value);
        const field = sceneField(name);
        const c = field === undefined ? undefined : objects.convert(field.type, value);
        if (c === undefined) return;
        for (let k = 0; k < c.length; k++) target._t[target._base + field.offset + k] = c[k];
        target._d[target._di] = 1;
    };
    const sceneAnimations = native.initial.animations;
    objects.Scene = Scene;
    objects.scene = thisScene;
    Object.defineProperty(global, 'thisScene', { value: thisScene, enumerable: true, writable: false, configurable: false });

    native.initial.objects.forEach(function (record) { objects.order.push(register(record)); });

    // MARK: engine.registerAsset (IAssetHandle)

    // IAssetHandle: what `registerAsset` returns. `createLayer` and `_Internal.stringifyConfig`
    // take its path through `toConfigString()`, like WE's other handles (IModelData).
    // `_workshopID()` is the `__workshopId` of the script that registered it, which places the path.
    class AssetHandle {
        constructor(path, owner) {
            Object.defineProperty(this, '_path', { value: path });
            Object.defineProperty(this, '_workshopID', { value: function () { return workshopIDOf(owner); } });
        }
        toConfigString() { return this._path; }
    }
    objects.AssetHandle = AssetHandle;

    // WE loads the asset with the scene when `precache` is set, and marks it for publishing; here
    // the renderer loads it when `createLayer` needs it, so both are the same handle.
    // Extensions share one `engine` object, whichever installs first.
    if (global.engine === undefined) global.engine = {};
    global.engine.registerAsset = function (file, precache) {
        rt.requireGlobalScope('registerAsset');
        return new AssetHandle(String(file), rt.current === null ? undefined : rt.byId.get(rt.current));
    };

    // `engine.isObjectValid(object)`: undocumented, named in scenescript64.dll. Best guess: whether a
    // layer (or one of its effects or materials) is still alive, i.e. not destroyed.
    global.engine.isObjectValid = function (object) {
        if (object === null || typeof object !== 'object') return false;
        if (object instanceof objects.Layer) return !object._dead;
        if (object instanceof objects.Effect) return !object._dead && !object._layer._dead;
        if (object instanceof objects.Material) return !object._dead && !object._effect._layer._dead;
        return false;
    };

    // `engine.requestFeatures(...)`: undocumented and global-scope only ("requestFeatures can only be
    // called from global scope."); what it enables is not known, so it does nothing else.
    global.engine.requestFeatures = function () {
        rt.requireGlobalScope('requestFeatures');
    };

    // MARK: thisLayer / thisObject

    // The object a binding names (SceneScriptObjectBinding), or null when it no longer exists.
    objects.bindingTarget = function (binding) {
        if (binding.kind === 'scene') return thisScene;
        const layer = objects.bySlot.get(binding.slot);
        if (layer === undefined) return null;
        if (binding.kind === 'layer') return layer;
        const effect = layer.getEffect(binding.effect);
        if (binding.kind === 'effect' || effect === null) return effect;
        return effect.getMaterial(binding.material);
    };

    objects.bind = function (id, binding) { objects.bindings.set(id, binding); };

    // What `thisObject` is for script `id`: the binding it was defined with
    // (SceneScriptInstance.binding), else one set through `bind` before its load.
    objects.bindingOf = function (id) {
        const record = rt.byId.get(id);
        if (record !== undefined && record.binding !== null && record.binding !== undefined) return record.binding;
        return objects.bindings.get(id);
    };

    objects.slotForID = function (id) {
        const layer = objects.byID.get(id);
        return layer === undefined || layer._dead ? -1 : layer._slot;
    };

    objects.layerForSlot = function (slot) {
        const layer = objects.bySlot.get(slot);
        return layer === undefined ? null : layer;
    };

    // `thisLayer` is the layer in the script's slot (undefined for scene-level scripts);
    // `thisObject` the owner of the bound property, else the layer, else the scene (§1.3, P9).
    rt.hooks.scope = function (record) {
        const layer = record.slot >= 0 ? objects.bySlot.get(record.slot) : undefined;
        const binding = record.binding !== null && record.binding !== undefined ? record.binding : objects.bindings.get(record.id);
        let thisObject = binding ? objects.bindingTarget(binding) : null;
        if (thisObject === null || thisObject === undefined) thisObject = layer !== undefined ? layer : thisScene;
        return { thisLayer: layer, thisObject: thisObject };
    };

    // MARK: deferred structure changes (after every update of the frame)

    function collect(layer, into) {
        if (into.indexOf(layer) >= 0) return;
        into.push(layer);
        const id = layer._id;
        objects.order.forEach(function (candidate) {
            if (candidate._record.parentID === id && candidate !== layer) collect(candidate, into);
        });
    }

    // The layers' scripts get their `destroy()` first, while the layers are still in the scene
    // ("just before the object is destroyed": `thisLayer` writes land, `getLayer` finds it; SF11);
    // then the layers go. A `destroy()` that destroys more layers starts another round.
    function destroyPending() {
        while (pendingDestroy.length > 0) {
            const doomed = [];
            pendingDestroy.forEach(function (layer) { collect(layer, doomed); });
            pendingDestroy.length = 0;
            doomed.forEach(function (layer) {
                rt.records.forEach(function (record) {
                    if (record.slot === layer._slot && !record.pendingDestroy) rt.remove(record.id);
                });
            });
            rt.destroyPending();
            doomed.forEach(function (layer) {
                if (layer._dead) return;
                const slot = layer._slot;
                const index = objects.order.indexOf(layer);
                if (index >= 0) objects.order.splice(index, 1);
                objects.bySlot.delete(slot);
                if (objects.byID.get(layer._id) === layer) objects.byID.delete(layer._id);
                objects.push(OP.destroy, slot);
                objects.detachLayer(layer);
            });
        }
    }

    rt.addPhaseHandler('deferred', function () {
        objects.flushStrings();
        destroyPending();
    });
})(this);
