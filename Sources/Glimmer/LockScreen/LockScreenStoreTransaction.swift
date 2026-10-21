import CryptoKit
import CoreFoundation
import Darwin
import Foundation

struct ExperimentalLockScreenFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LockScreenStorePatcher {
    static let provider = GlimmerIdentity.lockScreenProvider
    static let choice = GlimmerIdentity.lockScreenChoice

    /// The lock screen renders the system desktop role, not Idle (screen saver).
    /// Individual nodes use Desktop; linked nodes are split while retaining their
    /// former shared surface as Idle, so applying a lock screen does not change it.
    static func patch(_ bytes: Data, date: Date = Date()) throws -> Data {
        guard let root = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
            throw ExperimentalLockScreenFailure(message: "系统壁纸配置格式无法识别，未作修改。")
        }
        var changed = 0
        func visit(_ object: Any, mapping: Bool = false) throws -> Any {
            if var dictionary = object as? [String: Any] {
                let type = dictionary["Type"] as? String
                if type == "linked", let shared = dictionary["Linked"] as? [String: Any] {
                    // Preserve the screen-saver's existing effective surface when splitting.
                    dictionary["Desktop"] = shared
                    dictionary["Idle"] = shared
                    dictionary.removeValue(forKey: "Linked")
                    dictionary["Type"] = "individual"
                }
                let canUseDesktop = type == nil || type == "individual" || type == "desktop"
                    || (type == "linked" && dictionary["Type"] as? String == "individual")
                if canUseDesktop, var desktop = dictionary["Desktop"] as? [String: Any] {
                    var content = desktop["Content"] as? [String: Any] ?? [:]
                    content["Choices"] = [["Provider": provider, "Files": [Any](),
                                           "Configuration": Data(choice.utf8)]]
                    content["Shuffle"] = "$null"
                    desktop["Content"] = content
                    desktop["LastSet"] = date
                    desktop["LastUse"] = date
                    dictionary["Desktop"] = desktop
                    changed += 1
                }
                for key in ["AllSpacesAndDisplays", "SystemDefault", "Spaces", "Displays"] {
                    if let value = dictionary[key] {
                        dictionary[key] = try visit(value, mapping: key == "Spaces" || key == "Displays")
                    }
                }
                // Space/display IDs are arbitrary keys. Recurse their dictionaries without
                // traversing Content/Configuration, whose provider-specific payload is opaque.
                if mapping && dictionary["Desktop"] == nil && dictionary["Idle"] == nil && dictionary["Linked"] == nil {
                    for (key, value) in dictionary where !["AllSpacesAndDisplays", "SystemDefault", "Spaces", "Displays"].contains(key) {
                        if value is [String: Any] || value is [Any] { dictionary[key] = try visit(value) }
                    }
                }
                return dictionary
            }
            if let array = object as? [Any] { return try array.map { try visit($0) } }
            return object
        }
        let output = try visit(root)
        guard changed > 0 else { throw ExperimentalLockScreenFailure(message: "找不到可设置的系统桌面／锁屏角色，未作修改。") }
        return try PropertyListSerialization.data(fromPropertyList: output, format: .binary, options: 0)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// WallpaperAgent routinely touches these two role timestamps. Every other
    /// scalar, payload and unknown field remains part of the restore comparison.
    static func semanticallyEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = try? PropertyListSerialization.propertyList(from: lhs, format: nil),
              let right = try? PropertyListSerialization.propertyList(from: rhs, format: nil) else { return false }
        func normalize(_ object: Any, mapping: Bool = false) -> Any {
            if var dictionary = object as? [String: Any] {
                for role in ["Desktop", "Idle", "Linked"] {
                    if var surface = dictionary[role] as? [String: Any] {
                        for key in ["LastUse", "LastSet"] where surface[key] is Date { surface.removeValue(forKey: key) }
                        dictionary[role] = surface
                    }
                }
                for key in ["AllSpacesAndDisplays", "SystemDefault", "Spaces", "Displays"] {
                    if let value = dictionary[key] {
                        dictionary[key] = normalize(value, mapping: key == "Spaces" || key == "Displays")
                    }
                }
                if mapping && !["Desktop", "Idle", "Linked"].contains(where: { dictionary[$0] is [String: Any] }) {
                    for (key, value) in dictionary where !["AllSpacesAndDisplays", "SystemDefault", "Spaces", "Displays"].contains(key) {
                        if value is [String: Any] || value is [Any] { dictionary[key] = normalize(value) }
                    }
                }
                return dictionary
            }
            if let array = object as? [Any] { return array.map { normalize($0) } }
            return object
        }
        func equal(_ a: Any, _ b: Any) -> Bool {
            if let x = a as? [String: Any], let y = b as? [String: Any] {
                return Set(x.keys) == Set(y.keys) && x.allSatisfy { key, value in equal(value, y[key]!) }
            }
            if let x = a as? [Any], let y = b as? [Any] {
                return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
            }
            if let x = a as? Data, let y = b as? Data { return x == y }
            if let x = a as? Date, let y = b as? Date { return x == y }
            if let x = a as? String, let y = b as? String { return x == y }
            if let x = a as? NSNumber, let y = b as? NSNumber {
                let xBool = CFGetTypeID(x) == CFBooleanGetTypeID()
                let yBool = CFGetTypeID(y) == CFBooleanGetTypeID()
                let xFloat = ["f", "d"].contains(String(cString: x.objCType))
                let yFloat = ["f", "d"].contains(String(cString: y.objCType))
                return xBool == yBool && xFloat == yFloat && x == y
            }
            return false
        }
        return equal(normalize(left), normalize(right))
    }
}

struct LockScreenStoreSnapshot: Codable {
    let id: UUID
    let originalFiles: [String: Data]
    let appliedHashes: [String: String]
    let appliedFiles: [String: Data]
    let previousSharedConfiguration: Data?
    let appliedConfigurationHash: String
    let assetID: UUID
    /// Explicit source lets an old snapshot restore from the old shared root
    /// without silently redirecting or rewriting the system's current choice.
    let sharedDirectoryPath: String?

    init(id: UUID, originalFiles: [String: Data], appliedHashes: [String: String],
         appliedFiles: [String: Data], previousSharedConfiguration: Data?,
         appliedConfigurationHash: String, assetID: UUID, sharedDirectoryPath: String? = nil) {
        self.id = id
        self.originalFiles = originalFiles
        self.appliedHashes = appliedHashes
        self.appliedFiles = appliedFiles
        self.previousSharedConfiguration = previousSharedConfiguration
        self.appliedConfigurationHash = appliedConfigurationHash
        self.assetID = assetID
        self.sharedDirectoryPath = sharedDirectoryPath
    }
}

enum LockScreenSharedConfigurationLocator {
    struct Location {
        let directory: URL
        let data: Data
    }

    /// Locates the exact applied configuration by hash. Only the current shared
    /// directory, the explicitly supplied legacy directory, or a snapshot path
    /// equal to one of those may be read. Missing/mismatched data is an error.
    static func locate(snapshot: LockScreenStoreSnapshot, preferredDirectory: URL,
                       legacyDirectory: URL?) throws -> Location {
        var candidates: [URL] = []
        if let path = snapshot.sharedDirectoryPath {
            candidates.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        candidates.append(preferredDirectory)
        if let legacyDirectory { candidates.append(legacyDirectory) }
        let trusted = Set([preferredDirectory, legacyDirectory].compactMap { $0?.standardizedFileURL.path })
        var seen = Set<String>()
        for directory in candidates {
            let standardized = directory.standardizedFileURL
            guard trusted.contains(standardized.path), seen.insert(standardized.path).inserted else { continue }
            let configURL = standardized.appendingPathComponent("config.json", isDirectory: false)
            var info = stat()
            guard lstat(configURL.path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
            let data = try Data(contentsOf: configURL)
            if LockScreenStorePatcher.digest(data) == snapshot.appliedConfigurationHash {
                return Location(directory: standardized, data: data)
            }
        }
        throw ExperimentalLockScreenFailure(message: "当前扩展视频配置发生变化或已不在可信共享目录；为保护当前选择，不再自动恢复。")
    }
}

/// All writes are compare-before-write and restoration is compare-and-swap. A new
/// System Settings selection is never overwritten by restore or by rollback.
struct LockScreenStoreTransaction {
    let storeDirectory: URL
    let snapshotURL: URL
    var write: (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }

    func apply(configuration: Data, previousConfiguration: Data?, assetID: UUID,
               sharedDirectory: URL? = nil) throws -> LockScreenStoreSnapshot {
        var originals: [String: Data] = [:]
        var outputs: [String: Data] = [:]
        for name in ["Index.plist", "Index2.plist"] {
            let url = storeDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw ExperimentalLockScreenFailure(message: "系统壁纸配置是符号链接，未作修改。")
            }
            originals[name] = try Data(contentsOf: url)
            outputs[name] = try LockScreenStorePatcher.patch(originals[name]!)
        }
        guard !outputs.isEmpty else { throw ExperimentalLockScreenFailure(message: "没有找到当前用户的系统壁纸配置；不会新建或替换系统配置。") }
        try archivePreviousSnapshot()
        let snapshot = LockScreenStoreSnapshot(id: UUID(), originalFiles: originals,
            appliedHashes: outputs.mapValues(LockScreenStorePatcher.digest),
            appliedFiles: outputs,
            previousSharedConfiguration: previousConfiguration,
            appliedConfigurationHash: LockScreenStorePatcher.digest(configuration), assetID: assetID,
            sharedDirectoryPath: sharedDirectory?.standardizedFileURL.path)
        let snapshotData = try JSONEncoder().encode(snapshot)
        let pendingURL = snapshotURL.deletingLastPathComponent().appendingPathComponent("pending-\(snapshot.id.uuidString).json")
        try snapshotData.write(to: pendingURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
        var written: [String] = []
        do {
            for name in outputs.keys.sorted() {
                let url = storeDirectory.appendingPathComponent(name)
                guard LockScreenStorePatcher.semanticallyEqual(try Data(contentsOf: url), originals[name]!) else {
                    throw ExperimentalLockScreenFailure(message: "系统壁纸设置已改变，已停止应用以保留新选择。")
                }
                written.append(name)
                try write(outputs[name]!, url)
                guard LockScreenStorePatcher.semanticallyEqual(try Data(contentsOf: url), outputs[name]!) else {
                    throw ExperimentalLockScreenFailure(message: "系统壁纸配置写入后校验不一致。")
                }
            }
            try snapshotData.write(to: snapshotURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
            try? FileManager.default.removeItem(at: pendingURL)
            return snapshot
        } catch {
            var conflict = false
            for name in written.reversed() {
                let url = storeDirectory.appendingPathComponent(name)
                if let current = try? Data(contentsOf: url), LockScreenStorePatcher.semanticallyEqual(current, outputs[name]!) {
                    do { try write(originals[name]!, url) } catch { conflict = true }
                } else if let current = try? Data(contentsOf: url), LockScreenStorePatcher.semanticallyEqual(current, originals[name]!) {
                    // No app write remains to roll back.
                } else { conflict = true }
            }
            if conflict { throw ExperimentalLockScreenFailure(message: "应用失败；检测到外部更改或回滚失败，未覆盖新设置。备份已保留。") }
            try? FileManager.default.removeItem(at: pendingURL)
            throw error
        }
    }

    func validateRestoration(_ snapshot: LockScreenStoreSnapshot, allowOriginal: Bool = false) throws {
        guard !snapshot.originalFiles.isEmpty,
              Set(snapshot.originalFiles.keys).isSubset(of: ["Index.plist", "Index2.plist"]),
              Set(snapshot.originalFiles.keys) == Set(snapshot.appliedHashes.keys),
              Set(snapshot.originalFiles.keys) == Set(snapshot.appliedFiles.keys) else {
            throw ExperimentalLockScreenFailure(message: "恢复备份格式无效，未修改任何设置。")
        }
        for (name, hash) in snapshot.appliedHashes {
            guard LockScreenStorePatcher.digest(snapshot.appliedFiles[name]!) == hash else {
                throw ExperimentalLockScreenFailure(message: "恢复备份校验失败，未修改任何设置。")
            }
            let current = try Data(contentsOf: storeDirectory.appendingPathComponent(name))
            guard LockScreenStorePatcher.semanticallyEqual(current, snapshot.appliedFiles[name]!)
                    || (allowOriginal && LockScreenStorePatcher.semanticallyEqual(current, snapshot.originalFiles[name]!)) else {
                throw ExperimentalLockScreenFailure(message: "系统壁纸配置发生变化；为保护当前选择，不再恢复旧配置。")
            }
        }
    }

    func restore(_ snapshot: LockScreenStoreSnapshot, allowOriginal: Bool = false) throws {
        try validateRestoration(snapshot, allowOriginal: allowOriginal)
        var restored: [String] = []
        do {
            for name in snapshot.originalFiles.keys.sorted() {
                let url = storeDirectory.appendingPathComponent(name)
                if allowOriginal, LockScreenStorePatcher.semanticallyEqual(try Data(contentsOf: url), snapshot.originalFiles[name]!) { continue }
                // Check again immediately before each write, including concurrent settings changes.
                guard LockScreenStorePatcher.semanticallyEqual(try Data(contentsOf: url), snapshot.appliedFiles[name]!) else {
                    throw ExperimentalLockScreenFailure(message: "系统壁纸配置发生变化，恢复已停止。")
                }
                restored.append(name)
                try write(snapshot.originalFiles[name]!, url)
            }
        } catch {
            // Restore the pre-restore applied state only if our exact original write
            // is still present; external system selections always take precedence.
            for name in restored.reversed() {
                let url = storeDirectory.appendingPathComponent(name)
                if let current = try? Data(contentsOf: url), LockScreenStorePatcher.semanticallyEqual(current, snapshot.originalFiles[name]!) {
                    try? write(snapshot.appliedFiles[name]!, url)
                }
            }
            throw ExperimentalLockScreenFailure(message: "恢复未全部完成；原始备份已保留，未覆盖检测到的新选择。")
        }
    }

    private func archivePreviousSnapshot() throws {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        let previous = try Data(contentsOf: snapshotURL)
        let snapshot = try JSONDecoder().decode(LockScreenStoreSnapshot.self, from: previous)
        let directory = snapshotURL.deletingLastPathComponent().appendingPathComponent("history", isDirectory: true)
        try LockScreenOwnedFiles.makePrivateDirectory(directory)
        let destination = directory.appendingPathComponent("\(snapshot.id.uuidString).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == previous else {
                throw ExperimentalLockScreenFailure(message: "同名历史备份内容不一致，未覆盖历史或系统配置。")
            }
        } else {
            try LockScreenOwnedFiles.privateWrite(previous, to: destination)
        }
    }
}
