import Foundation
import Darwin

/// Reuse only content-addressed shader translations. Helpers keep private
/// session directories, scripts and properties; no renderer/session is shared.
/// The upstream key includes shader text, combos, translator revision, compiler
/// fingerprint and OS toolchain. Changed inputs therefore miss automatically.
enum SceneBackendShaderCache {
    static let maximumFiles = 4096
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumFileBytes = 2 * 1024 * 1024

    static func restore(registryRoot: URL, session: URL, manifest: String) throws -> Int {
        try transfer(registryRoot: registryRoot, session: session, manifest: manifest, restoring: true)
    }

    static func publish(registryRoot: URL, session: URL, manifest: String) throws -> Int {
        try transfer(registryRoot: registryRoot, session: session, manifest: manifest, restoring: false)
    }

    private static func transfer(registryRoot: URL, session: URL, manifest: String,
                                 restoring: Bool) throws -> Int {
        guard manifest.count == 64, manifest.allSatisfy({ $0.isHexDigit }) else { return 0 }
        let registry = try SceneBackendPrivateCache.openPrivateDirectory(registryRoot)
        defer { close(registry) }
        let snapshots = try directory(registry, "CompiledShaders-v1", create: true)
        defer { close(snapshots) }
        let shared = try directory(snapshots, manifest, create: true)
        defer { close(shared) }
        let lock = openat(shared, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { return 0 }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(), lockInfo.st_mode & 0o077 == 0, lockInfo.st_nlink == 1,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { return 0 }
        defer { _ = flock(lock, LOCK_UN) }
        let sessionRoot = try SceneBackendPrivateCache.openPrivateDirectory(session)
        defer { close(sessionRoot) }
        let local = try directory(sessionRoot, "shader-variants", create: restoring)
        defer { close(local) }
        let sharedURL = registryRoot.appendingPathComponent("CompiledShaders-v1/" + manifest)
        let localURL = session.appendingPathComponent("shader-variants")
        let source = restoring ? shared : local, destination = restoring ? local : shared
        let sourceURL = restoring ? sharedURL : localURL
        let destinationURL = restoring ? localURL : sharedURL
        var count = 0, bytes = 0
        // Bound the accumulated snapshot too, even as successive wallpapers add
        // new shader keys. Cache exhaustion is just a miss, never a load failure.
        var occupied = [String: Int]()
        for (generation, name) in try entries(destinationURL) {
            let parent = try directory(destination, generation, create: false)
            defer { close(parent) }
            if let size = try? regularSize(parent, name) { occupied[generation + "/" + name] = size }
        }
        var storedBytes = occupied.values.reduce(0, +)
        for (generation, name) in try entries(sourceURL) {
            try Task.checkCancellation()
            guard count < maximumFiles else { break }
            let from = try directory(source, generation, create: false)
            defer { close(from) }
            let file = openat(from, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { continue }
            defer { close(file) }
            guard let size = try? checkedSize(file), bytes <= maximumBytes - size else { continue }
            let key = generation + "/" + name
            let previous = occupied[key] ?? 0
            guard (previous > 0 || occupied.count < maximumFiles),
                  storedBytes - previous <= maximumBytes - size else { continue }
            var data = Data(count: size)
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < size {
                    let result = Darwin.read(file, buffer.baseAddress!.advanced(by: offset), size - offset)
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw UniversalSceneBackendError.invalidProject }
                    offset += result
                }
            }
            // Corrupt or truncated snapshots are misses. Upstream also decodes
            // the full variant before using it; no cache changes readiness rules.
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { continue }
            let to = try directory(destination, generation, create: true)
            defer { close(to) }
            let temporary = ".copy-" + UUID().uuidString
            let output = openat(to, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { continue }
            defer { close(output); _ = unlinkat(to, temporary, 0) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < size {
                    let result = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), size - offset)
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw UniversalSceneBackendError.invalidProject }
                    offset += result
                }
            }
            guard renameat(to, temporary, to, name) == 0 else { continue }
            count += 1; bytes += size
            storedBytes += size - previous; occupied[key] = size
        }
        return count
    }

    private static func entries(_ root: URL) throws -> [(String, String)] {
        var result = [(String, String)]()
        let generations = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard generations.count <= 64 else { return [] }
        for generation in generations.sorted() {
            let parts = generation.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].first == "r", parts[0].dropFirst().allSatisfy(\.isNumber),
                  (1...4).contains(parts[0].dropFirst().count), parts[1].count == 12,
                  parts[1].allSatisfy(\.isHexDigit) else { continue }
            // Open without following links before enumerating a generation.
            let parent = try SceneBackendPrivateCache.openPrivateDirectory(root)
            defer { close(parent) }
            let child = try directory(parent, generation, create: false)
            defer { close(child) }
            let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(generation).path)
            guard names.count <= maximumFiles else { return [] }
            for name in names.sorted() where name.hasSuffix(".json") {
                let key = name.dropLast(5)
                guard key.count == 64, key.allSatisfy(\.isHexDigit) else { continue }
                result.append((generation, name))
                guard result.count <= maximumFiles else { return [] }
            }
        }
        return result
    }

    private static func directory(_ parent: Int32, _ name: String, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw UniversalSceneBackendError.invalidProject }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw UniversalSceneBackendError.invalidProject }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(descriptor); throw UniversalSceneBackendError.invalidProject
        }
        return descriptor
    }

    private static func regularSize(_ parent: Int32, _ name: String) throws -> Int {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw UniversalSceneBackendError.invalidProject }
        defer { close(descriptor) }
        return try checkedSize(descriptor)
    }

    private static func checkedSize(_ descriptor: Int32) throws -> Int {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximumFileBytes else { throw UniversalSceneBackendError.invalidProject }
        return Int(info.st_size)
    }
}
