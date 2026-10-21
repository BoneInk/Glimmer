import Foundation

extension OWELog {
    /// `try?` that leaves a trace: `body`'s value, or nil after an error line "`what`: error".
    /// For reads and decodes the caller already falls back from, but whose failure means corrupt
    /// data, a permission problem or a bug. With `quietIfMissing`, a file that doesn't exist is
    /// the expected nil and logs nothing. Each distinct line is logged once per run, so a failure
    /// a view asks about again doesn't repeat; still, not for per-frame paths.
    @discardableResult
    static func attempt<T>(_ category: Category, _ what: @autoclosure () -> String,
                           quietIfMissing: Bool = false, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            if !(quietIfMissing && isMissingFile(error)) { logOnce(category, "\(what()): \(error)") }
            return nil
        }
    }

    /// The async form of `attempt(_:_:quietIfMissing:_:)`.
    @discardableResult
    static func attemptAsync<T>(_ category: Category, _ what: @autoclosure () -> String,
                                quietIfMissing: Bool = false, _ body: () async throws -> T) async -> T? {
        do {
            return try await body()
        } catch {
            if !(quietIfMissing && isMissingFile(error)) { logOnce(category, "\(what()): \(error)") }
            return nil
        }
    }

    /// Whether `error` says only that the file isn't there.
    static func isMissingFile(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) { return true }
        return false
    }

    private static let loggedLock = NSLock()
    nonisolated(unsafe) private static var logged: Set<String> = []

    private static func logOnce(_ category: Category, _ message: String) {
        loggedLock.lock()
        let isNew = logged.insert(message).inserted
        loggedLock.unlock()
        if isNew { OWELog.error(category, message) }
    }
}
