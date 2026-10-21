import Foundation
import Sparkle

/// How Sparkle's update window names the installed version and the update.
///
/// Every pre-release shares the bundle's `CFBundleShortVersionString` (`1.0.0`), which Sparkle shows
/// by default. The installed version is shown as its release label instead (`1.0.0-beta.2`, as in
/// Settings › About) and the update as its `sparkle:shortVersionString` (`1.0.0-beta.3`). When the
/// two read the same, each gets its build number, as Sparkle's standard display does.
final class UpdateVersionDisplay: NSObject, SUVersionDisplay {
    /// The installed release label, e.g. "1.0.0-beta.2".
    let installedLabel: String

    init(installedLabel: String) {
        self.installedLabel = installedLabel
        super.init()
    }

    /// The update's and the installed version's display strings.
    static func labels(update: String, updateBuild: String,
                       installed: String, installedBuild: String) -> (update: String, installed: String) {
        guard update == installed else { return (update, installed) }
        return ("\(update) (\(updateBuild))", "\(installed) (\(installedBuild))")
    }

    func formatUpdateVersion(fromUpdate update: SUAppcastItem,
                             andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
                             withBundleVersion bundleVersion: String) -> String {
        let labels = Self.labels(update: update.displayVersionString, updateBuild: update.versionString,
                                 installed: installedLabel, installedBuild: bundleVersion)
        inOutBundleDisplayVersion.pointee = labels.installed as NSString
        return labels.update
    }

    /// The installed version when no newer update is found.
    func formatBundleDisplayVersion(_ bundleDisplayVersion: String, withBundleVersion bundleVersion: String,
                                    matchingUpdate: SUAppcastItem?) -> String {
        installedLabel
    }
}
