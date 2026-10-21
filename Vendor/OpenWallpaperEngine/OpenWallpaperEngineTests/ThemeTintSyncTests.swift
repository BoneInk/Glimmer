import AppKit
import OWEInspectorKit
import OWETheming
import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// Theming's tint of the app's own windows: worked out from the settings, published by the app to
/// the defaults and the process channel, followed by the Wallpaper Editor's process, and applied at
/// each window's root. Nothing here touches the Mac's colour settings: the defaults are a throwaway
/// suite and the channel is in memory.
@MainActor
final class ThemeTintSyncTests: XCTestCase {
    private let red = ThemeColor(red: 0.85, green: 0.15, blue: 0.2)
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "ThemeTintSyncTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func accent() -> SystemAccentColor {
        SystemAccentColor(center: NotificationCenter(), distributedCenter: NotificationCenter())
    }

    private func settings(accent: Bool = true, app: AppAccentChoice = .themeColor,
                          system: SystemAccentChoice = .nearestApple) -> ThemingSettings {
        var settings = ThemingSettings()
        settings.isEnabled = true
        settings.accentColor = accent
        settings.appAccent = app
        settings.systemAccent = system
        return settings
    }

    func testTheTintFollowsTheSetting() {
        let messaging = MCPFakeProcessMessaging()
        let appAccent = accent()
        let sync = ThemeTintSync(defaults: defaults, messaging: messaging, channel: AppProcessChannel(isolationTag: "tests"),
                                 accent: appAccent, sender: "app")

        sync.publish(settings().appTint(for: red))
        XCTAssertEqual(appAccent.themeTint, red)
        sync.publish(settings(system: .multicolor).appTint(for: red))
        XCTAssertEqual(appAccent.themeTint, red, "Multicolor still gives the app the exact colour")
        sync.publish(settings(app: .system).appTint(for: red))
        XCTAssertNil(appAccent.themeTint, "Follow System Accent")
        sync.publish(settings(accent: false).appTint(for: red))
        XCTAssertNil(appAccent.themeTint)
        var off = settings()
        off.isEnabled = false
        sync.publish(off.appTint(for: red))
        XCTAssertNil(appAccent.themeTint, "theming off: the system accent, as before")
    }

    func testThePublishedTintReachesTheEditorsProcess() throws {
        let messaging = MCPFakeProcessMessaging()
        let channel = AppProcessChannel(isolationTag: "tests")
        let appAccent = accent()
        let editorAccent = accent()
        let app = ThemeTintSync(defaults: defaults, messaging: messaging, channel: channel, accent: appAccent, sender: "app")
        let editor = ThemeTintSync(defaults: defaults, messaging: messaging, channel: channel, accent: editorAccent,
                                   sender: "editor")

        app.publish(red)
        XCTAssertEqual(defaults.string(forKey: ThemeTintSync.defaultsKey), red.componentString)
        XCTAssertEqual(messaging.posted.map(\.name), [channel.name(.themeTintDidChange)])

        editor.follow()
        let followed = try XCTUnwrap(editorAccent.themeTint, "the editor takes the stored tint at launch")
        XCTAssertEqual(followed.red, red.red, accuracy: 1e-5)

        let green = ThemeColor(red: 0.3, green: 0.7, blue: 0.3)
        app.publish(green)
        XCTAssertEqual(try XCTUnwrap(editorAccent.themeTint).green, green.green, accuracy: 1e-5)

        app.publish(nil)
        XCTAssertNil(defaults.object(forKey: ThemeTintSync.defaultsKey))
        XCTAssertNil(editorAccent.themeTint, "the app quitting or Theming off: the system accent")

        let posts = messaging.posted.count
        app.publish(nil)
        XCTAssertEqual(messaging.posted.count, posts, "an unchanged tint isn't posted again")
        editor.stop()
    }

    func testEveryWindowRootGetsTheTint() throws {
        let appAccent = accent()
        var seen: [Color] = []
        let host = NSHostingView(rootView: AccentProbe { seen.append($0) }.appAccentTint(appAccent))
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(seen.last, Color.accentColor, "no tint: the system accent")

        appAccent.themeTint = red
        XCTAssertTrue(drawUntil(host) { seen.last == Color(themeColor: red) }, "the window's content takes the tint")
        appAccent.themeTint = nil
        XCTAssertTrue(drawUntil(host) { seen.last == Color.accentColor }, "and goes back to the system accent")
    }

    /// Lets SwiftUI update `host` until `done`, for up to 5 seconds.
    private func drawUntil(_ host: NSView, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        return done()
    }

    func testTheSettingsRoundTripWithTheGlobalSettings() throws {
        var settings = GlobalSettings()
        settings.theming = self.settings(app: .system, system: .multicolor)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.theming.systemAccent, .multicolor)
        XCTAssertEqual(decoded.theming.appAccent, .system)
        XCTAssertEqual(GlobalSettings().theming.systemAccent, .nearestApple, "the default is today's behaviour")
        XCTAssertEqual(GlobalSettings().theming.appAccent, .themeColor)
    }
}

/// Reports the accent its environment gives it.
private struct AccentProbe: View {
    @Environment(\.appAccentColor) private var accentColor
    let seen: (Color) -> Void

    var body: some View {
        seen(accentColor)
        return Color.clear
    }
}
