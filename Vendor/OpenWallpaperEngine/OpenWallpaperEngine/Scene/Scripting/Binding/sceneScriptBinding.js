'use strict';
// Property binding (docs/scenescript-plan.md WP8; SceneScriptBindingExtension.swift): the value a
// bound script's `init(value)`/`update(value)` receive, WE's converter for what they return, and
// user property changes of bound values and script properties.
(function (global) {
    const rt = global.__rt;
    // Script id → {path, type, user, scriptUsers} (SceneScriptBoundProperty).
    const sites = new Map();
    const KEYS = ['x', 'y', 'z', 'w'];
    const COMPONENTS = { vec2: 2, vec3: 3, degrees: 3, vec4: 4 };

    // WE's own classes from baseclasses.js (global lexical bindings, not properties of `global`).
    function vector(count, c) {
        switch (count) {
        case 2: return typeof Vec2 === 'function' ? new Vec2(c[0], c[1]) : { x: c[0], y: c[1] };
        case 3: return typeof Vec3 === 'function' ? new Vec3(c[0], c[1], c[2]) : { x: c[0], y: c[1], z: c[2] };
        default:
            return typeof Vec4 === 'function' ? new Vec4(c[0], c[1], c[2], c[3]) : { x: c[0], y: c[1], z: c[2], w: c[3] };
        }
    }

    // MARK: WE's converter (scenescript64.dll 0x181620e10; plan §1.9 P3, SceneScriptPropertyType)

    // The value a property of `type` takes from `value`, as a fresh value the script can't alias,
    // or undefined when the converter rejects it (the property keeps its value).
    function convert(type, value) {
        switch (type) {
        case 'number': return typeof value === 'number' ? value : undefined;
        case 'bool': return typeof value === 'boolean' ? value : undefined;
        case 'string':
            if (value === null || value === undefined || typeof value === 'symbol') return undefined;
            return String(value);
        default: {
            // Components read in order, the first non-number rejects (as the DLL's checks do);
            // no intermediate array, since this runs for every bound vector every frame.
            const count = COMPONENTS[type];
            if (count === undefined) return undefined;
            if (typeof value === 'number') return vector4(count, value, value, value, value);
            if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return undefined;
            const x = value.x;
            if (typeof x !== 'number') return undefined;
            const y = value.y;
            if (typeof y !== 'number') return undefined;
            if (count === 2) return vector4(2, x, y, 0, 0);
            const z = value.z;
            if (typeof z !== 'number') return undefined;
            if (count === 3) return vector4(3, x, y, z, 0);
            const w = value.w;
            if (typeof w !== 'number') return undefined;
            return vector4(4, x, y, z, w);
        }
        }
    }

    function vector4(count, x, y, z, w) {
        switch (count) {
        case 2: return typeof Vec2 === 'function' ? new Vec2(x, y) : { x: x, y: y };
        case 3: return typeof Vec3 === 'function' ? new Vec3(x, y, z) : { x: x, y: y, z: z };
        default: return typeof Vec4 === 'function' ? new Vec4(x, y, z, w) : { x: x, y: y, z: z, w: w };
        }
    }

    // A stored value handed to a script: vectors as fresh copies, so a script that changes its
    // argument without returning it changes nothing (test-risks S7).
    function copy(type, value) {
        const count = COMPONENTS[type];
        if (count === undefined || value === null || typeof value !== 'object') return value;
        const c = new Array(count);
        for (let i = 0; i < count; i++) c[i] = typeof value[KEYS[i]] === 'number' ? value[KEYS[i]] : 0;
        return vector(count, c);
    }

    // A user property's raw value in WE's scene forms (SceneScriptSceneValue.swift): a flag, a
    // number, vector text ("1 0.5 0", one number fills every component), text. With a condition,
    // a flag is whether the value's text equals it.
    function fromScene(type, raw, condition) {
        if (condition !== undefined && condition !== null && type === 'bool') return String(raw) === String(condition);
        switch (type) {
        case 'bool':
            if (typeof raw === 'boolean') return raw;
            if (typeof raw === 'number') return raw !== 0;
            if (raw === 'true' || raw === '1') return true;
            if (raw === 'false' || raw === '0') return false;
            return undefined;
        case 'string':
            return raw === null || raw === undefined ? undefined : String(raw);
        default: {
            const numbers = typeof raw === 'number' ? [raw]
                : typeof raw === 'boolean' ? [raw ? 1 : 0]
                    : typeof raw === 'string' ? raw.trim().split(/[\s,]+/).map(Number) : [];
            if (numbers.length === 0 || numbers.some(function (n) { return n !== n; })) return undefined;
            if (type === 'number') return numbers[0];
            const count = COMPONENTS[type];
            if (count === undefined) return undefined;
            const c = new Array(count);
            for (let i = 0; i < count; i++) c[i] = numbers.length === 1 ? numbers[0] : (i < numbers.length ? numbers[i] : 0);
            return vector(count, c);
        }
        }
    }

    // MARK: the bound property in the object model

    // How the property is read and written: a member of an object-model object, a material's
    // constant, or a field only its bound script writes (`size`, objects-layers.js).
    const MEMBER = 0, MATERIAL = 1, BOUND_ONLY = 2;
    // A record whose property isn't a member of the object model (the record's own value is the
    // property's value).
    const NOT_A_MEMBER = { mode: -1, object: null, key: '', owner: null };

    // The property's access for `record`, or null (the record keeps the value). Called twice per
    // bound script per frame, so it is cached on the record while its object stands: a destroyed
    // layer is detached (`_dead`) and its scripts go with it.
    function member(record) {
        const cached = record.access;
        if (cached !== undefined && (cached.owner === null || !cached.owner._dead)) {
            return cached === NOT_A_MEMBER ? null : cached;
        }
        const found = resolve(record);
        if (found !== undefined) record.access = found;
        return found === undefined || found === NOT_A_MEMBER ? null : found;
    }

    // The access, NOT_A_MEMBER, or undefined while the target is missing (not cached).
    function resolve(record) {
        const objects = rt.objects;
        const binding = record.binding;
        if (!objects || binding === null || binding === undefined) return NOT_A_MEMBER;
        const target = objects.bindingTarget(binding);
        if (target === null || target === undefined) return undefined;
        const owner = binding.kind === 'scene' ? null : objects.bySlot.get(binding.slot) || null;
        const property = String(binding.property);
        if (binding.kind === 'material') return { mode: MATERIAL, object: target, key: property, owner: owner };
        let object = target, key = property;
        if (binding.kind === 'layer' && property.indexOf('instanceoverride.') === 0) {
            object = target.instance;
            key = property.slice('instanceoverride.'.length);
        }
        if (object === null || object === undefined) return NOT_A_MEMBER;
        // Fields only a bound script sets (`size`, a light's `intensity`, the scene's `bloomhdr*`),
        // whether or not they are members.
        if (object === target && typeof objects.isBoundOnly === 'function' && objects.isBoundOnly(key, object)) {
            return { mode: BOUND_ONLY, object: object, key: key, owner: owner };
        }
        if (!(key in object) || typeof object[key] === 'function') return NOT_A_MEMBER;
        return { mode: MEMBER, object: object, key: key, owner: owner };
    }

    function read(access) {
        switch (access.mode) {
        case MATERIAL: return access.object.getMaterialProperty(access.key);
        case BOUND_ONLY: return rt.objects.readBound(access.object, access.key);
        default: return access.object[access.key];
        }
    }

    function write(access, value) {
        switch (access.mode) {
        case MATERIAL:
            access.object.setMaterialProperty(access.key, typeof value === 'boolean' ? (value ? 1 : 0) : value);
            break;
        case BOUND_ONLY:
            rt.objects.writeBound(access.object, access.key, value);
            break;
        default:
            access.object[access.key] = value;
        }
    }

    function assign(record, value) {
        const access = member(record);
        if (access !== null) write(access, value);
        record.value = value;
    }

    // MARK: hooks

    rt.hooks.argument = function (record) {
        const site = sites.get(record.id);
        if (site === undefined) return record.value;
        const access = member(record);
        if (access !== null) {
            const live = read(access);
            if (live !== undefined) return live;
        }
        return copy(site.type, record.value);
    };

    rt.hooks.coerce = function (record, returned) {
        const site = sites.get(record.id);
        if (site === undefined) return returned;
        const value = convert(site.type, returned);
        if (value === undefined) return undefined;
        const access = member(record);
        if (access !== null) write(access, value);
        return value;
    };

    // Before `applyUserProperties(changed)`: values bound to a changed property take its value,
    // and script properties bound to one are injected through WE's `_Internal.updateScriptProperties`
    // into scripts that finished evaluating.
    const userPropertiesChanged = rt.hooks.userPropertiesChanged;
    rt.hooks.userPropertiesChanged = function (changed) {
        userPropertiesChanged(changed);
        if (changed === null || typeof changed !== 'object') return;
        const records = rt.records.slice();
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            const site = sites.get(record.id);
            if (site === undefined || !record.enabled) continue;
            if (site.user && Object.prototype.hasOwnProperty.call(changed, site.user.name)) {
                const value = fromScene(site.type, rawValue(changed[site.user.name]), site.user.condition);
                if (value !== undefined) assign(record, value);
            }
            injectChangedScriptProperties(record, site, changed);
        }
    };

    function rawValue(entry) {
        return entry !== null && typeof entry === 'object' ? entry.value : entry;
    }

    function injectChangedScriptProperties(record, site, changed) {
        const vars = {};
        let any = false;
        Object.keys(site.scriptUsers).forEach(function (key) {
            const user = site.scriptUsers[key];
            if (!Object.prototype.hasOwnProperty.call(changed, user.name)) return;
            const raw = rawValue(changed[user.name]);
            vars[key] = user.condition !== undefined && user.condition !== null ? String(raw) === String(user.condition) : raw;
            any = true;
        });
        if (!any || !record.exports) return;
        const declared = rt.exports(record, 'scriptProperties');
        const internal = global._Internal;
        if (declared === null || typeof declared !== 'object' || !internal) return;
        rt.call(record, '<scriptProperties>', 'idle', internal.updateScriptProperties,
            [{ scriptProperties: declared }, JSON.stringify(vars)]);
    }

    // MARK: native side

    const binding = {
        // `property` is SceneScriptBoundProperty.javaScriptObject.
        bind: function (id, property) {
            sites.set(String(id), {
                path: String(property.path),
                type: String(property.type),
                user: property.user || null,
                scriptUsers: property.scriptUsers || {},
            });
        },
        convert: convert,
    };
    Object.defineProperty(rt, 'binding', { value: binding, enumerable: false, writable: false, configurable: false });
})(this);
