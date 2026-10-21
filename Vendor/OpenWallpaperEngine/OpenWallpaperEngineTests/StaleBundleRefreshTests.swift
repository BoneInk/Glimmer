import XCTest
@testable import OpenWallpaperEngine

/// Bundles made by an older converter get their package back from the Workshop when it was
/// deleted, one at a time, and whatever can't be updated is listed once.
@MainActor
final class StaleBundleRefreshTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "owe-stale-bundles-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func package(_ files: [(String, Data)]) -> Data {
        func u32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        let magic = Data("PKGV0001".utf8)
        var header = u32(magic.count) + magic + u32(files.count)
        var body = Data()
        for (path, contents) in files {
            let name = Data(path.utf8)
            header += u32(name.count) + name + u32(body.count) + u32(contents.count)
            body += contents
        }
        return header + body
    }

    /// A converted bundle at `name`, made by `version`, optionally with its archived package.
    @discardableResult
    private func bundle(_ name: String, version: Int, archived: Bool, title: String? = nil, workshopid: String? = nil,
                        dependencyEntries: [String]? = ["materials/workshop/2000000002/a.tex"]) throws -> URL {
        let directory = root.appending(path: name)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = workshopid.map { #","workshopid":"\#($0)""# } ?? ""
        try Data(#"{"file":"scene.json","title":"\#(title ?? name)","type":"scene"\#(id)}"#.utf8)
            .write(to: directory.appending(path: "project.json"))
        try Data("{}".utf8).write(to: directory.appending(path: "scene.json"))
        if archived {
            let source = directory.appending(path: WallpaperPackageConverter.sourceFolderName)
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try package([("scene.json", Data(#"{"objects":[]}"#.utf8))]).write(to: source.appending(path: "scene.pkg"))
        }
        let manifest = WallpaperPackageConverter.Manifest(
            converterVersion: version, sourcePackage: "scene.pkg", sourceHash: "", sourceRetained: archived,
            extractedFiles: ["scene.json"], warnings: [], convertedAt: Date(), verifiedAt: nil,
            verifiedObjectCount: nil, dependencyEntries: dependencyEntries)
        try JSONEncoder().encode(manifest).write(to: WallpaperPackageConverter.manifestURL(in: directory))
        return directory
    }

    private var old: Int { WallpaperPackageConverter.converterVersion - 1 }

    // MARK: - Detection

    func testStaleWithoutSourceIsQueued() throws {
        let directory = try bundle("1000000001", version: old, archived: false)
        let found = StaleBundleScanner.scan(storage: root)
        XCTAssertEqual(found.map(\.directory.lastPathComponent), ["1000000001"])
        XCTAssertEqual(found.first?.workshopId, "1000000001")
        XCTAssertEqual(found.first?.packageName, "scene.pkg")
        XCTAssertEqual(found.first?.directory.standardizedFileURL, directory.standardizedFileURL)
    }

    func testStaleWithSourceIsReconvertedLocally() throws {
        let directory = try bundle("1000000002", version: old, archived: true)
        XCTAssertEqual(StaleBundleScanner.scan(storage: root), [])
        XCTAssertNotNil(WallpaperPackageConverter.convertIfNeeded(wallpaperDirectory: directory))
        XCTAssertEqual(WallpaperPackageConverter.manifest(in: directory)?.converterVersion,
                       WallpaperPackageConverter.converterVersion)
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "scene.json"), encoding: .utf8), #"{"objects":[]}"#)
    }

    func testCurrentBundleIsLeftAlone() throws {
        try bundle("1000000003", version: WallpaperPackageConverter.converterVersion, archived: false)
        XCTAssertEqual(StaleBundleScanner.scan(storage: root), [])
    }

    func testUnaffectedBundleIsStampedCurrentAndNotQueued() throws {
        let directory = try bundle("1000000004", version: old, archived: false, dependencyEntries: [])
        XCTAssertEqual(StaleBundleScanner.scan(storage: root), [])
        XCTAssertEqual(WallpaperPackageConverter.manifest(in: directory)?.converterVersion,
                       WallpaperPackageConverter.converterVersion)
    }

    private func reference(_ path: String, in directory: URL) throws {
        let materials = directory.appending(path: "materials")
        try fm.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data(#"{"passes":[{"textures":["\#(path)"]}]}"#.utf8).write(to: materials.appending(path: "m.json"))
    }

    func testResolvedReferencesAreStamped() throws {
        let directory = try bundle("1000000005", version: old, archived: false, dependencyEntries: nil)
        try reference("workshop/2000000002/a", in: directory)
        let linked = root.appending(path: "dep/a.tex")
        try fm.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: linked)
        try fm.createDirectory(at: directory.appending(path: "materials/workshop"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: directory.appending(path: "materials/workshop/2000000002"),
                                  withDestinationURL: linked.deletingLastPathComponent())
        XCTAssertEqual(StaleBundleScanner.scan(storage: root), [])
        XCTAssertEqual(WallpaperPackageConverter.manifest(in: directory)?.converterVersion,
                       WallpaperPackageConverter.converterVersion)
    }

    func testUnresolvedReferenceIsQueued() throws {
        let directory = try bundle("1000000006", version: old, archived: false, dependencyEntries: nil)
        try reference(#"workshop\\2000000002\\missing"#, in: directory)
        XCTAssertEqual(StaleBundleScanner.scan(storage: root).map(\.directory.lastPathComponent), ["1000000006"])
        XCTAssertEqual(WallpaperPackageConverter.manifest(in: directory)?.converterVersion, old)
    }

    func testEmptyRecordedFieldSkipsTheScan() throws {
        let directory = try bundle("1000000007", version: old, archived: false, dependencyEntries: [])
        try reference("workshop/2000000002/missing", in: directory)
        XCTAssertEqual(StaleBundleScanner.scan(storage: root), [])
    }

    func testFolderNameWinsOverProjectWorkshopId() throws {
        try bundle("1000000003", version: old, archived: false, workshopid: "")
        try bundle("1000000004", version: old, archived: false, workshopid: "1000000099")
        XCTAssertEqual(StaleBundleScanner.scan(storage: root).map(\.workshopId), ["1000000003", "1000000004"])
    }

    func testProjectWorkshopIdNamesARenamedFolder() throws {
        try bundle("Renamed", version: old, archived: false, workshopid: "1000000005")
        XCTAssertEqual(StaleBundleScanner.scan(storage: root).first?.workshopId, "1000000005")
    }

    func testLocalImportHasNoWorkshopId() throws {
        try bundle("My Import", version: old, archived: false)
        XCTAssertNil(StaleBundleScanner.scan(storage: root).first?.workshopId)
    }

    // MARK: - Queue

    private final class FakeDownloader: StaleBundleDownloading {
        var signedIn = true
        var failing: Set<String> = []
        var fetched: [String] = []
        var pending: [(Bool) -> Void] = []

        func restoreSession(completion: @escaping (Bool) -> Void) { completion(signedIn) }

        func fetchArchivedPackage(workshopId: String, packageName: String, into wallpaperDirectory: URL,
                                  completion: @escaping (Bool) -> Void) {
            fetched.append(workshopId)
            let ok = !failing.contains(workshopId)
            pending.append { _ in completion(ok) }
        }

        /// Finishes the one download in flight.
        func finishNext() { pending.removeFirst()(true) }
    }

    private func item(_ id: String?, _ title: String) -> StaleBundle {
        StaleBundle(directory: root.appending(path: id ?? title), workshopId: id, packageName: "scene.pkg", title: title)
    }

    func testDownloadsOneAtATimeInOrderThenNotifiesFailures() {
        let downloader = FakeDownloader()
        downloader.failing = ["2"]
        var converted: [String] = []
        var notices: [[String]] = []
        let refresher = StaleBundleRefresher(downloader: downloader, isShown: { _ in false },
                                             reconvert: { converted.append($0.lastPathComponent) },
                                             notify: { notices.append($0) })
        var finished = false
        refresher.run([item("1", "A"), item("2", "B"), item(nil, "Local"), item("3", "C")]) { finished = true }

        XCTAssertEqual(downloader.fetched, ["1"])
        downloader.finishNext()
        XCTAssertEqual(downloader.fetched, ["1", "2"])
        downloader.finishNext()
        downloader.finishNext()
        XCTAssertEqual(downloader.fetched, ["1", "2", "3"])
        XCTAssertEqual(converted, ["1", "3"])
        XCTAssertTrue(finished)
        XCTAssertEqual(notices, [["Local", "B"]])
    }

    func testNoSessionKeepsBundlesAndNotifiesOnce() {
        let downloader = FakeDownloader()
        downloader.signedIn = false
        var converted: [URL] = []
        var notices: [[String]] = []
        let refresher = StaleBundleRefresher(downloader: downloader, isShown: { _ in false },
                                             reconvert: { converted.append($0) }, notify: { notices.append($0) })
        refresher.run([item("1", "A"), item("2", "B")])
        XCTAssertEqual(downloader.fetched, [])
        XCTAssertEqual(converted, [])
        XCTAssertEqual(notices, [["A", "B"]])
    }

    func testShownWallpaperWaitsUntilItIsNoLongerShown() {
        let downloader = FakeDownloader()
        var shown = true
        var converted: [String] = []
        let refresher = StaleBundleRefresher(downloader: downloader, isShown: { _ in shown },
                                             reconvert: { converted.append($0.lastPathComponent) }, notify: { _ in })
        refresher.run([item("1", "A")])
        downloader.finishNext()
        XCTAssertEqual(converted, [])
        refresher.shownWallpapersChanged()
        XCTAssertEqual(converted, [])
        shown = false
        refresher.shownWallpapersChanged()
        XCTAssertEqual(converted, ["1"])
    }
}
