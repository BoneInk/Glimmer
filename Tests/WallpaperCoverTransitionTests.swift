// Run this fixture with GW_COVER_TRANSITION_TESTS and the production
// WorkspaceWallpaperDetails.swift / GlassState.swift. Providers below are static
// substitutes; all presentation, geometry, lifecycle and rendering code is real.
#if GW_COVER_TRANSITION_TESTS
import AppKit
import Observation
import SwiftUI

struct WallpaperItem { let id = UUID(); var workshopID: String? }
struct WorkshopSearchResult: Identifiable { let id: String }
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    func thumbnail(for item: WallpaperItem) -> NSImage? { nil }
}
struct WorkshopCoverImage: View { let result: WorkshopSearchResult; var body: some View { Color.red } }
struct WorkshopRemoteImage: View { let url: URL; var body: some View { Color.red } }
private struct MotionOverride: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var windowGlassReduceMotionOverride: Bool {
        get { self[MotionOverride.self] }
        set { self[MotionOverride.self] = newValue }
    }
}
@MainActor @Observable private final class FixtureContext {
    var searches = "保留搜索"; var filter = "收藏"; var appearances = 0
    var detailAppearances = 0
}
private struct BrowsingFixture: View {
    let context: FixtureContext
    let key: String
    let image: NSImage
    @State private var localCounter = 0
    @State private var scrollPosition = ScrollPosition(y: 150)
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            Text(context.searches + context.filter + "\(localCounter)")
            Color.clear.frame(height: 240)
            Image(nsImage: image).resizable().frame(width: 180, height: 110)
                .wallpaperCoverSource(key, image: image)
            Color.clear.frame(height: 800)
        }
        .padding(20)
        }
        .scrollPosition($scrollPosition)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
        .onAppear { context.appearances += 1; localCounter += 1 }
    }
}
@main @MainActor enum WallpaperCoverTransitionTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), "FAIL: \(message)")
        print("PASS: \(message)")
    }
    static func tick(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
    static func redBounds(_ view: NSView) -> CGRect? {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/gw-transition-fixture.png"))
        var minX = bitmap.pixelsWide; var minY = bitmap.pixelsHigh; var maxX = -1; var maxY = -1
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent < 0.4 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 2) / scale, height: CGFloat(maxY - minY + 2) / scale)
    }
    static func main() async {
        let a = CGRect(x: 20, y: 280, width: 180, height: 110)
        let b = CGRect(x: 20, y: 60, width: 580, height: 326)
        check(WallpaperCoverTransitionGeometry.frame(source: a, destination: b, progress: 0, reduceMotion: false) == a, "open starts at actual card rectangle")
        check(WallpaperCoverTransitionGeometry.frame(source: a, destination: b, progress: 1, reduceMotion: false) == b, "open ends at actual preview rectangle")
        check(WallpaperCoverTransitionGeometry.frame(source: a, destination: b, progress: 0.5, reduceMotion: false) == CGRect(x: 20, y: 170, width: 380, height: 218), "cover travels and expands independently from the page")
        check(WallpaperCoverTransitionGeometry.frame(source: a, destination: b, progress: 0, reduceMotion: true) == b, "Reduce Motion has no geometry movement")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for reduced in [false, true] {
            let presentation = WorkspaceWallpaperDetails()
            let item = WallpaperItem(workshopID: "42")
            presentation.prepareSource("workshop:42:saved")
            presentation.open(item)
            check(presentation.route?.key == "workshop:42:saved", "duplicate Workshop shelf uses the clicked origin")
            let stale = presentation.route!.id
            presentation.dismiss(); presentation.open(item); presentation.finishDismissal(stale)
            check(presentation.route != nil && !presentation.closing, "stale close cannot dismiss a newer selection")
            presentation.acceptSnapshot(NSImage(size: CGSize(width: 10, height: 10)), routeID: stale)
            check(!presentation.snapshotPreparationFinished && presentation.destinationSnapshot == nil,
                  "late snapshot from an older route cannot complete or overwrite a reopened detail")
            let currentRoute = presentation.route!.id
            presentation.acceptSnapshot(nil, routeID: currentRoute)
            check(presentation.snapshotPreparationFinished, "a failed snapshot releases bounded preparation to the cover and available actions")
            presentation.acceptSnapshot(NSImage(size: CGSize(width: 10, height: 10)), routeID: currentRoute)
            check(presentation.destinationSnapshot == nil, "a late snapshot cannot replace the frozen outcome after preparation finishes")
            presentation.dismiss(); presentation.finishDismissal(presentation.route!.id)
            let context = FixtureContext()
            let image = NSImage(size: NSSize(width: 180, height: 110))
            image.lockFocus(); NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 180, height: 110).fill()
            image.unlockFocus()
            let host = NSHostingView(rootView:
                GeometryReader { windowContent in
                    WorkspaceWallpaperDetailsHost(presentation: presentation) {
                        HStack(spacing: 0) {
                            Color.blue.frame(width: 160)
                            BrowsingFixture(context: context, key: "workshop:42", image: image)
                        }
                        .padding(.top, windowContent.safeAreaInsets.top)
                        .padding(.bottom, windowContent.safeAreaInsets.bottom)
                    } detail: { _ in
                        Color.red.wallpaperCoverDestination(cornerRadius: 0, requiresSnapshot: reduced)
                            .onAppear { context.detailAppearances += 1 }
                    }
                    .ignoresSafeArea(.container)
                }.environment(\.windowGlassReduceMotionOverride, reduced))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 560),
                styleMask: reduced ? [.borderless] : [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentView = host; window.orderFrontRegardless(); await tick(0.4)
            let initial = redBounds(host)!
            check(abs(initial.width - 180) < 4 && initial.minX >= 160, "rendered source occupies only its card in the right pane")
            presentation.open(item)
            if !reduced {
                await tick(0.12)
                if let travelling = redBounds(host) {
                    check(travelling.width > initial.width + 10 && travelling.width < 800,
                          "native intermediate frame expands the cover between source and destination")
                } else { preconditionFailure("transition cover disappeared during movement") }
            }
            await tick(0.7)
            let expanded = redBounds(host)!
            check(expanded.width > 790 && expanded.height > host.bounds.height - 3 && expanded.minX < 3 && expanded.minY < 3, "native rendered cover fills the whole window and covers the sidebar")
            check(context.appearances == 1 && context.detailAppearances == 1, "opening retains browsing tree and mounts one detail")
            presentation.dismiss(); await tick(1.0)
            let returned = redBounds(host)!
            check(presentation.route == nil && abs(returned.minY - initial.minY) < 3 && abs(returned.width - initial.width) < 3, "return restores exact card position")
            check(context.appearances == 1 && context.searches == "保留搜索" && context.filter == "收藏", "return retains local state, search and filter")
            window.orderOut(nil)
            print("Native lifecycle passed, Reduce Motion: \(reduced)")
        }
    }
}
#endif
