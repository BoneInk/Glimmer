import Foundation
import os

/// The editor packages' error log (the app's own is `OWELog`, which they can't see): one line per
/// distinct failure, under the app's subsystem. The app turns it off with its Log Level.
public enum EditorLog {
    private static let logger = Logger(subsystem: "app.openwallpaperengine", category: "Editor")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var logged: Set<String> = []
    nonisolated(unsafe) private static var enabled = true

    /// Whether errors are logged; the app sets it from its Log Level.
    public static var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// Logs `message` once per run: a failure a view asks about again doesn't repeat.
    public static func error(_ message: String) {
        let isNew = lock.withLock { enabled && logged.insert(message).inserted }
        if isNew { logger.error("\(message, privacy: .public)") }
    }

    /// `try?` that leaves a trace: `body`'s value, or nil after an error line "`what`: error".
    /// For reads and decodes the caller already falls back from, but whose failure means corrupt
    /// data, a permission problem or a bug. With `quietIfMissing`, a file that doesn't exist is the
    /// expected nil and logs nothing.
    @discardableResult
    public static func attempt<T>(_ what: @autoclosure () -> String, quietIfMissing: Bool = false,
                                  _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            if !(quietIfMissing && isMissingFile(error)) { self.error("\(what()): \(error)") }
            return nil
        }
    }

    /// Whether `error` says only that the file isn't there.
    public static func isMissingFile(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) { return true }
        return false
    }
}
