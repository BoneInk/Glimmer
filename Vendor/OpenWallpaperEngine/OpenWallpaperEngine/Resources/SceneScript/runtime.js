'use strict';
// SceneScript runtime core (docs/scenescript-plan.md §4). Evaluated once per wallpaper instance,
// after WE's baseclasses.js and before every other runtime file. It owns the script records, the
// load and frame order, the phase flag, per-callback error isolation and the command ring.
// Other runtime files plug in through `__rt.addPhaseHandler`, `__rt.addEventHandler` and
// `__rt.hooks`; they never reorder the steps below. The order and the error semantics follow WE's
// own binaries (docs/scenescript-plan.md §1.9).
(function (global) {
    // Every callback WE calls on a script (lib.sceneScript.d.ts IComponent, plus the two the DLL names).
    const CALLBACKS = ['init', 'update', 'destroy', 'resizeScreen', 'applyUserProperties',
        'applyGeneralSettings', 'cursorEnter', 'cursorLeave', 'cursorMove', 'cursorDown', 'cursorUp',
        'cursorClick', 'mediaStatusChanged', 'mediaPlaybackChanged', 'mediaPropertiesChanged',
        'mediaThumbnailChanged', 'mediaTimelineChanged', 'animationEvent', 'cursorHitTest'];
    // Load states, in order; records added later go through the same steps on the next load.
    const DEFINED = 0, EVALUATED = 1, INJECTED = 2, INITIALIZED = 3, PROPERTIES_APPLIED = 4, READY = 5;
    const PHASES = ['frameGlobals', 'animations', 'timers', 'deferred'];
    // Event order within a frame (§1.9 P1): WE handles cursor input, then user property changes,
    // then media events. Events of the same order keep their arrival order.
    const EVENT_ORDER = { resize: 0, cursor: 100, userProperties: 200, generalSettings: 210, media: 300 };

    const rt = {
        CALLBACKS: CALLBACKS,
        // 'idle' outside script code, 'global' while a module body runs, 'callback' inside a callback.
        phase: 'idle',
        // The id of the record whose code is running; read by the native side after the watchdog fires.
        current: null,
        // The exported callback that is running ('update', 'cursorClick', …), or null outside one
        // (module bodies, timers). WE keeps the same index while it calls a callback.
        callback: null,
        // Set once the watchdog stopped script code: like WE, no script code runs again (§1.9 P5).
        halted: false,
        EVENT_ORDER: EVENT_ORDER,
        records: [],
        byId: new Map(),
        errors: [],
        // Ids of records removed since the native side last drained them (`drainRemoved`), so it
        // learns about removals scripts made (`destroyLayer`).
        removed: [],
        // Set once the first load finished: records defined afterwards are runtime-created.
        loadedOnce: false,
        frameIndex: 0,
        deltaTime: 0,
        native: {},
        hooks: {
            // The `__scope` a module factory receives: `thisLayer`, `thisObject` (object model, WP7).
            scope: function (record) { return { thisLayer: undefined, thisObject: undefined }; },
            // The argument `init`/`update` receive (property binding, WP8).
            argument: function (record) { return record.value; },
            // Coerces a returned value to the bound field's type; undefined keeps the value (WP8).
            coerce: function (record, value) { return value; },
            // Called with the raw changed user properties ({name: {type, value}}) before the
            // frame's `applyUserProperties(changed)`: property binding (WP8) applies user-bound
            // values and re-injects user-bound script properties there.
            userPropertiesChanged: function (properties) {},
            // Converts user properties for applyUserProperties and engine.userProperties (WP4:
            // `_Internal.convertUserProperties`).
            userProperties: function (properties) { return properties; },
            // Called right after a record's `init` (WP6 sends it the current media state there).
            initialized: function (record) {},
        },
        phaseHandlers: { frameGlobals: [], animations: [], timers: [], deferred: [] },
        eventHandlers: new Map(),
        modules: new Map(),
        ring: null,
    };

    // The position in the script at `url` that `error` came from: the first stack frame in that
    // script, so an error a runtime or extension helper built (`registerAudioBuffers can only be
    // called from global scope.`) names the script's line that called the helper, not the
    // helper's own. JavaScriptCore writes frames as `name@url:line:column`.
    function scriptPosition(error, url) {
        let stack;
        try {
            stack = error.stack;
        } catch (e) {
            stack = undefined;
        }
        if (typeof stack === 'string' && typeof url === 'string' && url !== '') {
            const frames = stack.split('\n');
            for (let i = 0; i < frames.length; i++) {
                const match = /:(\d+):(\d+)$/.exec(frames[i]);
                if (match === null) continue;
                const location = frames[i].slice(0, match.index);
                if (location === url || location.endsWith('@' + url)) {
                    return { line: Number(match[1]), column: Number(match[2]) };
                }
            }
        }
        if (url && error.sourceURL === url && typeof error.line === 'number') {
            return { line: error.line, column: typeof error.column === 'number' ? error.column : -1 };
        }
        // Runtime code, or no frame of the script (an error object made elsewhere and rethrown).
        if (!url && typeof error.line === 'number') {
            return { line: error.line, column: typeof error.column === 'number' ? error.column : -1 };
        }
        return { line: -1, column: -1 };
    }

    function describe(error, url) {
        if (error !== null && typeof error === 'object') {
            const position = scriptPosition(error, url);
            let message, name;
            try {
                message = String(error.message !== undefined ? error.message : error);
                name = error.name !== undefined ? String(error.name) : 'Error';
            } catch (e) {
                message = Object.prototype.toString.call(error);
                name = 'Error';
            }
            return { message: message, name: name, line: position.line, column: position.column };
        }
        let message;
        try {
            message = String(error);
        } catch (e) {
            message = typeof error;
        }
        return { message: message, name: 'Error', line: -1, column: -1 };
    }

    rt.reportError = function (record, callback, error) {
        const info = describe(error, record ? record.url : '');
        rt.errors.push({ id: record ? record.id : '', callback: callback, name: info.name,
            message: info.message, line: info.line, column: info.column });
    };

    rt.drainErrors = function () {
        const drained = rt.errors;
        rt.errors = [];
        return drained;
    };

    function run(record, label, phase, fn, args, callback) {
        if (!record.enabled || rt.halted) return undefined;
        const previousPhase = rt.phase, previousCurrent = rt.current, previousCallback = rt.callback;
        rt.phase = phase;
        rt.current = record.id;
        rt.callback = callback;
        let result;
        try {
            result = fn.apply(undefined, args);
        } catch (error) {
            rt.reportError(record, label, error);
            // WE disables the callback that threw, for that script only (§1.9 P4).
            if (callback) record.failed[callback] = true;
            result = undefined;
        }
        rt.phase = previousPhase;
        rt.current = previousCurrent;
        rt.callback = previousCallback;
        return result;
    }

    // `run` for a callback of one argument (`init`, `update`): the same, without an arguments
    // array, since `update` runs for every script every frame.
    function runOne(record, name, fn, argument) {
        if (!record.enabled || rt.halted) return undefined;
        const previousPhase = rt.phase, previousCurrent = rt.current, previousCallback = rt.callback;
        rt.phase = 'callback';
        rt.current = record.id;
        rt.callback = name;
        let result;
        try {
            result = fn(argument);
        } catch (error) {
            rt.reportError(record, name, error);
            record.failed[name] = true;
            result = undefined;
        }
        rt.phase = previousPhase;
        rt.current = previousCurrent;
        rt.callback = previousCallback;
        return result;
    }

    // Runs `fn` as `record`'s code in `phase` ('global' or 'callback'): for timers and ended
    // callbacks. An exception is recorded on the error channel and swallowed, so one script never
    // stops another; like WE, it disables nothing. Returns undefined when it threw.
    rt.call = function (record, label, phase, fn, args) {
        return run(record, label, phase, fn, args, null);
    };

    // Calls the exported callback `name`. One that threw once is never called again for this record.
    rt.invoke = function (record, name, args) {
        const exports = record.exports;
        if (!exports || record.failed[name] === true) return undefined;
        let fn;
        try {
            fn = exports[name];
        } catch (error) {
            rt.reportError(record, name, error);
            return undefined;
        }
        if (typeof fn !== 'function') return undefined;
        return run(record, name, 'callback', fn, args, name);
    };

    // `invoke` of a one-argument callback with the value it receives (`init`, `update`).
    function invokeWithValue(record, name) {
        const exports = record.exports;
        if (!exports || record.failed[name] === true) return undefined;
        let fn;
        try {
            fn = exports[name];
        } catch (error) {
            rt.reportError(record, name, error);
            return undefined;
        }
        if (typeof fn !== 'function') return undefined;
        return runOne(record, name, fn, rt.argument(record));
    }

    rt.exports = function (record, name) {
        return record.exports ? record.exports[name] : undefined;
    };

    // Applies what `init`/`update` returned through the binding's converter. The converter may
    // run script code (a returned object's getters or `toString`); a throw keeps the value.
    rt.apply = function (record, returned) {
        if (returned === undefined) return;
        let value;
        try {
            value = rt.hooks.coerce(record, returned);
        } catch (error) {
            rt.reportError(record, '<value>', error);
            return;
        }
        if (value === undefined) return;
        record.value = value;
    };

    // The argument `init`/`update` receive; a binding that fails to read it passes the last value.
    rt.argument = function (record) {
        try {
            return rt.hooks.argument(record);
        } catch (error) {
            rt.reportError(record, '<value>', error);
            return record.value;
        }
    };

    // MARK: phase rules (lib.sceneScript.d.ts, scenescript64.dll messages)

    // `what` as WE names it: 'registerAudioBuffers', 'registerAsset', 'requestFeatures'.
    rt.requireGlobalScope = function (what) {
        if (rt.phase !== 'global') throw new Error(what + ' can only be called from global scope.');
    };

    // `what` as WE names it: 'setTimeout', 'setInterval'; clearing uses `timeout cannot be cleared…`.
    rt.forbidGlobalScope = function (what) {
        if (rt.phase === 'global') throw new Error(what + ' cannot be called from global scope.');
    };

    // MARK: modules

    rt.registerModule = function (name, factory) {
        rt.modules.set(String(name).toLowerCase(), { factory: factory, exports: null, loading: false });
    };

    rt.require = function (name) {
        const entry = rt.modules.get(String(name).toLowerCase());
        if (!entry) throw new Error("Cannot find module '" + name + "'");
        if (entry.exports) return entry.exports;
        if (entry.loading) throw new Error("Circular import of module '" + name + "'");
        entry.loading = true;
        const scope = { thisLayer: undefined, thisObject: undefined, require: rt.require };
        try {
            entry.exports = entry.factory(rt, scope);
        } finally {
            entry.loading = false;
        }
        return entry.exports;
    };

    // MARK: records

    // `slot` is the object-table slot of the object the script belongs to, or -1; `url` the
    // script's sourceURL (error positions); `binding` what `thisObject` is (the object model's
    // SceneScriptObjectBinding), or null.
    rt.define = function (id, factory, value, scriptProperties, slot, url, binding) {
        if (rt.byId.has(id)) throw new Error('Duplicate script id ' + id);
        const record = { id: id, factory: factory, exports: null, value: value, enabled: true,
            state: DEFINED, scriptProperties: scriptProperties, slot: slot, pendingDestroy: false,
            destroyed: false, failed: {}, url: typeof url === 'string' ? url : '',
            binding: binding === undefined ? null : binding, late: rt.loadedOnce,
            // The property binding's cached access to the bound property (sceneScriptBinding.js).
            access: undefined };
        rt.records.push(record);
        rt.byId.set(id, record);
    };

    rt.disable = function (id) {
        const record = rt.byId.get(id);
        if (record) record.enabled = false;
    };

    rt.isEnabled = function (id) {
        const record = rt.byId.get(id);
        return record ? record.enabled : false;
    };

    rt.valueOf = function (id) {
        const record = rt.byId.get(id);
        return record ? record.value : undefined;
    };

    // Marks a script for removal after this frame's updates; false when there is no such script.
    rt.remove = function (id) {
        const record = rt.byId.get(id);
        if (!record) return false;
        record.pendingDestroy = true;
        return true;
    };

    rt.drainRemoved = function () {
        const drained = rt.removed;
        rt.removed = [];
        return drained;
    };

    // Native→JS entries in progress (`load`, `frame`, `teardown`); the global `__rt` is hidden
    // while any runs.
    let entries = 0;

    function entry(body, args) {
        entries += 1;
        try {
            return body.apply(undefined, args);
        } finally {
            entries -= 1;
        }
    }

    // MARK: load (plan §4.4)

    function evaluate(record) {
        const scope = rt.hooks.scope(record);
        scope.require = rt.require;
        const exports = rt.call(record, '<global>', 'global', record.factory, [rt, scope]);
        if (exports === undefined || exports === null) {
            // The module body threw: WE cannot use a module that failed to evaluate.
            record.enabled = false;
            return;
        }
        record.exports = exports;
    }

    function injectScriptProperties(record) {
        if (record.scriptProperties === null || record.scriptProperties === undefined) return;
        const declared = rt.exports(record, 'scriptProperties');
        if (declared === null || typeof declared !== 'object') return;
        const internal = global._Internal;
        if (!internal || typeof internal.updateScriptProperties !== 'function') return;
        const target = { scriptProperties: declared };
        rt.call(record, '<scriptProperties>', 'idle', internal.updateScriptProperties,
            [target, record.scriptProperties]);
    }

    function convertUserProperties(properties) {
        try {
            return rt.hooks.userProperties(properties);
        } catch (error) {
            rt.reportError(null, 'userProperties', error);
            return properties;
        }
    }

    // Module bodies, script properties, `init` (each followed by `hooks.initialized`), then
    // `applyUserProperties(all)` and `applyGeneralSettings`, each step over every record in order
    // (§1.9 P8). Each record advances through the states once, so records added after a load go
    // through the same steps on the next one, except `applyUserProperties`: P8's best guess is
    // that WE never sends it to scripts created at runtime, which see the current values through
    // `engine.userProperties` instead.
    rt.load = function (userProperties, generalSettings) {
        return entry(load, [userProperties, generalSettings]);
    };

    function load(userProperties, generalSettings) {
        if (rt.halted) return rt.errors.length;
        const records = rt.records;
        const converted = convertUserProperties(userProperties);
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (record.enabled && record.state === DEFINED) { evaluate(record); record.state = EVALUATED; }
        }
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (record.enabled && record.state === EVALUATED) { injectScriptProperties(record); record.state = INJECTED; }
        }
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (record.enabled && record.state === INJECTED) {
                rt.apply(record, invokeWithValue(record, 'init'));
                record.state = INITIALIZED;
                try {
                    rt.hooks.initialized(record);
                } catch (error) {
                    rt.reportError(null, 'initialized', error);
                }
            }
        }
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (record.enabled && record.state === INITIALIZED) {
                if (!record.late) rt.invoke(record, 'applyUserProperties', [converted]);
                record.state = PROPERTIES_APPLIED;
            }
        }
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (record.enabled && record.state === PROPERTIES_APPLIED) {
                rt.invoke(record, 'applyGeneralSettings', [generalSettings]);
                record.state = READY;
            }
        }
        rt.loadedOnce = true;
        return rt.errors.length;
    }

    // MARK: frame (plan §4.4)

    rt.addPhaseHandler = function (phase, handler) {
        if (PHASES.indexOf(phase) < 0) throw new Error('Unknown runtime phase ' + phase);
        rt.phaseHandlers[phase].push(handler);
    };

    // `order` is one of `EVENT_ORDER` (cursor, userProperties, media, …): events are handled by
    // order first, then by arrival.
    rt.addEventHandler = function (kind, order, handler) {
        if (rt.eventHandlers.has(kind)) throw new Error('Duplicate event handler for ' + kind);
        if (typeof order !== 'number') throw new Error('Event handler ' + kind + ' needs an order');
        rt.eventHandlers.set(kind, { order: order, handler: handler });
    };

    // Runtime code (not script code): a failure here is reported without a script id.
    function runPhase(phase, dt) {
        const handlers = rt.phaseHandlers[phase];
        for (let i = 0; i < handlers.length; i++) {
            try {
                handlers[i](dt);
            } catch (error) {
                rt.reportError(null, phase, error);
            }
        }
    }

    rt.broadcast = function (name, args) {
        const records = rt.records;
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (record.enabled && record.state === READY) rt.invoke(record, name, args);
        }
    };

    rt.addEventHandler('userProperties', EVENT_ORDER.userProperties, function (event) {
        try {
            rt.hooks.userPropertiesChanged(event.payload);
        } catch (error) {
            rt.reportError(null, 'userPropertiesChanged', error);
        }
        rt.broadcast('applyUserProperties', [convertUserProperties(event.payload)]);
    });
    rt.addEventHandler('generalSettings', EVENT_ORDER.generalSettings, function (event) {
        rt.broadcast('applyGeneralSettings', [event.payload]);
    });
    // Where WE handles a resolution change within the frame is not known; first is a best guess.
    // `Vec2` is baseclasses.js's class: a global lexical binding, not a property of `global`.
    // Every script gets its own Vec2, so one that changes it can't change the next one's (S14).
    rt.addEventHandler('resize', EVENT_ORDER.resize, function (event) {
        const size = event.payload;
        const records = rt.records;
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (!record.enabled || record.state !== READY) continue;
            const value = typeof Vec2 === 'function' ? new Vec2(size.x, size.y) : { x: size.x, y: size.y };
            rt.invoke(record, 'resizeScreen', [value]);
        }
    });

    function dispatch(events) {
        const queued = [];
        for (let i = 0; i < events.length; i++) {
            const entry = rt.eventHandlers.get(events[i].kind);
            if (!entry) {
                rt.reportError(null, 'event', new Error('No handler for event ' + events[i].kind));
                continue;
            }
            queued.push({ order: entry.order, index: i, handler: entry.handler, event: events[i] });
        }
        queued.sort(function (a, b) { return a.order - b.order || a.index - b.index; });
        for (let i = 0; i < queued.length; i++) {
            try {
                queued[i].handler(queued[i].event);
            } catch (error) {
                rt.reportError(null, 'event ' + queued[i].event.kind, error);
            }
        }
    }

    // Calls `destroy()` on every record marked for removal and drops them, until none is left: a
    // `destroy()` may remove other scripts (earlier or later ones), and each of those gets its own
    // `destroy()` too (SF2). Ids go to `removed` for the native side. The object model calls this
    // inside its deferred step, while the destroyed layers are still attached (SF11).
    rt.destroyPending = function () {
        let any = false;
        for (;;) {
            const doomed = rt.records.filter(function (record) { return record.pendingDestroy && !record.destroyed; });
            if (doomed.length === 0) break;
            any = true;
            for (let i = 0; i < doomed.length; i++) {
                doomed[i].destroyed = true;
                if (doomed[i].state === READY) rt.invoke(doomed[i], 'destroy', []);
            }
        }
        if (!any) return;
        rt.records = rt.records.filter(function (record) {
            if (!record.destroyed) return true;
            if (rt.byId.get(record.id) === record) rt.byId.delete(record.id);
            rt.removed.push(record.id);
            return false;
        });
    };

    // WE's frame (§1.9 P1): input and property events, media events, timeline animations and
    // `animationEvent`, then the engine tick (audio buffers, timers), then every `update`.
    rt.frame = function (dt, events) {
        return entry(frame, [dt, events]);
    };

    function frame(dt, events) {
        if (rt.halted) return rt.errors.length;
        rt.frameIndex += 1;
        rt.deltaTime = dt;
        runPhase('frameGlobals', dt);
        if (events.length > 0) dispatch(events);
        runPhase('animations', dt);
        runPhase('timers', dt);
        const records = rt.records;
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (record.enabled && record.state === READY && !record.pendingDestroy) {
                rt.apply(record, invokeWithValue(record, 'update'));
            }
        }
        runPhase('deferred', dt);
        rt.destroyPending();
        return rt.errors.length;
    }

    // Every script's `destroy()`, in order, then no records. A `destroy()` that removes another
    // script changes nothing here: every record gets exactly one `destroy()`.
    rt.teardown = function () {
        return entry(teardown, []);
    };

    function teardown() {
        const records = rt.records.slice();
        for (let i = 0; i < records.length && !rt.halted; i++) {
            const record = records[i];
            if (record.destroyed) continue;
            record.destroyed = true;
            if (record.state === READY) rt.invoke(record, 'destroy', []);
        }
        rt.records = [];
        rt.byId.clear();
        return rt.errors.length;
    }

    // Called by the native side after the watchdog terminated script code: stops all script code
    // for good, like WE's engine-wide flag, and returns the id that was running.
    rt.halt = function () {
        const id = rt.current;
        rt.halted = true;
        rt.current = null;
        rt.phase = 'idle';
        // A terminated entry never ran its `finally`.
        entries = 0;
        return id;
    };

    // MARK: command ring (SceneScriptCommandRing.swift owns the memory and the layout)

    rt.attachRing = function (header, records, args, recordStride) {
        rt.ring = { header: header, records: records, args: args, stride: recordStride, strings: [] };
    };

    // Appends one command. `numbers` is an array of numbers (or undefined), `strings` of strings.
    rt.push = function (opcode, target, numbers, strings) {
        const ring = rt.ring;
        const header = ring.header;
        const count = header[0], argCount = header[1];
        const numberCount = numbers ? numbers.length : 0;
        if ((count + 1) * ring.stride > ring.records.length || argCount + numberCount > ring.args.length) {
            header[2] = 1;
            return false;
        }
        const base = count * ring.stride;
        ring.records[base] = opcode;
        ring.records[base + 1] = target;
        ring.records[base + 2] = argCount;
        ring.records[base + 3] = numberCount;
        ring.records[base + 4] = strings ? ring.strings.length : 0;
        ring.records[base + 5] = strings ? strings.length : 0;
        for (let i = 0; i < numberCount; i++) ring.args[argCount + i] = numbers[i];
        if (strings) for (let i = 0; i < strings.length; i++) ring.strings.push(String(strings[i]));
        header[0] = count + 1;
        header[1] = argCount + numberCount;
        return true;
    };

    rt.resetRing = function () {
        rt.ring.header[0] = 0;
        rt.ring.header[1] = 0;
        rt.ring.header[2] = 0;
        rt.ring.strings = [];
    };

    // MARK: reach (test-risks S28)

    // Once every extension is installed: no hook or runtime function can be replaced any more,
    // by a script that got hold of `__rt` or by anything else.
    rt.seal = function () {
        Object.freeze(rt.hooks);
        Object.keys(rt).forEach(function (key) {
            if (typeof rt[key] === 'function') Object.defineProperty(rt, key, { writable: false, configurable: false });
        });
    };

    if (global.shared === undefined) global.shared = {};
    // Runtime and extension files capture `__rt` when they are evaluated. Scripts must not reach
    // it: the global reads as undefined while a native entry (load, frame, teardown) or any script
    // code runs, and a compiled module's own scope shadows the name (SceneScriptModuleTransformer).
    // So script code, or runtime code calling a builtin a script replaced, never sees the records,
    // hooks or ring. The native side and tests read it between entries.
    Object.defineProperty(global, '__rt', {
        get: function () { return entries === 0 && rt.current === null ? rt : undefined; },
        enumerable: false, configurable: false,
    });
})(this);
