import AppKit
import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// Drags in the Installed tab through AppKit: a press on a tile never moves the main window, and
/// drops reach the folder tiles' and breadcrumbs' handlers by way of SwiftUI's dragging
/// destinations, with a pasteboard as a real drag has, while Finder's files still go to the grid.
@MainActor
final class InstalledFolderDragDropTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        UserDefaults.app.removeObject(forKey: InstalledFolderStore.storageKey)
    }

    /// AppKit moves a window that moves by its background from a mouse-down on any view that
    /// allows it (SwiftUI's hosting view and non-opaque views do), before the tile sees a drag.
    func testPressingATileNeverMovesTheMainWindow() throws {
        let model = ContentViewModel()
        let folder = try XCTUnwrap(model.library.createFolder(named: "Games"))
        let window = MainWindowController.makeWindow()
        XCTAssertFalse(window.isMovableByWindowBackground, "the title bar and toolbar move it")
        host(HStack(spacing: 0) {
            InstalledFolderTile(viewModel: model, folder: try! XCTUnwrap(model.library.folders.tree.folder(folder)))
                .frame(width: 100, height: 100)
            GifImage(contentsOf: AppBundleLayout.wallpaperNotFoundURL).resizable().frame(width: 100, height: 100)
        }, in: window)
        let preview = try XCTUnwrap(window.contentView?.hitTest(NSPoint(x: 150, y: 50)))
        XCTAssertTrue(preview is PreviewImageView)
        XCTAssertFalse(preview.mouseDownCanMoveWindow, "a preview's press is its tile's in any window")
    }

    func testDropsOnFolderTilesMoveWallpapersAndFolders() throws {
        let model = ContentViewModel()
        let library = model.library
        let a = try XCTUnwrap(library.createFolder(named: "A"))
        let b = try XCTUnwrap(library.createFolder(named: "B"))
        let window = offscreenWindow()
        host(HStack(spacing: 0) {
            InstalledFolderTile(viewModel: model, folder: try! XCTUnwrap(library.folders.tree.folder(a))).frame(width: 100, height: 100)
            InstalledFolderTile(viewModel: model, folder: try! XCTUnwrap(library.folders.tree.folder(b))).frame(width: 100, height: 100)
            Color.clear.frame(width: 200, height: 100)
        }
        .onDrop(of: [.fileURL], delegate: LibraryDropImport(presentation: model.presentation)), in: window)
        let onA = NSPoint(x: 50, y: 50), onB = NSPoint(x: 150, y: 50), onGrid = NSPoint(x: 300, y: 50)

        XCTAssertTrue(drop(InstalledDragPayload.wallpapers(["workshop-1", "workshop-2"]).text, at: onA, in: window))
        XCTAssertEqual(library.folders.tree.folder(a)?.items, ["workshop-1", "workshop-2"], "a selection moves together")

        XCTAssertTrue(drop(InstalledDragPayload.folder(b).text, at: onA, in: window))
        XCTAssertEqual(library.folders.tree.path(to: b).map(\.title), ["A", "B"], "nested")

        // SwiftUI loads a drop's items after AppKit's performDragOperation returns, so it takes
        // every drop; the folder stays where it was.
        drop(InstalledDragPayload.folder(a).text, at: onA, in: window)
        drop(InstalledDragPayload.folder(a).text, at: onB, in: window)
        XCTAssertEqual(library.folders.tree.folders.map(\.title), ["A"], "never into itself or its subfolder")
        XCTAssertEqual(library.folders.tree.path(to: b).map(\.title), ["A", "B"])

        XCTAssertEqual(entered(InstalledDragPayload.wallpapers(["workshop-3"]).text, at: onGrid, in: window), [],
                       "the grid takes only files")
        let file = NSPasteboard(name: .init("owe-tests-\(UUID().uuidString)"))
        file.clearContents()
        file.writeObjects([URL(fileURLWithPath: "/tmp/wallpaper.mp4") as NSURL])
        XCTAssertEqual(entered(file, at: onGrid, in: window), .copy, "Finder's files still import on the grid")
    }

    func testDropsOnBreadcrumbsMoveUp() throws {
        let model = ContentViewModel()
        let library = model.library
        let a = try XCTUnwrap(library.createFolder(named: "A"))
        library.open(folder: a)
        let b = try XCTUnwrap(library.createFolder(named: "B"))
        library.open(folder: b)
        library.folders.update { $0.move(items: ["workshop-1"], to: b) }
        let window = offscreenWindow()
        host(InstalledFolderBreadcrumbs(viewModel: model), in: window)
        // Installed, A, B from the left; the last step is the folder shown.
        let steps = destinations(in: try XCTUnwrap(window.contentView)).map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
        XCTAssertGreaterThanOrEqual(steps.count, 2)

        XCTAssertTrue(drop(InstalledDragPayload.wallpapers(["workshop-1"]).text, at: NSPoint(x: steps[1].midX, y: steps[1].midY), in: window))
        XCTAssertEqual(library.folders.tree.folder(a)?.items, ["workshop-1"], "a parent")
        XCTAssertTrue(drop(InstalledDragPayload.wallpapers(["workshop-1"]).text, at: NSPoint(x: steps[0].midX, y: steps[0].midY), in: window))
        XCTAssertTrue(library.folders.tree.filedKeys.isEmpty, "Installed, the top level")
        XCTAssertTrue(drop(InstalledDragPayload.folder(b).text, at: NSPoint(x: steps[0].midX, y: steps[0].midY), in: window))
        XCTAssertEqual(library.folders.tree.folders.map(\.title).sorted(), ["A", "B"])
    }

    // MARK: Helpers

    private func offscreenWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 100), styleMask: .borderless,
                 backing: .buffered, defer: false)
    }

    private func host<V: View>(_ view: V, in window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 400, height: 100), display: false)
        window.contentView = NSHostingView(rootView: view.frame(width: 400, height: 100, alignment: .leading))
        window.orderBack(nil)
        windows.append(window)
        run(0.3)
    }

    private func run(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The views AppKit offers a drag to: SwiftUI's dragging destinations, outermost first.
    private func destinations(in view: NSView) -> [NSView] {
        (view.registeredDraggedTypes.isEmpty ? [] : [view]) + view.subviews.flatMap(destinations(in:))
    }

    /// The innermost destination under `point`, as AppKit picks it.
    private func destination(at point: NSPoint, in window: NSWindow) throws -> NSDraggingDestination {
        let view = destinations(in: try XCTUnwrap(window.contentView)).last { $0.convert($0.bounds, to: nil).contains(point) }
        return try XCTUnwrap(view as? NSDraggingDestination, "no drop target at \(point)")
    }

    private func pasteboard(_ text: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("owe-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard
    }

    private func entered(_ text: String, at point: NSPoint, in window: NSWindow) -> NSDragOperation {
        entered(pasteboard(text), at: point, in: window)
    }

    private func entered(_ pasteboard: NSPasteboard, at point: NSPoint, in window: NSWindow) -> NSDragOperation {
        guard let target = try? destination(at: point, in: window) else { return [] }
        let info = DraggingInfo(pasteboard: pasteboard, location: point, window: window)
        _ = target.draggingEntered?(info)
        let operation = target.draggingUpdated?(info) ?? []
        target.draggingExited?(info)
        return operation
    }

    /// Enters, hovers and drops `text` at `point`, as AppKit does; whether the drop was taken.
    @discardableResult
    private func drop(_ text: String, at point: NSPoint, in window: NSWindow) -> Bool {
        guard let target = try? destination(at: point, in: window) else { return false }
        let info = DraggingInfo(pasteboard: pasteboard(text), location: point, window: window)
        _ = target.draggingEntered?(info)
        run(0.1)
        let operation = target.draggingUpdated?(info) ?? []
        guard !operation.isEmpty, target.prepareForDragOperation?(info) ?? true else {
            target.draggingExited?(info)
            return false
        }
        let performed = target.performDragOperation?(info) ?? false
        target.concludeDragOperation?(info)
        run(0.3)
        return performed
    }
}

/// What AppKit hands a dragging destination: the drag's pasteboard and where it is.
private final class DraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    weak var draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .every
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { draggingDestinationWindow?.contentView }
    let draggingSequenceNumber = Int.random(in: 1...Int(Int32.max))
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
