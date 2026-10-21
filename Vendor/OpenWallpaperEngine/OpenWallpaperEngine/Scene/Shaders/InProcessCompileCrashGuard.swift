import Foundation

/// Detects an app crash or hang inside the in-process shader compiler and quarantines the shader
/// that caused it, so later launches skip that one shader and compile every other.
///
/// A glslang abort kills the app, and the same wallpaper would crash it again on every launch.
/// While a library call runs, the file `pending-<pid>` in `directory` holds the key of the shader it
/// compiles (`InProcessShaderCompiler.shaderKey`: a hash of the step, the stage and the full input,
/// which carries the variant's combos as defines). A pending file whose process is gone on the next
/// launch (`collectDeaths`) means that process died compiling that shader. After
/// `quarantineThreshold` such deaths the shader is quarantined: `isQuarantined` is true for it, its
/// variant fails (logged, like any failed translation) and nothing else changes. A call that hangs
/// (`recordHang`) quarantines its shader at once: a thread can't be killed, so a hang is as
/// certain as a crash.
///
/// The quarantine belongs to one build of the libraries (`fingerprint`): new libraries start with
/// none, since they may have fixed the crash.
///
/// Separate from the app's safe-restart ledger (`SafeRestartLedger`), which reacts to the same
/// crash per wallpaper (not restoring it); this one reacts per shader. Neither reads or writes the
/// other's files.
///
/// Thread-safe: `lock` owns `record`.
final class InProcessCompileCrashGuard {
    let directory: URL
    /// The libraries the quarantine applies to (`InProcessShaderCompiler.libraryFingerprint`).
    let fingerprint: String
    private let pid: Int32
    private let lock = NSLock()
    private var record: Record

    /// Deaths mid-compile of one shader that quarantine it. One is not enough: a force quit, logout
    /// or power loss during a compile leaves the same marker as a crash. They are not forgiven by
    /// clean runs, because safe restart keeps a crashing wallpaper from loading on the next launch,
    /// so its crashes are rarely consecutive.
    static let quarantineThreshold = 2

    /// What `quarantine.json` records: the libraries, and the deaths and hangs of each shader key.
    private struct Record: Codable {
        var fingerprint: String
        var deaths: [String: Int]
    }

    init(directory: URL, fingerprint: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.directory = directory
        self.fingerprint = fingerprint
        self.pid = pid
        record = Record(fingerprint: fingerprint, deaths: [:])
        if let stored = Self.loadRecord(from: directory.appending(path: "quarantine.json")),
           stored.fingerprint == fingerprint {
            record = stored
        }
    }

    private var pendingURL: URL { directory.appending(path: "pending-\(pid)") }
    private var recordURL: URL { directory.appending(path: "quarantine.json") }

    /// Marks `key` as compiling on this process. Calls are serialized on the compile thread, so at
    /// most one is in flight.
    func begin(_ key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(key.utf8).write(to: pendingURL)
        } catch {
            OWELog.error(.shader, "Could not write the shader compile marker \(pendingURL.path): \(error)")
        }
    }

    func end() {
        do {
            try FileManager.default.removeItem(at: pendingURL)
        } catch {
            OWELog.error(.shader, "Could not remove the shader compile marker \(pendingURL.path): \(error)")
        }
    }

    /// Whether `key`'s shader killed or hung the app often enough to be skipped.
    func isQuarantined(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (record.deaths[key] ?? 0) >= Self.quarantineThreshold
    }

    /// Checks for markers left by dead processes and records a death against the shader each names.
    /// Call once at launch, before compiling.
    func collectDeaths() {
        let fileManager = FileManager.default
        // Optional: no directory yet means nothing ever crashed here.
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for name in names where name.hasPrefix("pending-") {
            guard let owner = Int32(name.dropFirst("pending-".count)), !Self.isAlive(owner) else { continue }
            let url = directory.appending(path: name)
            // Optional: an unreadable marker is a death we can't pin on a shader.
            let key = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            do {
                try fileManager.removeItem(at: url)
            } catch {
                OWELog.error(.shader, "Could not remove the stale shader compile marker \(name): \(error)")
            }
            guard !key.isEmpty else {
                OWELog.error(.shader, "A previous run died while compiling an unknown shader in-process")
                continue
            }
            let deaths = (record.deaths[key] ?? 0) + 1
            record.deaths[key] = deaths
            changed = true
            OWELog.error(.shader, "A previous run died while compiling shader \(key.prefix(12)) in-process "
                         + "(\(deaths) with these libraries)"
                         + (deaths >= Self.quarantineThreshold ? "; it is skipped from now on" : ""))
        }
        if changed { save() }
        let count = record.deaths.values.filter { $0 >= Self.quarantineThreshold }.count
        if count > 0 {
            OWELog.error(.shader, "\(count) shader(s) quarantined for crashing or hanging the shader libraries; "
                         + "they are skipped until the libraries change")
        }
    }

    /// Quarantines the shader whose compile overran its timeout.
    func recordHang(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        record.deaths[key] = max(record.deaths[key] ?? 0, Self.quarantineThreshold)
        OWELog.error(.shader, "An in-process compile of shader \(key.prefix(12)) hung; it is skipped from now on")
        save()
    }

    private static func loadRecord(from url: URL) -> Record? {
        // Optional: a missing file means no shader ever crashed.
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Record.self, from: data)
        } catch {
            OWELog.error(.shader, "Discarding the unreadable shader quarantine \(url.path): \(error)")
            return nil
        }
    }

    /// Caller holds `lock`.
    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        } catch {
            OWELog.error(.shader, "Could not record the shader quarantine: \(error)")
        }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
