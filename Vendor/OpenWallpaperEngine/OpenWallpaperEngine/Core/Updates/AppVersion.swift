import Foundation

/// The version the app shows (Settings › About, exported settings, the legal notice).
///
/// A release build shows its full release version and build number, e.g. "1.0.0-beta.2 (2)".
/// A local build, which has no update signing key, shows its version and "Dev build".
enum AppVersion {
    static func displayString(infoDictionary info: [String: Any]) -> String {
        let configuration = AppUpdateConfiguration(infoDictionary: info)
        let label = label(infoDictionary: info)
        guard configuration.isConfigured else {
            return String(localized: "\(label) (Dev build)", comment: "A local build's version, e.g. 1.0.0 (Dev build)")
        }
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? label : "\(label) (\(build))"
    }

    /// The release version without the build, e.g. "1.0.0-beta.2": `OWEVersionLabel`, or
    /// `CFBundleShortVersionString` when the label is missing or unexpanded.
    static func label(infoDictionary info: [String: Any]) -> String {
        let versionLabel = AppUpdateConfiguration(infoDictionary: info).versionLabel
        return versionLabel.isEmpty || versionLabel.hasPrefix("$(")
            ? (info["CFBundleShortVersionString"] as? String ?? "")
            : versionLabel
    }

    static var current: String { displayString(infoDictionary: Bundle.main.infoDictionary ?? [:]) }
}
