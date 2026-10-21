#if GW_COVER_CONTINUOUS_TESTS
import AppKit
import Observation
import SwiftUI

struct WallpaperItem { let id = UUID(); var workshopID: String? }
struct WorkshopSearchResult: Identifiable { let id: String }
private struct MotionOverride: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var windowGlassReduceMotionOverride: Bool {
        get { self[MotionOverride.self] }
        set { self[MotionOverride.self] = newValue }
    }
}
@MainActor @Observable private final class ContinuousContext {
    var targetOffset: CGFloat = 0
    var ready = false
    var appearances = 0
}
private struct ContinuousSource: View {
    let image: NSImage
    let context: ContinuousContext
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Image(nsImage: image).resizable().scaledToFill().frame(width: 180, height: 110)
                .wallpaperCoverSource("workshop:continuous", image: image)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .position(x: 120, y: 380)
        }.onAppear { context.appearances += 1 }
    }
}
@main @MainActor enum WallpaperCoverContinuousTests {
    static var assertions = 0
    static let output = ProcessInfo.processInfo.environment["GW_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("GlimmerTests/continuous")
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1; precondition(value(), "FAIL: \(message)"); print("PASS: \(message)")
    }
    static func tick(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    static func bitmap(_ view: NSView, _ name: String) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: image)
        try! image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        return image
    }
    static func redBounds(_ bitmap: NSBitmapImageRep, width: CGFloat) -> CGRect {
        var minX = bitmap.pixelsWide; var minY = bitmap.pixelsHigh; var maxX = -1; var maxY = -1
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent < 0.4 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        precondition(maxX >= 0, "cover must remain visible")
        let scale = CGFloat(bitmap.pixelsWide) / width
        return .init(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                     width: CGFloat(maxX - minX + 4) / scale, height: CGFloat(maxY - minY + 4) / scale)
    }
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        precondition(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh)
        let count = a.bytesPerRow * a.pixelsHigh
        let x = a.bitmapData!, y = b.bitmapData!
        var difference: Double = 0
        for i in 0..<count { difference += Double(abs(Int(x[i]) - Int(y[i]))) }
        return difference / Double(count)
    }
    static func main() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let image = NSImage(size: CGSize(width: 360, height: 220))
        image.lockFocus()
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 360, height: 220).fill()
        NSColor.white.setFill(); NSRect(x: 155, y: 80, width: 50, height: 60).fill()
        NSColor.yellow.setFill(); NSRect(x: 50, y: 30, width: 25, height: 160).fill()
        NSColor.blue.setFill(); NSRect(x: 285, y: 30, width: 25, height: 160).fill()
        image.unlockFocus()
        let source = WallpaperCoverGeometry(frame: CGRect(x: 30, y: 325, width: 180, height: 110))
        let target = WallpaperCoverGeometry(frame: CGRect(x: 20, y: 60, width: 600, height: 326), mode: .fit, cornerRadius: 12)
        let frozen = WallpaperCoverFlightSnapshot(image: image, source: source, destination: target)
        let expected = frozen.state(at: 0.4)
        var changedPreference = target
        for i in 1...20 { changedPreference.frame.origin.y += CGFloat(i) }
        check(frozen.state(at: 0.4) == expected && frozen.destination.frame == target.frame,
              "multiple changing layout preferences cannot mutate frozen flight endpoints")
        for i in 1...100 {
            let a = frozen.state(at: CGFloat(i - 1) / 100), b = frozen.state(at: CGFloat(i) / 100)
            check(abs(a.imageFrame.width - b.imageFrame.width) < 5 && abs(a.frame.minY - b.frame.minY) < 3,
                  "continuous image crop and position sample \(i)")
        }
        let end = frozen.state(at: 1)
        check(end.imageFrame == WallpaperCoverTransitionGeometry.imageFrame(imageSize: image.size, container: target.frame, mode: .fit),
              "flight endpoint crop exactly equals inline static destination crop")
        let actual = frozen.state(at: 0.37)
        let reverse = WallpaperCoverFlightSnapshot(image: image,
            source: .init(frame: actual.frame, mode: .fit, cornerRadius: actual.cornerRadius), destination: source,
            sourceImageFrame: actual.imageFrame)
        check(reverse.state(at: 0) == actual, "mid-flight return begins at the last rendered rectangle AND image crop")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let frameHost = NSHostingView(rootView: AnyView(Color.white))
        window.contentView = frameHost; window.orderFrontRegardless()
        var endBitmap: NSBitmapImageRep!
        for progress in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            frameHost.rootView = AnyView(ZStack { Color.white; WallpaperCoverFlightView(snapshot: frozen, progress: progress) })
            await tick(0.08)
            let b = bitmap(frameHost, "flight-\(Int(progress * 100))")
            if progress == 1 { endBitmap = b }
        }
        let presentation = WorkspaceWallpaperDetails()
        presentation.open(WallpaperItem(workshopID: "continuous"))
        presentation.coverImage = image; presentation.destinationCoverVisible = true; presentation.livePreviewOpacity = 0
        frameHost.rootView = AnyView(ZStack(alignment: .topLeading) {
            Color.white
            Image(nsImage: image).resizable().scaledToFit().frame(width: 600, height: 326)
                .wallpaperCoverDestination(ready: false, mode: .fit)
                .position(x: target.frame.midX, y: target.frame.midY)
        }.environment(\.workspaceWallpaperDetails, presentation))
        await tick(0.12)
        let staticHandoff = bitmap(frameHost, "handoff-static")
        check(difference(endBitmap, staticHandoff) < 0.2, "native flight-to-static handoff has identical geometry crop and pixels")
        presentation.livePreviewOpacity = 1
        await tick(0.08)
        let liveHandoff = bitmap(frameHost, "handoff-live")
        // The image and crop are identical. Only the remote/live renderer's black
        // letterbox background differs, so compare the actual image's interior.
        let imageRect = end.imageFrame.insetBy(dx: 4, dy: 4)
        let centerA = staticHandoff.colorAt(x: Int(imageRect.midX * 2), y: Int(imageRect.midY * 2))!
        let centerB = liveHandoff.colorAt(x: Int(imageRect.midX * 2), y: Int(imageRect.midY * 2))!
        check(centerA == centerB, "static-to-live image center is stable across handoff")
        // Exercise the actual opacity composition, not just both endpoints:
        // complementary opacities on stacked layers incorrectly dim identical
        // artwork by 25% at the midpoint.
        presentation.livePreviewOpacity = 0.5
        await tick(0.08)
        let middleHandoff = bitmap(frameHost, "handoff-midpoint")
        let centerMid = middleHandoff.colorAt(x: Int(imageRect.midX * 2), y: Int(imageRect.midY * 2))!
        check(centerMid == centerB, "native midpoint keeps identical live/cover pixels fully opaque without a dark flash")

        let context = ContinuousContext()
        let live = WorkspaceWallpaperDetails()
        let root = WorkspaceWallpaperDetailsHost(presentation: live) {
            ContinuousSource(image: image, context: context)
        } detail: { _ in
            VStack(spacing: 0) {
                Color.clear.frame(height: 60 + context.targetOffset)
                Image(nsImage: image).resizable().scaledToFill().frame(height: 326).clipped()
                    .wallpaperCoverDestination(ready: context.ready)
                Spacer(minLength: 0)
            }.padding(.horizontal, 20)
        }
        frameHost.rootView = AnyView(root)
        await tick(0.2)
        let initial = redBounds(bitmap(frameHost, "dynamic-source"), width: 640)
        live.open(WallpaperItem(workshopID: "continuous"))
        await tick(0.1); context.targetOffset = 80
        await tick(0.04)
        let middle = redBounds(bitmap(frameHost, "dynamic-mid-1"), width: 640)
        let t = (middle.width - initial.width) / (600 - initial.width)
        let expectedY = initial.minY + (60 - initial.minY) * t
        check(abs(middle.minY - expectedY) < 7, "actual animated frame remains on original path after target re-layout")
        context.targetOffset = 130; await tick(0.035); context.targetOffset = 100
        await tick(1.3)
        let held = bitmap(frameHost, "dynamic-landed-not-ready")
        let landed = redBounds(held, width: 640)
        check(abs(landed.minY - 160) < 4 && live.livePreviewOpacity == 0,
              "late target changes settle continuously before static handoff; unready live preview stays covered")
        check(context.appearances == 1, "layout churn never reconstructs the source browsing tree")
        context.ready = true
        for index in 0...4 {
            await tick(0.06)
            _ = bitmap(frameHost, "live-crossfade-\(index)")
        }
        check(live.livePreviewOpacity == 1, "only readiness releases the static cover to the live renderer")
        live.dismiss(); await tick(1)
        let returned = redBounds(bitmap(frameHost, "dynamic-returned"), width: 640)
        check(live.route == nil && abs(returned.minY - initial.minY) < 4 && abs(returned.width - initial.width) < 4,
              "reverse handoff returns the same bitmap to the unchanged source rectangle")
        window.orderOut(nil)
        print("PASS: \(assertions) continuity assertions; native frame evidence at \(output.path)")
    }
}
#endif
