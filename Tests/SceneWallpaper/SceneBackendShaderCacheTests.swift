import Foundation
import Darwin

enum UniversalSceneBackendError: Error { case invalidProject }

@main
enum SceneBackendShaderCacheTests {
    static func main() throws {
        umask(0o077)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("ShaderCacheTest-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let manifest = String(repeating: "a", count: 64)
        let generation = "r17-0123456789ab"
        let name = String(repeating: "b", count: 64) + ".json"
        func check(_ value: Bool, _ description: String) throws {
            guard value else { throw NSError(domain: description, code: 1) }
            print("PASS \(description)")
        }
        let first = try SceneBackendPrivateCache.create(registryRoot: root, sessionID: UUID())
        try check(try SceneBackendShaderCache.restore(registryRoot: root, session: first, manifest: manifest) == 0,
                  "a cold cache is an ordinary miss")
        let local = first.appendingPathComponent("shader-variants/" + generation)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: local.path)
        let data = Data("{\"vertexMSL\":\"test vertex\",\"fragmentMSL\":\"test fragment\"}".utf8)
        try data.write(to: local.appendingPathComponent(name))
        try Data("private script state".utf8).write(to: first.appendingPathComponent("script-storage.json"))
        try check(try SceneBackendShaderCache.publish(registryRoot: root, session: first, manifest: manifest) == 1,
                  "a completed session publishes its translated shader")
        let second = try SceneBackendPrivateCache.create(registryRoot: root, sessionID: UUID())
        try check(try SceneBackendShaderCache.restore(registryRoot: root, session: second, manifest: manifest) == 1,
                  "a fresh isolated session reuses the translation")
        let restored = second.appendingPathComponent("shader-variants/" + generation + "/" + name)
        try check(try Data(contentsOf: restored) == data, "cached shader bytes remain identical")
        try check(!fm.fileExists(atPath: second.appendingPathComponent("script-storage.json").path),
                  "script state never crosses session boundaries")
        let other = try SceneBackendPrivateCache.create(registryRoot: root, sessionID: UUID())
        try check(try SceneBackendShaderCache.restore(registryRoot: root, session: other,
            manifest: String(repeating: "c", count: 64)) == 0, "a changed engine asset manifest misses")
        let shared = root.appendingPathComponent("CompiledShaders-v1/" + manifest + "/" + generation)
        try Data("broken JSON".utf8).write(to: shared.appendingPathComponent(name))
        let corrupt = try SceneBackendPrivateCache.create(registryRoot: root, sessionID: UUID())
        try check(try SceneBackendShaderCache.restore(registryRoot: root, session: corrupt, manifest: manifest) == 0,
                  "a corrupt translation is ignored")
        try fm.removeItem(at: shared.appendingPathComponent(name))
        try fm.createSymbolicLink(at: shared.appendingPathComponent(name), withDestinationURL: local.appendingPathComponent(name))
        try check(try SceneBackendShaderCache.restore(registryRoot: root, session: corrupt, manifest: manifest) == 0,
                  "a symlinked shader is never read")
        try fm.removeItem(at: shared.appendingPathComponent(name))
        try fm.linkItem(at: local.appendingPathComponent(name), to: shared.appendingPathComponent(name))
        try check(try SceneBackendShaderCache.restore(registryRoot: root, session: corrupt, manifest: manifest) == 0,
                  "a hard-linked shader is never read")
        try check(try Data(contentsOf: local.appendingPathComponent(name)) == data,
                  "original input remains unchanged after rejected cache entries")
        try fm.removeItem(at: shared.appendingPathComponent(name))
        let lock = root.appendingPathComponent("CompiledShaders-v1/" + manifest + "/.lock")
        let descriptor = open(lock.path, O_RDWR)
        guard descriptor >= 0 else { throw UniversalSceneBackendError.invalidProject }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw UniversalSceneBackendError.invalidProject }
        try check(try SceneBackendShaderCache.restore(registryRoot: root, session: corrupt, manifest: manifest) == 0,
                  "a competing cache writer causes an immediate miss")
        _ = flock(descriptor, LOCK_UN)
        try fm.removeItem(at: shared)
        try fm.createSymbolicLink(at: shared, withDestinationURL: local)
        do {
            _ = try SceneBackendShaderCache.restore(registryRoot: root, session: corrupt, manifest: manifest)
            throw NSError(domain: "symlink generation accepted", code: 1)
        } catch UniversalSceneBackendError.invalidProject {
            print("PASS symlinked generation directories are rejected")
        }
    }
}
