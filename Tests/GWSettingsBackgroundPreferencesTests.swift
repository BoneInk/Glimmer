import Foundation

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw ProbeFailure(description: name) }
    print("PASS: \(name)")
}

@main
enum GWSettingsBackgroundPreferencesTests {
    static func main() throws {
        let decoder = GWJSONFileStore.makeDecoder()
        let encoder = GWJSONFileStore.makeEncoder()

        try check(GWPreferencesSettings.default.appearance == .dark, "new installs default to white text on a dark appearance")
        let legacy = try decoder.decode(
            GWPreferencesSettings.self,
            from: Data(#"{"appearance":"dark","restoreWallpapersOnLaunch":true}"#.utf8)
        )
        try check(legacy.backgroundBrightness == 0.15, "legacy JSON uses brightness default")
        try check(legacy.backgroundBlur == 0.15, "legacy JSON uses blur default")
        try check(legacy.wallpaperFPS == 30, "legacy JSON uses wallpaper FPS default")
        try check(
            legacy.appearance == .dark && legacy.restoreWallpapersOnLaunch,
            "legacy JSON preserves existing preference fields"
        )

        let clamped = try decoder.decode(
            GWPreferencesSettings.self,
            from: Data(#"{"backgroundBrightness":2.0,"backgroundBlur":-0.25}"#.utf8)
        )
        try check(clamped.backgroundBrightness == 1, "decoded brightness clamps to upper bound")
        try check(clamped.backgroundBlur == 0, "decoded blur clamps to lower bound")

        let invalid = try decoder.decode(
            GWPreferencesSettings.self,
            from: Data(#"{"backgroundBrightness":"bright","backgroundBlur":null}"#.utf8)
        )
        try check(invalid.backgroundBrightness == 0.15, "invalid brightness type uses default")
        try check(invalid.backgroundBlur == 0.15, "null blur uses default")
        let invalidFPS = try decoder.decode(
            GWPreferencesSettings.self,
            from: Data(#"{"wallpaperFPS":"fast"}"#.utf8)
        )
        try check(invalidFPS.wallpaperFPS == 30, "invalid wallpaper FPS type uses default")
        let clampedFPS = try decoder.decode(
            GWPreferencesSettings.self,
            from: Data(#"{"wallpaperFPS":999}"#.utf8)
        )
        try check(clampedFPS.wallpaperFPS == 240, "decoded wallpaper FPS clamps to upper bound")

        let nonFiniteDecoder = JSONDecoder()
        nonFiniteDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let nonFinite = try nonFiniteDecoder.decode(
            GWPreferencesSettings.self,
            from: Data(#"{"backgroundBrightness":"NaN","backgroundBlur":"Infinity"}"#.utf8)
        )
        try check(nonFinite.backgroundBrightness == 0.15, "non-finite brightness uses default")
        try check(nonFinite.backgroundBlur == 0.15, "non-finite blur uses default")

        var mutated = GWPreferencesSettings()
        mutated.backgroundBrightness = -1
        mutated.backgroundBlur = .nan
        mutated.wallpaperFPS = 0
        try check(mutated.backgroundBrightness == 0, "assigned brightness clamps to range")
        try check(mutated.backgroundBlur == 0.15, "assigned non-finite blur uses default")
        try check(mutated.wallpaperFPS == 1, "assigned wallpaper FPS clamps to lower bound")

        let encoded = try encoder.encode(GWPreferencesSettings(
            appearance: .light,
            backgroundBrightness: 0.2,
            backgroundBlur: 0.8,
            wallpaperFPS: 120,
            restoreWallpapersOnLaunch: true
        ))
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        try check(object["appearance"] as? String == "light", "encoding preserves appearance")
        try check(object["backgroundBrightness"] as? Double == 0.2, "encoding includes brightness")
        try check(object["backgroundBlur"] as? Double == 0.8, "encoding includes blur")
        try check(object["wallpaperFPS"] as? Int == 120, "encoding includes wallpaper FPS")
        try check(
            object["restoreWallpapersOnLaunch"] as? Bool == true,
            "encoding preserves startup restoration"
        )

        print("PASS: all background preference compatibility tests")
    }
}
