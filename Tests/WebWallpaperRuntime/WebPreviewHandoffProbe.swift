#if GW_WEB_PREVIEW_HANDOFF_PROBE
import AppKit
import AVFoundation
import Observation
import SwiftUI
import WebKit

struct AppStorage { let root: URL }
struct WallpaperItem {
    let id = UUID()
    let fileURL: URL
    var workshopID: String? = nil
    var fileExists: Bool { true }; var isSceneWallpaper: Bool { false }; var isWebWallpaper: Bool { true }
    var isProjectWallpaper: Bool { true }; var isFavorite: Bool { false }; var isVideoWallpaper: Bool { false }
    var displayTitle: String { "失意狐狸--正太" }; var title: String { displayTitle }
    var fileSizeText: String { "Web" }; var resolutionText: String { "" }; var durationText: String { "" }
    var filePath: String { fileURL.path }; var originalURL: URL? { nil }; var originalExists: Bool { false }
}
struct WorkshopSearchResult: Identifiable { let id: String }
@MainActor @Observable final class AuthorPropertyServices {
    static let shared = AuthorPropertyServices()
    var revisions: [UUID: Int] = [:]
    var runtimes: [UUID: WebWallpaperRuntime] = [:]
    static func configuration(item: WallpaperItem, storage: AppStorage) async throws -> (payload: Data, manifest: WebWallpaperResourceManifest) {
        (Data("{}".utf8), .init(itemID: item.id, rootURL: storage.root, assets: [], directories: []))
    }
    func register(_ runtime: WebWallpaperRuntime, itemID: UUID, onConfigurationChange: (@MainActor () -> Void)? = nil) -> UUID {
        runtimes[itemID] = runtime; return UUID()
    }
    func unregister(itemID: UUID, token: UUID) { runtimes[itemID] = nil }
    func readySceneHosts(itemID: UUID) -> [String] { [] }
}
@MainActor enum ThumbnailCache {
    static let shared = ThumbnailProvider()
    static var image: NSImage!
}
@MainActor final class ThumbnailProvider { func thumbnail(for item: WallpaperItem) async -> NSImage? { ThumbnailCache.image } }
enum SceneWallpaperPresentation { static func badge(for value: String?) -> String { "Scene" } }
private struct TransparencyOverride: EnvironmentKey { static let defaultValue = false }
private struct MotionOverride: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var windowGlassReduceTransparencyOverride: Bool {
        get { self[TransparencyOverride.self] }
        set { self[TransparencyOverride.self] = newValue }
    }
    var windowGlassReduceMotionOverride: Bool {
        get { self[MotionOverride.self] }
        set { self[MotionOverride.self] = newValue }
    }
}
@MainActor @Observable final class HandoffState {
    var ready = false
    var failures: [String] = []
}
@MainActor final class HandoffProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await WebPreviewHandoffProbe.run() }
            catch { print("PROBE FAILED: \(error)") }
            NSApplication.shared.terminate(nil)
        }
    }
}
@main @MainActor enum WebPreviewHandoffProbe {
    static func main() {
        let application = NSApplication.shared
        let delegate = HandoffProbeDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
    static func tick(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    static func js(_ runtime: WebWallpaperRuntime, _ source: String) async -> String {
        do {
            let value = try await runtime.webView.evaluateJavaScript(source)
            return String(describing: value)
        } catch { return "ERROR: \(error)" }
    }
    static func run() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gw-web-preview-\(UUID())")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
                let width = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 1000
        let height = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4])! : 640
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: AnyView(Color.black))
        window.contentView = hosting; window.orderFrontRegardless()
        let poster = NSImage(contentsOf: project.deletingLastPathComponent().appendingPathComponent("preview.jpg"))!
        ThumbnailCache.image = poster
        var observations: [[String: String]] = []
        for mode in ["transition", "transition-reopen"] {
            window.orderFrontRegardless()
            let state = HandoffState()
            let item = WallpaperItem(fileURL: project)
            let presentation = WorkspaceWallpaperDetails()
            if mode == "under-browser" {
                hosting.rootView = AnyView(ZStack {
                    WebWallpaperPreviewView(item: item, isPaused: false, storage: .init(root: temp), onReady: { state.ready = true }).opacity(0.001)
                    Color.white
                    Image(nsImage: poster).resizable().scaledToFill().frame(width: 300,height: 200).clipped()
                })
            } else if mode == "runtime-direct" {
                let descriptor = try WebWallpaperProjectDescriptor(projectURL: project)
                let runtime = try WebWallpaperRuntime(projectURL: descriptor.projectURL, entryURL: descriptor.entryURL, propertiesJSON: Data("{}".utf8))
                runtime.webView.frame = hosting.bounds
                window.contentView = runtime.webView
                AuthorPropertyServices.shared.runtimes[item.id] = runtime
                runtime.load()
            } else if mode == "direct" {
                window.contentView = hosting
                hosting.rootView = AnyView(WebWallpaperPreviewView(item: item, isPaused: false, storage: .init(root: temp),
                    onReady: { state.ready = true }, onFailure: { state.failures.append($0) }))
            } else {
                hosting.rootView = AnyView(WorkspaceWallpaperDetailsHost(presentation: presentation) {
                    HStack(spacing: 20) {
                        Color.blue.frame(width: 180)
                        WallpaperCardView(item: item, isSelected: false, isMissing: false,
                            style: .init(reduceTransparency: false, reduceMotion: false), onToggleFavorite: {}, onSelect: {}, onApply: {},
                            onOpenDetails: { presentation.open(item) }).frame(width: 280).padding(.top, 270)
                        Spacer()
                    }
                } detail: { route in
                    WebWallpaperPreviewView(item: item,
                        isPaused: presentation.coverImage != nil && presentation.livePreviewOpacity == 0,
                        storage: .init(root: temp), onReady: { state.ready = true },
                        onFailure: { state.failures.append($0); presentation.acceptSnapshot(nil, routeID: route.id) },
                        onTransitionSnapshot: { image in presentation.acceptSnapshot(image, routeID: route.id) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .wallpaperCoverDestination(ready: state.ready, cornerRadius: 0, requiresSnapshot: true)
                }.frame(maxWidth: .infinity, maxHeight: .infinity))
                await tick(0.3)
                let recorder = Process(); recorder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                recorder.arguments = ["-x", "-v", "-V", "4", "-l", "\(window.windowNumber)", output.appendingPathComponent(mode + ".mov").path]
                try recorder.run(); await tick(0.5)
                presentation.open(item)
                await tick(1.4)
                if let target = presentation.destinationSnapshot {
                    let match = WallpaperCoverSnapshotAlignment.match(source: poster, target: target, in: CGRect(origin: .zero, size: window.contentLayoutRect.size))
                    print("alignment", String(describing: match))
                    let bitmap = NSBitmapImageRep(data: target.tiffRepresentation!)!
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(mode + "-target.png"))
                }
                presentation.dismiss()
                let closeDeadline = ContinuousClock.now + .seconds(2)
                while presentation.route != nil, ContinuousClock.now < closeDeadline { await tick(0.02) }
                print("closed", presentation.route == nil, "occlusion", window.occlusionState.rawValue)
                precondition(presentation.route == nil, "native Web return must finish before reopening")
                while recorder.isRunning { await tick(0.1) }
                let asset = AVURLAsset(url: output.appendingPathComponent(mode + ".mov"))
                let generator = AVAssetImageGenerator(asset: asset)
                generator.requestedTimeToleranceAfter = .zero; generator.requestedTimeToleranceBefore = .zero
                for index in 0..<40 {
                    if let (image, _) = try? await generator.image(at: CMTime(value: Int64(index), timescale: 10)) {
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(String(format: "%@-frame-%03d.png",mode,index)))
                    }
                }
            }
            await tick(2)
            var record = ["mode": mode, "ready": "\(state.ready)", "failures": state.failures.joined(separator: " | "),
                          "liveOpacity": "\(presentation.livePreviewOpacity)", "coverVisible": "\(presentation.destinationCoverVisible)"]
            if let runtime = AuthorPropertyServices.shared.runtimes[item.id] {
                record["state"] = runtime.state.rawValue; record["frame"] = "\(runtime.webView.frame)"; record["bounds"] = "\(runtime.webView.bounds)"
                record["windowAttached"] = "\(runtime.webView.window != nil)"
                record["occlusion"] = "\(window.occlusionState.rawValue)"
                record["DOM"] = await js(runtime, "JSON.stringify({width:innerWidth,height:innerHeight,visibility:document.visibilityState,lastFrame:typeof loop==='undefined'?null:loop.last,canvas:[...document.querySelectorAll('canvas')].map(c=>({id:c.id,w:c.width,h:c.height})),gl:typeof gl==='undefined'?'undefined':!!gl,lost:typeof gl==='undefined'||!gl?null:gl.isContextLost(),image:typeof imgW==='undefined'?null:[imgW,imgH]})")
                var view: NSView? = runtime.webView
                var chain: [String] = []
                while let node = view { chain.append("\(type(of: node)) frame=\(node.frame) alpha=\(node.alphaValue) hidden=\(node.isHidden)"); view = node.superview }
                record["viewChain"] = chain.joined(separator: "\n")
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", "\(window.windowNumber)", output.appendingPathComponent(mode + "-window.png").path]
                try capture.run(); capture.waitUntilExit()
                let snapshot = try await runtime.webView.takeSnapshot(configuration: nil)
                let bitmap = NSBitmapImageRep(data: snapshot.tiffRepresentation!)!
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(mode + "-wk.png"))
            } else { record["runtime"] = "MISSING" }
            observations.append(record)
            print(record)
            hosting.rootView = AnyView(Color.black)
            if mode == "under-browser" {
                hosting.rootView = AnyView(ZStack {
                    WebWallpaperPreviewView(item: item, isPaused: false, storage: .init(root: temp), onReady: { state.ready = true }).opacity(0.001)
                    Color.white
                    Image(nsImage: poster).resizable().scaledToFill().frame(width: 300,height: 200).clipped()
                })
            } else if mode == "runtime-direct" {
                AuthorPropertyServices.shared.runtimes[item.id]?.dispose()
                AuthorPropertyServices.shared.runtimes[item.id] = nil
                window.contentView = hosting
            }
            await tick(0.2)
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("probe.json"))
        window.orderOut(nil)
    }
}
#endif
