import AppKit
import CoreGraphics
import ApplicationServices

@main @MainActor
enum MaximizedWindowPolicyTests {
    struct Failure: Error { let message: String }
    private static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
        checks += 1
        print("PASS \(message)")
    }

    static func main() async throws {
        let visible = CGRect(x: 0, y: 38, width: 1512, height: 880)
        try check(GWMaximizedWindowGeometry.covers(visible, window: visible), "window aligned with menu bar and Dock pauses")
        try check(GWMaximizedWindowGeometry.covers(visible, window: CGRect(x: 0, y: 0, width: 1512, height: 982)), "full-screen window also covers usable desktop")
        try check(GWMaximizedWindowGeometry.covers(visible, window: visible.insetBy(dx: 1, dy: 1)), "one-point rounding is tolerated")
        for window in [
            CGRect(x: 0, y: 38, width: 756, height: 880), // half-screen
            CGRect(x: 20, y: 38, width: 1492, height: 880), // left gap
            CGRect(x: 0, y: 58, width: 1512, height: 860), // top gap
            CGRect(x: 0, y: 38, width: 1512, height: 800), // bottom gap
            CGRect(x: 0, y: 38, width: 1470, height: 880), // right gap
            CGRect.zero
        ] {
            try check(!GWMaximizedWindowGeometry.covers(visible, window: window), "partial desktop coverage keeps playback")
        }
        let leftDock = CGRect(x: 70, y: 38, width: 1442, height: 944)
        try check(GWMaximizedWindowGeometry.covers(leftDock, window: leftDock), "side Dock uses actual usable bounds")
        let upperScreen = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        let quartz = GWMaximizedWindowGeometry.quartzRect(upperScreen, primaryScreenTop: 982)
        try check(quartz == CGRect(x: -1920, y: -1080, width: 1920, height: 1080), "secondary screen above and left converts to WindowServer coordinates")
        try check(GWMaximizedWindowGeometry.covers(quartz, window: quartz), "negative-coordinate display can pause")

        let legacy = try JSONDecoder().decode(GWPolicySettings.self, from: Data("{}".utf8))
        try check(!legacy.pauseOnMaximizedWindow, "existing configurations keep the new policy disabled")
        var settings = legacy
        settings.pauseOnMaximizedWindow = true
        let restored = try JSONDecoder().decode(GWPolicySettings.self, from: JSONEncoder().encode(settings))
        try check(restored == settings, "new setting survives JSON round trip")

        var core = GWPolicyCore(settings: settings)
        let blocked = core.handle(.maximizedWindowChanged(true))
        try check(blocked?.effectiveIsPlaying == false && core.activePauseReasons == [.maximizedWindow], "maximized window blocks playback with a visible pause reason")
        try check(core.handle(.maximizedWindowChanged(true)) == nil, "unchanged sampling does not repeat playback callbacks")
        core.handle(.maximizedWindowChanged(false))
        try check(core.effectiveIsPlaying, "shrinking or removing window restores playback")
        core.handle(.maximizedWindowChanged(true))
        core.handle(.userRequestedPause)
        core.handle(.maximizedWindowChanged(false))
        try check(!core.effectiveIsPlaying && core.userIntent == .paused, "uncovering desktop preserves manual pause")
        core.handle(.userRequestedPlay)
        core.handle(.screenLocked)
        core.handle(.maximizedWindowChanged(true))
        core.handle(.maximizedWindowChanged(false))
        try check(core.activePauseReasons == [.screenLocked] && !core.effectiveIsPlaying, "removing maximization preserves other pause policies")
        core.handle(.screenUnlocked)
        core.handle(.maximizedWindowChanged(true))
        core.handle(.policySettingsChanged(legacy))
        try check(core.effectiveIsPlaying, "disabling new setting immediately removes its block")

        settings.resumeWhenPolicyLifts = false
        core = GWPolicyCore(settings: settings)
        core.handle(.maximizedWindowChanged(true))
        core.handle(.maximizedWindowChanged(false))
        try check(!core.effectiveIsPlaying && core.isResumeSuppressed, "automatic resume preference is respected")
        core.handle(.userRequestedPlay)
        try check(core.effectiveIsPlaying, "explicit play clears resume suppression")

        let controller = GWPolicyController(settings: settings, persistenceEnabled: false)
        var transitions: [GWPolicyTransition] = []
        controller.onPolicyChanged = { transitions.append($0) }
        controller.handle(.maximizedWindowChanged(true))
        try check(!controller.shouldPlayOnDisplay(userIsPaused: false), "controller blocks displays through existing integration API")
        controller.updateSettings { $0.pauseOnMaximizedWindow = false }
        try check(controller.shouldPlayOnDisplay(userIsPaused: false), "toggle applies immediately through controller")
        try check(!controller.shouldPlayOnDisplay(userIsPaused: true), "display manual pause is never overridden")
        try check(transitions.count == 2, "controller emits pause and resume callbacks")

        try await eventDrivenChecks()
        if CommandLine.arguments.contains("--live") { try await liveWindowCheck() }
        print("MaximizedWindowPolicyTests: \(checks) checks passed")
    }

    @MainActor final class TestWindowEvents: GWWindowEventMonitoring {
        var onChange: (@MainActor (Bool) -> Void)?
        var onIssue: (@MainActor (String?) -> Void)?
        var synchronizations = 0
        var stops = 0
        func synchronize(applicationPIDs: Set<pid_t>, refreshWindows: Bool) { synchronizations += 1 }
        func stop() { stops += 1 }
    }

    static func eventDrivenChecks() async throws {
        let events = TestWindowEvents()
        var trusted = false
        var covered = true
        var queries = 0
        let controller = GWPolicyController(
            settings: GWPolicySettings(pauseOnLowPowerMode: false, pauseOnMaximizedWindow: true),
            persistenceEnabled: false, autoStartMonitoring: true, windowEvents: events,
            windowAccessCheck: { trusted }, maximizedWindowQuery: { queries += 1; return covered }
        )
        defer { controller.stopMonitoring() }
        try check(queries == 0 && events.synchronizations == 0 && !controller.isWindowMonitoring,
                  "missing authorization performs no window scans or subscriptions")
        trusted = true
        controller.refreshWindowAccessibilityAuthorization()
        try check(events.synchronizations == 1 && queries == 1 && controller.core.hasMaximizedWindow,
                  "granting authorization starts subscriptions and one initial snapshot")
        covered = false
        for _ in 0..<100 { events.onChange?(false) }
        try await Task.sleep(for: .milliseconds(450))
        try check(queries == 2 && !controller.core.hasMaximizedWindow && controller.effectiveIsPlaying,
                  "100 window events coalesce into one scan and restore playback")
        let beforeDrag = queries
        for _ in 0..<4 {
            events.onChange?(false)
            try await Task.sleep(for: .milliseconds(120))
        }
        try check(queries == beforeDrag, "continuing drag events defer all geometry scans until interaction settles")
        try await Task.sleep(for: .milliseconds(400))
        try check(queries == beforeDrag + 1, "settled drag produces exactly one geometry scan")
        // “查看桌面”先恢复，返回原应用时合成器仍暂时报告窗口移出了屏幕。
        covered = false
        events.onChange?(true)
        try await Task.sleep(for: .milliseconds(450))
        try check(controller.effectiveIsPlaying, "show desktop resumes wallpaper on first visibility snapshot")
        let beforeReturnNotification = queries
        NotificationCenter.default.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        try await Task.sleep(for: .milliseconds(450))
        try check(queries == beforeReturnNotification + 1, "native application and window visibility notifications coalesce into one snapshot")
        try check(controller.effectiveIsPlaying, "return animation may initially still report no covering window")
        covered = true
        // 不再发送任何 AX/应用切换事件，模拟尺寸和焦点均未变化的原窗口。
        try await Task.sleep(for: .milliseconds(1100))
        try check(!controller.effectiveIsPlaying && controller.core.hasMaximizedWindow,
                  "one transition completion snapshot pauses wallpaper after returning to same maximized app")
        let afterReturn = queries
        try await Task.sleep(for: .milliseconds(1600))
        try check(queries == afterReturn, "transition completion snapshot never schedules another check")
        covered = false
        events.onChange?(true)
        try await Task.sleep(for: .milliseconds(450))
        controller.userRequestedPause()
        let beforeCancelledSettle = queries
        try await Task.sleep(for: .milliseconds(1300))
        try check(queries == beforeCancelledSettle, "manual pause cancels pending desktop completion snapshot")
        controller.userRequestedPlay()
        let idleQueries = queries
        try await Task.sleep(for: .milliseconds(6500))
        try check(queries == idleQueries, "idle desktop produces no scans beyond the removed five-second interval")
        covered = true
        events.onChange?(false)
        try await Task.sleep(for: .milliseconds(450))
        try check(controller.core.hasMaximizedWindow && !controller.effectiveIsPlaying,
                  "resize event pauses playback without waiting for a periodic check")
        controller.userRequestedPause()
        try check(!controller.isWindowMonitoring && events.stops > 0, "manual pause releases event subscriptions")
        let pausedQueries = queries
        events.onChange?(false)
        try await Task.sleep(for: .milliseconds(450))
        try check(queries == pausedQueries, "late callbacks after stopping do not scan windows")
        controller.updateSettings { $0.resumeWhenPolicyLifts = false }
        covered = false
        controller.userRequestedPlay()
        try check(controller.isWindowMonitoring, "explicit play recreates event subscriptions")
        try check(controller.effectiveIsPlaying, "explicit play after window changed while monitoring stopped overrides auto-resume suppression")
        controller.updateSettings { $0.resumeWhenPolicyLifts = true }
        controller.handle(.screenLocked)
        try check(!controller.isWindowMonitoring, "screen lock releases event subscriptions")
        controller.handle(.screenUnlocked)
        try check(controller.isWindowMonitoring, "unlock recreates event subscriptions and resamples current state")
        controller.updateSettings { $0.pauseOnLowPowerMode = true }
        controller.handle(.lowPowerModeChanged(true))
        try check(!controller.isWindowMonitoring, "another blocking policy releases event subscriptions")
        controller.handle(.lowPowerModeChanged(false))
        try check(controller.isWindowMonitoring, "lifting the other policy restores subscriptions")
        controller.updateSettings { $0.resumeWhenPolicyLifts = false }
        trusted = false
        events.onChange?(false)
        try await Task.sleep(for: .milliseconds(450))
        try check(!controller.isWindowMonitoring && !controller.core.hasMaximizedWindow,
                  "permission revocation removes observers and stale window pause")
        try check(!controller.core.isResumeSuppressed, "permission loss does not create a manual-resume requirement")
        trusted = true
        controller.refreshWindowAccessibilityAuthorization()
        events.onIssue?("unsupported test application")
        try check(controller.windowMonitoringIssue != nil, "unsupported events surface a settings explanation")
        let beforeStop = queries
        events.onChange?(false)
        controller.updateSettings { $0.pauseOnMaximizedWindow = false }
        try await Task.sleep(for: .milliseconds(450))
        try check(!controller.isWindowMonitoring && queries == beforeStop, "disabling setting cancels queued event scan")
        try check(!controller.core.activePauseReasons.contains(.maximizedWindow), "disabled setting clears pause reason")
    }

    /// 真实 WindowServer 窗口尺寸验证；不改用户现有窗口、壁纸或设置。
    static func liveWindowCheck() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        guard let screen = NSScreen.screens.first else { throw Failure(message: "no desktop screen") }
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 420, height: 300),
                              styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.title = "Glimmer window detection check"
        window.setFrame(screen.visibleFrame, display: true)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        func actualBounds() throws -> CGRect {
            guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]])?.first,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                throw Failure(message: "WindowServer did not expose test window geometry")
            }
            return rect
        }
        let visible = GWMaximizedWindowGeometry.quartzRect(screen.visibleFrame, primaryScreenTop: screen.frame.maxY)
        let maximizedBounds = try actualBounds()
        try check(GWMaximizedWindowGeometry.covers(visible, window: maximizedBounds), "real maximized NSWindow matches WindowServer bounds")
        try check(GWMaximizedWindowDetector.hasMaximizedWindow(), "live detector recognizes a real maximized app window")
        if !AXIsProcessTrusted() {
            let controller = GWPolicyController(
                settings: GWPolicySettings(pauseOnMaximizedWindow: true), persistenceEnabled: false,
                autoStartMonitoring: true
            )
            defer { controller.stopMonitoring() }
            try check(!controller.isWindowAccessibilityAuthorized && !controller.isWindowMonitoring,
                      "real untrusted process installs no AX observers and starts no fallback polling")
            try check(!controller.core.hasMaximizedWindow, "untrusted process does not apply an undetectable window policy")
            print("SKIP native AX callback delivery: test process has no Accessibility authorization")
        } else {
            let controller = GWPolicyController(
                settings: GWPolicySettings(pauseOnMaximizedWindow: true), persistenceEnabled: false,
                autoStartMonitoring: true,
                maximizedWindowQuery: {
                    guard !window.isMiniaturized, window.isVisible, let bounds = try? actualBounds() else { return false }
                    return GWMaximizedWindowGeometry.covers(visible, window: bounds)
                }
            )
            defer { controller.stopMonitoring() }
            // 只给 AX 初次订阅留出时间；生产逻辑不使用这个测试等待。
            try await Task.sleep(for: .seconds(2))
            try check(controller.isWindowMonitoring && controller.core.hasMaximizedWindow, "native AX observer starts on authorized process")
            window.setFrame(screen.visibleFrame.insetBy(dx: 100, dy: 100), display: true)
            try await Task.sleep(for: .seconds(1))
            try check(!controller.core.hasMaximizedWindow, "native AX resize event restores uncovered desktop")
            window.setFrame(screen.visibleFrame, display: true)
            try await Task.sleep(for: .seconds(1))
            try check(controller.core.hasMaximizedWindow, "native AX resize event detects maximization")
            window.miniaturize(nil)
            try await Task.sleep(for: .seconds(1))
            try check(!controller.core.hasMaximizedWindow, "native AX minimization event restores desktop")
        }
    }
}
