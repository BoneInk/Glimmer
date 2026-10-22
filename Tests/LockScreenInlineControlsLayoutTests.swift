import AppKit
import Observation
import SwiftUI

// Minimal test doubles keep this a layout-only probe. No lock-screen or
// wallpaper backend is constructed or invoked.
struct WallpaperItem {
    let id: UUID
    let displayTitle: String
    let isVideoWallpaper: Bool
    let isWebWallpaper: Bool
    let isSceneWallpaper: Bool
    let fileExists: Bool
}

struct TransientToast: Equatable {
    enum Tone: Equatable { case info, success, error }
    let message: String
    let tone: Tone

    init(_ message: String, tone: Tone) {
        self.message = message
        self.tone = tone
    }
}

@MainActor @Observable final class LockScreenActionController {
    enum Phase { case idle, preparing, applying }
    enum Completion { case none, cancelled, submitted, failed }

    @Observable final class CoordinatorDouble {
        var lastError: String?
        var canRestorePrevious = false
    }

    let coordinator = CoordinatorDouble()
    var phase: Phase = .idle
    var completion: Completion = .none
    var itemID: UUID?
    var feedback: String?
    private(set) var cancellationCount = 0

    var isBusy: Bool { phase != .idle }
    var canCancelPreparation: Bool { phase == .preparing }
    var showsStatus: Bool { isBusy || feedback != nil || coordinator.lastError != nil }
    var statusText: String { feedback ?? coordinator.lastError ?? "" }

    func startApply(item: WallpaperItem) -> String? { nil }
    func cancelPreparation() { cancellationCount += 1 }
    func restorePrevious() -> String? { nil }
}

private enum ProbeID: String { case panel, wallpaperButton, lockButton }

private final class GeometryProbeView: NSView {
    let probeID: ProbeID

    init(_ probeID: ProbeID) {
        self.probeID = probeID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private struct GeometryProbe: NSViewRepresentable {
    let id: ProbeID
    func makeNSView(context: Context) -> GeometryProbeView { GeometryProbeView(id) }
    func updateNSView(_ nsView: GeometryProbeView, context: Context) {}
}

private struct BottomPanelFixture: View {
    let item: WallpaperItem
    let actions: LockScreenActionController
    let onFeedback: (TransientToast) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 10) {
                Button {} label: {
                    WallpaperActionLabel(
                        title: "设为壁纸",
                        symbol: "display",
                        busy: actions.isBusy
                    )
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("wallpaper-apply")
                .background(GeometryProbe(id: .wallpaperButton))

                LockScreenApplyControls(item: item, onFeedback: onFeedback)
                    .background(GeometryProbe(id: .lockButton))
                Spacer(minLength: 0)
            }
            .background(GeometryProbe(id: .panel))
        }
        .frame(width: 560, height: 180)
        .environment(\.lockScreenActions, actions)
    }
}

@main @MainActor
enum LockScreenInlineControlsLayoutTests {
    private struct Snapshot {
        let panel: CGRect
        let wallpaperButton: CGRect
        let lockButton: CGRect
    }

    private static func settle(_ host: NSHostingView<BottomPanelFixture>) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        host.layoutSubtreeIfNeeded()
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func snapshot(_ host: NSHostingView<BottomPanelFixture>) -> Snapshot {
        let probes = descendants(of: host).compactMap { $0 as? GeometryProbeView }
        func frame(_ id: ProbeID) -> CGRect {
            guard let view = probes.first(where: { $0.probeID == id }) else {
                preconditionFailure("Missing geometry probe: \(id.rawValue)")
            }
            return view.convert(view.bounds, to: host)
        }
        return Snapshot(panel: frame(.panel), wallpaperButton: frame(.wallpaperButton), lockButton: frame(.lockButton))
    }

    private static func assertStable(_ baseline: Snapshot, _ current: Snapshot, state: String) {
        func assertFrame(_ lhs: CGRect, _ rhs: CGRect, name: String) {
            precondition(abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5 &&
                         abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5,
                         "\(name) moved in \(state): \(lhs) -> \(rhs)")
        }
        assertFrame(baseline.panel, current.panel, name: "panel")
        assertFrame(baseline.wallpaperButton, current.wallpaperButton, name: "wallpaper button")
        assertFrame(baseline.lockButton, current.lockButton, name: "lock button")
    }

    private static func click(at hostPoint: CGPoint, in host: NSView, window: NSWindow) {
        let windowPoint = host.convert(hostPoint, to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { preconditionFailure("Could not construct cancel click") }
            window.sendEvent(event)
        }
    }

    static func main() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let item = WallpaperItem(
            id: UUID(), displayTitle: "布局测试视频",
            isVideoWallpaper: true, isWebWallpaper: false, isSceneWallpaper: false, fileExists: true
        )
        let actions = LockScreenActionController()
        var feedback: [TransientToast] = []
        let host = NSHostingView(rootView: BottomPanelFixture(item: item, actions: actions) { feedback.append($0) })
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 180)
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 560, height: 180), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)

        settle(host)
        let idle = snapshot(host)
        precondition(idle.panel.height > 0 && idle.wallpaperButton.width > 0 && idle.lockButton.width > 0)
        precondition(abs(idle.wallpaperButton.width - idle.lockButton.width) < 0.5 && abs(idle.wallpaperButton.height - idle.lockButton.height) < 0.5,
                     "Wallpaper and lock-screen buttons must have identical sizes")

        actions.itemID = item.id
        actions.phase = .preparing
        settle(host)
        let preparing = snapshot(host)
        assertStable(idle, preparing, state: "preparing")

        // The production overlay gives its xmark a 20x20 frame, inset eight
        // points from the button's trailing edge. A native mouse dispatch at
        // that center proves the overlay contributes a real hit target.
        let cancelPoint = CGPoint(x: preparing.lockButton.maxX - 18,
                                  y: preparing.lockButton.midY)
        precondition(host.hitTest(cancelPoint) != nil, "Cancel point is outside native hit testing")
        click(at: cancelPoint, in: host, window: window)
        settle(host)
        precondition(actions.cancellationCount == 1,
                     "Preparing cancel overlay did not receive its native click")
        let cancelFrame = CGRect(x: cancelPoint.x - 10, y: cancelPoint.y - 10,
                                 width: 20, height: 20)

        actions.phase = .applying
        settle(host)
        assertStable(idle, snapshot(host), state: "applying")

        actions.phase = .idle
        settle(host)
        assertStable(idle, snapshot(host), state: "returned idle")

        actions.completion = .failed
        actions.feedback = "布局测试失败反馈"
        settle(host)
        assertStable(idle, snapshot(host), state: "error feedback")
        precondition(feedback == [TransientToast("布局测试失败反馈", tone: .error)],
                     "Error feedback did not leave layout through callback: \(feedback)")

        print("PASS idle -> preparing -> applying -> idle/error geometry remained fixed")
        print("panel=\(idle.panel) wallpaper=\(idle.wallpaperButton) lock=\(idle.lockButton)")
        print("PASS preparing cancel hit target=\(cancelFrame)")
        print("PASS error feedback callback=\(feedback[0].message)")

        // A local Scene item must enter the same single lock-screen control
        // without adding rows, a second button or moving the fixed layout.
        let sceneItem = WallpaperItem(
            id: UUID(), displayTitle: "布局测试 Scene",
            isVideoWallpaper: false, isWebWallpaper: false,
            isSceneWallpaper: true, fileExists: true
        )
        let sceneActions = LockScreenActionController()
        let sceneHost = NSHostingView(rootView: BottomPanelFixture(item: sceneItem, actions: sceneActions) { _ in })
        sceneHost.frame = CGRect(x: 0, y: 0, width: 560, height: 180)
        let sceneWindow = NSWindow(
            contentRect: CGRect(x: -10_000, y: 0, width: 560, height: 180), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        sceneWindow.contentView = sceneHost
        sceneWindow.orderBack(nil)
        settle(sceneHost)
        assertStable(idle, snapshot(sceneHost), state: "local Scene item")
        print("PASS local Scene item keeps the fixed lock-screen control layout")
        sceneWindow.close()
        window.close()
    }
}
