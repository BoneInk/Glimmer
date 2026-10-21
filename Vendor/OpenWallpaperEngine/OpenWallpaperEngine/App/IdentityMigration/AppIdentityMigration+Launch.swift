import Foundation
import ServiceManagement

extension AppIdentityMigration {
    /// The migration of this process's copy: the real one, or its isolated tag's.
    static func forCurrentProcess() -> AppIdentityMigration {
        let location = AppStorageLocation.current
        let current = AppBundleLayout.appIdentifier(for: Bundle.main.bundleIdentifier ?? AppStorageLocation.realBundleIdentifier)
        var migration = AppIdentityMigration(
            isolationTag: location.isolationTag,
            legacyIdentifier: legacyBundleIdentifier,
            currentIdentifier: current,
            supportDirectory: location.supportDirectory,
            cachesDirectory: location.cachesDirectory,
            libraryDirectory: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0],
            preferences: SystemPreferenceDomains(),
            keychain: { KeychainStore(service: $0) },
            keychainItems: SteamCredentials.keychainItems)
        migration.reinstallScreenSaver = { try reinstallLegacyScreenSaver(.current) }
        migration.reregisterLoginItem = reregisterLoginItem
        return migration
    }

    /// Replaces an installed screen saver that still has the old id with the bundled one.
    static func reinstallLegacyScreenSaver(_ installer: ScreenSaverInstaller) throws {
        guard installer.mayInstall, installer.isInstalled else { return }
        let info = installer.installedURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        // Optional lookup: a saver without a readable Info.plist isn't the old one.
        let identifier = NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String
        guard identifier == legacyBundleIdentifier + ".saver" else { return }
        guard installer.install() else { throw ScreenSaverNotReinstalled() }
        OWELog.info(.settings, "Identity migration: reinstalled the screen saver under the new id")
    }

    struct ScreenSaverNotReinstalled: Error, CustomStringConvertible {
        var description: String { "the screen saver couldn't be reinstalled" }
    }

    /// Launch at login, when it is on, registered for the new identity. macOS keeps the old
    /// identity's entry until the user removes it in System Settings › General › Login Items.
    static func reregisterLoginItem() throws {
        guard let data = UserDefaults.app.data(forKey: "GlobalSettings") else { return }
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
        guard settings.autoStart else { return }
        try SMAppService.mainApp.register()
        OWELog.info(.settings, "Identity migration: launch at login registered for the new identity")
    }
}
