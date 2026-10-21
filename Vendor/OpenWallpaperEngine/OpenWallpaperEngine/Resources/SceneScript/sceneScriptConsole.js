'use strict';
// The `console` global (lib.sceneScript.d.ts IConsole; WP4, docs/scenescript-plan.md): `log` and
// `error` (and V8's other console members, below) with any number of arguments, each converted with String() and joined by spaces, sent to
// SceneScriptConsole.swift with the id of the script that is running.
(function (global) {
    const rt = global.__rt;

    function text(values) {
        const parts = [];
        for (let i = 0; i < values.length; i++) {
            try {
                parts.push(String(values[i]));
            } catch (error) {
                // No usable toString (Object.create(null), one that throws): log its tag instead.
                parts.push(Object.prototype.toString.call(values[i]));
            }
        }
        return parts.join(' ');
    }

    function write(isError, values) {
        rt.native.consoleWrite(isError, text(values), rt.current === null ? '' : String(rt.current));
    }

    // Replaces JavaScriptCore's own console, which writes nowhere useful. WE's typings declare
    // only `log` and `error`, but WE runs scripts on V8, whose contexts carry V8's full console
    // (scenescript64.dll holds its member names), so calling `console.warn` doesn't throw there.
    // WE's log has only "Log: " and "Error: " lines; the rest of V8's console writes nothing, except
    // `warn`, `info`, `debug` and `trace`, which log like `log` so their text isn't lost here.
    const console = {
        log: function () { write(false, arguments); },
        error: function () { write(true, arguments); },
    };
    ['warn', 'info', 'debug', 'trace'].forEach(function (name) {
        console[name] = function () { write(false, arguments); };
    });
    ['dir', 'dirxml', 'table', 'group', 'groupCollapsed', 'groupEnd', 'clear', 'count', 'countReset', 'assert',
        'profile', 'profileEnd', 'time', 'timeLog', 'timeEnd', 'timeStamp'].forEach(function (name) {
        console[name] = function () {};
    });
    try {
        Object.defineProperty(global, 'console', {
            value: console,
            enumerable: false, writable: true, configurable: true,
        });
    } catch (error) {
        // Some JavaScriptCore versions define their own `console` as non-configurable: its
        // members are replaced instead.
        for (const name in console) {
            try {
                Object.defineProperty(global.console, name, {
                    value: console[name], enumerable: false, writable: true, configurable: true,
                });
            } catch (inner) {
                global.console[name] = console[name];
            }
        }
    }
})(this);
