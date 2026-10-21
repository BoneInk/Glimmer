import XCTest
@testable import OpenWallpaperEngine

/// Every way a Workshop item reaches the app ends in the Wallpaper Storage folder, as `<storage>/<id>`,
/// with nothing left in steamcmd's install dir. steamcmd is a fake that "downloads" by writing the
/// item where the script's `force_install_dir` says.
final class WorkshopStorageTests: XCTestCase {
    /// The storage folder the service reads at each download, so a test can change it.
    private final class StorageLocation {
        var url: URL
        init(_ url: URL) { self.url = url }
    }

    private var root: URL!
    private var storage: StorageLocation!
    private var previewCache: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var steamCmd: FakeSteamCmd!
    private var dependencyIndex: WorkshopDependencyIndex!
    private var downloadedIndex: DownloadedWallpaperIndex!
    private var presented: [WEWallpaper] = []
    private var service: SteamCmdService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        let firstStorage = root.appending(path: "Storage A", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstStorage, withIntermediateDirectories: true)
        storage = StorageLocation(firstStorage)
        previewCache = root.appending(path: "Caches/WorkshopPreviews", directoryHint: .isDirectory)
        defaultsSuite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        steamCmd = FakeSteamCmd()
        let storage = storage!
        dependencyIndex = WorkshopDependencyIndex(libraryDirectory: { storage.url })
        downloadedIndex = DownloadedWallpaperIndex(defaults: defaults, libraryDirectory: { storage.url })
        service = SteamCmdService(dependencyIndex: dependencyIndex, runner: steamCmd,
                                  storageDirectory: { try WallpaperStorage.availableDirectory(storage.url) },
                                  previewCacheRoot: previewCache, downloadedIndex: downloadedIndex,
                                  presentPreview: { [weak self] in self?.presented.append($0) },
                                  restoresSession: false)
        service.steamCmdPath = "/fake/steamcmd"
        service.steamUsername = "tester"
        service.isLoggedIn = true
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func download(_ id: String, asDependency: Bool = false) async -> URL? {
        await withCheckedContinuation { continuation in
            service.downloadWorkshopItem(workshopId: id, asDependency: asDependency) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private func children(of directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private func listed(in directory: URL) -> Set<String> {
        Set(InstalledLibrary.wallpapers(in: directory, hiding: dependencyIndex.ids).map(\.wallpaperDirectory.lastPathComponent))
    }

    private func makeWallpaper(_ id: String, in directory: URL, referencing dependency: String) throws -> URL {
        let folder = directory.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "scene", "title": "Uses \#(dependency)", "file": "scene.json"}"#.utf8)
            .write(to: folder.appending(path: "project.json"))
        try Data(#"{"objects": [{"effects": [{"file": "effects/workshop/\#(dependency)/glow/effect.json"}]}]}"#.utf8)
            .write(to: folder.appending(path: "scene.json"))
        return folder
    }

    /// A dependency service on the test storage whose Steam check answers `availability`
    /// (nothing by default, as when Steam leaves the ids out).
    @MainActor
    private func makeDependencyService(
        availability: @escaping WorkshopDependencyService.AvailabilityCheck = { _ in [:] },
        now: @escaping () -> Date = Date.init
    ) -> WorkshopDependencyService {
        let storage = storage!
        return WorkshopDependencyService(
            steamCmd: service,
            makeResolver: { WorkshopAssetResolver(roots: [storage.url]) },
            store: UnavailableWorkshopItemStore(fileURL: root.appending(path: "UnavailableWorkshopItems.json"), now: now),
            checkAvailability: availability)
    }

    // MARK: - Downloads

    @MainActor
    func testUserDownloadGoesIntoStorage() async throws {
        let destination = await download("1000000001")

        XCTAssertEqual(destination?.standardizedFileURL, storage.url.appending(path: "1000000001").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.url.appending(path: "1000000001/project.json").path))
        // steamcmd's staging folder, manifests included, is gone.
        XCTAssertEqual(try children(of: storage.url), ["1000000001"])
        XCTAssertEqual(steamCmd.installDirectories, [WorkshopItemInstaller.stagingDirectory(in: storage.url).path])
        XCTAssertEqual(service.downloadProgress["1000000001"], .completed)
        XCTAssertTrue(downloadedIndex.contains("1000000001"))
        XCTAssertEqual(listed(in: storage.url), ["1000000001"])
    }

    @MainActor
    func testDependencyDownloadGoesIntoStorageHiddenAndResolvable() async throws {
        let wallpaper = try makeWallpaper("1000000001", in: storage.url, referencing: "2000000002")
        let dependencies = makeDependencyService()

        dependencies.ensureDependencies(ofItemAt: wallpaper)
        try await sleepUntil("the dependency is installed", timeout: 10) { dependencies.states["2000000002"] == .installed }

        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.url.appending(path: "2000000002/project.json").path))
        XCTAssertEqual(try children(of: storage.url), ["1000000001", "2000000002", WorkshopDependencyIndex.fileName])
        XCTAssertTrue(dependencyIndex.contains("2000000002"))
        XCTAssertEqual(listed(in: storage.url), ["1000000001"], "a dependency-only item stays out of Installed")
        XCTAssertEqual(WorkshopAssetResolver(roots: [storage.url]).itemDirectory(for: "2000000002")?.standardizedFileURL,
                       storage.url.appending(path: "2000000002").standardizedFileURL)
    }

    /// A dependency Steam reports removed is never handed to steamcmd, is remembered for the next
    /// load, and the wallpaper still loads: its assets resolve as missing and nothing waits on it.
    @MainActor
    func testUnavailableDependencyIsSkippedAndTheWallpaperStillLoads() async throws {
        let wallpaper = try makeWallpaper("1000000001", in: storage.url, referencing: "9000000009")
        var reloads = 0
        let observer = NotificationCenter.default.addObserver(forName: .workshopDependenciesDidInstall, object: nil,
                                                              queue: .main) { _ in reloads += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let dependencies = makeDependencyService(availability: { _ in ["9000000009": .unavailable(.removedOrPrivate)] })

        dependencies.ensureDependencies(ofItemAt: wallpaper)
        try await sleepUntil("the dependency is unavailable", timeout: 10) {
            dependencies.states["9000000009"] == .itemUnavailable(.removedOrPrivate)
        }

        XCTAssertTrue(steamCmd.installDirectories.isEmpty, "steamcmd isn't asked for a removed item")
        XCTAssertTrue(dependencies.pending.isEmpty)
        XCTAssertEqual(dependencies.unavailableReason(for: "9000000009"), .removedOrPrivate)
        XCTAssertEqual(reloads, 0)
        // Loading: the reference resolves as missing and no link is made.
        let resolver = WorkshopAssetResolver(roots: [storage.url])
        WorkshopDependencyResolver.linkInstalledDependencies(inItemAt: wallpaper, resolver: resolver)
        XCTAssertNil(resolver.url(for: "effects/workshop/9000000009/glow/effect.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wallpaper.appending(path: "effects/workshop").path))

        // A later load skips it without asking Steam.
        let later = makeDependencyService(availability: { ids in
            XCTFail("asked Steam again for \(ids)")
            return [:]
        })
        later.ensureDependencies(ofItemAt: wallpaper)
        try await sleepUntil("the skipped dependency is reported", timeout: 10) {
            later.states["9000000009"] == .itemUnavailable(.removedOrPrivate)
        }
        XCTAssertTrue(steamCmd.installDirectories.isEmpty)
    }

    /// steamcmd's `File Not Found` reads as a removed item, with the clear message, and is remembered.
    @MainActor
    func testSteamCmdFileNotFoundMarksTheDependencyUnavailable() async throws {
        let wallpaper = try makeWallpaper("1000000001", in: storage.url, referencing: "9000000009")
        let dependencies = makeDependencyService()

        dependencies.ensureDependencies(ofItemAt: wallpaper)
        try await sleepUntil("the dependency is unavailable", timeout: 10) {
            dependencies.states["9000000009"] == .itemUnavailable(.removedOrPrivate)
        }

        XCTAssertEqual(service.downloadProgress["9000000009"],
                       .failed(WorkshopItemAvailability.Reason.removedOrPrivate.message))
        XCTAssertTrue(dependencies.pending.isEmpty)
        XCTAssertEqual(makeDependencyService().unavailableReason(for: "9000000009"), .removedOrPrivate)
    }

    /// When Steam can't be reached the dependency is downloaded as before.
    @MainActor
    func testOfflineCheckFallsBackToDownloading() async throws {
        let wallpaper = try makeWallpaper("1000000001", in: storage.url, referencing: "2000000002")
        let dependencies = makeDependencyService(availability: { _ in throw WorkshopAPIError.requestFailed })

        dependencies.ensureDependencies(ofItemAt: wallpaper)
        try await sleepUntil("the dependency is installed", timeout: 10) { dependencies.states["2000000002"] == .installed }
    }

    /// Retry forgets the item and checks it again; an item back on Steam downloads.
    @MainActor
    func testRetryChecksAnUnavailableDependencyAgain() async throws {
        let wallpaper = try makeWallpaper("1000000001", in: storage.url, referencing: "2000000002")
        var removed = true
        let dependencies = makeDependencyService(availability: { _ in
            removed ? ["2000000002": .unavailable(.otherApp)] : ["2000000002": .available]
        })
        dependencies.ensureDependencies(ofItemAt: wallpaper)
        try await sleepUntil("the dependency is unavailable", timeout: 10) {
            dependencies.states["2000000002"] == .itemUnavailable(.otherApp)
        }

        removed = false
        dependencies.retry(["2000000002"], forItemAt: wallpaper)
        try await sleepUntil("the dependency is installed", timeout: 10) { dependencies.states["2000000002"] == .installed }
        XCTAssertNil(dependencies.unavailableReason(for: "2000000002"))
    }

    @MainActor
    func testRedownloadKeepsTheInstalledItemAndLeavesNoCopy() async throws {
        _ = await download("1000000001")
        let marker = storage.url.appending(path: "1000000001/settings-marker")
        try Data().write(to: marker)

        let destination = await download("1000000001")

        XCTAssertNotNil(destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try children(of: storage.url), ["1000000001"])
    }

    @MainActor
    func testFailedDownloadReportsSteamCmdAndCleansUp() async throws {
        let destination = await download("9999999999")

        XCTAssertNil(destination)
        guard case .failed(let message) = service.downloadProgress["9999999999"] else {
            return XCTFail("expected a failure, got \(String(describing: service.downloadProgress["9999999999"]))")
        }
        // steamcmd's `File Not Found` is shown as what it means.
        XCTAssertEqual(message, WorkshopItemAvailability.Reason.removedOrPrivate.message)
        XCTAssertEqual(try children(of: storage.url), [])
    }

    @MainActor
    func testChangedStorageTakesNewDownloads() async throws {
        let firstStorage = storage.url
        _ = await download("1000000001")
        let secondStorage = root.appending(path: "Storage B", directoryHint: .isDirectory)
        storage.url = secondStorage

        let destination = await download("3000000003")

        XCTAssertEqual(destination?.standardizedFileURL, secondStorage.appending(path: "3000000003").standardizedFileURL)
        XCTAssertEqual(try children(of: secondStorage), ["3000000003"])
        XCTAssertEqual(try children(of: firstStorage), ["1000000001"])
    }

    @MainActor
    func testStorageOnDisconnectedVolumeFailsWithoutFallback() async throws {
        let volume = URL(fileURLWithPath: "/Volumes/owe-missing-\(UUID().uuidString)", isDirectory: true)
        storage.url = volume.appending(path: "OpenWallpaperStorage", directoryHint: .isDirectory)

        let destination = await download("1000000001")

        XCTAssertNil(destination)
        guard case .failed(let message) = service.downloadProgress["1000000001"] else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.contains("isn't connected"), message)
        XCTAssertTrue(steamCmd.installDirectories.isEmpty, "steamcmd must not run without the storage folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.path))
    }

    // MARK: - Previews

    @MainActor
    func testKeptPreviewMovesIntoStorage() async throws {
        dependencyIndex.recordDependencyDownload("1000000001", copiedIntoLibrary: true)
        service.previewWorkshopItem(workshopId: "1000000001")
        try await sleepUntil("the preview is presented", timeout: 10) { !presented.isEmpty }
        let preview = try XCTUnwrap(presented.first)
        XCTAssertTrue(WorkshopItemInstaller.isPreview(preview.wallpaperDirectory, cacheRoot: previewCache))
        XCTAssertEqual(try children(of: storage.url), [WorkshopDependencyIndex.fileName], "a preview isn't in the library")

        let kept = try XCTUnwrap(try service.keepPreview(preview))

        XCTAssertEqual(kept.wallpaperDirectory.standardizedFileURL, storage.url.appending(path: "1000000001").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.wallpaperDirectory.appending(path: "project.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.wallpaperDirectory.path), "no copy stays in the cache")
        XCTAssertFalse(dependencyIndex.contains("1000000001"), "keeping it makes it the user's")
        XCTAssertTrue(downloadedIndex.contains("1000000001"))
        XCTAssertEqual(listed(in: storage.url), ["1000000001"])
    }

    @MainActor
    func testKeepPreviewIgnoresLibraryWallpapers() async throws {
        let downloaded = await download("1000000001")
        let destination = try XCTUnwrap(downloaded)
        let wallpaper = WEWallpaper(using: WEProject(file: "scene.json", preview: "", title: "", type: "scene"), where: destination)
        XCTAssertNil(try service.keepPreview(wallpaper))
    }

    // MARK: - Storage folder

    func testUnmountedVolumeIsDetected() {
        XCTAssertNotNil(WallpaperStorage.unmountedVolume(of: URL(fileURLWithPath: "/Volumes/owe-missing-\(UUID().uuidString)/Storage")))
        XCTAssertNil(WallpaperStorage.unmountedVolume(of: root))
    }

    func testMovedLibraryCarriesItsDependencyList() throws {
        let source = root.appending(path: "Old", directoryHint: .isDirectory)
        let destination = root.appending(path: "New", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        WorkshopDependencyIndex(libraryDirectory: { source }).recordDependencyDownload("2000000002", copiedIntoLibrary: true)
        WorkshopDependencyIndex(libraryDirectory: { source }).recordDependencyDownload("5000000005", copiedIntoLibrary: true)
        WorkshopDependencyIndex(libraryDirectory: { destination }).recordDependencyDownload("6000000006", copiedIntoLibrary: true)

        // 5000000005 was already in the new folder, so it kept its standing there.
        try WorkshopDependencyIndex.carry(from: source, to: destination, movedItems: ["2000000002", "1000000001"])

        XCTAssertEqual(WorkshopDependencyIndex(libraryDirectory: { destination }).ids, ["2000000002", "6000000006"])
    }

    func testMovedLibraryMovesItsDependencyList() throws {
        let source = root.appending(path: "Old", directoryHint: .isDirectory)
        let destination = root.appending(path: "New", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        WorkshopDependencyIndex(libraryDirectory: { source }).recordDependencyDownload("2000000002", copiedIntoLibrary: true)

        try WorkshopDependencyIndex.carry(from: source, to: destination, movedItems: ["2000000002"])

        XCTAssertEqual(WorkshopDependencyIndex(libraryDirectory: { destination }).ids, ["2000000002"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: WorkshopDependencyIndex.fileName).path))
    }
}

/// Stands in for steamcmd: a `workshop_download_item` of a known id writes the item (and a
/// manifest, like steamcmd) under the script's `force_install_dir`; an unknown id fails.
private final class FakeSteamCmd: SteamCmdRunning {
    private let lock = NSLock()
    private var recordedInstallDirectories: [String] = []

    var installDirectories: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInstallDirectories
    }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        var installDirectory: URL?
        var workshopId: String?
        for line in script.lines {
            // Every argument is quoted, so the odd pieces between quotes are the arguments.
            let pieces = line.components(separatedBy: "\"")
            let arguments = stride(from: 1, to: pieces.count, by: 2).map { pieces[$0] }
            if line.hasPrefix("force_install_dir") { installDirectory = arguments.first.map { URL(fileURLWithPath: $0) } }
            if line.hasPrefix("workshop_download_item") { workshopId = arguments.dropFirst().first }
        }
        guard let installDirectory, let workshopId else {
            return SteamCmdRun(output: "Logged in OK\n", exitCode: 0)
        }
        lock.lock()
        recordedInstallDirectories.append(installDirectory.path)
        lock.unlock()
        guard workshopId.hasPrefix("1") || workshopId.hasPrefix("2") || workshopId.hasPrefix("3") else {
            return SteamCmdRun(output: "ERROR! Download item \(workshopId) failed (File Not Found).\n", exitCode: 0)
        }
        let item = WorkshopItemInstaller.contentDirectory(inSteamCmdRoot: installDirectory, workshopId: workshopId)
        do {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            try Data(#"{"type": "scene", "title": "Item \#(workshopId)", "file": "scene.json", "preview": "preview.jpg"}"#.utf8)
                .write(to: item.appending(path: "project.json"))
            try Data("\"AppWorkshop\" {}".utf8)
                .write(to: installDirectory.appending(path: "steamapps/workshop/appworkshop_431960.acf"))
        } catch {
            return SteamCmdRun(output: "ERROR! \(error)\n", exitCode: 1)
        }
        onOutput("Downloading item \(workshopId) ...\n")
        return SteamCmdRun(output: "Success. Downloaded item \(workshopId) to \"\(item.path)\"\n", exitCode: 0)
    }
}
