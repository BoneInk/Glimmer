import XCTest
@testable import OpenWallpaperEngine

/// Rejected shader sources go to a folder only the user can read, as files only they can read,
/// never through a symbolic link (`FailedShaderDump`).
final class FailedShaderDumpTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appending(path: "owe-failed-dump-\(UUID().uuidString)",
                                                                  directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int) & 0o777
    }

    func testDefaultDirectoryIsInTheAppsCaches() {
        let directory = FailedShaderDump.defaultDirectory
        XCTAssertTrue(directory.path.hasPrefix(AppStorageLocation.current.cachesDirectory.path))
        XCTAssertEqual(directory.lastPathComponent, "FailedShaders")
        XCTAssertFalse(directory.path.hasPrefix("/tmp"))
    }

    func testFolderIs0700AndFilesAre0600() throws {
        let directory = root.appending(path: "FailedShaders", directoryHint: .isDirectory)
        let dump = FailedShaderDump(directory: directory)
        let url = try dump.write("void main() {}\n// error\n", named: "effects_x_bad.frag")
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "void main() {}\n// error\n")

        // Rewriting replaces the text and keeps the mode.
        try dump.write("second\n", named: "effects_x_bad.frag")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second\n")
        XCTAssertEqual(try permissions(url), 0o600)
    }

    func testExistingFolderAndFileModesAreReset() throws {
        let directory = root.appending(path: "FailedShaders", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let url = directory.appending(path: "a.vert")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("old".utf8),
                                                     attributes: [.posixPermissions: 0o644]))
        try FailedShaderDump(directory: directory).write("new", named: "a.vert")
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(url), 0o600)
    }

    func testSymbolicLinksAreNotWrittenThrough() throws {
        let directory = root.appending(path: "FailedShaders", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = root.appending(path: "outside.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data("keep".utf8)))
        let link = directory.appending(path: "a.frag")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try FailedShaderDump(directory: directory).write("dump", named: "a.frag")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep", "the link's target is untouched")
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        XCTAssertEqual(values.isSymbolicLink, false)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "dump")
    }

    func testALinkInPlaceOfTheFolderIsRefused() throws {
        let target = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let directory = root.appending(path: "FailedShaders")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        XCTAssertThrowsError(try FailedShaderDump(directory: directory).write("dump", named: "a.frag"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
}
