import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

// Default deterministic mode controls only the visibility signal. Set
// GW_POSTER_NATIVE_VISIBILITY=1 to require native WindowServer occlusion state.
@MainActor final class VisibleProbeWindow: NSWindow {
    var reportVisible = true
    override var occlusionState: NSWindow.OcclusionState {
        guard reportVisible else { return [] }
        return ProcessInfo.processInfo.environment["GW_POSTER_NATIVE_VISIBILITY"] == "1" ? super.occlusionState : [.visible]
    }
}

@MainActor
final class WebPosterProbe: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var checks: [String] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); finish(nil) } catch { finish(error) }
        }
    }
    func check(_ condition: Bool, _ name: String) throws {
        if !condition { throw WebWallpaperFailure(message: name) }
        checks.append(name)
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebWallpaperFailure(message: "Wait timed out")
    }
    func color(_ image: CGImage) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.map(Int.init)
    }
    func writePoster(_ url: URL, red: CGFloat, green: CGFloat, blue: CGFloat) throws {
        let bitmap = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WebWallpaperFailure(message: "could not create poster destination")
        }
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WebWallpaperFailure(message: "could not write poster")
        }
    }
    func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let runtime = try WebWallpaperRuntime(projectURL: root.appendingPathComponent("project.json"),
                                               entryURL: root.appendingPathComponent("index.html"), propertiesJSON: Data("{}".utf8))
        defer { runtime.dispose() }
        var rejected = false
        do { _ = try await runtime.captureStaticPoster() } catch { rejected = true }
        try check(rejected && runtime.state == .idle, "not-ready host rejects snapshot without loading")
        let window = VisibleProbeWindow(contentRect: CGRect(x: 100, y: 100, width: 1280, height: 780),
                              styleMask: [.titled], backing: .buffered, defer: false)
        windows.append(window)
        window.contentView = runtime.webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.orderFrontRegardless()
        // Native mode intentionally accepts the real advisory state, including missing
        // .visible. The first static poster must still render for an ordered window.
        if ProcessInfo.processInfo.environment["GW_POSTER_NATIVE_VISIBILITY"] != "1" {
            window.reportVisible = false
        }
        try writePoster(root.appendingPathComponent("preview.png"), red: 0, green: 1, blue: 0)
        let screen = window.screen!
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        let displays = DisplayRegistry()
        displays.displays = [DisplayDescriptor(id: "active", displayID: number)]
        let playback = DesktopPlaybackController()
        let webItem = WallpaperItem(id: UUID(), fileURL: root.appendingPathComponent("project.json"))
        let session = DesktopPlaybackSession(item: webItem)
        session.webRuntime = runtime
        playback.sessions["active"] = session
        let model = WallpaperBackdropModel()
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        try await wait { model.image != nil }
        try check(color(model.image!)[1] > 235, "first preview poster renders without requiring visible occlusion bit")
        try writePoster(root.appendingPathComponent("preview.png"), red: 0, green: 0, blue: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 2)],
            ofItemAtPath: root.appendingPathComponent("preview.png").path)
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        for _ in 0..<100 where model.image.map({ self.color($0)[2] <= 235 }) != false {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(model.image.map { color($0)[2] > 235 } == true,
                  "editing the representative poster invalidates and reloads the backdrop source")
        runtime.load()
        try await wait { runtime.state == .ready }
        try await Task.sleep(for: .milliseconds(200))
        let first = try await runtime.captureStaticPoster()
        let red = color(first)
        try check(red[0] > 240 && red[1] < 15 && red[2] < 15, "real WebKit snapshot decodes painted red HTML")
        try check(max(first.width, first.height) <= 960, "snapshot output is bounded")
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        try await wait { model.image.map { self.color($0)[0] > 235 } == true }
        try check(color(model.image!)[0] > 235, "ready Web snapshot upgrades fallback without requiring visible occlusion bit")
        let cancelled = Task { try await runtime.captureStaticPoster() }
        await Task.yield()
        cancelled.cancel()
        do { _ = try await cancelled.value; throw WebWallpaperFailure(message: "cancelled snapshot accepted") }
        catch is CancellationError { try check(true, "cancelled WebKit request releases its waiter") }
        let frozen = model.image!
        _ = try await runtime.webView.evaluateJavaScript("document.body.style.background = 'rgb(0,0,255)'")
        runtime.setPaused(true)
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        runtime.setPaused(false)
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        try await Task.sleep(for: .milliseconds(250))
        try check(model.image === frozen && color(model.image!)[0] > 235, "pause/resume and changed DOM retain the successful static source")
        window.reportVisible = false
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        window.reportVisible = true
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        try check(model.image === frozen, "occlusion and visible re-entry preserve a captured poster")
        window.setContentSize(CGSize(width: 700, height: 500))
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        if window.occlusionState.contains(.visible) {
            try await wait { model.image !== frozen }
            try check(color(model.image!)[0] > 235, "resize re-renders cached red source without sampling changed blue DOM")
        } else {
            try await Task.sleep(for: .milliseconds(250))
            try check(model.image === frozen, "existing poster resize is deferred while native occlusion is absent")
        }
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: true)
        try check(model.image == nil, "opaque mode releases poster")
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        // Cancel a real in-flight WebKit result; it must not escape opaque mode.
        await Task.yield()
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: true)
        try await Task.sleep(for: .milliseconds(250))
        try check(model.image == nil, "opaque generation refuses late WebKit result")
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        // Switch away while that snapshot is pending. New source has no drawable fallback.
        await Task.yield()
        playback.sessions["active"] = DesktopPlaybackSession(item: WallpaperItem(id: UUID(), fileURL: root.appendingPathComponent("missing.mov")))
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        try await Task.sleep(for: .milliseconds(350))
        try check(model.image == nil, "source replacement refuses old Web result")
        model.stop(closing: true)
        try check(model.image == nil, "closing releases poster and pending work")
        playback.sessions["active"] = session
        model.configure(window: window, playback: playback, displays: displays, reduceTransparency: false)
        for _ in 0..<100 where model.image.map({ self.color($0)[2] <= 235 }) != false {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(model.image.map { color($0)[2] > 235 } == true,
                  "reopening a closed backdrop reloads its representative instead of staying blank")
        runtime.dispose()
        rejected = false
        do { _ = try await runtime.captureStaticPoster() } catch { rejected = true }
        try check(rejected && runtime.state == .disposed, "disposed host rejects snapshot")
    }
    func finish(_ error: Error?) {
        let object: [String: Any] = ["passed": error == nil, "checks": checks, "error": error?.localizedDescription ?? NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print(String(data: data, encoding: .utf8)!)
        exit(error == nil ? 0 : 1)
    }
}
@main enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = WebPosterProbe()
        app.delegate = delegate
        app.run()
    }
}
