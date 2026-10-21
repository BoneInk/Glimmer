#if GW_FULL_DETAILS_PREVIEW_PROBE
import AppKit
import AVKit
import SwiftUI

@MainActor final class FullDetailsProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { do { try await WallpaperFullDetailsPreviewProbe.run() } catch { print("FAILED: \(error)") }; NSApplication.shared.terminate(nil) }
    }
}
@main @MainActor enum WallpaperFullDetailsPreviewProbe {
    static func main() {
        let app = NSApplication.shared, delegate = FullDetailsProbeDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run(); withExtendedLifetime(delegate) {}
    }
    static func tick(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    static func players(_ view: NSView) -> [AVPlayerView] { (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap(players) }
    static func capture(_ window: NSWindow, to path: URL) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-l", "\(window.windowNumber)", path.path]; try p.run(); p.waitUntilExit()
    }
    static func temporalDifference(_ a: URL, _ b: URL) -> Double {
        let first = NSBitmapImageRep(data: try! Data(contentsOf: a))!, second = NSBitmapImageRep(data: try! Data(contentsOf: b))!
        var error = 0.0, count = 0
        // The upper wallpaper only: excludes floating settings, native titlebar,
        // shadow, return button and any transient/error text.
        for row in 0..<48 {
            for column in 0..<64 {
                let x = Int(Double(first.pixelsWide) * (0.12 + Double(column) / 64 * 0.76))
                let y = Int(Double(first.pixelsHigh) * (0.12 + Double(row) / 48 * 0.42))
                let a = first.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!, b = second.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                error += (abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)) * 255 / 3
                count += 1
            }
        }
        return error / Double(count)
    }
    static func run() async throws {
        precondition(CommandLine.arguments.count >= 4, "Usage: WallpaperFullDetailsPreviewProbe <output-dir> <library-json-path> <item-uuid> [more-item-uuids...]")
        let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("GW-full-detail-\(UUID())")
        let storage = AppStorage(root: fixtureRoot); try storage.prepareDirectories()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let library = try LibraryPersistence.load(from: URL(fileURLWithPath: CommandLine.arguments[2]))
        let requested = CommandLine.arguments.dropFirst(3).compactMap { UUID(uuidString: $0) }
        precondition(requested.count == CommandLine.arguments.count - 3, "Each item ID must be a UUID")
        let selected = library.items.filter { requested.contains($0.id) }
        precondition(Set(selected.map(\.id)) == Set(requested), "Each requested item must exist in the selected library")
        let store = VideoLibraryStore(storage: storage)
        for item in selected { store.add(item) }
        let registry = DisplayRegistry(snapshot: [])
        let playback = DesktopPlaybackController(store: store, displayRegistry: registry, storage: storage, previewOnly: true, writesToLibrary: false)
        defer { playback.tearDownAll() }
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 1200, height: 760), styleMask: [.titled,.closable,.fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        let host = NSHostingView(rootView: AnyView(Color.black)); window.contentView = host; window.orderFrontRegardless()
        var records: [[String: String]] = []
        for (runIndex, item) in (selected + selected).enumerated() {
            let prefix = "\(runIndex)-" + (item.isWebWallpaper ? "web" : "video")
            let presentation = WorkspaceWallpaperDetails()
            let selection = WallpaperDetailsSelection(itemID: item.id)
            host.rootView = AnyView(GeometryReader { geometry in
                WorkspaceWallpaperDetailsHost(presentation: presentation) {
                    HStack(spacing: 20) {
                        Color.blue.frame(width: 180)
                        WallpaperCardView(item: item, isSelected: false, isMissing: false,
                            style: .init(reduceTransparency: false, reduceMotion: false), onToggleFavorite: {}, onSelect: {}, onApply: {},
                            onOpenDetails: { presentation.open(item) }).frame(width: 280).padding(.top, 270)
                        Spacer()
                    }.padding(.top, geometry.safeAreaInsets.top)
                } detail: { _ in
                    WallpaperDetailsWindowContent(store: store, selection: selection, displays: registry, playback: playback,
                        onClose: { presentation.dismiss() }, immersive: true)
                }.ignoresSafeArea(.container)
            })
            window.orderFrontRegardless(); await tick(0.5)
            presentation.open(item)
            for index in 0...12 {
                await tick(0.5)
                var record = ["item": item.title, "t": "\(Double(index + 1) * 0.5)", "cover": "\(presentation.coverImage != nil)",
                    "coverVisible": "\(presentation.destinationCoverVisible)", "liveOpacity": "\(presentation.livePreviewOpacity)",
                    "snapshotFinished": "\(presentation.snapshotPreparationFinished)", "snapshot": "\(presentation.destinationSnapshot != nil)",
                    "occlusion": "\(window.occlusionState.rawValue)"]
                if let player = players(host).first {
                    record["playerTime"] = "\(player.player?.currentTime().seconds ?? -1)"; record["playerRate"] = "\(player.player?.rate ?? -1)"
                    record["playerReady"] = "\(player.isReadyForDisplay)"; record["playerBounds"] = "\(player.bounds)"
                    var chain: [String] = []; var view: NSView? = player
                    while let node = view { chain.append("\(type(of: node)) alpha=\(node.alphaValue) hidden=\(node.isHidden)"); view=node.superview }
                    record["chain"] = chain.joined(separator: "\n")
                }
                let web = AuthorPropertyServices.shared.readyHosts(itemID: item.id)
                record["webReadyHosts"] = "\(web.count)"
                if let runtime = web.first { record["webState"] = runtime.state.rawValue; record["webBounds"] = "\(runtime.webView.bounds)" }
                records.append(record); print(record)
                if index == 5 { try capture(window, to: output.appendingPathComponent(prefix + "-3s.png")) }
            }
            try capture(window, to: output.appendingPathComponent(prefix + "-6s.png"))
            let difference = temporalDifference(output.appendingPathComponent(prefix + "-3s.png"), output.appendingPathComponent(prefix + "-6s.png"))
            print("VISIBLE MEDIA DIFFERENCE", prefix, difference)
            precondition(difference > (item.isWebWallpaper ? 0.025 : 0.15), "the actual screen media region must change, not merely a hidden player's time")
            precondition(presentation.livePreviewOpacity == 1, "full detail must finish its handoff")
            if let player = players(host).first { precondition(player.player!.rate == 1 && player.player!.currentTime().seconds > 5, "actual full-detail video must advance at normal rate") }
            presentation.dismiss(); await tick(1)
            precondition(presentation.route == nil, "full-detail return must complete before reopening")
            host.rootView = AnyView(Color.black); await tick(0.2)
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("measurements.json"))
        window.orderOut(nil)
        precondition(playback.activeDisplayCount == 0 && store.assignments.isEmpty, "probe cannot assign a desktop")
    }
}
#endif
