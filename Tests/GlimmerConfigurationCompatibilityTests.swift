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

        let temporaryID = "session-display:" + UUID().uuidString
        let playback = GWPlaybackConfiguration(displays: [temporaryID: .default, "legacy-display-7": .default])
        let filtered = playback.normalized()
        try check(filtered.displays[temporaryID] == nil && filtered.displays["legacy-display-7"] != nil,
                  "normalization filters only temporary display identities")
        let playbackExport = try GWConfigurationTransfer.encodeExport(GWConfigurationEnvelope(playback: playback))
        try check(!String(decoding: playbackExport, as: UTF8.self).contains(temporaryID),
                  "production export strips temporary display identities")
        let rawImport = try GWJSONFileStore.makeEncoder().encode(GWConfigurationEnvelope(playback: playback))
        let importedPlayback = try GWConfigurationTransfer.validateImport(data: rawImport).playback
        try check(importedPlayback?.displays[temporaryID] == nil && importedPlayback?.displays["legacy-display-7"] != nil,
                  "production importer strips temporary identities and preserves legacy stable keys")
        var unsafeObject = try rootObject(rawImport)
        unsafeObject["playback"] = ["displays": [temporaryID: ["password": "test-only"]]]
        do {
            _ = try GWConfigurationTransfer.validateImport(data: JSONSerialization.data(withJSONObject: unsafeObject))
            throw ConfigurationTestFailure(description: "temporary display keys must not hide nested credentials")
        } catch GWConfigurationError.credentialContent {
            checks += 1
            print("PASS temporary display keys still reject nested credential fields")
        }

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
