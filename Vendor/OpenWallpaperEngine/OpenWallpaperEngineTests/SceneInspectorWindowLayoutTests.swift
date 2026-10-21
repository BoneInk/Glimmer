import OSLog
import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// Scene Edit / Export's object list keeps its width, also after it is hidden and shown, and
/// its rows give the object's name the room beside the visibility switch. The list once opened at
/// AppKit's default of about 140 points, its names cut to a single letter. Every mode shows the
/// same list; the Wallpaper mode is the one a test host opens (the others start the app's
/// isolated instances).
@MainActor
final class SceneInspectorWindowLayoutTests: XCTestCase {
    func testTheObjectListKeepsItsWidth() throws {
        try withEditor(mode: .wallpaper) { window in
            try assertObjectListLaidOut(in: window, "opened")

            // ⌃⌘S hides the list, and again shows it.
            for hides in [true, false] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control],
                                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                           characters: "s", charactersIgnoringModifiers: "s",
                                                           isARepeat: false, keyCode: 1))
                XCTAssertTrue(window.performKeyEquivalent(with: event))
                settle(window, seconds: 1)
                let pane = try XCTUnwrap(Self.sidebarPane(in: window.contentView))
                let item = ((pane.superview as? NSSplitView)?.delegate as? NSSplitViewController)?.splitViewItems.first
                XCTAssertEqual(item?.isCollapsed, hides)
            }
            try assertObjectListLaidOut(in: window, "shown again")
        }
    }

    /// The window lays out in a few passes. With the object list's search on the split view
    /// instead of its column, the search field's place and the columns' widths kept re-laying each
    /// other out: AppKit stopped the first layout after 300 passes and warned (`-layoutSubtreeIfNeeded
    /// … continued for 300 iterations`). It showed only for the first editor window of a process,
    /// so this test runs first in the class (every mode did it; it was seen in Android Export).
    func testTheFirstWindowLaysOutWithoutALayoutLoop() throws {
        let start = Date()
        try withEditor(mode: .androidExport, size: NSSize(width: 1120, height: 560)) { window in
            let host = try XCTUnwrap(window.contentView as? LayoutCountingHostingView<SceneInspectorView>)
            let passes = host.passesWhenOrderedFront
            XCTAssertLessThan(passes, 100, "the first layout took \(passes) passes")
            XCTAssertEqual(try Self.layoutLoopWarnings(since: start), [])

            // The search field stays at the top of the object list.
            let frameView = try XCTUnwrap(host.superview)
            let field = try XCTUnwrap(Self.views(in: frameView) { $0 is NSSearchField }.first as? NSSearchField, "no search field")
            let sidebar = try XCTUnwrap(Self.sidebarPane(in: host))
            let fieldFrame = field.convert(field.bounds, to: nil), sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
            XCTAssertTrue(sidebarFrame.minX - 1 <= fieldFrame.minX && fieldFrame.maxX <= sidebarFrame.maxX + 1,
                          "the search field \(fieldFrame) isn't over the object list \(sidebarFrame)")
        }
    }

    private static func layoutLoopWarnings(since date: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: date))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.apple.AppKit" && $0.composedMessage.contains("iterations") }
            .map(\.composedMessage)
    }

    private func assertObjectListLaidOut(in window: NSWindow, _ when: String,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let sidebar = try XCTUnwrap(Self.sidebarPane(in: window.contentView), "no split view", file: file, line: line)
        XCTAssertGreaterThanOrEqual(sidebar.frame.width, 240, "\(when): the object list is \(sidebar.frame.width) wide",
                                    file: file, line: line)
        // A row's name has the cell's width up to its switch, which keeps its own size at the end.
        let cells = Self.views(in: sidebar) { String(describing: type(of: $0)).hasPrefix("CellHostingView") }
        let switches = cells.compactMap { cell in
            Self.views(in: cell) { $0.accessibilityRole() == .button }.first.map { (cell, $0) }
        }
        XCTAssertFalse(switches.isEmpty, "\(when): no object rows", file: file, line: line)
        for (cell, toggle) in switches {
            let frame = toggle.convert(toggle.bounds, to: cell)
            XCTAssertGreaterThanOrEqual(frame.minX, 160, "\(when): a row's name has \(frame.minX) points",
                                        file: file, line: line)
            XCTAssertEqual(frame.maxX, cell.bounds.maxX, accuracy: 1, "\(when): the switch isn't at the row's end",
                           file: file, line: line)
            XCTAssertLessThan(frame.width, 80, "\(when): the switch is \(frame.width) wide", file: file, line: line)
        }
    }

    private func withEditor(mode: SceneInspectorMode, size: NSSize = NSSize(width: 1400, height: 820),
                            _ body: (NSWindow) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
         "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 1, "name": "stretched-1920-1080-background-layer", "image": "models/a.json", "origin": "960 540 0"},
                     {"id": 2, "name": "Clouds", "image": "models/b.json", "origin": "960 540 0"}]}
        """.utf8).write(to: folder.appending(path: "scene.json"))
        try Data(#"{"file": "scene.json", "title": "Layout", "type": "scene"}"#.utf8)
            .write(to: folder.appending(path: "project.json"))
        let wallpaper = WEWallpaper(using: WEProject(file: "scene.json", title: "Layout", type: "scene"), where: folder)

        // As `AppDelegate.showSceneInspector` makes it.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        let host = LayoutCountingHostingView(rootView: SceneInspectorView(wallpaper: wallpaper, initialMode: mode))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.orderFront(nil)
        host.passesWhenOrderedFront = host.layoutPasses
        defer {
            window.contentView = NSView()
            window.close()
        }
        settle(window, seconds: 0.5)
        try body(window)
    }

    private func settle(_ window: NSWindow, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// The outer split view's first pane: the object list.
    private static func sidebarPane(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 {
            return split.arrangedSubviews[0]
        }
        for subview in view.subviews {
            if let pane = sidebarPane(in: subview) { return pane }
        }
        return nil
    }

    private static func views(in view: NSView, where matches: (NSView) -> Bool) -> [NSView] {
        var found: [NSView] = matches(view) ? [view] : []
        for subview in view.subviews { found += views(in: subview, where: matches) }
        return found
    }
}

/// Counts its layout passes.
private final class LayoutCountingHostingView<Content: View>: NSHostingView<Content> {
    var layoutPasses = 0
    /// The passes counted while its window was ordered front.
    var passesWhenOrderedFront = 0

    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}

