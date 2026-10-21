import Foundation
import Darwin

enum SceneBackendPrivateCache {
    static func create(registryRoot: URL, sessionID: UUID) throws -> URL {
        let root = try openPrivateDirectory(registryRoot)
        defer { close(root) }
        let sessions = try child(root, name: "Sessions", create: true)
        defer { close(sessions) }
        let name = sessionID.uuidString.lowercased()
        let session = try child(sessions, name: name, create: true)
        close(session)
        return registryRoot.appendingPathComponent("Sessions/" + name, isDirectory: true)
    }

    private static func child(_ parent: Int32, name: String, create: Bool) throws -> Int32 {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw UniversalSceneBackendError.invalidProject
        }
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw UniversalSceneBackendError.invalidProject
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw UniversalSceneBackendError.invalidProject }
        do { try validate(descriptor); return descriptor }
        catch { close(descriptor); throw error }
    }

    static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("//"),
              url.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw UniversalSceneBackendError.invalidProject
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UniversalSceneBackendError.invalidProject }
        do {
            for part in url.path.split(separator: "/") {
                let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw UniversalSceneBackendError.invalidProject }
                close(descriptor); descriptor = next
            }
            try validate(descriptor); return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw UniversalSceneBackendError.invalidProject
        }
    }
}
