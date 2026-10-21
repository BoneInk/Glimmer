import Photos
import XCTest
@testable import OpenWallpaperEngine

/// "Also Save to Photos Album": the album is found or created, the Live Photo goes in as a photo
/// and its paired video, access is asked for only when the toggle is turned on, and a failure is a
/// notice, never a failed export. A fake library stands in for Photos: nothing is written to the
/// real one.
final class LivePhotoAlbumSyncTests: XCTestCase {
    private final class FakeLibrary: LivePhotoLibrary {
        var status: PHAuthorizationStatus
        var answer: PHAuthorizationStatus
        var albums: [String: String] = [:]
        var saved: [LivePhotoAssetRequest] = []
        var requests = 0
        var failure: Error?

        init(status: PHAuthorizationStatus = .authorized, answer: PHAuthorizationStatus = .authorized) {
            self.status = status
            self.answer = answer
        }

        func authorizationStatus() -> PHAuthorizationStatus { status }

        func requestAuthorization() async -> PHAuthorizationStatus {
            requests += 1
            status = answer
            return answer
        }

        func albumIdentifier(named name: String) async throws -> String? { albums[name] }

        func save(_ request: LivePhotoAssetRequest) async throws {
            if let failure { throw failure }
            saved.append(request)
            if request.albumIdentifier == nil { albums[request.albumName] = "album-\(albums.count + 1)" }
        }
    }

    private struct Refused: LocalizedError {
        var errorDescription: String? { "refused" }
    }

    private let still = URL(filePath: "/tmp/clip.HEIC")
    private let movie = URL(filePath: "/tmp/clip.MOV")

    // MARK: Album and request

    func testRequestIsThePhotoAndItsPairedVideo() {
        let request = LivePhotoAlbumSync.request(still: still, movie: movie, albumName: "Walls", albumIdentifier: nil)
        XCTAssertEqual(request.resources.map(\.type), [.photo, .pairedVideo])
        XCTAssertEqual(request.resources.map(\.url), [still, movie])
        XCTAssertEqual(request.albumName, "Walls")
        XCTAssertNil(request.albumIdentifier)
    }

    func testMissingAlbumIsCreatedThenReused() async throws {
        let library = FakeLibrary()
        try await LivePhotoAlbumSync.save(still: still, movie: movie, albumName: "Walls", library: library)
        XCTAssertNil(library.saved.first?.albumIdentifier, "a missing album is created with the asset")
        XCTAssertEqual(library.albums["Walls"], "album-1")
        try await LivePhotoAlbumSync.save(still: still, movie: movie, albumName: "Walls", library: library)
        XCTAssertEqual(library.saved.last?.albumIdentifier, "album-1")
        XCTAssertEqual(library.albums.count, 1)
    }

    func testExistingAlbumIsUsed() async throws {
        let library = FakeLibrary()
        library.albums["Open Wallpaper Engine"] = "existing"
        let name = try await LivePhotoAlbumSync.save(still: still, movie: movie, albumName: "  ", library: library)
        XCTAssertEqual(name, LivePhotoAlbumSync.defaultAlbumName)
        XCTAssertEqual(library.saved.first?.albumIdentifier, "existing")
        XCTAssertEqual(library.saved.first?.albumName, "Open Wallpaper Engine")
    }

    func testOnlyFullAccessCounts() {
        XCTAssertTrue(LivePhotoAlbumSync.isAuthorized(.authorized))
        for status in [PHAuthorizationStatus.notDetermined, .denied, .restricted, .limited] {
            XCTAssertFalse(LivePhotoAlbumSync.isAuthorized(status))
        }
        XCTAssertEqual(LivePhotoAlbumSync.albumName(" Phone Walls \n"), "Phone Walls")
    }

    // MARK: The toggle

    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!

    override func setUpWithError() throws {
        suite = "owe-livephoto-photos-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"file": "scene.json", "title": "Photos", "type": "scene", "workshopid": "616161"}"#.utf8)
            .write(to: directory.appending(path: "project.json"))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    @MainActor
    private func model(_ library: FakeLibrary) throws -> (LivePhotoExportModel, IsolatedSceneEditSession) {
        let project = try decodeTolerant(WEProject.self, from: Data(#"{"file": "scene.json", "title": "Photos", "type": "scene", "workshopid": "616161"}"#.utf8))
        let session = IsolatedSceneEditSession(wallpaper: WEWallpaper(using: project, where: directory), purpose: "photos-test",
                                               seededFrom: [.shared], defaults: defaults)
        return (LivePhotoExportModel(session: session, sceneSize: SIMD2(1920, 1080), defaults: defaults, photos: library), session)
    }

    @MainActor
    func testToggleIsOffByDefaultAndRemembered() throws {
        let (model, session) = try model(FakeLibrary())
        defer { session.end() }
        XCTAssertFalse(model.savesToPhotos)
        XCTAssertEqual(model.photosAlbum, LivePhotoAlbumSync.defaultAlbumName)
        model.setSavesToPhotos(true)
        model.photosAlbum = "Walls"
        let (again, _) = try self.model(FakeLibrary())
        XCTAssertTrue(again.savesToPhotos)
        XCTAssertEqual(again.photosAlbum, "Walls")
    }

    @MainActor
    func testAccessIsAskedOnlyWhenTurnedOn() async throws {
        let library = FakeLibrary(status: .notDetermined, answer: .authorized)
        let (model, session) = try model(library)
        defer { session.end() }
        XCTAssertEqual(library.requests, 0)
        model.setSavesToPhotos(true)
        for _ in 0..<100 where !model.savesToPhotos { await Task.yield() }
        XCTAssertEqual(library.requests, 1)
        XCTAssertTrue(model.savesToPhotos)
        XCTAssertFalse(model.photosAccessDenied)
    }

    @MainActor
    func testRefusedAccessTurnsTheToggleBackOff() async throws {
        let asked = FakeLibrary(status: .notDetermined, answer: .denied)
        let (model, session) = try model(asked)
        defer { session.end() }
        model.setSavesToPhotos(true)
        for _ in 0..<100 where !model.photosAccessDenied { await Task.yield() }
        XCTAssertFalse(model.savesToPhotos)
        XCTAssertTrue(model.photosAccessDenied)

        let denied = FakeLibrary(status: .denied)
        let (other, otherSession) = try self.model(denied)
        defer { otherSession.end() }
        other.setSavesToPhotos(true)
        XCTAssertFalse(other.savesToPhotos)
        XCTAssertTrue(other.photosAccessDenied)
        XCTAssertEqual(denied.requests, 0, "a refusal isn't asked again; the panel points to Privacy Settings")
    }

    @MainActor
    func testFailedSaveIsANotice() async throws {
        let library = FakeLibrary()
        library.failure = Refused()
        let (model, session) = try model(library)
        defer { session.end() }
        let files = LivePhotoHelper.Files(directory: directory, still: still, movie: movie, identifier: "id")
        await model.saveToPhotos(files, album: "Walls")
        XCTAssertNotNil(model.photosNotice)
        XCTAssertNil(model.errorMessage)
        library.failure = nil
        await model.saveToPhotos(files, album: "Walls")
        XCTAssertEqual(library.saved.count, 1)
    }
}
