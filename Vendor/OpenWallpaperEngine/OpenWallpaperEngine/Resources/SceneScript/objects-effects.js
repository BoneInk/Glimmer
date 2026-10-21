'use strict';
// SceneScript object model, part 3 of 6: `IEffect` and `IMaterial`. An effect's `visible` lives in
// the effect buffer; material constants live in the constant pool (read by getters) and every
// write is also a command, so the renderer applies it even to a constant the description left out.
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    const OP = objects.OP;
    const effectBuffer = objects.effects;
    const pool = objects.constants;

    // The components of a `Number|Vec2|Vec3|Vec4` argument: a number, or the numeric x, y, z, w
    // prefix of a vector (at least x and y). Undefined for anything else.
    function valueComponents(value) {
        if (typeof value === 'number') return [value];
        if (value === null || typeof value !== 'object') return undefined;
        const keys = ['x', 'y', 'z', 'w'];
        const out = [];
        for (let i = 0; i < 4 && typeof value[keys[i]] === 'number'; i++) out.push(value[keys[i]]);
        return out.length >= 2 ? out : undefined;
    }

    function readConstant(t, entry) {
        const i = entry.offset;
        switch (entry.count) {
        case 1: return t[i];
        case 2: return objects.vec2(t[i], t[i + 1]);
        case 3: return objects.vec3(t[i], t[i + 1], t[i + 2]);
        default: return objects.vec4(t[i], t[i + 1], t[i + 2], t[i + 3]);
        }
    }

    // Writes `values` into the pool entry: a single number fills every component.
    function writeConstant(t, entry, values) {
        for (let k = 0; k < entry.count; k++) {
            const v = values.length === 1 ? values[0] : values[k];
            if (typeof v === 'number') t[entry.offset + k] = v;
        }
    }

    // Whether writing `values` would leave the pool entry as it is (the pool is Float32).
    function holds(t, entry, values) {
        for (let k = 0; k < entry.count; k++) {
            const v = values.length === 1 ? values[0] : values[k];
            if (typeof v === 'number' && Math.fround(v) !== t[entry.offset + k]) return false;
        }
        return true;
    }

    // IMaterial: one pass of an effect. Its shader constants are members by their scene.json key
    // (`thisObject.multiply`, `thisObject['Bar Color']`), read from the pool and written through
    // `setMaterialProperty`.
    class Material {
        constructor(effect, index, record) {
            Object.defineProperty(this, '_effect', { value: effect });
            Object.defineProperty(this, '_index', { value: index });
            Object.defineProperty(this, '_record', { value: record });
            Object.defineProperty(this, '_t', { value: pool.values, writable: true });
            Object.defineProperty(this, '_dead', { value: false, writable: true });
            const constants = new Map();
            for (let i = 0; i < record.constants.length; i++) {
                const c = record.constants[i];
                constants.set(c.name, { offset: c.offset, count: c.count });
            }
            Object.defineProperty(this, '_constants', { value: constants });
            // Constants a write already reached the renderer for: rewriting one with the value it
            // holds changes nothing, so no command is sent (a bound constant's script returns
            // every frame).
            Object.defineProperty(this, '_sent', { value: new Set() });
            constants.forEach(function (entry, name) {
                if (name in Material.prototype) return;
                Object.defineProperty(this, name, {
                    configurable: true,
                    enumerable: true,
                    get: function () { return readConstant(this._t, this._constants.get(name)); },
                    set: function (value) {
                        const c = objects.components(value, this._constants.get(name).count);
                        if (c !== undefined) this._write(name, c);
                    },
                });
            }, this);
        }

        getAnimation(name) { return objects.resolveAnimation(this, this._record.animations, name); }

        // The constant's current value (number or VecN), or undefined when the material has none.
        getMaterialProperty(name) {
            const entry = this._constants.get(String(name));
            return entry === undefined ? undefined : readConstant(this._t, entry);
        }

        setMaterialProperty(name, value) {
            const values = valueComponents(value);
            if (values !== undefined) this._write(String(name), values);
        }
    }
    objects.defineMethod(Material.prototype, '_write', function (key, values) {
        const entry = this._constants.get(key);
        if (entry !== undefined) {
            if (this._sent.has(key) && holds(this._t, entry, values)) return;
            writeConstant(this._t, entry, values);
        }
        const layer = this._effect._layer;
        if (this._dead || layer._dead) return;
        if (entry === undefined) {
            objects.push(OP.setMaterialProperty, layer._slot, [this._effect._index, this._index].concat(values), [key]);
            return;
        }
        // A declared constant is named by its pool offset: no string crosses to Swift.
        objects.push(OP.setMaterialConstant, layer._slot, constantArguments(this._effect._index, this._index, entry, values));
        this._sent.add(key);
    });

    function constantArguments(effect, material, entry, values) {
        const numbers = [effect, material, entry.offset];
        for (let k = 0; k < values.length; k++) numbers.push(values[k]);
        return numbers;
    }

    // IEffect: one entry of a layer's `effects`.
    class Effect {
        constructor(layer, record) {
            Object.defineProperty(this, '_layer', { value: layer });
            Object.defineProperty(this, '_index', { value: record.index });
            Object.defineProperty(this, '_record', { value: record });
            Object.defineProperty(this, '_name', { value: String(record.name), writable: true });
            objects.attach(this, effectBuffer.values, record.slot, effectBuffer.dirty, record.slot);
            const materials = [];
            for (let i = 0; i < record.materials.length; i++) materials.push(new Material(this, i, record.materials[i]));
            Object.defineProperty(this, '_materials', { value: materials });
        }

        get name() { return this._name; }
        set name(value) { if (typeof value === 'string') this._name = value; }

        getMaterial(index) {
            const material = typeof index === 'number' ? this._materials[Math.floor(index)] : undefined;
            return material === undefined ? null : material;
        }

        getMaterialCount() { return this._materials.length; }

        // "Set a property value on all materials used by this effect that have a matching property."
        setMaterialProperty(name, value) {
            const values = valueComponents(value);
            if (values === undefined) return;
            const key = String(name);
            let changes = false, first;
            for (let i = 0; i < this._materials.length; i++) {
                const material = this._materials[i];
                const entry = material._constants.get(key);
                if (entry === undefined) continue;
                if (first === undefined) first = entry;
                if (!material._sent.has(key) || !holds(material._t, entry, values)) changes = true;
                writeConstant(material._t, entry, values);
            }
            // Unchanged everywhere it was sent before: nothing to tell the renderer.
            if ((first !== undefined && !changes) || this._dead) return;
            if (first === undefined) {
                objects.push(OP.setMaterialProperty, this._layer._slot, [this._index, -1].concat(values), [key]);
            } else {
                objects.push(OP.setMaterialConstant, this._layer._slot, constantArguments(this._index, -1, first, values));
            }
            for (let i = 0; i < this._materials.length; i++) {
                if (this._materials[i]._constants.has(key)) this._materials[i]._sent.add(key);
            }
        }

        executeMaterialFunction(name) {
            if (this._dead) return;
            objects.push(OP.executeMaterialFunction, this._layer._slot, [this._index], [String(name)]);
        }

        getAnimation(name) { return objects.resolveAnimation(this, this._record.animations, name); }
    }
    objects.defineField(Effect.prototype, 'visible', 0, 'bool', false);

    // Detaches an effect whose layer was destroyed: its materials keep their last values.
    objects.detachEffect = function (effect) {
        objects.detach(effect, 1);
        objects.forgetAnimations(effect._record.animations);
        for (let i = 0; i < effect._materials.length; i++) {
            const material = effect._materials[i];
            let size = 0;
            material._constants.forEach(function (entry) { size += entry.count; });
            const snapshot = new Float32Array(size);
            let offset = 0;
            material._constants.forEach(function (entry) {
                for (let k = 0; k < entry.count; k++) snapshot[offset + k] = material._t[entry.offset + k];
                entry.offset = offset;
                offset += entry.count;
            });
            material._t = snapshot;
            material._dead = true;
            objects.forgetAnimations(material._record.animations);
        }
    };

    objects.Effect = Effect;
    objects.Material = Material;
})(this);
