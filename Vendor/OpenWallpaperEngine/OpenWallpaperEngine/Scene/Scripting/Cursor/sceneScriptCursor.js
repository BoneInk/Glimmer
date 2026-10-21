'use strict';
// Cursor callbacks (WP10, docs/scenescript-plan.md §4.8; lib.sceneScript.d.ts IComponent cursor*
// and CursorEvent). SceneScriptCursorExtension.swift runs WE's cursor pass and posts one inbox
// event per callback, targeted at the slot of the object that was hit; only that object's
// scripts are called (§1.9 P7), once they ran `init`.
(function (global) {
    const rt = global.__rt;
    const CALLBACKS = ['cursorEnter', 'cursorLeave', 'cursorMove', 'cursorDown', 'cursorUp', 'cursorClick'];

    function exportsCallback(record, name) {
        try {
            return typeof rt.exports(record, name) === 'function';
        } catch (error) {
            return true; // Let `invoke` report the throwing getter.
        }
    }

    // scenescript64.dll builds the event for each call (0x18164ec5f): `button` (always 0, the
    // left button), `worldPosition` and `localPosition` as Vec3, and `hitBox` only when the pass
    // named a hit box (a puppet's or model's, SceneScriptCursorPass). `Vec3` is baseclasses.js's
    // global class binding.
    function cursorEvent(payload) {
        const world = payload.worldPosition, local = payload.localPosition;
        const event = { button: 0, worldPosition: new Vec3(world[0], world[1], world[2]),
            localPosition: new Vec3(local[0], local[1], local[2]) };
        if (typeof payload.hitBox === 'string') event.hitBox = payload.hitBox;
        return event;
    }

    function deliver(event) {
        const payload = event.payload;
        const name = payload.callback;
        if (CALLBACKS.indexOf(name) < 0) throw new Error('Unknown cursor callback ' + name);
        const records = rt.records;
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            if (!record.enabled || record.cursorReady !== true || record.slot !== event.target) continue;
            if (exportsCallback(record, name)) rt.invoke(record, name, [cursorEvent(payload)]);
        }
    }

    rt.addEventHandler('cursor', rt.EVENT_ORDER.cursor, deliver);
    rt.addEventHandler('cursorMove', rt.EVENT_ORDER.cursor, deliver);

    // WE sends cursor callbacks only to components that finished `init` (state 2, 0x14018a381).
    const initialized = rt.hooks.initialized;
    rt.hooks.initialized = function (record) {
        record.cursorReady = true;
        initialized(record);
    };
})(this);
