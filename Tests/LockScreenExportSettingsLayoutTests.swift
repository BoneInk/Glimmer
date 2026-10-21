import AppKit
import SwiftUI

@main @MainActor
enum LockScreenExportSettingsLayoutTests {
    struct Failure: Error { let message: String }
    static func main() async throws {
        _ = NSApplication.shared
        let coordinator = GWSettingsCoordinator(persistenceEnabled: false)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GW_LOCK_EXPORT_UI_EVIDENCE"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("GW-Lock-Export-UI").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for sync in [true, false] {
            coordinator.updatePreferences {
                $0.lockScreenExport = .init(syncWallpaperSettings: sync, resolution: .uhd2160, framesPerSecond: 60)
            }
            let view = LockScreenExportSettingsSection(coordinator: coordinator)
                .padding(20).frame(width: 700).environment(\.colorScheme, .dark)
                .environment(\.windowGlassReduceTransparencyOverride, true)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            guard size.height > 200, size.height < 720 else { throw Failure(message: "unexpected settings layout size \(size)") }
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw Failure(message: "could not capture settings")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw Failure(message: "could not encode settings capture")
            }
            try png.write(to: output.appendingPathComponent(sync ? "settings-sync.png" : "settings-manual.png"))
            window.contentView = nil
            print("PASS actual settings section renders \(sync ? "synchronized" : "manual") controls at 700pt (height \(size.height))")
        }
    }
}
