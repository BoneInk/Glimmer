import Foundation

/// WP10 of docs/scenescript-plan.md: the six cursor callbacks (`cursorEnter`, `cursorLeave`,
/// `cursorMove`, `cursorDown`, `cursorUp`, `cursorClick`), for the scripts of the objects the
/// cursor is over (§1.9 P7, §4.8).
///
/// The renderer calls `publish(_:)` once per frame, from any thread, with the cursor, the left
/// button and the hit-testable layers as last drawn. The cursor pass (`SceneScriptCursorPass`) runs
/// there and posts one inbox event per callback, targeted at the object's slot; the next
/// `frame(deltaTime:)` delivers them first among the frame's events (`EVENT_ORDER.cursor`), in the
/// order the pass made them. `sceneScriptCursor.js` builds WE's event object for each script.
///
/// `cursorHitTest` is in scenescript64.dll's callback table (index 7) but wallpaper64.exe never
/// sends it (the cursor pass sends only 8–13), so it is never called.
///
/// `lock` owns `pass` and `inbox`.
final class SceneScriptCursorExtension: SceneScriptRuntimeExtension {
    let scriptResources = ["sceneScriptCursor"]

    private let lock = NSLock()
    private var pass = SceneScriptCursorPass()
    private var inbox: SceneScriptInbox?

    func install(into runtime: SceneScriptRuntime) throws {
        lock.lock()
        inbox = runtime.inbox
        lock.unlock()
    }

    func tearDown(_ runtime: SceneScriptRuntime) {
        lock.lock()
        inbox = nil
        lock.unlock()
    }

    /// Runs this frame's cursor pass and queues its callbacks for the scripts. Returns the events,
    /// in delivery order. Any thread.
    @discardableResult
    func publish(_ frame: SceneScriptCursorFrame) -> [SceneScriptCursorEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = pass.update(frame)
        if let inbox {
            for event in events { inbox.post(event.inboxEvent) }
        }
        return events
    }
}
