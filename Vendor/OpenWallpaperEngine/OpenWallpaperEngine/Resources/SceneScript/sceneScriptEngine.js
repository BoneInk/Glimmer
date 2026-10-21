'use strict';
// The `engine`, `input` and `renderContext` globals (lib.sceneScript.d.ts IEngine, IInput,
// IRenderContext) and the conversion of user properties (WP4, docs/scenescript-plan.md).
// Per-frame numbers are getters over the shared Float32Array that SceneScriptEngineExtension.swift
// fills before each frame; the slot numbers below mirror its `Slot` enum. `engine.runtime` alone
// is a double (`engineClock`), so it keeps millisecond steps on a wallpaper that runs for weeks.
// Vectors are new objects on every read, like WE's getters.
(function (global) {
    const rt = global.__rt;
    const frame = rt.native.engineFrame;
    const clock = rt.native.engineClock;
    const FRAMETIME = 0, TIME_OF_DAY = 2, SCREEN_RESOLUTION = 3, CANVAS_SIZE = 5,
        CURSOR_WORLD = 7, CURSOR_SCREEN = 10, CURSOR_LEFT_DOWN = 12, IS_SCREENSAVER = 13,
        IS_RUNNING_IN_EDITOR = 14;

    function vec2(slot) { return new Vec2(frame[slot], frame[slot + 1]); }

    // MARK: user shortcuts

    // wallpaper64.exe allows user commands only while dispatching cursorClick, cursorDown and
    // cursorUp (callback indices 11–13), and one per click. `rt.callback` is the running callback
    // (scenescript64.dll keeps its index while calling it); timers run outside any callback, like
    // WE, which runs them as index 0 (`init`), never a cursor callback. A frame's cursor events belong to one
    // click at most, so the count resets every frame (best guess for where WE resets it).
    const SHORTCUT_CALLBACKS = ['cursorClick', 'cursorDown', 'cursorUp'];
    let shortcutRan = false;
    rt.addPhaseHandler('frameGlobals', function () { shortcutRan = false; });

    function openUserShortcut(name) {
        if (SHORTCUT_CALLBACKS.indexOf(rt.callback) < 0) {
            throw new Error('Cannot execute user command outside of cursor callbacks.');
        }
        if (typeof name !== 'string') return false;
        if (shortcutRan) throw new Error('Cannot execute more than one user command per cursor click.');
        const ran = rt.native.engineOpenUserShortcut(name) === true;
        if (ran) shortcutRan = true;
        return ran;
    }

    // MARK: user properties

    // The native side hands WE's raw property objects ({type, value, …}, as in project.json) to
    // `_Internal.convertUserProperties` as JSON (baseclasses.js): colours become Vec3, user
    // shortcuts {isbound, commandtype, file}, everything else its value. `engine.userProperties`
    // keeps every property's current converted value; each call converts separately, so a script
    // that changes the object it was given can't change `engine.userProperties`.
    // Without WE's prelude (no assets directory) there is no converter: scripts get the raw
    // objects, as when the conversion throws (runtime.js), and `engine.userProperties` stays empty.
    const userProperties = {};
    rt.hooks.userProperties = function (properties) {
        const internal = global._Internal;
        if (!internal || typeof internal.convertUserProperties !== 'function') return properties;
        const json = JSON.stringify(properties === undefined || properties === null ? {} : properties);
        Object.assign(userProperties, internal.convertUserProperties(json));
        return internal.convertUserProperties(json);
    };

    // MARK: engine

    // Other extensions (audio buffers, assets) add their members to the same object.
    const engine = global.engine !== undefined ? global.engine : {};
    Object.defineProperties(engine, {
        frametime: { get: function () { return frame[FRAMETIME]; }, enumerable: true, configurable: true },
        runtime: { get: function () { return clock[0]; }, enumerable: true, configurable: true },
        timeOfDay: { get: function () { return frame[TIME_OF_DAY]; }, enumerable: true, configurable: true },
        screenResolution: { get: function () { return vec2(SCREEN_RESOLUTION); }, enumerable: true, configurable: true },
        canvasSize: { get: function () { return vec2(CANVAS_SIZE); }, enumerable: true, configurable: true },
        userProperties: { get: function () { return userProperties; }, enumerable: true, configurable: true },
    });
    engine.AUDIO_RESOLUTION_16 = 16;
    engine.AUDIO_RESOLUTION_32 = 32;
    engine.AUDIO_RESOLUTION_64 = 64;
    engine.isRunningInEditor = function () { return frame[IS_RUNNING_IN_EDITOR] !== 0; };
    engine.isPortrait = function () { return frame[SCREEN_RESOLUTION + 1] > frame[SCREEN_RESOLUTION]; };
    engine.isLandscape = function () { return !engine.isPortrait(); };
    engine.isDesktopDevice = function () { return true; };
    engine.isMobileDevice = function () { return false; };
    engine.isWallpaper = function () { return frame[IS_SCREENSAVER] === 0; };
    engine.isScreensaver = function () { return frame[IS_SCREENSAVER] !== 0; };
    engine.openUserShortcut = openUserShortcut;
    global.engine = engine;

    // MARK: renderContext

    // lib.sceneScript.d.ts declares `renderContext: IRenderContext`, an interface with no members
    // yet: a script can read the global, and finds nothing on it.
    global.renderContext = {};

    // MARK: input

    global.input = Object.defineProperties({}, {
        cursorWorldPosition: {
            get: function () { return new Vec3(frame[CURSOR_WORLD], frame[CURSOR_WORLD + 1], frame[CURSOR_WORLD + 2]); },
            enumerable: true,
        },
        cursorScreenPosition: { get: function () { return vec2(CURSOR_SCREEN); }, enumerable: true },
        cursorLeftDown: { get: function () { return frame[CURSOR_LEFT_DOWN] !== 0; }, enumerable: true },
    });
})(this);
