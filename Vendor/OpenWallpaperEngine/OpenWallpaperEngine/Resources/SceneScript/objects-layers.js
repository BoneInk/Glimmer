'use strict';
// SceneScript object model, part 4 of 6: `ILayer` and its kinds as live classes over the object
// table. `ILayer` is the union of every kind (lib.sceneScript.d.ts), so every layer has every
// member; one that does not apply to the layer's kind is inert. Numeric members are generated from
// SceneScriptObjectField's list; strings live on the object and reach the renderer as commands.
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    const OP = objects.OP;
    const table = objects.table;
    const stride = table.layout.stride;
    const fields = rt.native.objects.fields;
    // SceneScriptObjectModel.maximumEmitCount.
    const MAX_EMIT = 1000000;
    const STRINGS = ['text', 'font', 'horizontalalign', 'verticalalign', 'anchor', 'alignment'];

    // Strings written this frame, flushed as one command per (slot, field) in the deferred phase.
    const pendingStrings = new Map();
    // Layer → {field: the value the renderer has}: a flush that would send the same value again
    // sends nothing (a clock returning its text every frame relays it out once a second).
    const flushed = new WeakMap();

    function lastFlushed(layer, field) {
        const values = flushed.get(layer);
        if (values !== undefined && Object.prototype.hasOwnProperty.call(values, field)) return values[field];
        if (field === 'name') return String(layer._record.name);
        const initial = layer._record.strings[field];
        return initial === undefined ? '' : String(initial);
    }

    function writeString(layer, field, value) {
        if (value === undefined || value === null || layer._dead) return;
        layer._strings[field] = String(value);
        pendingStrings.set(layer._slot + ':' + field, { layer: layer, field: field });
    }

    // Compared at the flush, not at each write, so A → B → A within a frame sends nothing.
    objects.flushStrings = function () {
        pendingStrings.forEach(function (entry) {
            const layer = entry.layer;
            if (layer._dead) return;
            const value = entry.field === 'name' ? layer._name : layer._strings[entry.field];
            if (value === lastFlushed(layer, entry.field)) return;
            if (!objects.push(OP.setString, layer._slot, undefined, [entry.field, value])) return;
            let values = flushed.get(layer);
            if (values === undefined) {
                values = {};
                flushed.set(layer, values);
            }
            values[entry.field] = value;
        });
        pendingStrings.clear();
    };

    // IParticleSystemInstance (`thisLayer.instance`): the particle system's `instanceoverride`
    // multipliers and control points, in the layer's own table slot.
    class ParticleInstance {
        constructor(layer) {
            Object.defineProperty(this, '_layer', { value: layer });
        }
    }

    // ILayer. `record` comes from SceneScriptObjectStore: slot, kind, id, name, parentID, strings,
    // effects, textureAnimation, animations, config.
    class Layer {
        constructor(record) {
            Object.defineProperty(this, '_record', { value: record });
            Object.defineProperty(this, '_slot', { value: record.slot });
            Object.defineProperty(this, '_id', { value: record.id });
            Object.defineProperty(this, '_name', { value: String(record.name), writable: true });
            const strings = {};
            for (let i = 0; i < STRINGS.length; i++) {
                const value = record.strings[STRINGS[i]];
                strings[STRINGS[i]] = value === undefined ? '' : String(value);
            }
            Object.defineProperty(this, '_strings', { value: strings });
            Object.defineProperty(this, '_effects', { value: null, writable: true });
            Object.defineProperty(this, '_instance', { value: null, writable: true });
            objects.attach(this, table.values, record.slot * stride, table.dirty, record.slot);
        }

        get id() { return this._id; }
        set id(value) {}

        get name() { return this._name; }
        set name(value) {
            if (value === undefined || value === null || this._dead) return;
            this._name = String(value);
            pendingStrings.set(this._slot + ':name', { layer: this, field: 'name' });
        }

        get instance() {
            if (this._instance === null) this._instance = new ParticleInstance(this);
            return this._instance;
        }
        set instance(value) {}

        getAnimation(name) { return objects.resolveAnimation(this, this._record.animations, name); }

        // The world transform the renderer wrote after its last transform pass (column-major, like
        // WE's Mat4).
        getTransformMatrix() {
            const t = this._t, base = this._base + table.layout.worldMatrix;
            const m = new Array(16);
            for (let i = 0; i < 16; i++) m[i] = t[base + i];
            return objects.mat4(m);
        }

        // "Returns the current parent layer or undefined if the layer is not parented."
        getParent() {
            if (this._record.parentID === null) return undefined;
            const parent = objects.byID.get(this._record.parentID);
            return parent === undefined ? undefined : parent;
        }

        getChildren() {
            const id = this._id;
            return objects.order.filter(function (layer) { return layer._record.parentID === id; });
        }

        // IEffectLayer.getEffect(name|index): by position, or by the effect's name.
        getEffect(nameOrIndex) {
            const effects = this._effectList();
            let effect;
            if (typeof nameOrIndex === 'number') {
                effect = effects[Math.floor(nameOrIndex)];
            } else if (nameOrIndex !== undefined && nameOrIndex !== null) {
                const name = String(nameOrIndex);
                effect = effects.find(function (candidate) { return candidate.name === name; });
            }
            return effect === undefined ? null : effect;
        }

        getEffectCount() { return this._record.effects.length; }

        // The image's spritesheet animation, or null when its texture is not animated.
        getTextureAnimation() {
            const record = this._record.textureAnimation;
            return record === null || record === undefined ? null : objects.animationFor(this, record, true);
        }

        // Sound and particle playback; inert on other kinds.
        play() {}
        pause() {}
        stop() {}
        isPlaying() { return false; }
        emitParticles(count) {}
    }
    objects.defineMethod(Layer.prototype, '_effectList', function () {
        if (this._effects === null) {
            const effects = [];
            for (let i = 0; i < this._record.effects.length; i++) {
                effects.push(new objects.Effect(this, this._record.effects[i]));
            }
            this._effects = effects;
        }
        return this._effects;
    });

    // Generated numeric members (SceneScriptObjectField).
    for (let i = 0; i < fields.length; i++) {
        const field = fields[i];
        if (field.group === 'layer') {
            if (field.member) objects.defineField(Layer.prototype, field.name, field.offset, field.type, field.readOnly);
        } else if (field.group === 'instance') {
            const offset = field.offset, type = field.type;
            Object.defineProperty(ParticleInstance.prototype, field.name, {
                configurable: true,
                enumerable: true,
                get: function () { return objects.read(type, this._layer._t, this._layer._base + offset); },
                set: function (value) {
                    const layer = this._layer;
                    const c = layer._dead ? undefined : objects.convert(type, value);
                    if (c === undefined) return;
                    for (let k = 0; k < c.length; k++) layer._t[layer._base + offset + k] = c[k];
                    layer._d[layer._di] = 1;
                },
            });
        }
    }
    const PLAYING = fields.find(function (field) { return field.field === 'playing'; }).offset;

    // Fields member writes can't change (`size`: read-only in lib.sceneScript.d.ts), or that aren't
    // members at all (a light's `intensity`), but a script bound to them can: WE's native property
    // is writable (wallpaper64.exe 0x1401a4200). The property binding reads and writes them
    // through these.
    const boundOnly = {};
    fields.forEach(function (field) {
        if (field.group === 'layer' && (field.readOnly || !field.member)) boundOnly[field.name] = field;
    });
    objects.isBoundOnly = function (name) { return Object.prototype.hasOwnProperty.call(boundOnly, name); };
    objects.readBound = function (layer, name) {
        const field = boundOnly[name];
        return field === undefined ? undefined : objects.read(field.type, layer._t, layer._base + field.offset);
    };
    objects.writeBound = function (layer, name, value) {
        const field = boundOnly[name];
        if (field === undefined || layer._dead) return;
        const c = objects.convert(field.type, value);
        if (c === undefined) return;
        for (let k = 0; k < c.length; k++) layer._t[layer._base + field.offset + k] = c[k];
        layer._d[layer._di] = 1;
    };

    for (let i = 0; i < STRINGS.length; i++) {
        const field = STRINGS[i];
        Object.defineProperty(Layer.prototype, field, {
            configurable: true,
            enumerable: true,
            get: function () { return this._strings[field]; },
            set: function (value) { writeString(this, field, value); },
        });
    }

    // A puppet image's animation layers, bones, bone physics, blend shapes and attachments are
    // below; parenting and orientation are in objects-transforms.js.
    const P = Layer.prototype;

    // MARK: IVideoTexture
    //
    // An image whose texture is a video (a TEXB0004 MP4 payload) has `record.video` {duration}.
    // The texture starts playing and looping, as WE's video textures do. Its time and playing
    // state are the player's, which the renderer writes into the layer's row (`videoTime`,
    // `playing`) before every frame; a call changes them here at once, so a script reads back what
    // it did, and reaches the player as an `OP.videoTexture` command [action (play 0, pause 1,
    // stop 2, seek 3, rate 4, loop 5), value?].
    const videoTextures = [];
    class VideoTexture {
        constructor(owner, duration) {
            Object.defineProperty(this, '_owner', { value: owner });
            Object.defineProperty(this, '_duration', { value: duration });
            Object.defineProperty(this, '_state', { value: { rate: 1, loop: true, seen: 0, seeked: false } });
            Object.defineProperty(this, '_ended', { value: [] });
        }
        get duration() { return this._duration; }
        set duration(value) {}
        get rate() { return this._state.rate; }
        set rate(value) {
            if (typeof value !== 'number' || !isFinite(value)) return;
            this._state.rate = Math.max(0, value);
            this._command(4, this._state.rate);
        }
        get loop() { return this._state.loop; }
        set loop(value) {
            this._state.loop = !!value;
            this._command(5, this._state.loop ? 1 : 0);
        }
        // A finished video restarts from 0.
        play() {
            if (!this._state.loop && this.getCurrentTime() >= this._duration) this._setTime(0);
            this._setPlaying(true);
            this._command(0);
        }
        pause() { this._setPlaying(false); this._command(1); }
        stop() { this._setPlaying(false); this._setTime(0); this._command(2); }
        isPlaying() { return this._owner._t[this._owner._base + table.layout.playing] !== 0; }
        getCurrentTime() { return this._owner._t[this._owner._base + table.layout.videoTime]; }
        setCurrentTime(time) {
            if (typeof time !== 'number' || !isFinite(time)) return;
            this._setTime(Math.max(0, Math.min(time, this._duration)));
            this._command(3, this.getCurrentTime());
        }
        addEndedCallback(callback) {
            if (typeof callback === 'function') this._ended.push(callback);
        }
    }
    objects.defineMethod(VideoTexture.prototype, '_setTime', function (time) {
        this._owner._t[this._owner._base + table.layout.videoTime] = time;
        this._state.seeked = true;
    });
    objects.defineMethod(VideoTexture.prototype, '_setPlaying', function (playing) {
        this._owner._t[this._owner._base + table.layout.playing] = playing ? 1 : 0;
    });
    objects.defineMethod(VideoTexture.prototype, '_command', function (action, value) {
        if (this._owner._dead) return;
        objects.push(OP.videoTexture, this._owner._slot, value === undefined ? [action] : [action, value]);
    });
    // Once per frame, on the player's time: the end was reached when a looping video's time went
    // back without a seek, or one that doesn't loop stopped at its end. Ended callbacks run before
    // `update`, as an animation layer's do.
    objects.defineMethod(VideoTexture.prototype, '_check', function () {
        if (this._owner._dead) return;
        const state = this._state, time = this.getCurrentTime(), previous = state.seen;
        const seeked = state.seeked;
        state.seen = time;
        state.seeked = false;
        if (seeked) return;
        const ended = state.loop ? time < previous
            : !this.isPlaying() && time >= this._duration - 1e-3 && previous < this._duration - 1e-3;
        if (!ended) return;
        for (let c = 0; c < this._ended.length; c++) {
            try {
                this._ended[c].call(this);
            } catch (error) {
                rt.reportError(null, 'IVideoTexture ended callback', error);
            }
        }
    });
    rt.addPhaseHandler('animations', function () {
        for (let i = 0; i < videoTextures.length; i++) videoTextures[i]._check();
    });

    // The image's video texture, or null when its texture is not a video.
    objects.defineMethod(P, 'getVideoTexture', function () {
        const video = this._record.video;
        if (video === null || video === undefined) return null;
        if (!this._videoTexture) {
            Object.defineProperty(this, '_videoTexture', { value: new VideoTexture(this, Number(video.duration) || 0) });
            videoTextures.push(this._videoTexture);
        }
        return this._videoTexture;
    });

    // MARK: puppet and model rigs (docs/models-plan.md §2.8, §4.3 P2 and M6)
    //
    // A puppet image's or a model's record has `rig` {slot, bones, clips, layers, attachments}; its state is
    // slot `rig.slot` of the rig buffer (SceneScriptRigLayout), which the renderer's animator
    // writes before every frame. Calls change it at once, so a script reads back what it did, and
    // reach the animator as commands. Matrices are WE's Mat4 memory (column-major here, translation
    // in 12..14). The bone and attachment angles are radians, as the host's (0x14020fa10) and the
    // compiled puppet JSON's are; WE 2.8 hands scripts them unconverted (docs/models-plan.md §5.24),
    // unlike the layers' `angles`, which stay degrees.
    const rigBuffer = rt.native.objects.rigs;
    const RL = rt.native.objects.rigLayout;
    const rigValues = rigBuffer.values;
    // Keys of script-made layers; authored layers keep their scene ids.
    let nextLayerKey = 1 << 21;
    // Every layer object handed out, for `addEndedCallback`.
    const animationLayers = [];

    function rigOf(layer) { return layer._dead ? null : (layer._record.rig || null); }
    function rigBase(rig) { return rig.slot * rigBuffer.stride; }
    function rigLayerCount(rig) { return rigValues[rigBase(rig) + RL.layerCount] | 0; }
    function rigLayerBase(rig, index) { return rigBase(rig) + RL.layers + index * RL.layerStride; }
    function rigLayerIndex(rig, key) {
        const count = rigLayerCount(rig);
        for (let i = 0; i < count; i++) if (rigValues[rigLayerBase(rig, i) + RL.layerKey] === key) return i;
        return -1;
    }
    function rigNames(rig) {
        if (!rig.names) {
            rig.names = new Map();
            rig.layers.forEach(function (layer) { rig.names.set(layer.key, String(layer.name)); });
        }
        return rig.names;
    }
    // A bone given by index or name: its index, or -1.
    function rigBone(rig, bone) {
        if (typeof bone === 'number') {
            const index = Math.floor(bone);
            return index >= 0 && index < rig.bones.length ? index : -1;
        }
        if (bone === undefined || bone === null) return -1;
        const name = String(bone);
        for (let i = 0; i < rig.bones.length; i++) if (rig.bones[i].name === name) return i;
        return -1;
    }
    function rigMatrix(rig, bone, offset) {
        const base = rigBase(rig) + RL.bones + bone * RL.boneStride + offset;
        const m = new Array(16);
        for (let i = 0; i < 16; i++) m[i] = rigValues[base + i];
        return m;
    }
    function writeRigMatrix(rig, bone, offset, m) {
        const base = rigBase(rig) + RL.bones + bone * RL.boneStride + offset;
        for (let i = 0; i < 16; i++) rigValues[base + i] = m[i];
    }
    // A Mat4 (or {m}) as 16 finite numbers; undefined otherwise.
    function matrixArgument(value) {
        const m = value && Array.isArray(value.m) ? value.m : value;
        if (!Array.isArray(m) || m.length !== 16) return undefined;
        for (let i = 0; i < 16; i++) if (typeof m[i] !== 'number' || !isFinite(m[i])) return undefined;
        return m.slice();
    }
    function vectorArgument(value) {
        if (!value || typeof value !== 'object') return undefined;
        const v = [value.x, value.y, value.z];
        for (let i = 0; i < 3; i++) if (typeof v[i] !== 'number') return undefined;
        return v;
    }
    function multiply(a, b) {
        const out = new Array(16);
        for (let c = 0; c < 4; c++) {
            for (let r = 0; r < 4; r++) {
                out[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
            }
        }
        return out;
    }
    // WE's Euler extraction (0x14020fa10): z = atan2(m01, m00), y = atan2(-m02, |(m12, m22)|),
    // x = atan2(sin z·m20 − cos z·m21, cos z·m11 − sin z·m10); in radians.
    function eulerRadians(m) {
        const z = Math.atan2(m[1], m[0]);
        const y = Math.atan2(-m[2], Math.sqrt(m[6] * m[6] + m[10] * m[10]));
        const sz = Math.sin(z), cz = Math.cos(z);
        const x = Math.atan2(sz * m[8] - cz * m[9], cz * m[5] - sz * m[4]);
        return objects.vec3(x, y, z);
    }
    // `m` with its rotation replaced by R = Rz·Ry·Rx of `radians`, keeping each axis's scale and
    // the translation (the rows of 0x1401dd630).
    function withAngles(m, radians) {
        const x = radians[0], y = radians[1], z = radians[2];
        const cx = Math.cos(x), sx = Math.sin(x), cy = Math.cos(y), sy = Math.sin(y), cz = Math.cos(z), sz = Math.sin(z);
        const rows = [[cy * cz, cy * sz, -sy], [sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy],
            [cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy]];
        const out = m.slice();
        for (let r = 0; r < 3; r++) {
            const scale = Math.sqrt(m[r * 4] * m[r * 4] + m[r * 4 + 1] * m[r * 4 + 1] + m[r * 4 + 2] * m[r * 4 + 2]);
            for (let c = 0; c < 3; c++) out[r * 4 + c] = rows[r][c] * scale;
        }
        return out;
    }

    // IAnimationLayer: one layer of a puppet's animator, found by its key in the rig buffer.
    class AnimationLayer {
        constructor(owner, key) {
            Object.defineProperty(this, '_owner', { value: owner });
            Object.defineProperty(this, '_key', { value: key });
            Object.defineProperty(this, '_ended', { value: [], writable: true });
            Object.defineProperty(this, '_seenEnded', { value: 0, writable: true });
        }

        get fps() { const clip = this._clip(); return clip ? clip.fps : 0; }
        set fps(value) {}
        get frameCount() { const clip = this._clip(); return clip ? clip.frameCount : 0; }
        set frameCount(value) {}
        get duration() { const clip = this._clip(); return clip ? clip.duration : 0; }
        set duration(value) {}

        get name() {
            const rig = rigOf(this._owner);
            return rig ? (rigNames(rig).get(this._key) || '') : '';
        }
        set name(value) {
            const rig = rigOf(this._owner);
            if (rig && value !== undefined && value !== null) rigNames(rig).set(this._key, String(value));
        }

        get rate() { return this._get(RL.layerRate); }
        set rate(value) { this._write(RL.layerRate, 0, value); }
        get blend() { return this._get(RL.layerBlend); }
        set blend(value) { this._write(RL.layerBlend, 1, value); }
        get visible() { return this._get(RL.layerVisible) !== 0; }
        set visible(value) {
            if (typeof value !== 'boolean' && typeof value !== 'number') return;
            this._write(RL.layerVisible, 2, value ? 1 : 0);
        }

        // A finished clip restarts from 0; paused and finished clear.
        play() {
            const flags = this._get(RL.layerFlags) | 0;
            if ((flags & RL.flagFinished) !== 0) this._setTime(0);
            this._set(RL.layerFlags, flags & ~(RL.flagPaused | RL.flagFinished));
            this._command(0);
        }
        pause() {
            this._set(RL.layerFlags, (this._get(RL.layerFlags) | 0) | RL.flagPaused);
            this._command(1);
        }
        // Paused at 0, not finished, running forwards.
        stop() {
            this._setTime(0);
            this._set(RL.layerFlags, ((this._get(RL.layerFlags) | 0) | RL.flagPaused) & ~(RL.flagFinished | RL.flagBackwards));
            this._command(2);
        }
        isPlaying() {
            const index = this._index();
            return index >= 0 && ((this._get(RL.layerFlags) | 0) & (RL.flagPaused | RL.flagFinished)) === 0;
        }
        getFrame() { return this._get(RL.layerFrame); }
        setFrame(frame) {
            if (typeof frame !== 'number' || !isFinite(frame)) return;
            const fps = this.fps;
            if (fps > 0) this._setTime(frame / fps);
            this._command(3, frame);
        }
        // The timeline of one of the layer's own fields (`rate`, `blend`): the one named so
        // (`options.name`), else the one on the field of that key. WE's typings don't list it, but
        // 3159348391 plays its moves with `getAnimationLayer('Kick').getAnimation('go').play()` and
        // WE runs them (its blend timelines raise the move over the idle). Null for a layer a
        // script created and when the layer has no such timeline.
        getAnimation(name) {
            const rig = rigOf(this._owner);
            if (!rig || this._index() < 0 || name === undefined || name === null) return null;
            let authored = -1;
            for (let i = 0; i < rig.layers.length; i++) {
                if (rig.layers[i].key === this._key) authored = rig.layers[i].authored;
            }
            if (typeof authored !== 'number' || authored < 0) return null;
            const prefix = objects.animationLayerPrefix + authored + '.', key = String(name);
            const records = (this._owner._record.animations || []).filter(function (record) {
                return typeof record.property === 'string' && record.property.indexOf(prefix) === 0;
            });
            const found = records.find(function (record) { return record.name === key; })
                || records.find(function (record) { return record.property === prefix + key; });
            return found ? objects.animationFor(this._owner, found, false) : null;
        }
        addEndedCallback(callback) {
            if (typeof callback !== 'function') return;
            this._ended.push(callback);
            if (animationLayers.indexOf(this) < 0) {
                this._seenEnded = this._get(RL.layerEnded);
                animationLayers.push(this);
            }
        }
    }
    objects.defineMethod(AnimationLayer.prototype, '_index', function () {
        const rig = rigOf(this._owner);
        return rig ? rigLayerIndex(rig, this._key) : -1;
    });
    objects.defineMethod(AnimationLayer.prototype, '_get', function (field) {
        const index = this._index();
        return index < 0 ? 0 : rigValues[rigLayerBase(rigOf(this._owner), index) + field];
    });
    objects.defineMethod(AnimationLayer.prototype, '_set', function (field, value) {
        const index = this._index();
        if (index >= 0) rigValues[rigLayerBase(rigOf(this._owner), index) + field] = value;
    });
    objects.defineMethod(AnimationLayer.prototype, '_clip', function () {
        const rig = rigOf(this._owner), index = this._index();
        return rig && index >= 0 ? rig.clips[rigValues[rigLayerBase(rig, index) + RL.layerClip] | 0] : undefined;
    });
    objects.defineMethod(AnimationLayer.prototype, '_setTime', function (time) {
        this._set(RL.layerTime, time);
        this._set(RL.layerFrame, time * this.fps);
    });
    objects.defineMethod(AnimationLayer.prototype, '_write', function (field, code, value) {
        if (typeof value !== 'number' || this._index() < 0) return;
        this._set(field, value);
        objects.push(OP.rigLayerSet, this._owner._slot, [this._key, code, value]);
    });
    objects.defineMethod(AnimationLayer.prototype, '_command', function (action, frame) {
        if (this._index() < 0) return;
        objects.push(OP.rigLayerPlayback, this._owner._slot,
            frame === undefined ? [this._key, action] : [this._key, action, frame]);
    });

    // The one object per layer key, so repeated `getAnimationLayer` calls return the same object.
    function animationLayerFor(owner, key) {
        if (!owner._animationLayers) Object.defineProperty(owner, '_animationLayers', { value: new Map() });
        let layer = owner._animationLayers.get(key);
        if (layer === undefined) {
            layer = new AnimationLayer(owner, key);
            owner._animationLayers.set(key, layer);
        }
        return layer;
    }

    // `addEndedCallback`: once per time the renderer counted the clip's end, for the layers of
    // `owner` (every layer when undefined).
    function runEndedCallbacks(owner) {
        for (let i = 0; i < animationLayers.length; i++) {
            const layer = animationLayers[i];
            if (owner !== undefined && layer._owner !== owner) continue;
            if (layer._index() < 0) continue;
            const ended = layer._get(RL.layerEnded);
            if (ended <= layer._seenEnded) continue;
            layer._seenEnded = ended;
            for (let c = 0; c < layer._ended.length; c++) {
                try {
                    layer._ended[c].call(layer);
                } catch (error) {
                    rt.reportError(null, 'IAnimationLayer ended callback', error);
                }
            }
        }
    }

    // A clip event's `event` argument: scenescript64.dll parses the name the host passes as JSON
    // (callback 6's case, 0x18164eac2: `JSON.parse` in a TryCatch, 0x180014a00), which is how WE's
    // editor stores a clip event's name in the `.mdl` (2321732083's is
    // `{"$$hashKey":"object:752","frame":0,"name":"sword"}`). A name that isn't JSON gives
    // undefined [I: the fallback handle the DLL takes, isolate+0x378, read as `undefined`].
    function clipEvent(name) {
        try {
            return JSON.parse(name);
        } catch (error) {
            return undefined;
        }
    }

    // A puppet's or model's layers this frame (SceneScriptEvent.rigAnimation): WE's object update
    // sends each clip event the layers crossed to the object's scripts as `animationEvent`, then
    // runs the layers' ended callbacks, before the cursor pass, the media events, the timelines'
    // events and `update`.
    rt.addEventHandler('rigAnimation', rt.EVENT_ORDER.cursor - 50, function (event) {
        const owner = objects.bySlot.get(event.payload.slot);
        if (owner === undefined || owner._dead) return;
        const names = event.payload.events || [];
        for (let i = 0; i < names.length; i++) {
            const name = String(names[i]);
            objects.sendAnimationEvent(owner, function () { return clipEvent(name); });
        }
        runEndedCallbacks(owner);
    });

    // Ends counted without an event for their object (none is lost; each runs once).
    rt.addPhaseHandler('animations', function () { runEndedCallbacks(undefined); });

    // createAnimationLayer / playSingleAnimation: a clip by name (or id), or a JSON config with
    // `animation`, and the config keys (`name`, `blendin`, `blendout`, `blendtime`, `autosort`,
    // `additive`, `rate`, `blend`, `visible`). Inserted where WE's parser puts a layer.
    function createAnimationLayer(owner, animation, config, single) {
        const rig = rigOf(owner);
        if (!rig) return null;
        let options = {};
        let layerName;
        if (animation !== null && typeof animation === 'object') {
            options = Object.assign({}, animation);
            // `{animation, name}`: the clip and the layer's name; `{name}` alone names the clip.
            if (options.animation !== undefined) layerName = options.name;
            animation = options.animation !== undefined ? options.animation : options.name;
        }
        if (config !== null && typeof config === 'object') {
            options = Object.assign(options, config);
            if (config.name !== undefined) layerName = config.name;
        }
        let clip = -1;
        for (let i = 0; i < rig.clips.length && clip < 0; i++) {
            if (typeof animation === 'number' ? rig.clips[i].id === animation : rig.clips[i].name === String(animation)) clip = i;
        }
        if (clip < 0 && typeof animation === 'string') {
            for (let i = 0; i < rig.clips.length && clip < 0; i++) if (String(rig.clips[i].id) === animation) clip = i;
        }
        const count = rigLayerCount(rig);
        if (clip < 0 || count >= RL.maximumLayers) return null;
        const flag = function (name) { return options[name] ? 1 : 0; };
        const number = function (name, fallback) { return typeof options[name] === 'number' ? options[name] : fallback; };
        const key = nextLayerKey++;
        const name = layerName !== undefined && layerName !== null ? String(layerName) : rig.clips[clip].name;
        const additive = flag('additive');
        const visible = options.visible === undefined ? 1 : flag('visible');
        let position = count;
        if (options.autosort) {
            while (position > 0 && rigValues[rigLayerBase(rig, position - 1) + RL.layerAdditive] !== 0) position -= 1;
        }
        for (let i = count; i > position; i--) {
            const to = rigLayerBase(rig, i), from = rigLayerBase(rig, i - 1);
            for (let k = 0; k < RL.layerStride; k++) rigValues[to + k] = rigValues[from + k];
        }
        const base = rigLayerBase(rig, position);
        const entry = [key, clip, 0, 0, 0, number('rate', 1), number('blend', 1), visible, additive, 0];
        for (let k = 0; k < RL.layerStride; k++) rigValues[base + k] = k < entry.length ? entry[k] : 0;
        rigValues[rigBase(rig) + RL.layerCount] = count + 1;
        rigNames(rig).set(key, name);
        objects.push(OP.rigLayerCreate, owner._slot,
            [key, single ? 1 : 0, additive, flag('blendin'), flag('blendout'), flag('autosort'), number('blendtime', 0.5),
                number('rate', 1), number('blend', 1), visible], [rig.clips[clip].name, name]);
        return animationLayerFor(owner, key);
    }

    // A layer given by name, index or object: its key, or undefined.
    function animationLayerKey(owner, rig, which) {
        if (which instanceof AnimationLayer) return which._owner === owner && which._index() >= 0 ? which._key : undefined;
        const count = rigLayerCount(rig);
        if (typeof which === 'number') {
            const index = Math.floor(which);
            return index >= 0 && index < count ? rigValues[rigLayerBase(rig, index) + RL.layerKey] : undefined;
        }
        if (which === undefined || which === null) return undefined;
        const names = rigNames(rig), name = String(which);
        for (let i = 0; i < count; i++) {
            const key = rigValues[rigLayerBase(rig, i) + RL.layerKey];
            if (names.get(key) === name) return key;
        }
        return undefined;
    }

    objects.defineMethod(P, 'getAnimationLayerCount', function () {
        const rig = rigOf(this);
        return rig ? rigLayerCount(rig) : 0;
    });
    objects.defineMethod(P, 'getAnimationLayer', function (which) {
        const rig = rigOf(this);
        const key = rig ? animationLayerKey(this, rig, which) : undefined;
        return key === undefined ? null : animationLayerFor(this, key);
    });
    objects.defineMethod(P, 'createAnimationLayer', function (animation, config) {
        return createAnimationLayer(this, animation, config, false);
    });
    objects.defineMethod(P, 'playSingleAnimation', function (animation, config) {
        return createAnimationLayer(this, animation, config, true);
    });
    objects.defineMethod(P, 'destroyAnimationLayer', function (which) {
        const rig = rigOf(this);
        const key = rig ? animationLayerKey(this, rig, which) : undefined;
        if (key === undefined) return false;
        const index = rigLayerIndex(rig, key), count = rigLayerCount(rig);
        for (let i = index; i < count - 1; i++) {
            const to = rigLayerBase(rig, i), from = rigLayerBase(rig, i + 1);
            for (let k = 0; k < RL.layerStride; k++) rigValues[to + k] = rigValues[from + k];
        }
        rigValues[rigBase(rig) + RL.layerCount] = count - 1;
        objects.push(OP.rigLayerDestroy, this._slot, [key]);
        return true;
    });

    // The bone API is the image's (0x140211327); a model has its animation layers and attachment
    // points but no bone API (0x140227814), so it answers as a layer without a rig.
    function boneRigOf(layer) { return layer._record.kind === 'model' ? null : rigOf(layer); }
    objects.defineMethod(P, 'getBoneCount', function () {
        const rig = boneRigOf(this);
        return rig ? rig.bones.length : 0;
    });
    objects.defineMethod(P, 'getBoneIndex', function (name) {
        const rig = boneRigOf(this);
        return rig && typeof name === 'string' ? rigBone(rig, name) : -1;
    });
    objects.defineMethod(P, 'getBoneParentIndex', function (child) {
        const rig = boneRigOf(this);
        const bone = rig ? rigBone(rig, child) : -1;
        return bone < 0 ? -1 : rig.bones[bone].parent;
    });
    // The bone's world matrix (the object's world times its model-space matrix, 0x14020f1d0).
    objects.defineMethod(P, 'getBoneTransform', function (which) {
        const rig = boneRigOf(this);
        const bone = rig ? rigBone(rig, which) : -1;
        return objects.mat4(bone < 0 ? undefined : rigMatrix(rig, bone, RL.boneWorld));
    });
    // Sets the bone's world matrix; only its own palette entry moves (0x14020f350).
    objects.defineMethod(P, 'setBoneTransform', function (which, transform) {
        const rig = boneRigOf(this);
        const bone = rig ? rigBone(rig, which) : -1;
        const m = matrixArgument(transform);
        if (bone < 0 || m === undefined) return;
        writeRigMatrix(rig, bone, RL.boneWorld, m);
        objects.push(OP.rigBoneWorld, this._slot, [bone].concat(m));
    });
    objects.defineMethod(P, 'getLocalBoneTransform', function (which) {
        const rig = boneRigOf(this);
        const bone = rig ? rigBone(rig, which) : -1;
        return objects.mat4(bone < 0 ? undefined : rigMatrix(rig, bone, 0));
    });
    function setLocal(layer, which, change) {
        const rig = boneRigOf(layer);
        const bone = rig ? rigBone(rig, which) : -1;
        if (bone < 0) return;
        const m = change(rigMatrix(rig, bone, 0));
        if (m === undefined) return;
        writeRigMatrix(rig, bone, 0, m);
        objects.push(OP.rigBoneLocal, layer._slot, [bone].concat(m));
    }
    objects.defineMethod(P, 'setLocalBoneTransform', function (which, transform) {
        setLocal(this, which, function () { return matrixArgument(transform); });
    });
    objects.defineMethod(P, 'getLocalBoneAngles', function (which) {
        const rig = boneRigOf(this);
        const bone = rig ? rigBone(rig, which) : -1;
        return bone < 0 ? objects.vec3(0, 0, 0) : eulerRadians(rigMatrix(rig, bone, 0));
    });
    objects.defineMethod(P, 'setLocalBoneAngles', function (which, angles) {
        const radians = vectorArgument(angles);
        if (radians !== undefined) setLocal(this, which, function (m) { return withAngles(m, radians); });
    });
    objects.defineMethod(P, 'getLocalBoneOrigin', function (which) {
        const rig = boneRigOf(this);
        const bone = rig ? rigBone(rig, which) : -1;
        if (bone < 0) return objects.vec3(0, 0, 0);
        const m = rigMatrix(rig, bone, 0);
        return objects.vec3(m[12], m[13], m[14]);
    });
    objects.defineMethod(P, 'setLocalBoneOrigin', function (which, origin) {
        const v = vectorArgument(origin);
        if (v === undefined) return;
        setLocal(this, which, function (m) { m[12] = v[0]; m[13] = v[1]; m[14] = v[2]; return m; });
    });

    // Bone physics (0x140210990, 0x140210e10; docs/models-plan.md §2.14): one bone, by index or
    // by the first bone of that name (the host matches an empty name with the first bone). The
    // state changes for the renderer's next frame. Without a bone (no arguments, or only the
    // vectors) WE 2.8 returns undefined, throws nothing and moves nothing (§5.31): so here.
    function physicsBone(rig, which) {
        if (typeof which === 'number') return rigBone(rig, which);
        if (typeof which !== 'string') return -1;
        return which === '' ? (rig.bones.length > 0 ? 0 : -1) : rigBone(rig, which);
    }
    objects.defineMethod(P, 'applyBonePhysicsImpulse', function (which, directionalImpulse, angularImpulse) {
        const rig = boneRigOf(this);
        const bone = rig ? physicsBone(rig, which) : -1;
        const linear = vectorArgument(directionalImpulse), angular = vectorArgument(angularImpulse);
        if (bone < 0 || linear === undefined || angular === undefined) return;
        objects.push(OP.rigBonePhysicsImpulse, this._slot, [bone].concat(linear, angular));
    });
    objects.defineMethod(P, 'resetBonePhysicsSimulation', function (which) {
        const rig = boneRigOf(this);
        const bone = rig ? physicsBone(rig, which) : -1;
        if (bone >= 0) objects.push(OP.rigBonePhysicsReset, this._slot, [bone]);
    });

    // Blend shapes: the targets of the rig's first mesh (MDMP), on images only (0x140210400,
    // 0x1402104b0, 0x1402105c0). A weight holds for the renderer's next frame: every frame starts
    // the weights over, then the rig's morph tracks set theirs (docs/models-plan.md §2.9).
    function blendShapeIndex(rig, which) {
        const count = rigValues[rigBase(rig) + RL.blendShapeCount] | 0;
        if (typeof which === 'number') {
            const index = Math.floor(which);
            return index >= 0 && index < count ? index : -1;
        }
        if (typeof which !== 'string') return -1;
        return rig.blendShapes ? rig.blendShapes.indexOf(which) : -1;
    }
    objects.defineMethod(P, 'getBlendShapeIndex', function (name) {
        const rig = boneRigOf(this);
        return rig && typeof name === 'string' ? blendShapeIndex(rig, name) : -1;
    });
    objects.defineMethod(P, 'getBlendShapeWeight', function (which) {
        const rig = boneRigOf(this);
        const index = rig ? blendShapeIndex(rig, which) : -1;
        return index < 0 ? 0 : rigValues[rigBase(rig) + RL.blendShapes + index];
    });
    objects.defineMethod(P, 'setBlendShapeWeight', function (which, weight) {
        const rig = boneRigOf(this);
        const index = rig ? blendShapeIndex(rig, which) : -1;
        if (index < 0 || typeof weight !== 'number' || !isFinite(weight)) return;
        if (index < RL.maximumBlendShapes) rigValues[rigBase(rig) + RL.blendShapes + index] = weight;
        objects.push(OP.rigBlendShape, this._slot, [index, weight]);
    });

    // ILayer attachments: the layer's own rig's attachment points (MDAT), in the world.
    function attachmentOf(layer, which) {
        const rig = rigOf(layer);
        if (!rig) return undefined;
        if (typeof which === 'number') return rig.attachments[Math.floor(which)];
        const name = String(which);
        return rig.attachments.find(function (attachment) { return attachment.name === name; });
    }
    function attachmentMatrix(layer, which) {
        const attachment = attachmentOf(layer, which);
        if (attachment === undefined || attachment.bone >= rigOf(layer).bones.length) return undefined;
        return multiply(rigMatrix(rigOf(layer), attachment.bone, RL.boneWorld), attachment.matrix);
    }
    // For objects-transforms.js: a layer's rig, and an attachment's world matrix (undefined when
    // the layer has no such attachment).
    objects.rigOf = rigOf;
    objects.attachmentWorld = attachmentMatrix;
    objects.multiplyMat4 = multiply;
    objects.defineMethod(P, 'getAttachmentIndex', function (name) {
        const rig = rigOf(this);
        if (!rig) return -1;
        const key = String(name);
        for (let i = 0; i < rig.attachments.length; i++) if (rig.attachments[i].name === key) return i;
        return -1;
    });
    objects.defineMethod(P, 'getAttachmentMatrix', function (which) {
        return objects.mat4(attachmentMatrix(this, which));
    });
    objects.defineMethod(P, 'getAttachmentOrigin', function (which) {
        const m = attachmentMatrix(this, which);
        return m === undefined ? objects.vec3(0, 0, 0) : objects.vec3(m[12], m[13], m[14]);
    });
    objects.defineMethod(P, 'getAttachmentAngles', function (which) {
        const m = attachmentMatrix(this, which);
        return m === undefined ? objects.vec3(0, 0, 0) : eulerRadians(m);
    });

    function setPlaying(layer, playing) {
        layer._t[layer._base + PLAYING] = playing ? 1 : 0;
        layer._d[layer._di] = 1;
    }

    function playback(layer, opcode, playing) {
        setPlaying(layer, playing);
        if (!layer._dead) objects.push(opcode, layer._slot);
    }

    class ImageLayer extends Layer {}
    class TextLayer extends Layer {}
    class ModelLayer extends Layer {}
    class GroupLayer extends Layer {}

    // ISoundLayer. `isPlaying()` reads the state the renderer keeps; `play()`/`stop()` set it at once.
    class SoundLayer extends Layer {
        play() { playback(this, OP.soundPlay, true); }
        pause() { playback(this, OP.soundPause, false); }
        stop() { playback(this, OP.soundStop, false); }
        isPlaying() { return this._t[this._base + PLAYING] !== 0; }
    }

    // IParticleSystem.
    class ParticleSystem extends Layer {
        play() { playback(this, OP.particlesPlay, true); }
        pause() { playback(this, OP.particlesPause, false); }
        stop() { playback(this, OP.particlesStop, false); }
        isPlaying() { return this._t[this._base + PLAYING] !== 0; }
        // A count is floored and clamped to [0, MAX_EMIT]; NaN (an out-of-range audio read times
        // anything) emits nothing. SceneScriptObjectModel validates it again natively.
        emitParticles(count) {
            if (this._dead) return;
            if (typeof count !== 'number') {
                objects.push(OP.particlesEmit, this._slot);
                return;
            }
            if (count !== count) return;
            objects.push(OP.particlesEmit, this._slot, [Math.max(0, Math.min(MAX_EMIT, Math.floor(count)))]);
        }
    }

    const CLASSES = { image: ImageLayer, text: TextLayer, sound: SoundLayer, particle: ParticleSystem,
        model: ModelLayer, group: GroupLayer };

    objects.makeLayer = function (record) {
        const LayerClass = CLASSES[record.kind] || Layer;
        const layer = new LayerClass(record);
        // A video texture plays from the layer's start, so its clock starts with the layer.
        if (record.video) layer.getVideoTexture();
        return layer;
    };

    // Detaches a destroyed layer: it keeps its last values; writes and commands do nothing.
    objects.detachLayer = function (layer) {
        // Build the effects first so a later `getEffect` on the stale layer never reaches reused slots.
        layer._effectList().forEach(objects.detachEffect);
        objects.detach(layer, stride);
        objects.forgetAnimations(layer._record.animations);
        if (layer._record.textureAnimation) objects.forgetAnimations([layer._record.textureAnimation]);
        const video = videoTextures.indexOf(layer._videoTexture);
        if (video >= 0) videoTextures.splice(video, 1);
    };

    objects.Layer = Layer;
    objects.ImageLayer = ImageLayer;
    objects.TextLayer = TextLayer;
    objects.SoundLayer = SoundLayer;
    objects.ParticleSystem = ParticleSystem;
    objects.ModelLayer = ModelLayer;
    objects.GroupLayer = GroupLayer;
    objects.ParticleInstance = ParticleInstance;
    objects.AnimationLayer = AnimationLayer;
})(this);
