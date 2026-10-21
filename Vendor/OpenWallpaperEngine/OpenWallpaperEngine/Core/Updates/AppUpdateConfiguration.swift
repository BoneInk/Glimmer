import Foundation

/// What the updater needs from the app's Info.plist, and the channel rules, kept free of Sparkle so
/// they can be tested.
///
/// The release workflow fills `SUPublicEDKey` from the `SPARKLE_PUBLIC_ED_KEY` build setting and
/// `OWEVersionLabel` from the tag (`1.0.0` or `1.0.0-beta.1`). Local and Debug builds leave the key
/// empty, so they never check for updates: without the key Sparkle can't verify an update.
struct AppUpdateConfiguration: Equatable {
    /// The Sparkle channel pre-release appcast items are tagged with.
    static let betaChannel = "beta"

    let feedURL: URL?
    let publicEDKey: String
    /// The release's full version, with its pre-release suffix (`1.0.0-rc.2`).
    let versionLabel: String

    init(feedURL: URL?, publicEDKey: String, versionLabel: String) {
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.versionLabel = versionLabel
    }

    init(infoDictionary info: [String: Any]) {
        let feed: String = info["SUFeedURL"] as? String ?? ""
        let key: String = info["SUPublicEDKey"] as? String ?? ""
        let label: String = info["OWEVersionLabel"] as? String
            ?? info["CFBundleShortVersionString"] as? String ?? ""
        self.init(feedURL: URL(string: feed), publicEDKey: key, versionLabel: label)
    }

    /// The app's (the Wallpaper Editor's app reads the app's, `AppBundleLayout.appBundle`).
    static var main: AppUpdateConfiguration { .init(infoDictionary: AppBundleLayout.appBundle.infoDictionary ?? [:]) }

    /// A real EdDSA public key (32 bytes, base64) and an https feed; anything else (an empty build
    /// setting, an unexpanded `$(…)`, a placeholder) leaves the updater off.
    var isConfigured: Bool {
        guard feedURL?.scheme == "https",
              let data = Data(base64Encoded: publicEDKey), data.count == 32 else { return false }
        return true
    }

    /// Whether this build is itself a pre-release (`-alpha.N`, `-beta.N`, `-rc.N`).
    var isPrereleaseBuild: Bool { ReleaseVersion(versionLabel)?.prerelease != nil }

    /// Whether beta updates are offered: the user's choice, which defaults to on for a pre-release build.
    func receivesBetaUpdates(storedPreference: Bool?) -> Bool {
        storedPreference ?? isPrereleaseBuild
    }

    /// The Sparkle channels besides the default one that updates may come from.
    func allowedChannels(storedPreference: Bool?) -> Set<String> {
        receivesBetaUpdates(storedPreference: storedPreference) ? [Self.betaChannel] : []
    }
}
