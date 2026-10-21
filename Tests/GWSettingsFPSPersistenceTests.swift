import Foundation

private struct FPSProbeFailure: Error, CustomStringConvertible {
    let description: String
}

private func fpsCheck(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw FPSProbeFailure(description: name) }
    print("PASS: \(name)")
}

@main @MainActor
enum GWSettingsFPSPersistenceTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-fps-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var applied: [Int] = []
        let actions = GWSettingsExternalActions(applyWallpaperFPS: { applied.append($0) })
        let coordinator = GWSettingsCoordinator(paths: GWSettingsPaths(root: root), external: actions)

        try fpsCheck(coordinator.preferences.wallpaperFPS == 30, "new profile starts at 30 FPS")
        coordinator.updatePreferences { $0.wallpaperFPS = 72 }
        try fpsCheck(applied == [72], "preference update applies FPS exactly once at runtime")

        let reloaded = GWSettingsCoordinator(paths: GWSettingsPaths(root: root), external: actions)
        try fpsCheck(reloaded.preferences.wallpaperFPS == 72, "FPS persists through a fresh coordinator")
        reloaded.pushPreferencesToExternal()
        try fpsCheck(applied.last == 72, "loaded FPS pushes to external runtimes")

        let envelope = GWConfigurationEnvelope(preferences: GWPreferencesSettings(wallpaperFPS: 120))
        let data = try GWJSONFileStore.makeEncoder().encode(envelope)
        let validated = try reloaded.validateImport(data: data)
        _ = try reloaded.commitImport(validated)
        try fpsCheck(reloaded.preferences.wallpaperFPS == 120 && applied.last == 120,
                     "validated import persists and applies its FPS")

        reloaded.resetPreferences()
        try fpsCheck(reloaded.preferences.wallpaperFPS == 30 && applied.last == 30,
                     "preference reset restores and applies 30 FPS")
        let final = try GWPreferencesPersistence.load(from: GWSettingsPaths(root: root).preferencesFile)
        try fpsCheck(final?.settings.wallpaperFPS == 30, "reset FPS is durable on disk")
    }
}
