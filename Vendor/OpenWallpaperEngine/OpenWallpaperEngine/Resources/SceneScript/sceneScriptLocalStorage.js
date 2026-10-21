'use strict';
// The `localStorage` global (lib.sceneScript.d.ts ILocalStorage; WP4, docs/scenescript-plan.md),
// following scenescript64.dll's LocalStorageSet/Get/Delete/Clear:
//
// - Not callable at global scope, with WE's own (copy-pasted) messages.
// - A key that is not a string throws "LocalStorageSet key not a string.", in get and delete too.
// - The location is 'global' only for the exact string 'global'; anything else, or nothing, is
//   'screen' (the default).
// - `set` stores `JSON.stringify(value)` as text (v8::JSON::Stringify, so a function is stored as
//   "undefined"). Setting `undefined`, or a value JSON can't serialize (a cycle, a BigInt),
//   deletes the key instead, and a serializing error is thrown afterwards. WE runs that delete
//   with `set`'s own arguments, so it reads the value as the location: it always hits 'screen'.
// - A store holds at most 100000 bytes (SceneScriptStorage.capacity); a `set` past it throws
//   "LocalStorageSet failed, possibly out of memory." and stores nothing.
// - `get` returns the parsed value, undefined for a missing key and null for text that doesn't
//   parse. Class instances come back as plain objects (a Vec3 as {x, y, z}), as through JSON.
// - `delete` returns whether the key was stored.
(function (global) {
    const rt = global.__rt;
    const native = rt.native;
    const LOCATION_GLOBAL = 'global', LOCATION_SCREEN = 'screen';

    function checkScope(what) {
        if (rt.phase === 'global') throw new Error(what + ' cannot be cleared from global scope.');
    }

    function checkKey(key) {
        if (typeof key !== 'string') throw new Error('LocalStorageSet key not a string.');
    }

    function isGlobal(location) {
        return typeof location === 'string' && location === LOCATION_GLOBAL;
    }

    function remove(key, location) {
        return native.storageDelete(key, isGlobal(location)) === true;
    }

    const storage = {
        LOCATION_GLOBAL: LOCATION_GLOBAL,
        LOCATION_SCREEN: LOCATION_SCREEN,

        set: function (key, value, location) {
            checkScope('LocalStorageSet');
            checkKey(key);
            if (value === undefined) {
                remove(key, value);
                return;
            }
            let json;
            try {
                json = String(JSON.stringify(value));
            } catch (error) {
                remove(key, value);
                throw error;
            }
            if (native.storageSet(key, json, isGlobal(location)) !== true) {
                throw new Error('LocalStorageSet failed, possibly out of memory.');
            }
        },

        get: function (key, location) {
            checkScope('LocalStorageGet');
            checkKey(key);
            const json = native.storageGet(key, isGlobal(location));
            if (json === null || json === undefined) return undefined;
            try {
                return JSON.parse(json);
            } catch (error) {
                return null;
            }
        },

        delete: function (key, location) {
            checkScope('LocalStorageDelete');
            checkKey(key);
            return remove(key, location);
        },

        clear: function (location) {
            checkScope('LocalStorageClear');
            native.storageClear(isGlobal(location));
        },
    };

    Object.defineProperty(global, 'localStorage', {
        value: storage, enumerable: false, writable: true, configurable: true,
    });
})(this);
