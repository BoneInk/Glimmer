#if GW_FULL_CANVAS_LAYOUT_TESTS
import AppKit
import Observation
import SwiftUI

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
// Same adapter as WorkshopGlassAppearance, without unrelated Steam account UI.
extension View {
    func workshopGlassSurface(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        GlassStyleReader { style in
            self.modifier(WorkspaceGlassSurface(reduceTransparency: style.reduceTransparency,
                cornerRadius: cornerRadius, tint: tint, interactive: interactive))
        }
    }
}
private struct CanvasRects: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, b in b }) }
}
private extension View {
    func measure(_ name: String) -> some View {
        background { GeometryReader { geometry in Color.clear.preference(key: CanvasRects.self, value: [name: geometry.frame(in: .named("canvas"))]) } }
    }
}
@MainActor @Observable private final class CanvasProbe {
    var rects: [String: CGRect] = [:]
    var scrollToEnd = false
    var backs = 0
}
private struct CanvasFixture: View {
    let probe: CanvasProbe
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.indigo, .blue, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: geometry.size.width, height: geometry.size.height).measure("media")
                HStack(alignment: .bottom, spacing: 16) {
                    WallpaperDetailFloatingPanel(maxHeight: min(320, geometry.size.height * 0.44)) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("整窗壁纸 · 固定画面中的浮动设置").font(.title3.weight(.semibold))
                            Text("1920 × 1080 · 演示素材").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("设为壁纸") {}.buttonStyle(.glassProminent)
                                Button("锁屏") {}.buttonStyle(.glass)
                                Spacer()
                            }
                            HStack {
                                Button {} label: { Image(systemName: "pause.fill") }.buttonStyle(.glass)
                                Button {} label: { Image(systemName: "speaker.slash.fill") }.buttonStyle(.glass)
                            }
                        }
                    }.frame(width: min(390, max(320, geometry.size.width * 0.34))).measure("actions")
                    ScrollViewReader { proxy in
                        WallpaperDetailFloatingPanel(maxHeight: min(320, geometry.size.height * 0.44)) {
                            VStack(alignment: .leading, spacing: 18) {
                                Text("播放与作者设置").font(.caption.weight(.semibold))
                                ForEach(0..<12) { index in
                                    HStack { Text("参数 \(index + 1)"); Slider(value: .constant(0.5)) }.id(index)
                                }
                                Button("最后一项设置") {}.buttonStyle(.glass).id("last").measure("last")
                            }
                        }
                        .measure("settings")
                        .onChange(of: probe.scrollToEnd) { _, value in if value { proxy.scrollTo("last", anchor: .bottom) } }
                    }
                }
                .frame(maxWidth: 1160).padding(.horizontal, 24).padding(.bottom, 24)
                WallpaperDetailBackButton { probe.backs += 1 }.measure("back")
                    .padding(.leading, 24).padding(.top, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .coordinateSpace(name: "canvas")
        .onPreferenceChange(CanvasRects.self) { probe.rects = $0 }
    }
}
@main @MainActor enum WallpaperFullCanvasLayoutTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = ProcessInfo.processInfo.environment["GW_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("GlimmerTests/full-canvas")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [CGSize(width: 1000, height: 640), CGSize(width: 1240, height: 800)] {
            let probe = CanvasProbe()
            let host = NSHostingView(rootView: CanvasFixture(probe: probe))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            let media = probe.rects["media"]!, back = probe.rects["back"]!, actions = probe.rects["actions"]!, settings = probe.rects["settings"]!
            precondition(media.origin == .zero && media.size == size, "media must cover the full window including the old sidebar")
            precondition(back.size == CGSize(width: 44, height: 44) && back.minX == 24 && back.minY == 20,
                         "back is a single circular control, without a horizontal toolbar")
            precondition(actions.maxY <= size.height - 23 && settings.maxY <= size.height - 23 && settings.height <= 320 && settings.minY > size.height * 0.5,
                         "glass settings must leave the majority of the media unobscured")
            probe.scrollToEnd = true
            try await Task.sleep(for: .milliseconds(200))
            let last = probe.rects["last"]!, viewport = probe.rects["settings"]!
            precondition(viewport.intersects(last) && last.maxY <= viewport.maxY + 2,
                         "long author settings remain directly reachable with internal scrolling")
            let screenshot = Process()
            screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            screenshot.arguments = ["-x", "-l", "\(window.windowNumber)", output.appendingPathComponent("window-\(Int(size.width))x\(Int(size.height)).png").path]
            try? screenshot.run(); screenshot.waitUntilExit()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("canvas-\(Int(size.width))x\(Int(size.height)).png"))
            print("PASS: full window \(size), circular back \(back), floating actions \(actions), settings \(settings); final setting reachable")
            window.orderOut(nil)
        }
        print("PASS: native full-canvas layout; production floating panel/back and real Liquid Glass, no desktop or lock screen actions")
    }
}
#endif
