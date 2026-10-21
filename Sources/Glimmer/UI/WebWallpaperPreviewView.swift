import AppKit
import SwiftUI
import WebKit
import Observation

/// A separate WebKit context for previews. Never changes desktop assignments.
struct WebWallpaperPreviewView: View {
    let item: WallpaperItem
    let isPaused: Bool
    let storage: AppStorage
    var wallpaperFPS = 30
    var onReady: (() -> Void)? = nil
    var onFailure: ((String) -> Void)? = nil
    var onTransitionSnapshot: ((NSImage?) -> Void)? = nil
    @GlassState private var model = WebWallpaperPreviewModel()
    private var revision: Int { AuthorPropertyServices.shared.revisions[item.id, default: 0] }

    var body: some View {
        ZStack {
            Color.black
            if let runtime = model.runtime {
                WebWallpaperHostView(runtime: runtime).id(ObjectIdentifier(runtime))
            } else if model.error == nil { ProgressView() }
            if onTransitionSnapshot == nil, let error = model.error ?? model.runtime?.lastError {
                VStack(spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.white)
                    Button("重新加载") { model.dispose(); Task { await model.update(item: item, paused: isPaused, storage: storage, wallpaperFPS: wallpaperFPS) } }
                        .buttonStyle(.glass)
                }.padding(12)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: "\(item.id):\(revision)") { await model.update(item: item, paused: isPaused, storage: storage, wallpaperFPS: wallpaperFPS) }
        .task(id: model.runtime.map(ObjectIdentifier.init)) {
            guard let onTransitionSnapshot, let runtime = model.runtime else { return }
            let image = await model.transitionSnapshot(runtime)
            guard !Task.isCancelled, model.runtime === runtime else { return }
            onTransitionSnapshot(image)
        }
        .onChange(of: isPaused) { _, value in model.setPaused(value) }
        .onChange(of: wallpaperFPS) { _, value in model.setWallpaperFPS(value) }
        .onChange(of: model.runtime?.state, initial: true) { _, state in
            if (state == .ready || state == .paused), model.error == nil, model.runtime?.lastError == nil { onReady?() }
            else if state == .failed { onFailure?(model.error ?? model.runtime?.lastError ?? "Web 预览无法加载") }
        }
        .onChange(of: model.error ?? model.runtime?.lastError, initial: true) { _, error in
            if let error { onFailure?(error) }
        }
        .onDisappear { model.dispose() }
    }
}

private struct WebWallpaperHostView: NSViewRepresentable {
    let runtime: WebWallpaperRuntime
    func makeNSView(context: Context) -> WKWebView { runtime.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor @Observable
private final class WebWallpaperPreviewModel {
    var runtime: WebWallpaperRuntime?
    var error: String?
    private var itemID: UUID?
    private var generation = 0
    private var desiredPaused = false
    private var desiredWallpaperFPS = 30
    private var hostToken: UUID?

    func update(item: WallpaperItem, paused: Bool, storage: AppStorage, wallpaperFPS: Int = 30) async {
        if itemID != item.id { dispose(); itemID = item.id }
        desiredPaused = paused
        desiredWallpaperFPS = min(max(wallpaperFPS, 1), 240)
        generation += 1
        let ticket = generation
        do {
            let config = try await AuthorPropertyServices.configuration(item: item, storage: storage)
            try Task.checkCancellation()
            guard generation == ticket else { return }
            if itemID == item.id, let runtime {
                try runtime.configureResourceManifest(config.manifest)
                try runtime.applyPropertiesJSON(config.payload)
                try runtime.setFrameRateLimit(desiredWallpaperFPS)
                runtime.setPaused(desiredPaused)
                error = nil
                return
            }
            let project = try WebWallpaperProjectDescriptor(projectURL: item.fileURL)
            let runtime = try WebWallpaperRuntime(projectURL: project.projectURL, entryURL: project.entryURL, propertiesJSON: Data("{}".utf8))
            try runtime.setFrameRateLimit(desiredWallpaperFPS)
            try runtime.configureResourceManifest(config.manifest)
            try runtime.applyPropertiesJSON(config.payload)
            self.runtime = runtime
            hostToken = AuthorPropertyServices.shared.register(runtime, itemID: item.id, onConfigurationChange: { [weak self] in self?.generation += 1 })
            itemID = item.id
            runtime.setPaused(desiredPaused)
            runtime.load()
            error = nil
        } catch is CancellationError { }
        catch { if generation == ticket { self.error = error.localizedDescription } }
    }

    func transitionSnapshot(_ expected: WebWallpaperRuntime) async -> NSImage? {
        // A snapshot callback can itself stall; race the whole operation, not
        // merely the gaps between attempts. captureStaticPoster releases its
        // continuation immediately on cancellation and ignores late callbacks.
        let cg = await withTaskGroup(of: CGImage?.self) { group in
            group.addTask { await self.sampleTransitionSnapshot(expected) }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        guard !Task.isCancelled, runtime === expected, let cg else { return nil }
        return NSImage(cgImage: cg, size: expected.webView.bounds.size)
    }
    private func sampleTransitionSnapshot(_ expected: WebWallpaperRuntime) async -> CGImage? {
        while !Task.isCancelled, runtime === expected {
            if expected.state == .failed || expected.state == .disposed { return nil }
            if expected.state == .ready || expected.state == .paused,
               expected.webView.bounds.width > 0, expected.webView.bounds.height > 0,
               let cg = try? await expected.captureStaticPoster(), Self.hasVisibleContent(cg) { return cg }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        return nil
    }
    private static func hasVisibleContent(_ image: CGImage) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let visible = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            var low = 255, high = 0
            for index in stride(from: 0, to: 32 * 32 * 4, by: 4) {
                let luminance = (Int(buffer[index]) + Int(buffer[index + 1]) + Int(buffer[index + 2])) / 3
                low = min(low, luminance); high = max(high, luminance)
            }
            return high - low > 18
        }
        return visible
    }

    func setPaused(_ value: Bool) { desiredPaused = value; runtime?.setPaused(value) }
    func setWallpaperFPS(_ value: Int) {
        desiredWallpaperFPS = min(max(value, 1), 240)
        try? runtime?.setFrameRateLimit(desiredWallpaperFPS)
    }
    func dispose() {
        generation += 1
        if let itemID, let hostToken { AuthorPropertyServices.shared.unregister(itemID: itemID, token: hostToken) }
        hostToken = nil
        runtime?.dispose(); runtime = nil; itemID = nil; error = nil
    }
}
