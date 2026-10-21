'use strict';
// SceneScript object model, part 2 of 6: `IAnimation` and `ITextureAnimation` over the animation
// buffer (docs/timeline-plan.md §3; layout in SceneScriptObjectStore.AnimationLayout). The
// renderer writes each clock's state before a frame; the methods here apply WE's rules to it in
// call order, so a script reads back what it just did, mark the slot dirty and push the command.
// The renderer reads a dirty slot back after the frame. `__rt.objects.hooks.animation` can still
// hand out other objects, and `animationEvent(event, value)` arrives as an inbox event (§3.3).
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    const OP = objects.OP;
    const buffer = objects.animations;
    const layout = objects.animationLayout;
    const PAUSED = layout.paused, FINISHED = layout.finished, BACKWARDS = layout.backwards;
    const OVERRIDDEN = layout.overridden;
    const f32 = Math.fround;

    // What both interfaces share. `record` is the animation's record from SceneScriptObjectStore
    // (slot, name, fps, frameCount, duration, property).
    class PlaybackState {
        constructor(record) {
            // Non-enumerable internals; `objects.detach` points them at a snapshot once the owner
            // is destroyed, so a stale reference never touches a reused slot.
            Object.defineProperty(this, '_record', { value: record });
            objects.attach(this, buffer.values, record.slot * buffer.stride, buffer.dirty, record.slot);
        }

        get frameCount() { return this._record.frameCount; }
        set frameCount(value) {}
        get duration() { return this._record.duration; }
        set duration(value) {}

        // Any number (0 freezes, a negative one runs backwards); WE stores it as a float.
        get rate() { return this._get(layout.rate); }
        set rate(value) {
            if (typeof value !== 'number' || this._dead) return;
            this._set(layout.rate, value);
            this._rateWritten();
        }
    }
    objects.defineMethod(PlaybackState.prototype, '_get', function (field) {
        return this._t[this._base + field];
    });
    // Writes one float of the slot and marks it dirty (a destroyed owner's snapshot takes it harmlessly).
    objects.defineMethod(PlaybackState.prototype, '_set', function (field, value) {
        this._t[this._base + field] = value;
        this._d[this._di] = 1;
    });
    objects.defineMethod(PlaybackState.prototype, '_flags', function () {
        return this._get(layout.flags) | 0;
    });
    objects.defineMethod(PlaybackState.prototype, '_setFlags', function (flags) {
        this._set(layout.flags, flags);
    });
    objects.defineMethod(PlaybackState.prototype, '_rateWritten', function () {});
    objects.defineMethod(PlaybackState.prototype, '_command', function (opcode, numbers) {
        if (!this._dead) objects.push(opcode, this._record.slot, numbers);
    });

    // IAnimation: a property timeline of an object, effect, material or the scene (§3.1, callbacks
    // 0x140170770…). Its clock is `time` (float seconds) and the paused/finished/backwards flags.
    class Animation extends PlaybackState {
        // WE stores 1/fps and returns 1 / that, in float.
        get fps() { return f32(1 / this._frameDuration()); }
        set fps(value) {}
        get name() { return this._record.name; }
        set name(value) {}

        // A finished animation restarts from 0; paused and finished clear (a mirror keeps its direction).
        play() {
            if (this._dead) return;
            const flags = this._flags();
            if ((flags & FINISHED) !== 0) this._setTime(0);
            this._setState(flags & ~(PAUSED | FINISHED));
            this._command(OP.animationPlay);
        }

        pause() {
            if (this._dead) return;
            this._setState(this._flags() | PAUSED);
            this._command(OP.animationPause);
        }

        // Paused at 0, not finished, running forwards.
        stop() {
            if (this._dead) return;
            this._setTime(0);
            this._setState((this._flags() | PAUSED) & ~(FINISHED | BACKWARDS));
            this._command(OP.animationStop);
        }

        isPlaying() { return (this._flags() & (PAUSED | FINISHED)) === 0; }

        // `time / frameDuration`: a fractional frame.
        getFrame() { return this._get(layout.frame); }

        // `time = frame × frameDuration` in float, not clamped; the play state stays (a finished
        // single stays finished, and `play()` then restarts it from 0).
        setFrame(frame) {
            if (typeof frame !== 'number' || this._dead) return;
            this._setTime(f32(f32(frame) * this._frameDuration()));
            this._command(OP.animationSetFrame, [frame]);
        }
    }
    objects.defineMethod(Animation.prototype, '_frameDuration', function () {
        return f32(1 / f32(this._record.fps));
    });
    objects.defineMethod(Animation.prototype, '_setTime', function (time) {
        this._set(layout.time, time);
        this._set(layout.frame, f32(f32(time) / this._frameDuration()));
    });
    // The flags, and `playing` as `isPlaying()` for code that reads only that slot.
    objects.defineMethod(Animation.prototype, '_setState', function (flags) {
        this._setFlags(flags);
        this._set(layout.playing, (flags & (PAUSED | FINISHED)) === 0 ? 1 : 0);
    });

    // ITextureAnimation: an image's spritesheet animation (§3.2, wrapper at layer+0x4c0). Every
    // user of the texture shares one clock (`sharedFrame`/`sharedTime`, renderer-written); a
    // script that takes control copies it into this layer's override (`frame`, `time`), which the
    // renderer advances by the frame time × rate while `playing`. `join()` gives control back.
    class TextureAnimation extends PlaybackState {
        // playing = 1; it doesn't take control.
        play() {
            if (this._dead) return;
            this._set(layout.playing, 1);
            this._command(OP.animationPlay);
        }

        // Takes control (copying the shared frame the first time), not playing.
        pause() {
            if (this._dead) return;
            this._take();
            this._set(layout.playing, 0);
            this._command(OP.animationPause);
        }

        // Frame 0, time 0, not playing, in control.
        stop() {
            if (this._dead) return;
            this._set(layout.frame, 0);
            this._set(layout.time, 0);
            this._setFlags(this._flags() | OVERRIDDEN);
            this._set(layout.playing, 0);
            this._command(OP.animationStop);
        }

        // False only while in control and not playing.
        isPlaying() {
            return (this._flags() & OVERRIDDEN) === 0 || this._get(layout.playing) !== 0;
        }

        // The integer frame: the override's while in control, else the shared one.
        getFrame() {
            return ((this._flags() & OVERRIDDEN) !== 0 ? this._get(layout.frame) : this._get(layout.sharedFrame)) | 0;
        }

        // Frame `n` (an int, not range-checked), time 0; taking control this way starts it playing.
        setFrame(frame) {
            if (typeof frame !== 'number' || this._dead) return;
            const n = frame | 0;
            this._set(layout.frame, n);
            this._set(layout.time, 0);
            const flags = this._flags();
            if ((flags & OVERRIDDEN) === 0) {
                this._setFlags(flags | OVERRIDDEN);
                this._set(layout.playing, 1);
            }
            this._command(OP.animationSetFrame, [n]);
        }

        // Back to the shared clock; the override keeps its frame, time and playing flag.
        join() {
            if (this._dead) return;
            this._setFlags(this._flags() & ~OVERRIDDEN);
            this._command(OP.animationJoin);
        }
    }
    // Copies the shared frame and time into the override and takes control, unless it has it.
    objects.defineMethod(TextureAnimation.prototype, '_take', function () {
        const flags = this._flags();
        if ((flags & OVERRIDDEN) !== 0) return;
        this._set(layout.frame, this._get(layout.sharedFrame));
        this._set(layout.time, this._get(layout.sharedTime));
        this._setFlags(flags | OVERRIDDEN);
    });
    // A stored rate other than 1 (NaN too) takes control (0x1401fa4a0).
    objects.defineMethod(TextureAnimation.prototype, '_rateWritten', function () {
        if (this._get(layout.rate) !== 1) this._take();
    });

    objects.Animation = Animation;
    objects.TextureAnimation = TextureAnimation;

    const instances = new Map();

    // The one JS object per animation slot, so repeated `getAnimation` calls return the same object.
    objects.animationFor = function (owner, record, textured) {
        let animation = instances.get(record.slot);
        if (animation === undefined) {
            animation = objects.hooks.animation ? objects.hooks.animation(owner, record, textured) : undefined;
            if (animation === undefined) animation = textured ? new TextureAnimation(record) : new Animation(record);
            instances.set(record.slot, animation);
        }
        return animation;
    };

    // Detaches the animations of `records` (their owner was destroyed; Swift reuses the slots).
    objects.forgetAnimations = function (records) {
        for (let i = 0; i < records.length; i++) {
            const animation = instances.get(records[i].slot);
            if (animation !== undefined) objects.detach(animation, buffer.stride);
            instances.delete(records[i].slot);
        }
    };

    // The property the running script is bound to, when `owner` is its `thisObject`: what
    // `getAnimation()` without a name refers to (IThisPropertyObject: "Leave empty to get the
    // animation object bound to the current property").
    objects.currentProperty = function (owner) {
        if (rt.current === null) return undefined;
        const binding = objects.bindingOf(rt.current);
        if (!binding || objects.bindingTarget(binding) !== owner) return undefined;
        return binding.property;
    };

    // The property prefix of an animation layer's own timelines (`animationlayers.<index>.<key>`):
    // they belong to the object (their events go to its scripts) but are found through the layer
    // (`IAnimationLayer.getAnimation`), not by the object's or the scene's `getAnimation(name)`.
    objects.animationLayerPrefix = 'animationlayers.';
    function isLayerTimeline(record) {
        return typeof record.property === 'string' && record.property.indexOf(objects.animationLayerPrefix) === 0;
    }

    // IObject.getAnimation(name?) over `records` (the owner's animation records): the animation
    // named so (`options.name`), else the one on the property of that key, which is how a
    // timeline without a name is found (2321732083 plays its ships' unnamed `origin` timelines
    // with `getAnimation('origin').play()`, and WE flies them). Null when the owner has neither.
    objects.resolveAnimation = function (owner, records, name) {
        let found;
        if (name === undefined || name === null) {
            const property = objects.currentProperty(owner);
            if (property === undefined) return null;
            found = records.find(function (record) { return record.property === property; });
        } else {
            const key = String(name);
            found = records.find(function (record) { return record.name === key && !isLayerTimeline(record); })
                || records.find(function (record) { return record.property === key; });
        }
        return found ? objects.animationFor(owner, found, false) : null;
    };

    // thisScene.getAnimation(name). scenescript64.dll's callback (0x181635ee0, 0x18163613d) takes
    // only a string name, which it hands to the host with no owner: anything else gives null, a
    // name no animation has gives undefined. The host's search isn't traced; it covers every
    // owner (d.ts: "by name from any layer"), in the order the scene registers animations: the
    // layers in scene order (created ones after), each with its own fields, then its effects' and
    // their materials', then the scene's own settings.
    objects.findAnimation = function (name, sceneRecords) {
        if (typeof name !== 'string') return null;
        function named(records) {
            if (!records) return undefined;
            for (let i = 0; i < records.length; i++) {
                if (records[i].name === name && !isLayerTimeline(records[i])) return records[i];
            }
            return undefined;
        }
        for (const layer of objects.bySlot.values()) {
            if (layer._dead) continue;
            const record = layer._record;
            let found = named(record.animations);
            if (found) return objects.animationFor(layer, found, false);
            const effects = record.effects || [];
            for (let e = 0; e < effects.length; e++) {
                const effect = layer.getEffect(effects[e].index);
                found = named(effects[e].animations);
                if (found && effect !== null) return objects.animationFor(effect, found, false);
                const materials = effects[e].materials || [];
                for (let m = 0; m < materials.length; m++) {
                    found = named(materials[m].animations);
                    const material = effect === null ? null : effect.getMaterial(m);
                    if (found && material !== null) return objects.animationFor(material, found, false);
                }
            }
        }
        const found = named(sceneRecords);
        return found ? objects.animationFor(objects.scene, found, false) : undefined;
    };

    // MARK: animationEvent (§3.3)

    function holds(records, slot) {
        if (!records) return false;
        for (let i = 0; i < records.length; i++) if (records[i].slot === slot) return true;
        return false;
    }

    // The object that owns animation `slot` (a layer, effect, material or the scene), or null.
    objects.animationOwner = function (slot) {
        const scene = objects.scene;
        if (holds(rt.native.objects.initial.animations, slot)) return scene;
        for (const layer of objects.bySlot.values()) {
            if (layer._dead) continue;
            const record = layer._record;
            if (holds(record.animations, slot)) return layer;
            const effects = record.effects || [];
            for (let e = 0; e < effects.length; e++) {
                const effect = effects[e];
                if (holds(effect.animations, slot)) return layer.getEffect(effect.index);
                const materials = effect.materials || [];
                for (let m = 0; m < materials.length; m++) {
                    if (holds(materials[m].animations, slot)) {
                        const owner = layer.getEffect(effect.index);
                        return owner === null ? null : owner.getMaterial(m);
                    }
                }
            }
        }
        return null;
    };

    // Sends `animationEvent(event, value)` to every initialised script whose `thisObject` is
    // `owner` (WE: the scripts attached to the owner, and the animated property's own script), in
    // list order, each with its own `makeEvent()`; the return is applied like `update`'s (P3).
    objects.sendAnimationEvent = function (owner, makeEvent) {
        const records = rt.records;
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (!record.enabled || record.animationReady !== true || record.pendingDestroy) continue;
            let exported;
            try {
                exported = typeof rt.exports(record, 'animationEvent') === 'function';
            } catch (error) {
                exported = true; // Let `invoke` report the throwing getter.
            }
            if (!exported || rt.hooks.scope(record).thisObject !== owner) continue;
            rt.apply(record, rt.invoke(record, 'animationEvent', [makeEvent(), rt.argument(record)]));
        }
    };

    // A timeline event for the owner of animation `slot`. Payload: {slot, name, frame}.
    // SceneScriptEvent.animationEvent posts it after the clocks advanced, before timers and `update`.
    objects.dispatchAnimationEvent = function (payload) {
        const owner = objects.animationOwner(payload.slot);
        if (owner === null) return;
        objects.sendAnimationEvent(owner, function () { return { name: String(payload.name), frame: payload.frame }; });
    };

    // After media events (§1.9 P1: timeline animations and `animationEvent` follow them).
    rt.addEventHandler('animationEvent', rt.EVENT_ORDER.media + 100, function (event) {
        objects.dispatchAnimationEvent(event.payload);
    });

    // WE calls `animationEvent` only on scripts that finished `init`.
    const initialized = rt.hooks.initialized;
    rt.hooks.initialized = function (record) {
        record.animationReady = true;
        initialized(record);
    };
})(this);
