import Foundation

/// Narrow defaults boundary so migration commit behavior can be tested without
/// reading or writing the user's real preference domains.
protocol GlimmerDefaultsStoring: AnyObject {
    func bool(forKey: String) -> Bool
    func object(forKey: String) -> Any?
    func set(_ value: Any?, forKey: String)
    func synchronize() -> Bool
    func persistentDomain(forName: String) -> [String: Any]?
}

extension UserDefaults: GlimmerDefaultsStoring {}

/// One-time preference-domain migration. Existing values in the Glimmer domain
/// always win; the previous domain is only read and is never removed.
enum GlimmerUserDefaultsMigration {
    struct Result: Equatable, Sendable {
        let importedKeys: Int
        let importedWindowFrame: Bool
        let markerAlreadyPresent: Bool
        /// True only after both imported values and the completion marker have
        /// been accepted by the defaults store.
        let committed: Bool
        let failureReason: String?
    }

    @discardableResult
    static func migrateIfNeeded(to current: any GlimmerDefaultsStoring = UserDefaults.standard,
                                legacy legacyStorage: (any GlimmerDefaultsStoring)? = nil,
                                legacySuiteName: String = GlimmerIdentity.legacyBundleIdentifier,
                                markerKey: String = GlimmerIdentity.defaultsMigrationMarker) -> Result {
        if current.bool(forKey: markerKey) {
            return Result(importedKeys: 0, importedWindowFrame: false,
                          markerAlreadyPresent: true, committed: true, failureReason: nil)
        }
        let legacy = legacyStorage ?? UserDefaults(suiteName: legacySuiteName)
        let oldValues = legacy?.persistentDomain(forName: legacySuiteName) ?? [:]
        let oldFrameKey = "NSWindow Frame \(GlimmerIdentity.legacyLibraryWindowAutosaveName)"
        let newFrameKey = "NSWindow Frame \(GlimmerIdentity.libraryWindowAutosaveName)"
        var imported = 0
        for (key, value) in oldValues where key != markerKey && key != oldFrameKey {
            guard current.object(forKey: key) == nil else { continue }
            current.set(value, forKey: key)
            imported += 1
        }
        var frameImported = false
        if current.object(forKey: newFrameKey) == nil, let frame = oldValues[oldFrameKey] {
            current.set(frame, forKey: newFrameKey)
            frameImported = true
        }

        // Values are flushed before the marker. If this fails, no completion
        // marker is claimed and the next launch retries the (idempotent) import.
        guard current.synchronize() else {
            current.set(false, forKey: markerKey)
            _ = current.synchronize()
            return Result(importedKeys: imported, importedWindowFrame: frameImported,
                          markerAlreadyPresent: false, committed: false,
                          failureReason: "旧偏好写入未能提交，将在下次启动重试")
        }

        current.set(true, forKey: markerKey)
        guard current.synchronize() else {
            // Best effort to remove a marker that the store did not confirm.
            // Even if this second flush also fails, callers must not report the
            // migration as committed and therefore retry on the next launch.
            current.set(false, forKey: markerKey)
            _ = current.synchronize()
            return Result(importedKeys: imported, importedWindowFrame: frameImported,
                          markerAlreadyPresent: false, committed: false,
                          failureReason: "旧偏好迁移标记未能提交，将在下次启动重试")
        }
        return Result(importedKeys: imported, importedWindowFrame: frameImported,
                      markerAlreadyPresent: false, committed: true, failureReason: nil)
    }

    static func windowFrameKey(for autosaveName: String) -> String {
        "NSWindow Frame \(autosaveName)"
    }
}
