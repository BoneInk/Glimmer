import ImageIO
import XCTest
import OWEEditor
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's Take Snapshot and Record GIF: drawn offscreen by the canvas's own
/// renderer, given to Save as New Wallpaper's copy, and written in place only into a wallpaper of
/// the user's own in the storage folder.
@MainActor
final class WallpaperEditorThumbnailTests: XCTestCase {
    private var fixture: MCPSceneFixture!
    private var wallpaper: WEWallpaper!
    private let storageKey = "CustomWallpapersDirectory"
    private var savedStorage: String?

    override func setUp() async throws {
        fixture = try MCPSceneFixture()
        wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: fixture.folder, hiding: []))
        savedStorage = UserDefaults.app.string(forKey: storageKey)
    }

    override func tearDown() async throws {
        UserDefaults.app.set(savedStorage, forKey: storageKey)
        if let wallpaper {
            let identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
            try? SceneEditOverlayFiles.draftStore.discard(for: identity.rawValue) // The isolated tests' draft, if any.
            WallpaperEditorDraft(wallpaper: wallpaper).endProperties()
        }
        fixture?.remove()
    }

    func testOnlyTheUsersOwnWallpaperInTheStorageFolderIsWrittenInPlace() throws {
        UserDefaults.app.set(fixture.root.path, forKey: storageKey)
        XCTAssertTrue(WallpaperEditorController.savesThumbnailInPlace(wallpaper))
        var official = wallpaper!
        official.project.official = true
        XCTAssertFalse(WallpaperEditorController.savesThumbnailInPlace(official), "one of Wallpaper Engine's own")
        UserDefaults.app.set(fixture.root.appending(path: "elsewhere").path, forKey: storageKey)
        XCTAssertFalse(WallpaperEditorController.savesThumbnailInPlace(wallpaper), "a read-only Library folder's")
    }

    func testSaveAsNewGivesTheCopyTheThumbnail() throws {
        let library = fixture.root.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        UserDefaults.app.set(library.path, forKey: storageKey)
        let gif = WallpaperThumbnail(kind: .gif, data: Data("GIF89a-thumbnail".utf8), side: 256)
        let copy = try LocalWallpaperSave.save(wallpaper, overlay: SceneEditOverlay(),
                                               assetsDirectory: fixture.root.appending(path: "assets"), title: "Copy", thumbnail: gif)
        XCTAssertEqual(try Data(contentsOf: copy.appending(path: "preview.gif")), gif.data)
        let project = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: copy.appending(path: "project.json"))) as? [String: Any])
        XCTAssertEqual(project["preview"] as? String, "preview.gif")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "preview.gif").path), "the original is untouched")
    }

    func testTakeSnapshotIsDrawnByTheCanvasRenderer() async throws {
        // The fixture's image layer is drawn by WE's own genericimage2 shader.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.appending(path: "shaders/genericimage2.vert").path),
                          "needs Wallpaper Engine's assets (OWE_ASSETS)")
        let editor = try WallpaperEditorController(wallpaper: wallpaper, host: WallpaperEditorAppDelegate.makeSceneHost(),
                                                   resumesDraft: false)
        editor.window.orderFront(nil)
        defer { editor.window.close() }
        // The canvas loads its scene; a snapshot then comes from its renderer.
        let deadline = Date().addingTimeInterval(60) // A cold runner translates the scene's shaders first.
        while editor.thumbnail.pending == nil, Date() < deadline {
            editor.thumbnail.problem = nil
            await editor.thumbnail.takeSnapshot()
            if editor.thumbnail.pending == nil { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        let pending = try XCTUnwrap(editor.thumbnail.pending, "the canvas drew no snapshot")
        XCTAssertEqual(pending.side, 1024, "the 1920×1080 scene's centre square at WE's snapshot size")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(pending.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 1024)
        XCTAssertFalse(editor.isEdited, "a thumbnail not yet used is no change")
        editor.thumbnail.use()
        XCTAssertFalse(editor.isEdited, "a wallpaper outside the storage folder: only Save as New writes it")
    }
}
