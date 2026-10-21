import XCTest
@testable import OpenWallpaperEngine

/// Installing the Chromium engine with a fake download (never the network): the SHA-256 pin,
/// the atomic install and its rollback, pruning to two versions, cancel and updates.
final class ChromiumEngineInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-chromium-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var engineRoot: URL { root.appending(path: "support/ChromiumEngine", directoryHint: .isDirectory) }

    // MARK: Helpers

    /// A bzip2 tar laid out like CEF's minimal distribution for `version`.
    private func makeArchive(version: String, withFramework: Bool = true, marker: String = "binary") throws -> URL {
        let top = "cef_binary_\(version)_macosarm64_minimal"
        let source = root.appending(path: "source-\(UUID().uuidString)")
        let framework = source.appending(path: "\(top)/Release/\(ChromiumEnginePackage.frameworkName)")
        try FileManager.default.createDirectory(at: framework.appending(path: "Libraries"), withIntermediateDirectories: true)
        if withFramework {
            try Data(marker.utf8).write(to: framework.appending(path: ChromiumEnginePackage.frameworkBinary))
        }
        try Data("lib".utf8).write(to: framework.appending(path: "Libraries/libcef_sandbox.dylib"))
        try Data("license".utf8).write(to: source.appending(path: "\(top)/LICENSE.txt"))
        try Data("not unpacked".utf8).write(to: source.appending(path: "\(top)/README.txt"))
        let archive = root.appending(path: "\(top)-\(UUID().uuidString).tar.bz2")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cjf", archive.path, "-C", source.path, top]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    private func pin(version: String, archive: URL, sha256: String? = nil) throws -> ChromiumEnginePin {
        ChromiumEnginePin(version: version, platform: "macosarm64",
                          sha256: try sha256 ?? VersionedInstallStore.sha256(of: archive),
                          downloadSize: 1, installedSize: 1)
    }

    @MainActor
    private func makeInstaller(pin: ChromiumEnginePin, downloader: SteamCmdPackageDownloading) -> ChromiumEngineInstaller {
        ChromiumEngineInstaller(root: engineRoot, pin: pin, downloader: downloader,
                                trash: { try FileManager.default.removeItem(at: $0) })
    }

    @MainActor
    private func install(version: String, archive: URL? = nil) async throws -> ChromiumEngineInstaller {
        let archive = try archive ?? makeArchive(version: version)
        let installer = makeInstaller(pin: try pin(version: version, archive: archive),
                                      downloader: CopyingDownloader(source: archive))
        installer.install()
        await installer.wait()
        return installer
    }

    private func visibleEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: engineRoot.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func stagingEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: engineRoot.path)
            .filter { $0.hasPrefix(ChromiumEngineInstallJob.stagingPrefix) }
    }

    // MARK: Pins

    func testPinnedBuildsAreOfficialAndComplete() {
        XCTAssertEqual(Set(ChromiumEnginePin.pinned.map(\.platform)), ["macosarm64", "macosx64"])
        for pin in ChromiumEnginePin.pinned {
            XCTAssertEqual(pin.sha256.count, 64)
            XCTAssertTrue(pin.sha256.allSatisfy { "0123456789abcdef".contains($0) })
            XCTAssertEqual(pin.downloadURL.scheme, "https")
            XCTAssertEqual(pin.downloadURL.host, "cef-builds.spotifycdn.com")
            XCTAssertTrue(pin.downloadURL.absoluteString.hasSuffix("_\(pin.platform)_minimal.tar.bz2"))
            XCTAssertTrue(pin.downloadURL.absoluteString.contains("%2B"), "+ must be escaped")
        }
        XCTAssertNotNil(ChromiumEnginePin.current())
    }

    // MARK: SHA-256

    @MainActor
    func testAWrongHashIsRefusedAndNothingIsInstalled() async throws {
        let archive = try makeArchive(version: "1.0.0")
        let installer = makeInstaller(pin: try pin(version: "1.0.0", archive: archive, sha256: String(repeating: "0", count: 64)),
                                      downloader: CopyingDownloader(source: archive))
        installer.install()
        await installer.wait()

        guard case .failed = installer.phase else { return XCTFail("expected a failure, got \(installer.phase)") }
        XCTAssertNil(installer.installedVersion)
        XCTAssertEqual(try visibleEntries(), [])
        XCTAssertEqual(try stagingEntries(), [], "the .partial download is deleted")
    }

    @MainActor
    func testAWrongHashSaysSo() async throws {
        let archive = try makeArchive(version: "1.0.0")
        let installer = makeInstaller(pin: try pin(version: "1.0.0", archive: archive, sha256: String(repeating: "0", count: 64)),
                                      downloader: CopyingDownloader(source: archive))
        installer.install()
        await installer.wait()
        let mismatch = ChromiumEnginePackage.Failure.checksumMismatch(expected: "", actual: "").localizedDescription
        XCTAssertEqual(installer.phase, .failed(mismatch))
    }

    func testOfflineHTTPAndDiskFullErrorsSaySo() {
        XCTAssertTrue(ChromiumEngineInstaller.message(for: URLError(.notConnectedToInternet)).contains("internet connection"))
        XCTAssertTrue(ChromiumEngineInstaller.message(for: URLSessionSteamCmdDownloader.Failure.httpStatus(404)).contains("404"))
        XCTAssertTrue(ChromiumEngineInstaller.message(for: CocoaError(.fileWriteOutOfSpace)).contains("disk space"))
        XCTAssertTrue(ChromiumEngineInstaller.message(for: URLError(.cannotWriteToFile)).contains("disk space"))
    }

    // MARK: Atomic install

    @MainActor
    func testInstallUnpacksOnlyTheFrameworkAndLicense() async throws {
        let installer = try await install(version: "1.0.0")

        XCTAssertEqual(installer.phase, .installed)
        XCTAssertEqual(installer.installedVersion, "1.0.0")
        XCTAssertTrue(installer.isCurrent)
        XCTAssertFalse(installer.needsUpdate)
        XCTAssertNotNil(installer.installedSize)
        let folder = engineRoot.appending(path: "1.0.0")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, [ChromiumEnginePackage.manifestName, ChromiumHelperIPC.engineBundleName, "LICENSE.txt"].sorted())
        XCTAssertEqual(ChromiumEnginePackage.manifest(in: folder)?.version, "1.0.0")
        XCTAssertEqual(try stagingEntries(), [])
    }

    @MainActor
    func testAnArchiveWithoutTheFrameworkInstallsNothing() async throws {
        let archive = try makeArchive(version: "1.0.0", withFramework: false)
        let installer = try await install(version: "1.0.0", archive: archive)

        guard case .failed = installer.phase else { return XCTFail("expected a failure, got \(installer.phase)") }
        XCTAssertEqual(try visibleEntries(), [])
        XCTAssertEqual(try stagingEntries(), [])
    }

    @MainActor
    func testAFailedReinstallKeepsTheExistingInstall() async throws {
        _ = try await install(version: "1.0.0")
        let broken = try makeArchive(version: "1.0.0", withFramework: false)
        let installer = try await install(version: "1.0.0", archive: broken)

        guard case .failed = installer.phase else { return XCTFail("expected a failure, got \(installer.phase)") }
        XCTAssertEqual(installer.installedVersion, "1.0.0")
        XCTAssertNotNil(ChromiumEnginePackage.manifest(in: engineRoot.appending(path: "1.0.0")))
    }

    /// The rename into place fails: the folder that was there comes back.
    func testCommitRollsBackWhenTheRenameFails() throws {
        let archive = try makeArchive(version: "1.0.0", marker: "old")
        let pin = try pin(version: "1.0.0", archive: archive)
        let target = engineRoot.appending(path: "1.0.0")
        try FileManager.default.createDirectory(at: engineRoot, withIntermediateDirectories: true)
        let scratch = root.appending(path: "scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try ChromiumEnginePackage.unpack(archive, pin: pin, scratch: scratch, into: target)

        let staging = engineRoot.appending(path: "\(ChromiumEngineInstallJob.stagingPrefix)test")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let job = ChromiumEngineInstallJob(root: engineRoot, pin: pin, downloader: CopyingDownloader(source: archive))
        XCTAssertThrowsError(try job.commit(staging.appending(path: "missing"), staging: staging))

        let binary = ChromiumEnginePackage.frameworksFolder(in: target).appending(path: "\(ChromiumEnginePackage.frameworkName)/\(ChromiumEnginePackage.frameworkBinary)")
        XCTAssertEqual(try String(contentsOf: binary, encoding: .utf8), "old")
        XCTAssertNotNil(ChromiumEnginePackage.manifest(in: target))
    }

    @MainActor
    func testStaleStagingFoldersAreCleanedUp() async throws {
        let stale = engineRoot.appending(path: "\(ChromiumEngineInstallJob.stagingPrefix)crashed")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        _ = try await install(version: "1.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    @MainActor
    func testQuarantineIsClearedFromTheVerifiedArchiveOnly() async throws {
        let archive = try makeArchive(version: "1.0.0")
        let installer = makeInstaller(pin: try pin(version: "1.0.0", archive: archive),
                                      downloader: CopyingDownloader(source: archive, quarantine: true))
        installer.install()
        await installer.wait()

        XCTAssertEqual(installer.phase, .installed)
        let folder = engineRoot.appending(path: "1.0.0")
        let files = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertFalse(SteamCmdPackage.hasQuarantine(folder.appending(path: file).path), file)
        }
    }

    // MARK: Versions

    @MainActor
    func testOnlyTheCurrentAndPreviousVersionsAreKept() async throws {
        _ = try await install(version: "1.0.0")
        _ = try await install(version: "2.0.0")
        XCTAssertEqual(try visibleEntries(), ["1.0.0", "2.0.0"])
        let installer = try await install(version: "3.0.0")

        XCTAssertEqual(try visibleEntries(), ["2.0.0", "3.0.0"])
        XCTAssertEqual(installer.installedVersion, "3.0.0")
        XCTAssertEqual(VersionedInstallState.read(in: engineRoot),
                       VersionedInstallState(active: "3.0.0", previous: "2.0.0"))
    }

    @MainActor
    func testReinstallingTheSameVersionKeepsThePreviousOne() async throws {
        _ = try await install(version: "1.0.0")
        _ = try await install(version: "2.0.0")
        _ = try await install(version: "2.0.0")
        XCTAssertEqual(try visibleEntries(), ["1.0.0", "2.0.0"])
        XCTAssertEqual(VersionedInstallState.read(in: engineRoot),
                       VersionedInstallState(active: "2.0.0", previous: "1.0.0"))
    }

    @MainActor
    func testANewPinNeedsAnUpdate() async throws {
        _ = try await install(version: "1.0.0")
        let archive = try makeArchive(version: "2.0.0")
        let installer = makeInstaller(pin: try pin(version: "2.0.0", archive: archive),
                                      downloader: CopyingDownloader(source: archive))
        XCTAssertEqual(installer.installedVersion, "1.0.0")
        XCTAssertTrue(installer.needsUpdate)
        XCTAssertFalse(installer.isCurrent)

        installer.update()
        await installer.wait()
        XCTAssertTrue(installer.isCurrent)
        XCTAssertFalse(installer.needsUpdate)
    }

    @MainActor
    func testRemoveDeletesEveryVersion() async throws {
        _ = try await install(version: "1.0.0")
        let installer = try await install(version: "2.0.0")
        try installer.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: engineRoot.path))
        XCTAssertNil(installer.installedVersion)
        XCTAssertNil(installer.installedSize)
    }

    // MARK: Cancel

    @MainActor
    func testCancelLeavesNothingBehind() async throws {
        let archive = try makeArchive(version: "1.0.0")
        let installer = makeInstaller(pin: try pin(version: "1.0.0", archive: archive), downloader: HangingDownloader())
        installer.install()
        XCTAssertTrue(installer.isBusy)
        installer.cancel()
        await installer.wait()

        XCTAssertEqual(installer.phase, .idle)
        XCTAssertNil(installer.installedVersion)
        XCTAssertEqual(try visibleEntries(), [])
        XCTAssertEqual(try stagingEntries(), [])
    }
}

/// Copies a local archive as if it were downloaded, optionally flagging it quarantined.
private struct CopyingDownloader: SteamCmdPackageDownloading {
    let source: URL
    var quarantine = false

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        progress(0.5)
        try FileManager.default.copyItem(at: source, to: destination)
        if quarantine {
            let value = "0081;00000000;Test;"
            XCTAssertEqual(setxattr(destination.path, SteamCmdPackage.quarantineAttribute, value, value.utf8.count, 0, 0), 0)
        }
        progress(1)
    }
}

/// Never finishes until cancelled.
private struct HangingDownloader: SteamCmdPackageDownloading {
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
