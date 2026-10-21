import Foundation

/// The system's now-playing session, for SceneScript's media events (docs/scenescript-plan.md
/// WP6). `MacMediaSessionSource` reads it from macOS; tests use a fake. One source serves every
/// runtime of the process: each runtime's `SceneScriptMediaExtension` subscribes.
protocol MediaSessionSource: AnyObject {
    /// Adds a subscriber and returns its id. `update` receives the current state soon after, then
    /// every state that may have changed, on any thread, never concurrently with itself. A source
    /// that can't work reports a state with `enabled == false`.
    func subscribe(_ update: @escaping (MediaSessionState) -> Void) -> Int

    /// Removes a subscriber without waiting for the source's work; no `update` for it starts after
    /// this returns.
    func unsubscribe(_ id: Int)
}
