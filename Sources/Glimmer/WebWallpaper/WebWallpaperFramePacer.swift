import Foundation

/// Limits authored RAF callbacks on WebKit's own display clock. Media, CSS,
/// workers and timers keep native semantics; this is not a total GPU-work cap.
enum WebWallpaperFramePacer {
    static func script(fps: Int) -> String {
        """
        (() => {
          const request = window.requestAnimationFrame.bind(window);
          const cancel = window.cancelAnimationFrame.bind(window);
          const interval = 1000 / \(max(1, min(240, fps)));
          const pending = new Map();
          let next = 0, handle = null, slot = null;
          function schedule() {
            if (handle === null && pending.size) handle = request(frame);
          }
          function frame(time) {
            handle = null;
            if (slot !== null && time + 0.01 < slot) { schedule(); return; }
            slot = slot === null || time - slot >= interval ? time + interval : slot + interval;
            const batch = Array.from(pending.entries());
            for (const [id, callback] of batch) {
              if (!pending.delete(id)) continue;
              try { callback(time); }
              catch (error) { setTimeout(() => { throw error; }, 0); }
            }
            schedule();
          }
          window.requestAnimationFrame = callback => {
            if (typeof callback !== 'function') throw new TypeError('Animation callback must be a function');
            const id = ++next;
            pending.set(id, callback); schedule(); return id;
          };
          window.cancelAnimationFrame = id => {
            pending.delete(id);
            if (!pending.size && handle !== null) { cancel(handle); handle = null; slot = null; }
          };
        })();
        """
    }
}
