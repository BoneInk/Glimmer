import Foundation

private struct MigrationTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct GlimmerStorageMigrationTests {
    private static var checks = 0

    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/glimmer-storage-migration-\(UUID().uuidString)",
                       isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try testSuccessfulMigrationAndIdempotence(root: root)
        try testConflictingTargets(root: root)
        try testTargetSymlinkIsRejected(root: root)
        try testInterruptedCopyLeavesNoTarget(root: root)
        try testUnsafeLinksAreRejected(root: root)
        print("GlimmerStorageMigrationTests: \(checks) checks passed; temp roots only, source retained, no user data accessed")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw MigrationTestFailure(description: label) }
        checks += 1
        print("PASS \(label)")
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url)
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw MigrationTestFailure(description: "expected JSON object at \(url.lastPathComponent)")
        }
        return dictionary
    }

    private static func captureMigrationError(
        _ label: String,
        _ operation: () throws -> Void
    ) throws -> GlimmerStorageMigration.MigrationError {
        do {
            try operation()
        } catch let error as GlimmerStorageMigration.MigrationError {
            checks += 1
            print("PASS \(label)")
            return error
        }
        throw MigrationTestFailure(description: label)
    }

    private static func testSuccessfulMigrationAndIdempotence(root: URL) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent("Successful/Legacy", isDirectory: true)
        let target = root.appendingPathComponent("Successful/Glimmer", isDirectory: true)
        let external = root.appendingPathComponent("Successful/External/clip.mp4")
        try write("external fixture", to: external)

        let managedVideo = source.appendingPathComponent("Media/video.mp4")
        let managedPoster = source.appendingPathComponent("ExperimentalLockScreen/Assets/asset/poster.jpg")
        try write("managed video bytes", to: managedVideo)
        try write("managed poster bytes", to: managedPoster)
        let bookmark = Data([0x00, 0x01, 0x7f, 0xff]).base64EncodedString()
        let library: [String: Any] = [
            "schemaVersion": 1,
            "items": [[
                "filePath": managedVideo.path,
                "originalPath": external.path,
                "securityScopedBookmark": bookmark
            ]]
        ]
        try writeJSON(library, to: source.appendingPathComponent("library.json"))

        let state: [String: Any] = [
            "state": "prepared",
            "asset": [
                "id": UUID().uuidString,
                "itemID": UUID().uuidString,
                "title": "fixture",
                "videoURL": managedVideo.absoluteString,
                "posterURL": managedPoster.absoluteString,
                "durationSeconds": 1.5,
                "codec": "h264"
            ],
            "warning": "fixture warning"
        ]
        try writeJSON(state, to: source.appendingPathComponent("ExperimentalLockScreen/state.json"))

        let workshop = source.appendingPathComponent("Workshop", isDirectory: true)
        let framework = workshop.appendingPathComponent(
            "SteamCMD/Frameworks/Breakpad.framework", isDirectory: true)
        try fm.createDirectory(at: framework.appendingPathComponent("Versions/A/Resources"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: framework.appendingPathComponent("Versions/A/Headers"),
                               withIntermediateDirectories: true)
        try write("breakpad binary", to: framework.appendingPathComponent("Versions/A/Breakpad"))
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path,
                                  withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path,
                                  withDestinationPath: "Versions/Current/Resources")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Headers").path,
                                  withDestinationPath: "Versions/Current/Headers")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Breakpad").path,
                                  withDestinationPath: "Versions/Current/Breakpad")
        try fm.createSymbolicLink(atPath: workshop.appendingPathComponent("Frameworks").path,
                                  withDestinationPath: "MacOS/Frameworks")

        let sourceLibraryBefore = try Data(contentsOf: source.appendingPathComponent("library.json"))
        try check(GlimmerStorageMigration.requiresMigration(source: source, target: target),
                  "launch gate detects a pending migration before the target exists")
        let published = try GlimmerStorageMigration.migrateIfNeeded(source: source, target: target)
        try check(published, "first migration publishes a new target")
        try check(!GlimmerStorageMigration.requiresMigration(source: source, target: target),
                  "retained legacy backup does not block an initialized target")
        try check(GlimmerStorageMigration.isInitializedProfile(at: target),
                  "migration writes a valid completion marker")
        try check(!GlimmerStorageMigration.isInitializedProfile(at: source),
                  "legacy source is not marked and remains non-destructive")
        try check(try Data(contentsOf: source.appendingPathComponent("library.json")) == sourceLibraryBefore,
                  "legacy configuration bytes are unchanged")
        try check(fm.fileExists(atPath: managedVideo.path) && fm.fileExists(atPath: managedPoster.path),
                  "legacy managed files remain in place")

        let migratedLibrary = try json(target.appendingPathComponent("library.json"))
        let item = try checkDictionary((migratedLibrary["items"] as? [Any])?.first, "library item")
        try check(item["filePath"] as? String == target.appendingPathComponent("Media/video.mp4").path,
                  "managed absolute filePath is rebased to the new root")
        try check(item["originalPath"] as? String == external.path,
                  "external originalPath is preserved verbatim")
        try check(item["securityScopedBookmark"] as? String == bookmark,
                  "opaque security-scoped bookmark bytes are preserved verbatim")

        let migratedState = try json(target.appendingPathComponent("ExperimentalLockScreen/state.json"))
        let asset = try checkDictionary(migratedState["asset"], "lock-screen asset")
        let videoString = try checkString(asset["videoURL"], "videoURL")
        let posterString = try checkString(asset["posterURL"], "posterURL")
        let videoURL = try checkURL(videoString, "videoURL")
        let posterURL = try checkURL(posterString, "posterURL")
        try check(videoURL.isFileURL && posterURL.isFileURL,
                  "lock-screen Codable URLs remain file URLs")
        try check(videoURL.path.hasPrefix(target.path + "/"),
                  "lock-screen video URL is inside the new root")
        try check(posterURL.path.hasPrefix(target.path + "/"),
                  "lock-screen poster URL is inside the new root")
        try check(fm.fileExists(atPath: videoURL.path) && fm.fileExists(atPath: posterURL.path),
                  "rebased lock-screen assets remain usable")

        let targetFramework = target.appendingPathComponent(
            "Workshop/SteamCMD/Frameworks/Breakpad.framework")
        try check(try fm.destinationOfSymbolicLink(
            atPath: target.appendingPathComponent("Workshop/Frameworks").path) == "MacOS/Frameworks",
                  "contained dangling Workshop/Frameworks link is copied verbatim")
        try check(!fm.fileExists(atPath: target.appendingPathComponent("Workshop/MacOS/Frameworks").path),
                  "dangling link is copied, never followed")
        try check(try fm.destinationOfSymbolicLink(
            atPath: targetFramework.appendingPathComponent("Resources").path)
            == "Versions/Current/Resources",
                  "Breakpad Resources link is copied verbatim")
        try check(try fm.destinationOfSymbolicLink(
            atPath: targetFramework.appendingPathComponent("Headers").path)
            == "Versions/Current/Headers",
                  "Breakpad Headers link is copied verbatim")
        try check(try fm.destinationOfSymbolicLink(
            atPath: targetFramework.appendingPathComponent("Breakpad").path)
            == "Versions/Current/Breakpad",
                  "Breakpad binary link is copied verbatim")
        try check(try fm.destinationOfSymbolicLink(
            atPath: targetFramework.appendingPathComponent("Versions/Current").path) == "A",
                  "Breakpad Versions/Current link is copied verbatim")

        let repeated = try GlimmerStorageMigration.migrateIfNeeded(source: source, target: target)
        try check(!repeated, "repeated migration accepts the initialized target without rewriting it")
        try check(try Data(contentsOf: source.appendingPathComponent("library.json")) == sourceLibraryBefore,
                  "repeated migration still leaves the legacy source untouched")
    }

    private static func testConflictingTargets(root: URL) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent("Conflict/Legacy", isDirectory: true)
        try write("legacy", to: source.appendingPathComponent("keep.txt"))
        let emptyTarget = root.appendingPathComponent("Conflict/Empty", isDirectory: true)
        try fm.createDirectory(at: emptyTarget, withIntermediateDirectories: true)
        try check(!GlimmerStorageMigration.requiresMigration(source: source, target: emptyTarget),
                  "existing unmarked target is handled as a conflict, not an old-process launch gate")
        let emptyError = try captureMigrationError("empty preexisting target reports a conflict") {
            _ = try GlimmerStorageMigration.migrateIfNeeded(source: source, target: emptyTarget)
        }
        try check(emptyError.localizedDescription.contains("不是完整初始化"),
                  "empty target conflict explains the missing completion marker")
        try check(fm.fileExists(atPath: source.appendingPathComponent("keep.txt").path),
                  "empty-target conflict retains the legacy tree")
        try check(try fm.contentsOfDirectory(atPath: emptyTarget.path).isEmpty,
                  "empty-target conflict performs no target writes")

        let partialTarget = root.appendingPathComponent("Conflict/Partial", isDirectory: true)
        try write("partial", to: partialTarget.appendingPathComponent("partial.txt"))
        _ = try captureMigrationError("partial preexisting target reports a conflict") {
            _ = try GlimmerStorageMigration.migrateIfNeeded(source: source, target: partialTarget)
        }
        try check(fm.fileExists(atPath: partialTarget.appendingPathComponent("partial.txt").path),
                  "partial target is preserved")

        let initializedTarget = root.appendingPathComponent("Conflict/Initialized", isDirectory: true)
        try fm.createDirectory(at: initializedTarget, withIntermediateDirectories: true)
        try GlimmerStorageMigration.ensureInitializedProfile(at: initializedTarget)
        let initializedSource = root.appendingPathComponent("Conflict/InitializedLegacy", isDirectory: true)
        try write("must not merge", to: initializedSource.appendingPathComponent("source-only.txt"))
        let accepted = try GlimmerStorageMigration.migrateIfNeeded(
            source: initializedSource, target: initializedTarget)
        try check(!accepted, "valid initialized target is idempotently accepted")
        try check(!fm.fileExists(atPath: initializedTarget.appendingPathComponent("source-only.txt").path),
                  "accepted initialized target is never merged with the legacy tree")
        try check(fm.fileExists(atPath: initializedSource.appendingPathComponent("source-only.txt").path),
                  "initialized-target acceptance leaves the legacy tree intact")

        let absentSource = root.appendingPathComponent("Conflict/AbsentSource", isDirectory: true)
        let unmarkedTarget = root.appendingPathComponent("Conflict/UnmarkedWithNoSource", isDirectory: true)
        try fm.createDirectory(at: unmarkedTarget, withIntermediateDirectories: true)
        try check(!GlimmerStorageMigration.requiresMigration(source: absentSource, target: unmarkedTarget),
                  "launch gate stays closed without a legacy source")
        _ = try captureMigrationError("unmarked target is a conflict even when no source exists") {
            _ = try GlimmerStorageMigration.migrateIfNeeded(source: absentSource, target: unmarkedTarget)
        }
    }

    private static func testTargetSymlinkIsRejected(root: URL) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent("TargetSymlink/Legacy", isDirectory: true)
        try write("source", to: source.appendingPathComponent("keep.txt"))
        let elsewhere = root.appendingPathComponent("TargetSymlink/Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let linkedTarget = root.appendingPathComponent("TargetSymlink/Glimmer", isDirectory: true)
        try fm.createSymbolicLink(atPath: linkedTarget.path, withDestinationPath: elsewhere.path)
        let error = try captureMigrationError("literal target symlink is rejected before resolution") {
            _ = try GlimmerStorageMigration.migrateIfNeeded(source: source, target: linkedTarget)
        }
        try check(error.localizedDescription.contains("符号链接"),
                  "target symlink rejection identifies the unsafe path")
        try check(try fm.contentsOfDirectory(atPath: elsewhere.path).isEmpty,
                  "target symlink rejection writes nothing through the link")
        try check(fm.fileExists(atPath: source.appendingPathComponent("keep.txt").path),
                  "target symlink rejection retains the source")
    }

    private static func testInterruptedCopyLeavesNoTarget(root: URL) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent("Interrupted/Legacy", isDirectory: true)
        for index in 0..<4 {
            try write("file \(index)", to: source.appendingPathComponent("Media/\(index).bin"))
        }
        let target = root.appendingPathComponent("Interrupted/Glimmer", isDirectory: true)
        _ = try captureMigrationError("injected copy interruption fails the migration") {
            _ = try GlimmerStorageMigration.migrateIfNeededForTesting(
                source: source, target: target, interruptAfterRegularFiles: 2)
        }
        try check(!fm.fileExists(atPath: target.path),
                  "interrupted copy never publishes a partial target")
        let parentEntries = try fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        try check(!parentEntries.contains { $0.hasPrefix(".Glimmer-migration-") },
                  "interrupted copy removes its private staging directory")
        try check((0..<4).allSatisfy {
            fm.fileExists(atPath: source.appendingPathComponent("Media/\($0).bin").path)
        }, "interrupted copy leaves every legacy file intact")
    }

    private static func testUnsafeLinksAreRejected(root: URL) throws {
        let fm = FileManager.default
        func makeSource(_ name: String) throws -> URL {
            let source = root.appendingPathComponent("UnsafeLinks/\(name)/Legacy", isDirectory: true)
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            return source
        }
        func rejectLink(_ name: String, destination: String, containing text: String) throws {
            let source = try makeSource(name)
            try fm.createSymbolicLink(atPath: source.appendingPathComponent("unsafe-link").path,
                                      withDestinationPath: destination)
            let target = root.appendingPathComponent("UnsafeLinks/\(name)/Glimmer", isDirectory: true)
            let error = try captureMigrationError("\(name) link is rejected") {
                _ = try GlimmerStorageMigration.migrateIfNeeded(source: source, target: target)
            }
            try check(error.localizedDescription.contains(text),
                      "\(name) link rejection has the expected safety reason")
            try check(!fm.fileExists(atPath: target.path),
                  "\(name) link rejection never publishes a target")
            try check(try fm.destinationOfSymbolicLink(
                atPath: source.appendingPathComponent("unsafe-link").path) == destination,
                  "\(name) link remains untouched in the source")
        }
        try rejectLink("absolute", destination: "/etc/passwd", containing: "绝对")
        try rejectLink("escaping", destination: "../../outside", containing: "越出")

        let cyclicSource = try makeSource("cyclic")
        try fm.createSymbolicLink(atPath: cyclicSource.appendingPathComponent("unsafe-link").path,
                                  withDestinationPath: "unsafe-link")
        let cyclicTarget = root.appendingPathComponent("UnsafeLinks/cyclic/Glimmer", isDirectory: true)
        let cyclicError = try captureMigrationError("self-referential link is rejected") {
            _ = try GlimmerStorageMigration.migrateIfNeeded(source: cyclicSource, target: cyclicTarget)
        }
        try check(cyclicError.localizedDescription.contains("循环"),
                  "cyclic link rejection identifies the loop")
        try check(!fm.fileExists(atPath: cyclicTarget.path),
                  "cyclic link rejection never publishes a target")
        try check(try fm.destinationOfSymbolicLink(
            atPath: cyclicSource.appendingPathComponent("unsafe-link").path) == "unsafe-link",
                  "cyclic link remains untouched in the source")
    }

    private static func checkDictionary(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw MigrationTestFailure(description: "expected dictionary for \(label)")
        }
        return dictionary
    }

    private static func checkString(_ value: Any?, _ label: String) throws -> String {
        guard let string = value as? String else {
            throw MigrationTestFailure(description: "expected string for \(label)")
        }
        return string
    }

    private static func checkURL(_ value: String, _ label: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw MigrationTestFailure(description: "expected URL for \(label)")
        }
        return url
    }
}
