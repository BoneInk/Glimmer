import XCTest
@testable import OpenWallpaperEngine

/// The fixture library holds a user scene (1000000001) that depends on a scene (3000000003), which
/// uses an effect from an asset item (2000000002, `"category": "Asset"`, no `type`), and an
/// unrelated user video (4000000004).
final class InstalledLibraryTests: XCTestCase {
    private let library = Fixtures.url("Library/installed")
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func temporaryLibrary() throws -> URL {
        let copy = try Fixtures.temporaryCopy(of: "Library/installed")
        temporaryDirectories.append(copy)
        return copy
    }

    private func listedIds(in directory: URL, hiding dependencies: Set<String>) -> Set<String> {
        Set(InstalledLibrary.wallpapers(in: directory, hiding: dependencies).map(\.wallpaperDirectory.lastPathComponent))
    }

    // MARK: - Listing

    func testAssetItemsAreNotListed() {
        XCTAssertEqual(listedIds(in: library, hiding: []), ["1000000001", "3000000003", "4000000004"])
    }

    func testDependencyOnlyItemsAreNotListed() {
        XCTAssertEqual(listedIds(in: library, hiding: ["3000000003", "2000000002"]), ["1000000001", "4000000004"])
    }

    func testWallpaperTypesFollowWE() {
        func classify(_ json: String) -> Bool? { InstalledLibrary.isWallpaperProject(Data(json.utf8)) }
        XCTAssertEqual(classify(#"{"type": "Scene"}"#), true)
        XCTAssertEqual(classify(#"{"type": "video"}"#), true)
        XCTAssertEqual(classify(#"{"type": "web"}"#), true)
        XCTAssertEqual(classify(#"{"type": "application"}"#), true)
        XCTAssertEqual(classify(#"{"type": "preset"}"#), false)
        XCTAssertEqual(classify(#"{"category": "Asset", "file": "assets.json"}"#), false)
        XCTAssertNil(classify("not json"))
    }

    func testFolderWithoutProjectStaysVisibleAsInvalid() throws {
        let directory = try temporaryLibrary()
        try FileManager.default.createDirectory(at: directory.appending(path: "Broken Import"), withIntermediateDirectories: true)
        let broken = InstalledLibrary.wallpapers(in: directory, hiding: []).first { $0.wallpaperDirectory.lastPathComponent == "Broken Import" }
        XCTAssertEqual(broken?.project, .invalid)
    }

    // MARK: - Dependency index

    func testIndexRecordsDependencyDownloadsAndPersists() throws {
        let directory = try temporaryLibrary()
        let index = WorkshopDependencyIndex(libraryDirectory: { directory })
        index.recordDependencyDownload("2000000002", copiedIntoLibrary: true)
        index.recordDependencyDownload("3000000003", copiedIntoLibrary: true)
        XCTAssertEqual(WorkshopDependencyIndex(libraryDirectory: { directory }).ids, ["2000000002", "3000000003"])
        XCTAssertEqual(listedIds(in: directory, hiding: index.ids), ["1000000001", "4000000004"])
    }

    func testUserDownloadWinsOverDependency() throws {
        let directory = try temporaryLibrary()
        let index = WorkshopDependencyIndex(libraryDirectory: { directory })
        index.recordDependencyDownload("3000000003", copiedIntoLibrary: true)
        index.recordUserDownload("3000000003")
        XCTAssertFalse(WorkshopDependencyIndex(libraryDirectory: { directory }).contains("3000000003"))
        XCTAssertTrue(listedIds(in: directory, hiding: index.ids).contains("3000000003"))
    }

    func testDependencyDownloadOfUserItemKeepsItListed() throws {
        let directory = try temporaryLibrary()
        let index = WorkshopDependencyIndex(libraryDirectory: { directory })
        // The user's own copy was already in the library, so steamcmd didn't copy anything.
        index.recordDependencyDownload("4000000004", copiedIntoLibrary: false)
        XCTAssertFalse(index.contains("4000000004"))
    }

    func testIndexFollowsTheLibraryDirectory() throws {
        let first = try temporaryLibrary()
        let second = try temporaryLibrary()
        var current = first
        let index = WorkshopDependencyIndex(libraryDirectory: { current })
        index.recordDependencyDownload("2000000002", copiedIntoLibrary: true)
        current = second
        XCTAssertTrue(index.ids.isEmpty)
        current = first
        XCTAssertEqual(index.ids, ["2000000002"])
    }

    // MARK: - Resolution

    func testHiddenDependenciesStillResolve() throws {
        XCTAssertEqual(WorkshopDependencyResolver.referencedWorkshopIds(inItemAt: library.appending(path: "1000000001")), ["3000000003"])
        XCTAssertEqual(WorkshopDependencyResolver.referencedWorkshopIds(inItemAt: library.appending(path: "3000000003")), ["2000000002"])
        let resolver = WorkshopAssetResolver(roots: [library])
        XCTAssertTrue(resolver.isInstalled("3000000003"))
        let effect = try XCTUnwrap(resolver.url(for: "effects/workshop/2000000002/glow/effect.json"))
        XCTAssertEqual(effect.standardizedFileURL, library.appending(path: "2000000002/effects/glow/effect.json").standardizedFileURL)
    }

    // MARK: - Cleanup

    func testDependenciesInUseAreKept() {
        XCTAssertTrue(WorkshopDependencyCleanup.orphanedDependencies(in: library, dependencyIds: ["2000000002", "3000000003"]).isEmpty)
    }

    func testDeletingTheLastUserRemovesItsDependencyChain() throws {
        let directory = try temporaryLibrary()
        let index = WorkshopDependencyIndex(libraryDirectory: { directory })
        index.recordDependencyDownload("2000000002", copiedIntoLibrary: true)
        index.recordDependencyDownload("3000000003", copiedIntoLibrary: true)
        try FileManager.default.removeItem(at: directory.appending(path: "1000000001"))

        XCTAssertEqual(WorkshopDependencyCleanup.removeOrphans(in: directory, index: index), ["2000000002", "3000000003"])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(remaining, ["4000000004"])
        XCTAssertTrue(index.ids.isEmpty)
    }

    func testUserItemsAreNeverCleanedUp() throws {
        let directory = try temporaryLibrary()
        let index = WorkshopDependencyIndex(libraryDirectory: { directory })
        index.recordDependencyDownload("3000000003", copiedIntoLibrary: true)
        try FileManager.default.removeItem(at: directory.appending(path: "1000000001"))

        // The asset item is unreferenced now too, but the user got it themselves.
        XCTAssertEqual(WorkshopDependencyCleanup.removeOrphans(in: directory, index: index), ["3000000003"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "2000000002").path))
    }
}
