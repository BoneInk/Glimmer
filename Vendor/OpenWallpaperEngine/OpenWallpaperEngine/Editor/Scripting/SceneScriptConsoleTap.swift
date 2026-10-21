import Foundation
import os

/// Hands what running scripts write (`console.log`/`console.error`) and the errors the runtime
/// reports for them to whoever listens for that wallpaper: the Wallpaper Editor's console. Lines
/// still go to the log as before; with no listener a line costs one lock.
enum SceneScriptConsoleTap {
    struct Line: Sendable {
        /// `SceneScriptStorageKey.key(forWallpaperDirectory:)`, as the runtime names the wallpaper.
        var wallpaperID: String
        var scriptID: String
        var isError: Bool
        var message: String
        /// 1-based line in the script's source, when known.
        var line: Int?
    }

    typealias Handler = @Sendable (Line) -> Void

    private struct Listener {
        let wallpaperID: String
        let handler: Handler
    }

    private static let listeners = OSAllocatedUnfairLock(initialState: [UUID: Listener]())

    /// Starts handing `wallpaperID`'s lines to `handler` (on the script thread); returns the token
    /// that stops it.
    static func listen(to wallpaperID: String, handler: @escaping Handler) -> UUID {
        let token = UUID()
        listeners.withLock { $0[token] = Listener(wallpaperID: wallpaperID, handler: handler) }
        return token
    }

    static func stop(_ token: UUID) {
        _ = listeners.withLock { $0.removeValue(forKey: token) }
    }

    /// From the runtime's thread.
    static func post(_ line: Line) {
        let handlers = listeners.withLock { listeners in
            listeners.values.filter { $0.wallpaperID == line.wallpaperID }.map(\.handler)
        }
        for handler in handlers { handler(line) }
    }
}
