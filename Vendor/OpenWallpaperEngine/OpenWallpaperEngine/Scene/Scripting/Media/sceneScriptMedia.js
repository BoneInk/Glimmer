'use strict';
// Media integration callbacks (WP6, docs/scenescript-plan.md; lib.sceneScript.d.ts IComponent
// media* and the Media*Event classes). SceneScriptMediaExtension.swift posts one inbox event per
// changed part, tagged with the state's version, and answers `__rt.native.mediaSnapshot()` with
// the current state's events and version. Every script gets its own event object.
(function (global) {
    const rt = global.__rt;
    const native = rt.native;

    // WE's baseclasses.js declares `class Vec3` at top level: a global binding, not a property of
    // the global object.
    function vec3(rgb) { return new Vec3(rgb[0], rgb[1], rgb[2]); }

    // Inbox kind → the callback WE calls and its event object.
    const EVENTS = {
        mediaStatus: ['mediaStatusChanged', function (p) { return { enabled: p.enabled }; }],
        mediaPlayback: ['mediaPlaybackChanged', function (p) { return { state: p.state }; }],
        mediaProperties: ['mediaPropertiesChanged', function (p) {
            return { title: p.title, artist: p.artist, subTitle: p.subTitle, albumTitle: p.albumTitle,
                albumArtist: p.albumArtist, genres: p.genres, contentType: p.contentType };
        }],
        mediaThumbnail: ['mediaThumbnailChanged', function (p) {
            return { hasThumbnail: p.hasThumbnail, primaryColor: vec3(p.primaryColor),
                secondaryColor: vec3(p.secondaryColor), tertiaryColor: vec3(p.tertiaryColor),
                textColor: vec3(p.textColor), highContrastColor: vec3(p.highContrastColor) };
        }],
        mediaTimeline: ['mediaTimelineChanged', function (p) { return { position: p.position, duration: p.duration }; }],
    };

    function exportsCallback(record, name) {
        try {
            return typeof rt.exports(record, name) === 'function';
        } catch (error) {
            return true; // Let `invoke` report the throwing getter.
        }
    }

    function send(record, kind, payload) {
        const entry = EVENTS[kind];
        if (!entry || !exportsCallback(record, entry[0])) return;
        rt.invoke(record, entry[0], [entry[1](payload)]);
    }

    Object.keys(EVENTS).forEach(function (kind) {
        rt.addEventHandler(kind, rt.EVENT_ORDER.media, function (event) {
            const payload = event.payload;
            const records = rt.records;
            for (let i = 0; i < records.length; i++) {
                const record = records[i];
                // Scripts not yet initialised get the state after their `init` instead; scripts
                // initialised with this version or a newer one have seen this change already.
                if (record.enabled && record.mediaVersion !== undefined && record.mediaVersion < payload.version) {
                    send(record, kind, payload);
                }
            }
        });
    });

    // WE sends the current media state to each script right after its `init` (§1.9 P8).
    const initialized = rt.hooks.initialized;
    rt.hooks.initialized = function (record) {
        initialized(record);
        record.mediaVersion = -1;
        const snapshot = native.mediaSnapshot();
        record.mediaVersion = snapshot.version;
        for (let i = 0; i < snapshot.events.length; i++) {
            send(record, snapshot.events[i].kind, snapshot.events[i].payload);
        }
    };
})(this);
