import Foundation
import OWETheming

/// Theming's tint of Open Wallpaper Engine's own windows (`ThemingSettings.appTint`) in each
/// process: the app works it out (`ThemingController.appTint`) and publishes it; the Wallpaper
/// Editor's process follows it. The colour is kept in the defaults both processes share, and the
/// app posts `themeTintDidChange` on the process channel after each change, so the editor reads it
/// again. Either side sets `SystemAccentColor.themeTint`, which every window's root applies
/// (`AppAccentTint`).
@MainActor
final class ThemeTintSync {
    /// The tint as "r g b" (0…1); absent for the system accent.
    static let defaultsKey = "ThemingAppTint"

    private let defaults: UserDefaults
    private let messaging: AppProcessMessaging
    private let channel: AppProcessChannel
    private let accent: SystemAccentColor
    private let sender: String
    private var token: AnyObject?

    init(defaults: UserDefaults = .app, messaging: AppProcessMessaging, channel: AppProcessChannel = .current,
         accent: SystemAccentColor = .shared, sender: String = AppProcessChannel.processSender) {
        self.defaults = defaults
        self.messaging = messaging
        self.channel = channel
        self.accent = accent
        self.sender = sender
    }

    /// The app: `tint` becomes this process's tint and the stored one, and the editor hears of it.
    func publish(_ tint: ThemeColor?) {
        if accent.themeTint != tint { accent.themeTint = tint }
        guard Self.stored(in: defaults) != tint else { return }
        if let tint {
            defaults.set(tint.componentString, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
        messaging.post(channel.name(.themeTintDidChange), sender: sender, userInfo: [:])
    }

    /// The editor's process: takes the stored tint now and after each change the app posts.
    func follow() {
        take()
        guard token == nil else { return }
        token = messaging.observe(channel.name(.themeTintDidChange)) { [weak self] _, _ in self?.take() }
    }

    func stop() {
        if let token { messaging.remove(token) }
        token = nil
    }

    private func take() {
        let tint = Self.stored(in: defaults)
        if accent.themeTint != tint { accent.themeTint = tint }
    }

    /// The stored tint; nil when absent or not a colour.
    static func stored(in defaults: UserDefaults) -> ThemeColor? {
        defaults.string(forKey: defaultsKey).flatMap(ThemeColor.init(weString:))
    }
}
