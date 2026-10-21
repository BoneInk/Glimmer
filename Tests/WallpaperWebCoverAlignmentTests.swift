#if GW_WEB_COVER_ALIGNMENT_TESTS
import AppKit
import SwiftUI
struct WallpaperItem { let id = UUID(); var workshopID: String? }
struct WorkshopSearchResult: Identifiable { let id: String }
private struct MotionOverride: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var windowGlassReduceMotionOverride: Bool { get { self[MotionOverride.self] } set { self[MotionOverride.self] = newValue } }
}
@main @MainActor enum WallpaperWebCoverAlignmentTests {
    static var checks = 0
    static func check(_ result: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(result(), message); print("PASS: \(message)")
    }
    static func bitmap(_ host: NSView, at url: URL) -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return bitmap
    }
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        var difference = 0.0; let n = a.bytesPerRow * a.pixelsHigh
        for i in 0..<n { difference += Double(abs(Int(a.bitmapData![i]) - Int(b.bitmapData![i]))) }
        return difference / Double(n)
    }
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[3]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = NSImage(contentsOfFile: CommandLine.arguments[1])!, target = NSImage(contentsOfFile: CommandLine.arguments[2])!
        let destination = CGRect(x: 0, y: 0, width: 1000, height: 640), origin = CGRect(x: 220, y: 330, width: 280, height: 280 / 1.5)
        let match = WallpaperCoverSnapshotAlignment.match(source: source, target: target, in: destination)!
        check(abs(match.sourceFrame.minX - 180) < 1 && abs(match.sourceFrame.width - 640) < 1,
              "actual square poster is registered to center 640-square in the actual Web frame, rather than stretched to the window")
        check(match.meanError < 10, "actual project center-crop match is supported by pixel agreement")
        var flight = WallpaperCoverFlightSnapshot(image: source, source: .init(frame: origin), destination: .init(frame: destination, cornerRadius: 0))
        let start = flight.state(at: 0).imageFrame, scale = start.width / match.sourceFrame.width
        let secondStart = CGRect(x: start.minX - match.sourceFrame.minX * scale, y: start.minY,
            width: destination.width * scale, height: destination.height * scale)
        flight.destinationSourceImageFrame = match.sourceFrame; flight.secondImage = target
        flight.secondImageSourceFrame = secondStart; flight.secondImageDestinationFrame = destination
        let frozen = flight
        for index in 1...100 {
            let a = frozen.state(at: CGFloat(index - 1) / 100), b = frozen.state(at: CGFloat(index) / 100)
            check(abs(a.imageFrame.width - b.imageFrame.width) < 4 && abs(a.secondImageFrame!.width - b.secondImageFrame!.width) < 6,
                  "source and target picture transforms remain continuous at sample \(index)")
        }
        check(frozen.state(at: 1).secondImageFrame == destination && frozen.state(at: 1).blend == 1,
              "flight ends on the exact captured Web canvas frame and pixels")
        let actual = frozen.state(at: 0.37)
        var reverse = WallpaperCoverFlightSnapshot(image: source,
            source: .init(frame: actual.frame, cornerRadius: actual.cornerRadius), destination: .init(frame: origin), sourceImageFrame: actual.imageFrame)
        reverse.secondImage = target; reverse.secondImageSourceFrame = actual.secondImageFrame; reverse.secondImageDestinationFrame = secondStart
        reverse.sourceBlend = actual.blend; reverse.destinationBlend = 0
        check(reverse.state(at: 0) == actual, "mid-flight back preserves both rendered image rectangles and the current blend")
        let unrelated = NSImage(size: CGSize(width: 120, height: 120))
        unrelated.lockFocus(); NSColor.magenta.setFill(); NSRect(x: 0, y: 0, width: 120, height: 120).fill(); unrelated.unlockFocus()
        check(WallpaperCoverSnapshotAlignment.match(source: unrelated, target: target, in: destination) == nil,
              "unrelated posters are rejected rather than falsely registered")
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: AnyView(Color.white)); host.frame = destination
        for progress in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            host.rootView = AnyView(ZStack { Color.white; WallpaperCoverFlightView(snapshot: frozen, progress: progress) })
            try await Task.sleep(for: .milliseconds(60))
            _ = bitmap(host, at: output.appendingPathComponent("flight-\(Int(progress * 100)).png"))
        }
        let end = bitmap(host, at: output.appendingPathComponent("flight-end.png"))
        let presentation = WorkspaceWallpaperDetails(); presentation.open(WallpaperItem(workshopID: nil))
        presentation.coverImage = source; presentation.destinationSnapshot = target
        presentation.destinationCoverVisible = true; presentation.livePreviewOpacity = 0
        host.rootView = AnyView(Image(nsImage: target).resizable().scaledToFill().frame(width: 1000, height: 640)
            .wallpaperCoverDestination(cornerRadius: 0).environment(\.workspaceWallpaperDetails, presentation))
        try await Task.sleep(for: .milliseconds(60))
        let landed = bitmap(host, at: output.appendingPathComponent("static-handoff.png"))
        check(difference(end, landed) < 0.2, "native two-image flight end and inline snapshot handoff have identical pixels")
        presentation.livePreviewOpacity = 0.5; try await Task.sleep(for: .milliseconds(60))
        let middle = bitmap(host, at: output.appendingPathComponent("live-handoff-midpoint.png"))
        check(difference(landed, middle) < 0.2, "native actual-Web snapshot midpoint has no crop movement or darkening")
        presentation.livePreviewOpacity = 1; try await Task.sleep(for: .milliseconds(60))
        let live = bitmap(host, at: output.appendingPathComponent("live-handoff.png"))
        check(difference(landed, live) < 0.5, "native actual-Web snapshot and same-size live image keep positions through the last handoff")
        print("PASS: \(checks) actual Web alignment and native pixel assertions")
    }
}
#endif
