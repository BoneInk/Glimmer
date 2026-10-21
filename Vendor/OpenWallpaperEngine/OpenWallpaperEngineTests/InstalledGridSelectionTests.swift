import AppKit
import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// The Installed grid's Select All and the image a drag of its wallpapers shows, over a library of
/// its own.
@MainActor
final class InstalledGridSelectionTests: XCTestCase {
    private let storageKey = "CustomWallpapersDirectory"
    private var savedStorage: String?
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        savedStorage = UserDefaults.app.string(forKey: storageKey)
        root = FileManager.default.temporaryDirectory.appending(path: "owe-grid-\(UUID().uuidString)", directoryHint: .isDirectory)
        for name in ["a", "b", "c"] {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = #"{"file": "clip.mp4", "title": "\#(name.uppercased())", "type": "video"}"#
            try Data(project.utf8).write(to: folder.appending(path: "project.json"))
        }
        UserDefaults.app.set(root.path, forKey: storageKey)
        suite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        UserDefaults.app.set(savedStorage, forKey: storageKey)
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func library() -> InstalledLibraryModel {
        let filters = FilterResultsViewModel()
        filters.reset()
        return InstalledLibraryModel(filters: filters, steamCmd: SteamCmdService(), presentation: ContentPresentation(),
                                     folders: InstalledFolderStore(defaults: defaults))
    }

    private func titles(_ library: InstalledLibraryModel) -> [String] {
        library.selectedWallpaperItems().map(\.project.title).sorted()
    }

    /// As Finder's Select All: what the folder shown lists, not what is filed elsewhere.
    func testSelectAllSelectsTheFolderShown() throws {
        let library = library()
        XCTAssertEqual(library.allWallpapers.count, 3)
        XCTAssertEqual(library.displayedWallpapers.count, 3, "no filter hides them")
        let c = try XCTUnwrap(library.allWallpapers.first { $0.project.title == "C" })
        let folder = try XCTUnwrap(library.createFolder(moving: [c]))

        library.selectAll()
        XCTAssertEqual(titles(library), ["A", "B"], "the top level")
        library.open(folder: folder)
        XCTAssertTrue(library.selectedWallpapers.isEmpty, "opening a folder clears it")
        library.selectAll()
        XCTAssertEqual(titles(library), ["C"])
    }

    /// Edit › Select All reaches the main window's controller through the responder chain past
    /// the grid's views, while a text field, first in the chain, keeps ⌘A for its text.
    func testSelectAllGoesThroughTheResponderChain() {
        let action = #selector(NSText.selectAll(_:))
        XCTAssertTrue(MainWindowController.instancesRespond(to: action))
        let window = MainWindowController.makeWindow()
        defer { window.close() }
        let host = NSHostingView(rootView: ScrollView { LazyVGrid(columns: [GridItem()]) { Color.red.frame(height: 50) } })
        window.contentView = host
        var responder: NSResponder? = host
        while let current = responder, current !== window {
            XCTAssertFalse(current.responds(to: action), "\(type(of: current)) would take Select All")
            responder = current.nextResponder
        }
        XCTAssertTrue(NSTextView.instancesRespond(to: action), "a field editor takes it first")
    }

    /// Several wallpapers drag as a stack of up to three of their tiles, the dragged one in
    /// front, with how many there are.
    func testDragImageStacksTheSelection() throws {
        let library = library()
        let wallpapers = library.displayedWallpapers
        XCTAssertEqual(wallpapers.count, 3)
        for wallpaper in wallpapers { library.toggleSelection(for: wallpaper) }

        let preview = InstalledDragPreview(library: library, wallpaper: wallpapers[1], size: 100)
        XCTAssertEqual(preview.count, 3)
        XCTAssertEqual(preview.pictures.count, 3)
        XCTAssertEqual(preview.pictures.first, wallpapers[1].previewURL ?? AppBundleLayout.wallpaperNotFoundURL,
                       "the dragged tile in front")
        library.clearSelection()
        XCTAssertEqual(InstalledDragPreview(library: library, wallpaper: wallpapers[1], size: 100).count, 1, "a tile alone")

        let five = InstalledDragPreview(pictures: Array(repeating: AppBundleLayout.wallpaperNotFoundURL, count: 5), count: 5, size: 100)
        let renderer = ImageRenderer(content: five)
        let image = try XCTUnwrap(renderer.cgImage)
        // Three tiles offset by 7 points each, and 8 points round them.
        XCTAssertEqual(Double(image.width) / renderer.scale, 100 + 14 + 16, accuracy: 1)
    }
}
