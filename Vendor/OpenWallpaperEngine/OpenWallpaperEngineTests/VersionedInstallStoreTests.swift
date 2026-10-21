import XCTest
import OWEEditor
@testable import OpenWallpaperEngine

/// The core every on-demand install shares (`VersionedInstallStore`, `VersionedInstallFailure`),
/// with a fake download and a build that writes one file: the SHA-256 check, staging, the atomic
/// swap and its rollback, keeping the active and the previous version, and the error messages.
/// `ChromiumEngineInstallerTests` and `DepthMapPluginInstallerTests` run each specialization.
final class VersionedInstallStoreTests: XCTestCase {
    private var root: URL!
    private var store: VersionedInstallStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-versioned-install-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VersionedInstallStore(root: root.appending(path: "installs", directoryHint: .isDirectory),
                                      category: .app, subject: "test install")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func entries(staging: Bool = false) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? [])
            .filter { staging ? $0.hasPrefix(VersionedInstallStore.stagingPrefix) : !$0.hasPrefix(".") }.sorted()
    }

    /// Installs `version` with one file holding `marker`.
    private func install(_ version: String, marker: String = "new") async throws {
        try await store.install(version: version) { staging in
            let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: unpacked.appending(path: "file"))
            return unpacked
        }
    }

    private func marker(_ version: String) throws -> String {
        try String(contentsOf: store.root.appending(path: "\(version)/file"), encoding: .utf8)
    }

    // MARK: SHA-256

    /// No `.state.json` is no install; a corrupt one reads as none too (and is logged), and a
    /// written one reads back.
    func testStateReadsMissingCorruptAndWritten() throws {
        XCTAssertEqual(VersionedInstallState.read(in: root), VersionedInstallState())
        try Data("{not json".utf8).write(to: root.appending(path: VersionedInstallState.fileName))
        XCTAssertEqual(VersionedInstallState.read(in: root), VersionedInstallState())
        let state = VersionedInstallState(active: "2", previous: "1")
        try state.write(in: root)
        XCTAssertEqual(VersionedInstallState.read(in: root), state)
    }

    func testVerifyComparesTheWholeFile() throws {
        let file = root.appending(path: "file")
        try Data("abc".utf8).write(to: file)
        // SHA-256("abc"), the FIPS 180-2 test vector.
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertNoThrow(try VersionedInstallStore.verify(file, sha256: abc.uppercased()))
        try Data("abd".utf8).write(to: file)
        XCTAssertThrowsError(try VersionedInstallStore.verify(file, sha256: abc)) { error in
            XCTAssertEqual((error as? VersionedInstallStore.ChecksumMismatch)?.expected, abc)
        }
    }

    func testFetchKeepsAFileOnlyWhenItMatchesItsPin() async throws {
        let source = root.appending(path: "source")
        try Data("abc".utf8).write(to: source)
        let sha = try VersionedInstallStore.sha256(of: source)
        let destination = root.appending(path: "nested/folder/file")
        var verified = false
        try await store.fetch(URL(string: "https://example.invalid/file")!, sha256: sha, to: destination,
                              downloader: LocalFileDownloader(source: source), progress: { _ in },
                              verifying: { verified = true })
        XCTAssertTrue(verified)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abc".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))

        struct Mapped: Error {}
        let other = root.appending(path: "other")
        do {
            try await store.fetch(URL(string: "https://example.invalid/file")!, sha256: String(repeating: "0", count: 64),
                                  to: other, downloader: LocalFileDownloader(source: source), progress: { _ in },
                                  mismatch: { _ in Mapped() })
            XCTFail("kept a file that doesn't match its pin")
        } catch {
            XCTAssertTrue(error is Mapped, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: Staging and the swap

    func testInstallCommitsAndLeavesNoStaging() async throws {
        let stale = store.root.appending(path: "\(VersionedInstallStore.stagingPrefix)crashed")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try await install("1")
        XCTAssertEqual(entries(), ["1"])
        XCTAssertEqual(entries(staging: true), [], "the stale and the new staging folder are gone")
        XCTAssertEqual(VersionedInstallState.read(in: store.root), VersionedInstallState(active: "1", previous: nil))
        XCTAssertNotNil(store.installedSize)
    }

    func testAFailedBuildInstallsNothing() async throws {
        struct Broken: Error {}
        do {
            try await store.install(version: "1") { _ in throw Broken() }
            XCTFail("expected the build's error")
        } catch {
            XCTAssertTrue(error is Broken)
        }
        XCTAssertEqual(entries(), [])
        XCTAssertEqual(entries(staging: true), [])
        XCTAssertNil(VersionedInstallState.read(in: store.root).active)
        XCTAssertNil(store.installedSize)
    }

    func testCommitRollsBackWhenTheRenameFails() async throws {
        try await install("1", marker: "old")
        let staging = store.root.appending(path: "\(VersionedInstallStore.stagingPrefix)test")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.commit(staging.appending(path: "missing"), version: "1", staging: staging))
        XCTAssertEqual(try marker("1"), "old")
    }

    func testReinstallingAVersionReplacesItInPlace() async throws {
        try await install("1", marker: "old")
        try await install("1", marker: "new")
        XCTAssertEqual(try marker("1"), "new")
        XCTAssertEqual(VersionedInstallState.read(in: store.root), VersionedInstallState(active: "1", previous: nil))
    }

    // MARK: Versions

    func testOnlyTheActiveAndThePreviousVersionAreKept() async throws {
        try await install("1")
        try await install("2")
        XCTAssertEqual(entries(), ["1", "2"])
        try await install("3")
        XCTAssertEqual(entries(), ["2", "3"])
        XCTAssertEqual(VersionedInstallState.read(in: store.root), VersionedInstallState(active: "3", previous: "2"))
    }

    /// The depth model's readers (the editor's process) find staging by the layout's prefix.
    func testTheDepthMapLayoutSharesTheStagingPrefix() {
        XCTAssertEqual(DepthMapPluginLayout.stagingPrefix, VersionedInstallStore.stagingPrefix)
        XCTAssertEqual(DepthMapPluginLayout.State.fileName, VersionedInstallState.fileName)
    }

    // MARK: Messages

    func testFailureMessages() {
        func message(_ error: Error) -> String {
            VersionedInstallFailure.message(for: error, offline: { "offline" }, diskFull: { "disk full" })
        }
        XCTAssertEqual(message(URLError(.notConnectedToInternet)), "offline")
        XCTAssertEqual(message(URLError(.timedOut)), "offline")
        XCTAssertTrue(message(URLSessionSteamCmdDownloader.Failure.httpStatus(503)).contains("503"))
        XCTAssertEqual(message(CocoaError(.fileWriteOutOfSpace)), "disk full")
        XCTAssertEqual(message(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), "disk full")
        XCTAssertEqual(message(URLError(.cannotWriteToFile)), "disk full")
        XCTAssertEqual(message(CocoaError(.fileReadNoSuchFile)), CocoaError(.fileReadNoSuchFile).localizedDescription)
    }
}

/// Copies a local file as if it were downloaded.
private struct LocalFileDownloader: SteamCmdPackageDownloading {
    let source: URL

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
        progress(1)
    }
}
