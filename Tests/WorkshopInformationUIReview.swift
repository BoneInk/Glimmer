import AppKit
import SwiftUI
import Darwin

@main @MainActor
enum WorkshopInformationUIReview {
    static var window: NSWindow?
    static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlimmerInformationReview-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("GW_UI_REVIEW_ROOT", root.path, 1)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: .init(x: 120, y: 100, width: 760, height: 740),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Glimmer · 壁纸信息验证"
        let sheet = WallpaperInformationSheet(itemID: "3313102203", onOpenWork: { work in
            print("OPEN_WORK \(work.id) \(work.declaredKind.rawValue)"); fflush(stdout)
        })
        window.contentView = NSHostingView(rootView: sheet.environment(\.colorScheme, .dark))
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("UI_REVIEW_ROOT \(root.path)"); fflush(stdout)
        NSApp.run()
        try? FileManager.default.removeItem(at: root)
    }
}
