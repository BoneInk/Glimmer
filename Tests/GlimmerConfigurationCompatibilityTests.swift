import Foundation

private struct ConfigurationTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct GlimmerConfigurationCompatibilityTests {
    private static var checks = 0

    static func main() throws {
        let preferences = GWPreferencesSettings(wallpaperFPS: 90)
        let envelope = GWConfigurationEnvelope(preferences: preferences)
        let exported = try GWConfigurationTransfer.encodeExport(envelope)
        var exportedObject = try rootObject(exported)
        try check(exportedObject["format"] as? String == GlimmerIdentity.configurationFormat,
                  "new exports use the Glimmer configuration format identifier")
        try check(GlimmerIdentity.configurationFormat == "glimmer.configuration",
                  "new configuration export identifier is exact")
        let validatedNew = try GWConfigurationTransfer.validateImport(data: exported)
        try check(validatedNew.preferences?.wallpaperFPS == 90,
                  "new-format export validates through the production importer")

        exportedObject["format"] = GlimmerIdentity.legacyConfigurationFormat
        let legacyData = try JSONSerialization.data(
            withJSONObject: exportedObject, options: [.sortedKeys, .withoutEscapingSlashes])
        let validatedLegacy = try GWConfigurationTransfer.validateImport(data: legacyData)
        try check(validatedLegacy.preferences?.wallpaperFPS == 90,
                  "legacy-format configuration remains readable")
        try check(GlimmerIdentity.acceptedConfigurationFormats.contains(
            GlimmerIdentity.legacyConfigurationFormat),
                  "legacy configuration identifier remains an explicit read-only compatibility input")
        try check(GlimmerIdentity.legacyConfigurationFormat == "glasswallpaper.configuration",
                  "legacy configuration compatibility input is exact")

        exportedObject["format"] = "com.example.unrelated"
        let unrelated = try JSONSerialization.data(
            withJSONObject: exportedObject, options: [.sortedKeys, .withoutEscapingSlashes])
        do {
            _ = try GWConfigurationTransfer.validateImport(data: unrelated)
            throw ConfigurationTestFailure(description: "unrelated configuration format must be rejected")
        } catch GWConfigurationError.unrecognizedFormat {
            checks += 1
            print("PASS unrelated configuration format is rejected")
        }

        print("GlimmerConfigurationCompatibilityTests: \(checks) checks passed; new export and legacy read")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw ConfigurationTestFailure(description: label) }
        checks += 1
        print("PASS \(label)")
    }

    private static func rootObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationTestFailure(description: "configuration export is not a JSON object")
        }
        return object
    }
}
