//
//  SafeRestartStore.swift
//  Open Wallpaper Engine
//

import Foundation

/// Persists the `SafeRestartLedger` as a small JSON file, flushed to disk on every write so the
/// sentinel survives a kernel panic or power loss, not only an app crash.
struct SafeRestartStore {
    let fileURL: URL

    static var defaultFileURL: URL {
        AppStorageLocation.current.supportDirectory
            .appending(path: "SafeRestart.json")
    }

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() -> SafeRestartLedger {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SafeRestartLedger() }
        do {
            return try JSONDecoder().decode(SafeRestartLedger.self, from: Data(contentsOf: fileURL))
        } catch {
            OWELog.error(.app, "Reading the safe-restart sentinel at \(fileURL.path) failed: \(error)")
            return SafeRestartLedger()
        }
    }

    func save(_ ledger: SafeRestartLedger) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: fileURL, options: .atomic)
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() } // Closing a read handle after a successful sync cannot lose data.
            try handle.synchronize()
        } catch {
            OWELog.error(.app, "Writing the safe-restart sentinel at \(fileURL.path) failed: \(error)")
        }
    }
}
