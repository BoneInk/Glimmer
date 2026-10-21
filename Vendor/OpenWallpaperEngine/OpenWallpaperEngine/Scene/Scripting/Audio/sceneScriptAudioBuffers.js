'use strict';
// `engine.registerAudioBuffers(resolution)` (WP5, docs/scenescript-plan.md; lib.sceneScript.d.ts
// IEngine and AudioBuffers), as scenescript64.dll does it (0x181655170). Each call gets new
// Float32Arrays over the scene's one native store per resolution and channel
// (`__rt.native.audioBuffer(resolution, channel)`), which SceneScriptAudioBuffersExtension.swift
// refills in place before every frame, so the arrays are live.
(function (global) {
    const rt = global.__rt;
    const native = rt.native;
    const LEFT = 0, RIGHT = 1, AVERAGE = 2;

    function registerAudioBuffers(resolution) {
        rt.requireGlobalScope('registerAudioBuffers');
        // The DLL reads a number argument as an int32; without one it uses 16.
        const bands = typeof resolution === 'number' ? resolution | 0 : 16;
        if (bands !== 16 && bands !== 32 && bands !== 64) {
            throw new Error('Resolution must be either 16, 32 or 64.');
        }
        return {
            left: native.audioBuffer(bands, LEFT),
            right: native.audioBuffer(bands, RIGHT),
            average: native.audioBuffer(bands, AVERAGE),
        };
    }

    // WP4's engine file adds its members to the same object, whichever runs first.
    const engine = global.engine !== undefined ? global.engine : {};
    engine.registerAudioBuffers = registerAudioBuffers;
    if (engine.AUDIO_RESOLUTION_16 === undefined) engine.AUDIO_RESOLUTION_16 = 16;
    if (engine.AUDIO_RESOLUTION_32 === undefined) engine.AUDIO_RESOLUTION_32 = 32;
    if (engine.AUDIO_RESOLUTION_64 === undefined) engine.AUDIO_RESOLUTION_64 = 64;
    global.engine = engine;
})(this);
