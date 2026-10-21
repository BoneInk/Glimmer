import CryptoKit
import Darwin
import Foundation

struct RenderedLockScreenVideoFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Internal control-flow signal: the material observed after export no longer
/// matches the material that produced the staged video. Resolve retries once.
struct RenderedLockScreenVideoSourceChanged: Error, Sendable {}

/// Shared cache state machine for finite lock-screen recordings. Web and Scene
/// supply the project/engine identity and exporter; staging, probe validation,
/// single-flight, cancellation, atomic publish, leases and LRU stay here.
@MainActor
final class RenderedLockScreenVideoCache {
    struct Settings: Codable, Hashable, Sendable {
        var signature: String
        var duration: TimeInterval
        var framesPerSecond: Int
        var width: Int
        var height: Int

        init(signature: String, duration: TimeInterval = 10, framesPerSecond: Int = 30,
             width: Int = 1920, height: Int = 1080) {
            self.signature = signature
            self.duration = duration
            self.framesPerSecond = framesPerSecond
            self.width = width
            self.height = height
        }

        var cacheSignature: String { "\(signature):\(duration):\(framesPerSecond):\(width)x\(height)" }
    }

    /// identityHash covers project bytes plus the actual engine/assets identity;
    /// payloadHash covers the saved author payload handed to the exporter.
    struct Material: Sendable {
        let identityHash: String
        let payloadHash: String
        let payload: Data
    }

    typealias MaterialProvider = @MainActor @Sendable () async throws -> Material
    typealias ExportOperation = @MainActor @Sendable (
        _ payload: Data, _ directory: URL,
        _ progress: @escaping @Sendable (String) async -> Void
    ) async throws -> URL

    private struct Manifest: Codable {
        let schema: Int
        let key: String
        let projectHash: String
        let payloadHash: String
        let settings: String
        let videoHash: String
        let videoBytes: Int64
        let duration: Double
        let width: Int
        let height: Int
        let codec: String
        let createdAt: Date
        var lastAccessedAt: Date
    }
    private struct Flight {
        let id: UUID
        let task: Task<URL, Error>
        var waiters: [UUID: Waiter]
    }
    private struct Waiter { let continuation: CheckedContinuation<URL, Error> }
    private static var flights: [String: Flight] = [:]
    private static var leases: [String: Int] = [:]
    private static let schema = 1
    private static let maximumEntries = 8
    private static let maximumBytes: Int64 = 268_435_456

    private let root: URL
    private let settings: Settings
    private let materialProvider: MaterialProvider
    private let exportOperation: ExportOperation
    private let beforeWaitOperation: @MainActor @Sendable () async -> Void

    init(root: URL, settings: Settings,
         materialProvider: @escaping MaterialProvider,
         exportOperation: @escaping ExportOperation,
         beforeWaitOperation: @escaping @MainActor @Sendable () async -> Void = {}) {
        self.root = root
        self.settings = settings
        self.materialProvider = materialProvider
        self.exportOperation = exportOperation
        self.beforeWaitOperation = beforeWaitOperation
    }

    func video(progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        try await resolve(leasesResult: false, progress: progress)
    }

    func withVideo<Result>(progress: @escaping @Sendable (String) async -> Void = { _ in },
                           operation: (URL) async throws -> Result) async throws -> Result {
        let video = try await resolve(leasesResult: true, progress: progress)
        let leaseKey = Self.leaseKey(root: root, entryKey: video.deletingLastPathComponent().lastPathComponent)
        defer { Self.releaseLease(leaseKey) }
        return try await operation(video)
    }

    private func resolve(leasesResult: Bool,
                         progress: @escaping @Sendable (String) async -> Void) async throws -> URL {
        do {
            return try await resolveOnce(leasesResult: leasesResult, progress: progress)
        } catch is RenderedLockScreenVideoSourceChanged {
            try Task.checkCancellation()
            await progress("检测到内容变化，正在重新生成锁屏视频")
            try Task.checkCancellation()
            do {
                return try await resolveOnce(leasesResult: leasesResult, progress: progress)
            } catch is RenderedLockScreenVideoSourceChanged {
                throw RenderedLockScreenVideoFailure(
                    message: "项目、作者设置或渲染引擎在重新生成期间再次变化，已停止自动重试。请完成调整后重试。")
            }
        }
    }

    private func resolveOnce(leasesResult: Bool,
                             progress: @escaping @Sendable (String) async -> Void) async throws -> URL {
        try Task.checkCancellation()
        let material = try await materialProvider()
        try Task.checkCancellation()
        let key = Self.key(material: material, settings: settings)
        try LockScreenOwnedFiles.makePrivateDirectory(root)
        if let hit = try await validatedEntry(key: key, material: material, touchesLRU: true) {
            try Task.checkCancellation()
            await progress("正在复用已转换的锁屏视频")
            try Task.checkCancellation()
            if leasesResult { Self.acquireLease(Self.flightKey(root: root, key: key)) }
            return hit
        }

        let flightKey = Self.flightKey(root: root, key: key)
        let flight: Flight
        if let existing = Self.flights[flightKey] { flight = existing }
        else {
            let id = UUID()
            let task = Task { [self] in
                try await generate(material: material, key: key, progress: progress)
            }
            flight = Flight(id: id, task: task, waiters: [:]); Self.flights[flightKey] = flight
            Task { @MainActor in
                let result: Result<URL, Error>
                do { result = .success(try await task.value) } catch { result = .failure(error) }
                Self.finishFlight(key: flightKey, id: id, result: result)
            }
        }
        await beforeWaitOperation()
        let result = try await wait(for: flight, key: flightKey)
        try Task.checkCancellation()
        if leasesResult { Self.acquireLease(flightKey) }
        return result
    }

    private func generate(material: Material, key: String,
                          progress: @escaping @Sendable (String) async -> Void) async throws -> URL {
        if let raced = try await validatedEntry(key: key, material: material, touchesLRU: true) {
            return raced
        }
        let manager = FileManager.default
        let stage = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try LockScreenOwnedFiles.makePrivateDirectory(stage)
        var published = false
        defer { if !published { try? manager.removeItem(at: stage) } }
        let generated = try await exportOperation(material.payload, stage, progress)
        try Task.checkCancellation()
        guard try Self.safeRegularFile(generated), Self.contains(generated, in: stage) else {
            throw RenderedLockScreenVideoFailure(message: "锁屏缓存输出路径无效。")
        }
        let video = stage.appendingPathComponent("video.mp4")
        if generated.standardizedFileURL != video.standardizedFileURL { try manager.moveItem(at: generated, to: video) }
        let probe = try await VideoProbe.probe(url: video)
        try validate(probe: probe)
        let attributes = try manager.attributesOfItem(atPath: video.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard bytes > 0, bytes <= Self.maximumBytes else {
            throw RenderedLockScreenVideoFailure(message: "锁屏缓存视频大小无效。")
        }
        let videoHash = try await Self.cancellableFileHash(video, maximumBytes: Self.maximumBytes)
        let current = try await materialProvider()
        try Task.checkCancellation()
        guard current.identityHash == material.identityHash, current.payloadHash == material.payloadHash else {
            throw RenderedLockScreenVideoSourceChanged()
        }
        let manifest = Manifest(schema: Self.schema, key: key, projectHash: material.identityHash,
            payloadHash: material.payloadHash, settings: settings.cacheSignature, videoHash: videoHash,
            videoBytes: bytes, duration: probe.durationSeconds, width: probe.pixelWidth,
            height: probe.pixelHeight, codec: probe.videoCodec ?? "unknown",
            createdAt: Date(), lastAccessedAt: Date())
        try LockScreenOwnedFiles.privateWrite(try Self.encoder.encode(manifest),
                                              to: stage.appendingPathComponent("manifest.json"))
        try Task.checkCancellation()
        let destination = root.appendingPathComponent(key, isDirectory: true)
        if let raced = try await validatedEntry(key: key, material: material, touchesLRU: true) {
            return raced
        }
        var previous: URL?
        if manager.fileExists(atPath: destination.path) {
            let replacement = root.appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: destination, to: replacement); previous = replacement
        }
        do { try manager.moveItem(at: stage, to: destination); published = true }
        catch { if let previous { try? manager.moveItem(at: previous, to: destination) }; throw error }
        if let previous { try? manager.removeItem(at: previous) }
        await trim(keeping: key)
        return destination.appendingPathComponent("video.mp4")
    }

    private func wait(for flight: Flight, key: String) async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    Self.cancelWaiter(key: key, flightID: flight.id, waiterID: waiterID)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard var current = Self.flights[key], current.id == flight.id else {
                    Task { @MainActor in
                        do { continuation.resume(returning: try await flight.task.value) }
                        catch { continuation.resume(throwing: error) }
                    }
                    return
                }
                current.waiters[waiterID] = Waiter(continuation: continuation)
                Self.flights[key] = current
            }
        } onCancel: {
            Task { @MainActor in Self.cancelWaiter(key: key, flightID: flight.id, waiterID: waiterID) }
        }
    }

    private static func finishFlight(key: String, id: UUID, result: Result<URL, Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        for waiter in flight.waiters.values { waiter.continuation.resume(with: result) }
    }

    private static func cancelWaiter(key: String, flightID: UUID, waiterID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        if let waiter = flight.waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(throwing: CancellationError())
        }
        if flight.waiters.isEmpty { flights[key] = nil; flight.task.cancel() }
        else { flights[key] = flight }
    }

    private func validatedEntry(key: String, material: Material,
                                touchesLRU: Bool) async throws -> URL? {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard try Self.safeDirectory(directory), Self.contains(directory, in: root) else { return nil }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let video = directory.appendingPathComponent("video.mp4")
        let cachedVideoHash = try? await Self.cancellableFileHash(video, maximumBytes: Self.maximumBytes)
        guard try Self.safeRegularFile(video),
              let manifestData = try? Self.readRegularFile(manifestURL, maximumBytes: 65_536),
              let manifest = try? Self.decoder.decode(Manifest.self, from: manifestData),
              manifest.schema == Self.schema, manifest.key == key,
              manifest.projectHash == material.identityHash,
              manifest.payloadHash == material.payloadHash,
              manifest.settings == settings.cacheSignature,
              manifest.videoHash == cachedVideoHash,
              manifest.videoBytes == ((try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.int64Value ?? -1) else { return nil }
        guard let probe = try? await VideoProbe.probe(url: video) else { return nil }
        do { try validate(probe: probe) } catch { return nil }
        guard abs(manifest.duration - probe.durationSeconds) <= 0.001,
              manifest.width == probe.pixelWidth, manifest.height == probe.pixelHeight,
              manifest.codec.lowercased() == (probe.videoCodec ?? "unknown").lowercased() else { return nil }
        if touchesLRU {
            var updated = manifest; updated.lastAccessedAt = Date()
            try LockScreenOwnedFiles.privateWrite(try Self.encoder.encode(updated), to: manifestURL)
        }
        return video
    }

    private func validate(probe: VideoProbeResult) throws {
        let codec = (probe.videoCodec ?? "").lowercased()
        guard probe.isPlayable, abs(probe.durationSeconds - settings.duration) <= 0.2,
              probe.pixelWidth == settings.width, probe.pixelHeight == settings.height,
              let frameRate = probe.frameRate, abs(frameRate - Double(settings.framesPerSecond)) <= 0.01,
              codec.contains("avc") || codec.contains("h264") else {
            throw RenderedLockScreenVideoFailure(message: "锁屏缓存视频规格无效。")
        }
    }

    /// Call only after a replacement has been fully prepared. Production uses
    /// an item-specific root, so this never removes another wallpaper's cache.
    static func discardOtherEntries(in root: URL, keeping video: URL) {
        let directory = video.deletingLastPathComponent().standardizedFileURL
        guard directory.deletingLastPathComponent() == root.standardizedFileURL,
              (try? safeRegularFile(video)) == true else { return }
        let manager = FileManager.default
        for entry in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let key = entry.lastPathComponent
            guard key.count == 64, key.allSatisfy(\.isHexDigit), entry.standardizedFileURL != directory,
                  contains(entry, in: root), (try? safeDirectory(entry)) == true,
                  leases[leaseKey(root: root, entryKey: key), default: 0] == 0,
                  flights[flightKey(root: root, key: key)] == nil else { continue }
            try? manager.removeItem(at: entry)
        }
    }

    private func trim(keeping key: String) async {
        let manager = FileManager.default
        var entries: [(url: URL, access: Date, bytes: Int64)] = []
        for url in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.count == 64 && url.lastPathComponent.allSatisfy({ $0.isHexDigit }) {
            guard (try? Self.safeDirectory(url)) == true,
                  Self.contains(url, in: root),
                  let data = try? Self.readRegularFile(url.appendingPathComponent("manifest.json"), maximumBytes: 65_536),
                  let manifest = try? Self.decoder.decode(Manifest.self, from: data),
                  manifest.schema == Self.schema, manifest.key == url.lastPathComponent,
                  manifest.videoBytes > 0, manifest.videoBytes <= Self.maximumBytes,
                  (try? Self.safeRegularFile(url.appendingPathComponent("video.mp4"))) == true,
                  ((try? manager.attributesOfItem(atPath: url.appendingPathComponent("video.mp4").path)[.size] as? NSNumber)?.int64Value ?? -1) == manifest.videoBytes else { continue }
            entries.append((url, manifest.lastAccessedAt, manifest.videoBytes))
        }
        var total = entries.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        for entry in entries.sorted(by: { $0.access < $1.access })
        where entries.count > Self.maximumEntries || total > Self.maximumBytes {
            if entry.url.lastPathComponent == key { continue }
            if Self.leases[Self.leaseKey(root: root, entryKey: entry.url.lastPathComponent), default: 0] > 0 { continue }
            try? manager.removeItem(at: entry.url); total -= max(0, entry.bytes)
            entries.removeAll { $0.url == entry.url }
        }
    }

    private static let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()
    private static let decoder = JSONDecoder()
    private static func key(material: Material, settings: Settings) -> String {
        contentHash(Data("\(schema)\u{0}\(material.identityHash)\u{0}\(material.payloadHash)\u{0}\(settings.cacheSignature)".utf8))
    }
    private static func flightKey(root: URL, key: String) -> String {
        root.standardizedFileURL.path + ":" + key
    }
    private static func leaseKey(root: URL, entryKey: String) -> String {
        root.standardizedFileURL.path + ":" + entryKey
    }
    private static func acquireLease(_ key: String) { leases[key, default: 0] += 1 }
    private static func releaseLease(_ key: String) {
        let remaining = leases[key, default: 1] - 1
        if remaining <= 0 { leases[key] = nil } else { leases[key] = remaining }
    }

    nonisolated static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func projectHash(root: URL) async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            try RenderedLockScreenProjectHasher.hash(root: root)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated private static func fileHash(_ url: URL, maximumBytes: Int64 = 2_147_483_648) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RenderedLockScreenVideoFailure(message: "无法读取锁屏缓存文件。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw RenderedLockScreenVideoFailure(message: "锁屏缓存文件节点不安全。")
        }
        var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
            if count == 0 { break }
            digest.update(data: buffer.prefix(count))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func cancellableFileHash(_ url: URL, maximumBytes: Int64) async throws -> String {
        let task = Task.detached(priority: .userInitiated) { try fileHash(url, maximumBytes: maximumBytes) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated private static func readRegularFile(_ url: URL, maximumBytes: Int64) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0,
              info.st_size <= maximumBytes else { throw POSIXError(.EACCES) }
        var data = Data(); data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.count > maximumBytes { throw POSIXError(.EFBIG) }
        }
        return data
    }

    nonisolated private static func safeRegularFile(_ url: URL) throws -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && value.st_uid == getuid() && value.st_nlink == 1
    }

    nonisolated private static func safeDirectory(_ url: URL) throws -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && value.st_uid == getuid()
    }

    nonisolated private static func contains(_ child: URL, in parent: URL) -> Bool {
        child.standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path + "/")
    }
}

/// Project-tree hashing shared by the cache material providers. It rejects
/// symlinks, hard links, foreign owners and oversized trees before reading.
private enum RenderedLockScreenProjectHasher {
    static func hash(root: URL) throws -> String {
        var digest = SHA256(), count = 0, total: Int64 = 0
        func safeDirectory(_ url: URL) -> Bool {
            var value = stat()
            return lstat(url.path, &value) == 0 && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                && value.st_uid == getuid()
        }
        func fileHash(_ url: URL) throws -> String {
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw WebProjectError.invalid("无法读取项目文件") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0,
                  info.st_size <= 2_147_483_648 else {
                throw WebProjectError.invalid("项目文件节点不安全")
            }
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                try Task.checkCancellation()
                let count = read(fd, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
                if count == 0 { break }
                hash.update(data: buffer.prefix(count))
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func walk(_ directory: URL, _ relative: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 64 else { throw WebProjectError.invalid("项目目录层级过深") }
            guard safeDirectory(directory),
                  directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
                throw WebProjectError.invalid("项目目录包含链接或不安全节点")
            }
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                count += 1
                guard count <= 20_000 else { throw WebProjectError.invalid("项目目录项过多") }
                let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                var info = stat()
                guard lstat(child.path, &info) == 0, info.st_uid == getuid() else {
                    throw WebProjectError.invalid("项目节点不安全")
                }
                let type = info.st_mode & mode_t(S_IFMT)
                digest.update(data: Data((type == mode_t(S_IFDIR) ? "D" : "F").utf8))
                digest.update(data: Data(path.utf8)); digest.update(data: Data([0]))
                if type == mode_t(S_IFDIR) { try walk(child, path, depth: depth + 1) }
                else if type == mode_t(S_IFREG), info.st_nlink == 1 {
                    let hash = try fileHash(child)
                    var current = stat()
                    guard lstat(child.path, &current) == 0 else { throw WebProjectError.invalid("项目文件已变化") }
                    total += current.st_size
                    guard total <= 2_147_483_648 else { throw WebProjectError.invalid("项目过大") }
                    digest.update(data: Data(hash.utf8))
                } else { throw WebProjectError.invalid("项目包含符号链接、硬链接或特殊文件") }
            }
        }
        try walk(root, "", depth: 0)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
