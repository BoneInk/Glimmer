import XCTest
@testable import OpenWallpaperEngine

/// A wallpaper's own translations, project.json `general.localization`: keys resolve in the app's
/// language, then English, then show as written, as WE's UI resolves them; WE's own text wins
/// over the author's in a language.
final class WallpaperAuthorLocalizationTests: XCTestCase {
    /// Shaped like the library's localized web wallpapers: `ui_` keys in mixed case, markup in
    /// the values, a table under a code WE doesn't use (`nn-no`), and a key only some languages have.
    private static let project: [String: Any] = [
        "general": [
            "properties": [
                "HEADER_AUDIO": ["text": "ui_HEADER_AUDIO", "type": "bool", "order": 1],
                "background_color": ["text": "ui_background_color", "type": "color", "order": 2],
                "mode": ["text": "ui_mode", "type": "combo", "order": 3,
                         "options": [["label": "ui_mode_bars", "value": "0"], ["label": "Plain", "value": "1"]]],
                "plain": ["text": "Brightness", "type": "slider", "order": 4],
            ],
            "localization": [
                "en-us": ["ui_HEADER_AUDIO": "<u><h4>Audio Settings</h4></u>", "ui_background_color": "Background color",
                          "ui_mode": "Mode", "ui_mode_bars": "Bars", "not_ui_key": "dropped", "ui_number": 3],
                "de-de": ["ui_HEADER_AUDIO": "<u><h4>Audio</h4></u>", "ui_background_color": "Hintergrundfarbe"],
                "nn-no": ["ui_background_color": "Bakgrunnsfarge"],
            ],
        ],
    ]

    private func labels(_ languages: [String], we: WallpaperEngineLabels = WallpaperEngineLabels()) -> WallpaperEngineLabels {
        we.addingAuthorTranslations(projectJSON: Self.project, languages: languages)
    }

    func testDecodingKeepsOnlyUIKeysWithText() {
        let localization = WallpaperAuthorLocalization(projectJSON: Self.project)
        XCTAssertEqual(Set(localization.tables.keys), ["en-us", "de-de", "nn-no"])
        XCTAssertNil(localization.table(for: "en-us")["not_ui_key"], "WE keeps only ui_ keys")
        XCTAssertNil(localization.table(for: "en-us")["ui_number"])
        XCTAssertEqual(localization.table(for: "fr-fr"), [:])
        XCTAssertEqual(WallpaperAuthorLocalization(projectJSON: ["general": ["properties": [:]]]).tables, [:])
    }

    func testAKeyResolvesInTheAppsLanguageThenEnglishThenNot() {
        let german = labels(["de-DE"])
        XCTAssertEqual(german.translation("ui_background_color"), "Hintergrundfarbe")
        XCTAssertEqual(german.translation("ui_mode_bars"), "Bars", "German lacks it: English")
        XCTAssertNil(german.translation("ui_missing"), "neither has it: the caller shows the key")
        XCTAssertNil(german.translation("Brightness"))
        XCTAssertEqual(labels(["en-US"]).translation("ui_background_color"), "Background color")
        XCTAssertEqual(labels(["ja-JP"]).translation("ui_background_color"), "Background color", "no Japanese table")
    }

    func testTheLanguageIsTheCodeScriptsGet() {
        // Norwegian is nb-no in WE, so an author's nn-no table is never used, as in WE.
        XCTAssertEqual(SceneScriptGeneralSettings.language(for: ["nn-NO"]), "nb-no")
        XCTAssertEqual(labels(["nn-NO"]).translation("ui_background_color"), "Background color")
    }

    func testAuthorKeysMatchExactly() {
        XCTAssertEqual(labels(["en"]).translation("ui_HEADER_AUDIO"), "<u><h4>Audio Settings</h4></u>")
        XCTAssertNil(labels(["en"]).translation("ui_header_audio"))
    }

    func testWEsOwnTextWinsInALanguageButNotOverTheAuthorsLanguage() {
        let we = WallpaperEngineLabels(english: ["ui_background_color": "WE English", "ui_mode": "WE Mode"],
                                       localized: ["ui_mode": "WE Modus"])
        let german = labels(["de-DE"], we: we)
        XCTAssertEqual(german.translation("ui_mode"), "WE Modus", "WE's German beats the author's (none) and English")
        XCTAssertEqual(german.translation("ui_background_color"), "Hintergrundfarbe",
                       "the author's German beats WE's English")
        XCTAssertEqual(labels(["en"], we: we).translation("ui_background_color"), "WE English",
                       "in one language WE's own table wins, as WE extends the author's with it")
    }

    /// The properties panel shows the wallpaper's own text, without its markup, for a title.
    func testThePropertiesPanelUsesTheWallpapersTranslations() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-author-l10n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            Fixtures.removeStoredSettings(for: directory)
            try? FileManager.default.removeItem(at: directory) // test scratch folder
        }
        var root = Self.project
        root["file"] = "index.html"
        root["title"] = "Localized fixture"
        root["type"] = "web"
        // English only, so the test reads the same whatever the test host's language.
        var general = try XCTUnwrap(root["general"] as? [String: Any])
        var localization = try XCTUnwrap(general["localization"] as? [String: Any])
        localization.removeValue(forKey: "de-de")
        localization.removeValue(forKey: "nn-no")
        general["localization"] = localization
        root["general"] = general
        let data = try JSONSerialization.data(withJSONObject: root)
        try data.write(to: directory.appending(path: "project.json"))
        let wallpaper = WEWallpaper(using: try JSONDecoder().decode(WEProject.self, from: data), where: directory)

        let model = SceneUserPropertiesModel(wallpaper: wallpaper, scopes: [.shared])
        let titles = Dictionary(uniqueKeysWithValues: model.properties.map { ($0.id, $0.title) })
        XCTAssertEqual(titles["HEADER_AUDIO"], "Audio Settings")
        XCTAssertEqual(titles["background_color"], "Background color")
        XCTAssertEqual(titles["plain"], "Brightness")
        let options = try XCTUnwrap(model.properties.first { $0.id == "mode" }?.options.map(\.title))
        XCTAssertEqual(options, ["Bars", "Plain"])
    }
}
