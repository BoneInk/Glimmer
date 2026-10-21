import XCTest
@testable import OpenWallpaperEngine

/// "Export More with These Settings…" as the Installed tab's export selection: entering it from
/// the Android Export mode, picking (click, ⌘, ⇧, Select All, wallpapers Android can't play), the
/// library's actions being off while it shows, and Export as .mpkg and Cancel ending it.
@MainActor
final class AndroidBatchPickerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "owe-android-selection-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    // MARK: Fixtures

    private func wallpaper(_ name: String, type: String = "scene", file: String = "scene.json") throws -> WEWallpaper {
        let folder = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = #"{"file": "\#(file)", "title": "\#(name)", "type": "\#(type)", "preview": "preview.gif"}"#
        try Data(project.utf8).write(to: folder.appending(path: "project.json"))
        try Data("GIF89a-preview".utf8).write(to: folder.appending(path: "preview.gif"))
        if type == "scene" {
            try Data(#"{"camera": {}, "general": {"orthogonalprojection": {"width": 1600, "height": 900}}, "objects": []}"#.utf8)
                .write(to: folder.appending(path: file))
        } else {
            try Data([0, 1, 2]).write(to: folder.appending(path: file))
        }
        return try XCTUnwrap(InstalledLibrary.wallpaper(at: folder, hiding: []))
    }

    /// The Android Export mode on `edited`, whose selection goes nowhere unless a test says so.
    private func model(_ edited: WEWallpaper) -> AndroidExportEditorModel {
        let session = IsolatedSceneEditSession(wallpaper: edited, purpose: "android-selection-test-\(UUID().uuidString)",
                                               seededFrom: [.shared], defaults: defaults)
        addTeardownBlock { @MainActor in session.end() }
        let model = AndroidExportEditorModel(session: session, sceneSize: SIMD2(1600, 900), defaults: defaults)
        model.beginsSelection = { _ in }
        model.endsSelection = { _ in }
        return model
    }

    private struct Library {
        var edited: WEWallpaper
        var scenes: [WEWallpaper]
        var video: WEWallpaper
        var web: WEWallpaper
        var all: [WEWallpaper] { [edited] + scenes + [video, web] }
    }

    private func library() throws -> Library {
        Library(edited: try wallpaper("Edited"), scenes: [try wallpaper("Bravo"), try wallpaper("Alpha"), try wallpaper("Charlie")],
                video: try wallpaper("Delta", type: "video", file: "clip.mp4"), web: try wallpaper("Echo", type: "web", file: "index.html"))
    }

    private func selection(_ library: Library, model: AndroidExportEditorModel? = nil,
                           exported: @escaping ([WEWallpaper]) -> Void = { _ in }) -> AndroidBatchPicker {
        AndroidBatchPicker(model: model ?? self.model(library.edited), library: { library.all }, export: exported)
    }

    private func titles(_ wallpapers: [WEWallpaper]) -> [String] { wallpapers.map(\.project.title) }

    // MARK: Entering

    func testExportMoreOpensTheSelectionOnceTheSettingsSheetHasClosed() throws {
        let model = model(try wallpaper("Edited"))
        var opened: [AndroidExportEditorModel] = []
        model.beginsSelection = { opened.append($0) }
        model.showSettings()
        model.chooseMoreAfterSheet()
        XCTAssertNil(model.sheet, "the Export Settings sheet closes first")
        XCTAssertTrue(opened.isEmpty, "one window-level change at a time: the selection waits for the sheet")
        model.sheetDidClose()
        XCTAssertTrue(opened.count == 1 && opened[0] === model)
        model.sheetDidClose()
        XCTAssertEqual(opened.count, 1, "a later sheet closing opens nothing")
    }

    func testEnteringShowsTheInstalledTabWithTheEditedWallpaperPickedAndTheLibraryActionsOff() throws {
        let library = try library()
        let content = ContentViewModel()
        content.navigation.topTabBarSelection = 3
        XCTAssertTrue(content.allowsLibraryActions)
        let selection = selection(library)
        content.showAndroidBatchPicker(selection)
        XCTAssertEqual(content.navigation.topTabBarSelection, 0, "the Installed tab")
        XCTAssertTrue(content.androidBatchPicker === selection)
        XCTAssertFalse(content.allowsLibraryActions, "context menus, Details, drags, imports and the other tabs are off")
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(selection.isSelected(library.edited), "the edited wallpaper starts picked")
        XCTAssertTrue(content.library.selectedWallpapers.isEmpty, "the library's own selection is untouched")
    }

    func testANewSelectionReplacesTheOldAndOnlyItsOwnEndClearsIt() throws {
        let library = try library()
        let content = ContentViewModel()
        let first = selection(library), second = selection(library)
        content.showAndroidBatchPicker(first)
        content.showAndroidBatchPicker(second)
        content.endAndroidBatchPicker(first)
        XCTAssertTrue(content.androidBatchPicker === second, "an older selection ending leaves the new one")
        content.endAndroidBatchPicker(for: first.model)
        XCTAssertTrue(content.androidBatchPicker === second, "another mode closing leaves it")
        content.endAndroidBatchPicker(for: second.model)
        XCTAssertNil(content.androidBatchPicker, "its mode closing ends it")
        XCTAssertTrue(content.allowsLibraryActions)
    }

    func testClosingTheModeEndsItsSelection() throws {
        let model = model(try wallpaper("Edited"))
        var ended: [AndroidExportEditorModel] = []
        model.endsSelection = { ended.append($0) }
        model.closeBatch()
        XCTAssertTrue(ended.count == 1 && ended[0] === model)
    }

    // MARK: Selecting

    func testClicksPickAsInTheGridAndKeepPicksFromOtherFolders() throws {
        let library = try library()
        let selection = selection(library)
        let shown = library.scenes + [library.video, library.web]
        selection.click(library.scenes[0], kind: .replace, in: shown)
        XCTAssertTrue(selection.isSelected(library.scenes[0]), "a click picks")
        XCTAssertTrue(selection.isSelected(library.edited), "picks the grid doesn't show stay picked")
        selection.click(library.scenes[0], kind: .toggle, in: shown)
        XCTAssertFalse(selection.isSelected(library.scenes[0]), "⌘-click unpicks")
        selection.click(library.scenes[0], kind: .toggle, in: shown)
        selection.click(library.video, kind: .extend, in: shown)
        XCTAssertEqual(Set(titles(library.all.filter(selection.isSelected))), ["Edited", "Bravo", "Alpha", "Charlie", "Delta"],
                       "⇧-click adds the run from the last click")
        selection.click(library.scenes[0], kind: .replace, in: shown)
        XCTAssertFalse(selection.isSelected(library.scenes[0]), "a click on a picked one unpicks it")
    }

    func testWallpapersAndroidCantPlayCantBePicked() throws {
        let library = try library()
        let selection = selection(library)
        XCTAssertEqual(selection.reason(for: library.web), String(localized: "Wallpaper type not supported on Android devices"))
        XCTAssertNil(selection.reason(for: library.video))
        XCTAssertNil(selection.reason(for: library.scenes[1]))
        selection.click(library.web, kind: .replace, in: library.all)
        selection.click(library.web, kind: .toggle, in: library.all)
        XCTAssertFalse(selection.isSelected(library.web))
        selection.click(library.edited, kind: .replace, in: library.all)
        selection.click(library.web, kind: .extend, in: library.all)
        XCTAssertFalse(selection.isSelected(library.web), "nor by a run")
        selection.selectAll(library.all)
        XCTAssertEqual(selection.count, 5, "Select All picks every one that can be exported")
        XCTAssertFalse(selection.isSelected(library.web))
    }

    // MARK: Export and Cancel

    func testExportHandsThePicksToTheBatchAndEnds() throws {
        let library = try library()
        var exported: [[WEWallpaper]] = []
        let selection = selection(library, exported: { exported.append($0) })
        var finished = 0
        selection.onFinish = { _ in finished += 1 }
        selection.selectAll(library.all)
        selection.export()
        XCTAssertEqual(exported.map(titles), [["Edited", "Alpha", "Bravo", "Charlie", "Delta"]],
                       "the edited wallpaper first, then the others by title")
        XCTAssertEqual(finished, 1)
    }

    func testExportWithNothingPickedDoesNothing() throws {
        let library = try library()
        var exported = 0
        let selection = selection(library, exported: { _ in exported += 1 })
        var finished = 0
        selection.onFinish = { _ in finished += 1 }
        selection.click(library.edited, kind: .toggle, in: library.all)
        XCTAssertEqual(selection.count, 0)
        selection.export()
        XCTAssertEqual(exported, 0)
        XCTAssertEqual(finished, 0, "the selection stays for a pick")
    }

    func testCancelEndsWithoutExporting() throws {
        let library = try library()
        var exported = 0
        let content = ContentViewModel()
        let selection = selection(library, exported: { _ in exported += 1 })
        selection.onFinish = { content.endAndroidBatchPicker($0) }
        content.showAndroidBatchPicker(selection)
        selection.selectAll(library.all)
        selection.cancel()
        XCTAssertEqual(exported, 0)
        XCTAssertNil(content.androidBatchPicker)
        XCTAssertTrue(content.allowsLibraryActions, "the library's actions are back")
    }

    func testTheSummaryNamesTheSettingsTheBatchUses() throws {
        let library = try library()
        let model = model(library.edited)
        model.chooseMode(.preRendered)
        model.options.frameRate = 24
        let selection = selection(library, model: model)
        XCTAssertTrue(selection.summary.contains(String(localized: "Pre-Rendered, \(24) FPS")))
        XCTAssertTrue(selection.summary.contains("Edited"))
    }
}
