import Foundation

/// One live animation scheduler shared by desktop, preview and lock-screen Web
/// hosts. Host pause stops RAF scheduling after a single initial paused bootstrap
/// batch. CSS, workers and timers retain their own clocks. HTML media suspension is managed separately by the runtime.
enum WebWallpaperFramePacer {
    static func script(fps: Int, paused: Bool = false) -> String {
        """
        (() => {
          const request = window.requestAnimationFrame.bind(window);
          const cancel = window.cancelAnimationFrame.bind(window);
          let fps = \(max(1, min(240, fps)));
          let interval = 1000 / fps;
          const pending = new Map();
          let paused = \(paused ? "true" : "false"), bootstrap = paused;
          let next = 0, handle = null, slot = null, dispatching = false, pauseEpoch = 0;
          window.__gwSetWallpaperPaused = value => {
            value = !!value;
            if (value === paused) return;
            paused = value; bootstrap = false; slot = null;
            if (paused) {
              ++pauseEpoch;
              if (handle !== null) { cancel(handle.id); handle = null; }
            } else schedule();
          };
          window.__gwSetWallpaperFrameRate = value => {
            if (!Number.isFinite(value) || value < 1 || value > 240) return;
            value = Math.trunc(value);
            if (value === fps) return;
            fps = value; interval = 1000 / fps; slot = null;
          };
          function schedule() {
            if ((paused && !bootstrap) || dispatching || handle !== null || !pending.size) return;
            // An entry identity rejects a cancelled native callback that was already
            // dispatched before pause/resume scheduled its replacement.
            const entry = {id: null};
            handle = entry;
            entry.id = request(time => {
              if (handle !== entry) return;
              handle = null;
              frame(time);
            });
          }
          function frame(time) {
            if (paused && !bootstrap) return;
            // One initial author batch gives common RAF-only canvases a first
            // image. Nested requests remain pending without further wakeups.
            const bootstrapping = paused && bootstrap;
            bootstrap = false;
            if (slot !== null && time + 0.01 < slot) { schedule(); return; }
            slot = slot === null || time - slot >= interval ? time + interval : slot + interval;
            const batch = Array.from(pending.entries()), epoch = pauseEpoch;
            dispatching = true;
            try {
              for (const [id, callback] of batch) {
                // Keep uncalled entries pending, including when an author pauses
                // and resumes synchronously from another callback in this batch.
                if ((paused && !bootstrapping) || epoch !== pauseEpoch) break;
                if (!pending.delete(id)) continue;
                try { callback(time); }
                catch (error) { setTimeout(() => { throw error; }, 0); }
              }
            } finally { dispatching = false; schedule(); }
          }
          window.requestAnimationFrame = callback => {
            if (typeof callback !== 'function') throw new TypeError('Animation callback must be a function');
            const id = ++next;
            pending.set(id, callback); schedule(); return id;
          };
          window.cancelAnimationFrame = id => {
            pending.delete(id);
            if (!pending.size) {
              if (handle !== null) { cancel(handle.id); handle = null; }
              if (!dispatching) slot = null;
            }
          };
        })();
        """
    }
}
