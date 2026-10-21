'use strict';
// SceneScript model data (lib.sceneScript.d.ts `IScene.createModelData`, `IModelData`): geometry a
// script builds, shown by a model layer made with `thisScene.createLayer({model: modelData})`.
// scenescript64.dll parses the configuration (0x18162fd40), hands it to the engine and sets the
// object's `__modelDataToken` (0x1816362d9…0x1816365ea), which WE's `IModelData.toConfigString`
// (baseclasses.js) writes into the layer's configuration as its `model`. The messages are the DLL's.
// The native side keeps the data per wallpaper instance (SceneScriptModelDataStore).
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    const native = rt.native.objects;
    const IModelData = global.IModelData;
    // WE's baseclasses.js defines the class; without it (logged at load) there is no model data.
    if (typeof IModelData !== 'function') return;
    const FORMAT = ['position', 'normal', 'tangentSigned', 'uv', 'color'];
    const FLOATS = { position: 3, normal: 3, tangentSigned: 4, uv: 2, color: 4 };

    function fail(message) { throw new Error(message); }

    function isIndexBuffer(value) { return value instanceof Uint16Array || value instanceof Uint32Array; }

    // `configuration.shapes`, or for `applyData`/`replaceData` also an array of shapes or one shape.
    function shapeList(configuration, acceptsBare) {
        if (configuration !== null && typeof configuration === 'object' && Array.isArray(configuration.shapes)) {
            return configuration.shapes;
        }
        if (!acceptsBare) return null;
        if (Array.isArray(configuration)) return configuration;
        if (configuration !== null && typeof configuration === 'object') return [configuration];
        return null;
    }

    // A shape configuration checked as the DLL checks it, in the form the native side takes.
    function shape(config) {
        if (config === null || typeof config !== 'object') fail('Shapes missing.');
        if (!(config.vertexBuffer instanceof Float32Array)) fail('Vertex buffer missing.');
        if (!Array.isArray(config.vertexFormat) || config.vertexFormat.length === 0) fail('Vertex format missing.');
        let last = -1, stride = 0;
        config.vertexFormat.forEach(function (name) {
            const index = FORMAT.indexOf(name);
            if (index <= last) fail('Vertex format in incorrect order.');
            last = index;
            stride += FLOATS[name];
        });
        if (config.vertexBuffer.length % stride !== 0) fail('Inconsistent vertex buffer size');
        if (config.indexBuffer !== undefined && config.indexBuffer !== null && !isIndexBuffer(config.indexBuffer)) {
            fail('Incorrect index buffer type');
        }
        const material = config.material;
        if (material === undefined || material === null) fail('Material missing.');
        const path = typeof material === 'string' ? material
            : (typeof material.toConfigString === 'function' ? String(material.toConfigString()) : null);
        if (path === null || path === '') fail('Material missing.');
        const workshop = objects.AssetHandle && material instanceof objects.AssetHandle ? material._workshopID() : '';
        return {
            vertexBuffer: config.vertexBuffer,
            indexBuffer: isIndexBuffer(config.indexBuffer) ? config.indexBuffer : undefined,
            vertexFormat: config.vertexFormat.slice(),
            material: path,
            workshop: workshop,
            dynamicVertices: config.isVertexBufferDynamic === true,
            dynamicIndices: config.isIndexBufferDynamic === true,
        };
    }

    function bounds(configuration) {
        const low = objects.components(configuration.boundingBoxMins, 3);
        const high = objects.components(configuration.boundingBoxMaxs, 3);
        return low === undefined || high === undefined ? null : low.concat(high);
    }

    // What the object keeps of each shape: the checked form, its buffers copied (a later
    // `replaceData` passes only what changes).
    function kept(shapes) {
        return shapes.map(function (s) {
            return Object.assign({}, s, {
                vertexBuffer: s.vertexBuffer.slice(),
                indexBuffer: s.indexBuffer === undefined ? undefined : s.indexBuffer.slice(),
            });
        });
    }

    function tokenOf(data) {
        const token = data.__modelDataToken;
        if (typeof token !== 'number') fail('Invalid model data token');
        return token;
    }

    function create(configuration) {
        const list = configuration === null || typeof configuration !== 'object' ? null : shapeList(configuration, false);
        if (list === null || list.length === 0) fail('Shapes missing.');
        const shapes = list.map(shape);
        const box = bounds(configuration);
        const token = native.createModelData(shapes, box);
        if (typeof token !== 'number') fail(String(token));
        const data = new IModelData();
        Object.defineProperty(data, '__modelDataToken', { value: token, enumerable: false });
        Object.defineProperty(data, '_shapes', { value: kept(shapes), writable: true, enumerable: false });
        Object.defineProperty(data, '_bounds', { value: box, writable: true, enumerable: false });
        return data;
    }

    // MARK: IScene

    objects.defineMethod(objects.Scene.prototype, 'createModelData', function (configuration) {
        rt.forbidGlobalScope('createModelData');
        return create(configuration);
    });

    objects.defineMethod(objects.Scene.prototype, 'destroyModelData', function (data) {
        rt.forbidGlobalScope('destroyModelData');
        if (!(data instanceof IModelData)) return;
        native.destroyModelData(tokenOf(data));
    });

    // MARK: IModelData

    // The format constants on instances too, as the typings declare them.
    FORMAT.forEach(function (name) {
        const key = name === 'tangentSigned' ? 'TANGENT_SIGNED' : name.toUpperCase();
        Object.defineProperty(IModelData.prototype, key, { value: name, enumerable: false });
    });

    // New contents for the dynamic buffers, as large as before or smaller; only what is passed
    // changes ("You should only pass the options that you intend to update").
    objects.defineMethod(IModelData.prototype, 'applyData', function (configuration) {
        const token = tokenOf(this);
        const list = shapeList(configuration, true);
        if (list === null) return;
        if (list.length > this._shapes.length) fail('Cannot add shapes in IModelData.update');
        const self = this;
        const updates = list.map(function (update, index) {
            if (update === null || typeof update !== 'object' || update.vertexBuffer === null || update.indexBuffer === null) {
                fail('Cannot delete shape or buffers in IModelData.update');
            }
            const shape = self._shapes[index];
            if (update.material !== undefined) {
                const path = typeof update.material === 'string' ? update.material
                    : (update.material && typeof update.material.toConfigString === 'function'
                        ? String(update.material.toConfigString()) : null);
                if (path !== shape.material) fail('Material cannot be changed in IModelData.update');
            }
            if (update.vertexFormat !== undefined
                && (!Array.isArray(update.vertexFormat) || update.vertexFormat.join() !== shape.vertexFormat.join())) {
                fail('Vertex format cannot be changed in IModelData.update');
            }
            if (update.vertexBuffer !== undefined && !(update.vertexBuffer instanceof Float32Array)) fail('Vertex buffer missing.');
            if (update.indexBuffer !== undefined && !isIndexBuffer(update.indexBuffer)) fail('Incorrect index buffer type');
            return { vertexBuffer: update.vertexBuffer, indexBuffer: update.indexBuffer };
        });
        const failure = native.applyModelData(token, updates);
        if (failure) fail(failure);
    });

    // Other, possibly incompatible data under the same object; not from `update`.
    objects.defineMethod(IModelData.prototype, 'replaceData', function (configuration) {
        const token = tokenOf(this);
        if (rt.callback === 'update') fail('IModelData.replace cannot be called in update.');
        const list = shapeList(configuration, true);
        if (list === null) return;
        const self = this;
        const merged = [];
        const count = Math.max(list.length, this._shapes.length);
        for (let index = 0; index < count; index++) {
            const change = index < list.length ? list[index] : undefined;
            if (change === null) continue; // deletes the shape
            const previous = self._shapes[index];
            if (change === undefined) {
                if (previous !== undefined) merged.push(previous);
                continue;
            }
            const config = previous === undefined ? {} : {
                vertexBuffer: previous.vertexBuffer, indexBuffer: previous.indexBuffer, vertexFormat: previous.vertexFormat,
                material: previous.material, isVertexBufferDynamic: previous.dynamicVertices,
                isIndexBufferDynamic: previous.dynamicIndices,
            };
            Object.keys(change).forEach(function (key) {
                config[key] = change[key] === null ? undefined : change[key];
            });
            const made = shape(config);
            if (change.material === undefined && previous !== undefined) made.workshop = previous.workshop;
            merged.push(made);
        }
        if (merged.length === 0) fail('Shapes missing.');
        const box = configuration !== null && typeof configuration === 'object' && !Array.isArray(configuration)
            && configuration.boundingBoxMins !== undefined ? bounds(configuration) : this._bounds;
        const failure = native.replaceModelData(token, merged, box);
        if (failure) fail(failure);
        this._shapes = kept(merged);
        this._bounds = box;
    });
})(this);
