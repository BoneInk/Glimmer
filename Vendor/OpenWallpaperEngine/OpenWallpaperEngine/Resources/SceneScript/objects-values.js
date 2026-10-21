'use strict';
// SceneScript object model, part 1 of 6 (docs/scenescript-plan.md WP7): the `__rt.objects`
// namespace, value conversion and generated accessors over the shared tables.
// SceneScriptObjectModel.swift installed
// `__rt.native.objects` (tables, field lists, opcodes, native functions) before this file runs.
(function (global) {
    const rt = global.__rt;
    const native = rt.native.objects;
    const DEG2RAD = Math.PI / 180;
    // Radians → degrees in float, like WE's C++: exactly 90, 45, 180, 360 for their Float32 radians.
    const RAD2DEG_F = Math.fround(180 / Math.PI);
    function toDegrees(radians) { return Math.fround(radians * RAD2DEG_F); }
    // WE's classes from baseclasses.js (global lexical bindings, not properties of `global`).
    const HAS_VEC = typeof Vec3 === 'function' && typeof Vec2 === 'function';

    const objects = {
        OP: native.opcodes,
        table: rt.table,
        effects: native.effects,
        constants: native.constants,
        animations: native.animations,
        animationLayout: native.animationLayout,
        sceneBuffer: native.scene,
        // Script id → {kind, slot, effect, material, property} (SceneScriptObjectBinding).
        bindings: new Map(),
        // Extension points for later packages (WP12 replaces `animation` to return timeline-backed
        // objects; the default returns `Animation`/`TextureAnimation` over the animation buffer).
        hooks: {},
    };

    // MARK: vectors (WE's own classes, so WEVector/WEMath and the Vec methods work on them)

    objects.vec2 = function (x, y) { return HAS_VEC ? new Vec2(x, y) : { x: x, y: y }; };
    objects.vec3 = function (x, y, z) { return HAS_VEC ? new Vec3(x, y, z) : { x: x, y: y, z: z }; };
    objects.vec4 = function (x, y, z, w) {
        return typeof Vec4 === 'function' ? new Vec4(x, y, z, w) : { x: x, y: y, z: z, w: w };
    };
    objects.mat4 = function (m) { return typeof Mat4 === 'function' ? new Mat4(m) : { m: m }; };
    objects.mat3 = function () { return typeof Mat3 === 'function' ? new Mat3() : { m: [1, 0, 0, 0, 1, 0, 0, 0, 1] }; };

    // MARK: conversion (plan §1.9 P3)

    // WE's property converter: a number for numbers (NaN passes and is written), a boolean or number
    // for flags, numeric x/y(/z) for vectors with a bare number broadcast to every component.
    // Anything else leaves the property unchanged (undefined here). Angles convert to radians.
    function components(value, count) {
        if (typeof value === 'number') {
            const out = new Array(count);
            for (let i = 0; i < count; i++) out[i] = value;
            return out;
        }
        if (value === null || typeof value !== 'object') return undefined;
        const keys = ['x', 'y', 'z', 'w'];
        const out = new Array(count);
        for (let i = 0; i < count; i++) {
            const component = value[keys[i]];
            if (typeof component !== 'number') return undefined;
            out[i] = component;
        }
        return out;
    }
    objects.components = components;

    // `type` is a field type from SceneScriptObjectField/SceneScriptSceneField. Returns the stored
    // (table-unit) components, or undefined when WE would reject the value.
    objects.convert = function (type, value) {
        switch (type) {
        case 'number': return typeof value === 'number' ? [value] : undefined;
        case 'bool':
            if (typeof value === 'boolean') return [value ? 1 : 0];
            if (typeof value === 'number') return [value !== 0 ? 1 : 0];
            return undefined;
        case 'vec2': return components(value, 2);
        case 'vec3': return components(value, 3);
        case 'degrees': {
            const c = components(value, 3);
            return c === undefined ? undefined : [c[0] * DEG2RAD, c[1] * DEG2RAD, c[2] * DEG2RAD];
        }
        default: return undefined;
        }
    };

    // Reads the script value of a field of `type` at `t[i]`: vectors are fresh copies (WE).
    objects.read = function (type, t, i) {
        switch (type) {
        case 'number': return t[i];
        case 'bool': return t[i] !== 0;
        case 'vec2': return objects.vec2(t[i], t[i + 1]);
        case 'vec3': return objects.vec3(t[i], t[i + 1], t[i + 2]);
        case 'degrees': return objects.vec3(toDegrees(t[i]), toDegrees(t[i + 1]), toDegrees(t[i + 2]));
        default: return undefined;
        }
    };

    // Angles are degrees at the API and Float32 radians in the table, so a plain round trip turns
    // 90 into 89.99999… or 90.0000025 and `angles.z += 0.36` drifts (SF13, S15). The degrees a
    // script wrote stay authoritative while the stored radians are the ones that write produced;
    // radians anyone else wrote (the renderer, an animation) convert in float.
    function readDegrees(owner, offset, t, i) {
        const cached = owner._deg === undefined ? undefined : owner._deg[offset];
        if (cached !== undefined && cached.r[0] === t[i] && cached.r[1] === t[i + 1] && cached.r[2] === t[i + 2]) {
            return objects.vec3(cached.d[0], cached.d[1], cached.d[2]);
        }
        return objects.read('degrees', t, i);
    }

    // Updates the remembered entry in place: an `angles` script writes every frame.
    function rememberDegrees(owner, offset, x, y, z, t, i) {
        if (owner._deg === undefined) Object.defineProperty(owner, '_deg', { value: {} });
        let entry = owner._deg[offset];
        if (entry === undefined) {
            entry = { d: [0, 0, 0], r: [0, 0, 0] };
            owner._deg[offset] = entry;
        }
        entry.d[0] = x; entry.d[1] = y; entry.d[2] = z;
        entry.r[0] = t[i]; entry.r[1] = t[i + 1]; entry.r[2] = t[i + 2];
    }

    // Accessors per field type. They run for every field every script reads or writes, every
    // frame, so each is a small function of its own that writes the table directly: no
    // intermediate arrays, no switch on the type. The rules are `objects.convert`'s.
    function getter(type, offset) {
        switch (type) {
        case 'number': return function () { return this._t[this._base + offset]; };
        case 'bool': return function () { return this._t[this._base + offset] !== 0; };
        case 'vec2': return function () { const t = this._t, i = this._base + offset; return objects.vec2(t[i], t[i + 1]); };
        case 'vec3': return function () {
            const t = this._t, i = this._base + offset;
            return objects.vec3(t[i], t[i + 1], t[i + 2]);
        };
        case 'degrees': return function () { return readDegrees(this, offset, this._t, this._base + offset); };
        default: return function () { return undefined; };
        }
    }

    function setter(type, offset) {
        switch (type) {
        case 'number': return function (value) {
            if (this._dead || typeof value !== 'number') return;
            this._t[this._base + offset] = value;
            this._d[this._di] = 1;
        };
        case 'bool': return function (value) {
            if (this._dead) return;
            let flag;
            if (typeof value === 'boolean') flag = value ? 1 : 0;
            else if (typeof value === 'number') flag = value !== 0 ? 1 : 0;
            else return;
            this._t[this._base + offset] = flag;
            this._d[this._di] = 1;
        };
        case 'vec2': return function (value) {
            if (this._dead) return;
            let x, y;
            if (typeof value === 'number') {
                x = value; y = value;
            } else {
                if (value === null || typeof value !== 'object') return;
                x = value.x;
                if (typeof x !== 'number') return;
                y = value.y;
                if (typeof y !== 'number') return;
            }
            const t = this._t, i = this._base + offset;
            t[i] = x; t[i + 1] = y;
            this._d[this._di] = 1;
        };
        case 'vec3':
        case 'degrees': {
            const degrees = type === 'degrees';
            return function (value) {
                if (this._dead) return;
                let x, y, z;
                if (typeof value === 'number') {
                    x = value; y = value; z = value;
                } else {
                    if (value === null || typeof value !== 'object') return;
                    x = value.x;
                    if (typeof x !== 'number') return;
                    y = value.y;
                    if (typeof y !== 'number') return;
                    z = value.z;
                    if (typeof z !== 'number') return;
                }
                const t = this._t, i = this._base + offset;
                if (degrees) {
                    t[i] = x * DEG2RAD; t[i + 1] = y * DEG2RAD; t[i + 2] = z * DEG2RAD;
                    rememberDegrees(this, offset, x, y, z, t, i);
                } else {
                    t[i] = x; t[i + 1] = y; t[i + 2] = z;
                }
                this._d[this._di] = 1;
            };
        }
        default: return function (value) {};
        }
    }

    // Defines `name` on `proto` over a shared buffer. Instances carry `_t` (the Float32Array),
    // `_base` (their first float), `_d` (the dirty bytes) and `_di` (their dirty index); a
    // destroyed layer points them at a private snapshot, so a stale reference never touches a
    // reused slot. A read-only field ignores writes, like the rest of WE's inert members.
    objects.defineField = function (proto, name, offset, type, readOnly) {
        Object.defineProperty(proto, name, {
            configurable: true,
            enumerable: true,
            get: getter(type, offset),
            set: readOnly ? function (value) {} : setter(type, offset),
        });
    };

    // Gives `target` the non-enumerable internals `defineField` reads, over `count` floats of `t`
    // from `base`, dirty byte `d[di]`.
    objects.attach = function (target, t, base, d, di) {
        Object.defineProperty(target, '_t', { value: t, writable: true });
        Object.defineProperty(target, '_base', { value: base, writable: true });
        Object.defineProperty(target, '_d', { value: d, writable: true });
        Object.defineProperty(target, '_di', { value: di, writable: true });
        Object.defineProperty(target, '_dead', { value: false, writable: true });
    };

    // Points `target` at a private copy of its `count` floats: it keeps its last values, and
    // writes and commands through it do nothing (Swift reuses the slot).
    objects.detach = function (target, count) {
        if (target._dead) return;
        const snapshot = new Float32Array(count);
        for (let i = 0; i < count; i++) snapshot[i] = target._t[target._base + i];
        target._t = snapshot;
        target._base = 0;
        target._d = new Uint8Array(1);
        target._di = 0;
        target._dead = true;
    };

    objects.defineMethod = function (proto, name, fn) {
        Object.defineProperty(proto, name, { configurable: true, enumerable: false, writable: true, value: fn });
    };

    // MARK: commands

    objects.push = function (opcode, target, numbers, strings) {
        return rt.push(opcode, target, numbers, strings);
    };

    Object.defineProperty(rt, 'objects', { value: objects, enumerable: false, writable: false, configurable: false });
})(this);
