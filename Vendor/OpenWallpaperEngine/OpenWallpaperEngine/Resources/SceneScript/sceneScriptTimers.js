'use strict';
// `engine.setTimeout` and `engine.setInterval` (lib.sceneScript.d.ts IEngine; WP4,
// docs/scenescript-plan.md). Both return a function that cancels the timer; WE has no
// clearTimeout ("Not implemented. Use returned function to clear."). Follows scenescript64.dll:
//
// - Not callable at global scope; the delay is in milliseconds, 0 when missing or not a number;
//   no callback (or not a function) returns null and starts nothing.
// - A timer belongs to the script that started it. Each frame, in the `timers` phase (after
//   events and animations, before every `update`), every script's timers run in script order,
//   each script over a snapshot of its list: the remaining time (a float, like WE's) drops by
//   the frame time, and a timer whose remaining time is no longer above 0 fires. So a NaN delay
//   fires on the next frame, like WE's `comiss`.
// - After firing, an interval's remaining time is reset to its period, so it fires at most once
//   per frame; a timeout is removed.
// - Callbacks run through `__rt.call`: an error is logged and disables nothing.
(function (global) {
    const rt = global.__rt;
    // Keyed by record object, not id: a script removed and added again under the same id starts
    // with no timers.
    const timersByRecord = new Map();

    function start(callback, delay, repeat, what) {
        rt.forbidGlobalScope(what);
        if (typeof callback !== 'function') return null;
        const record = rt.byId.get(rt.current);
        if (record === undefined) return null;
        const seconds = typeof delay === 'number' ? Math.fround(delay / 1000) : 0;
        const timer = { remaining: seconds, period: seconds, repeat: repeat, callback: callback, active: true };
        let timers = timersByRecord.get(record);
        if (timers === undefined) {
            timers = [];
            timersByRecord.set(record, timers);
        }
        timers.push(timer);
        return function () {
            if (rt.phase === 'global') throw new Error('timeout cannot be cleared from global scope.');
            cancel(record, timer);
        };
    }

    function cancel(record, timer) {
        if (!timer.active) return;
        timer.active = false;
        const timers = timersByRecord.get(record);
        if (timers === undefined) return;
        const index = timers.indexOf(timer);
        if (index >= 0) timers.splice(index, 1);
    }

    function tick(dt) {
        const elapsed = Math.fround(dt);
        const records = rt.records;
        for (let i = 0; i < records.length; i++) {
            const record = records[i];
            const timers = timersByRecord.get(record);
            if (timers === undefined || timers.length === 0) continue;
            const snapshot = timers.slice();
            for (let j = 0; j < snapshot.length; j++) {
                const timer = snapshot[j];
                if (!timer.active) continue;
                timer.remaining = Math.fround(timer.remaining - elapsed);
                if (timer.remaining > 0) continue;
                rt.call(record, timer.repeat ? 'setInterval' : 'setTimeout', 'callback', timer.callback, []);
                if (timer.repeat) {
                    timer.remaining = timer.period;
                } else {
                    cancel(record, timer);
                }
            }
        }
        // Timers of removed scripts die with them.
        timersByRecord.forEach(function (timers, record) {
            if (rt.byId.get(record.id) !== record) timersByRecord.delete(record);
        });
    }

    rt.addPhaseHandler('timers', tick);

    global.engine.setTimeout = function (callback, delay) {
        return start(callback, delay, false, 'setTimeout');
    };
    global.engine.setInterval = function (callback, delay) {
        return start(callback, delay, true, 'setInterval');
    };
})(this);
