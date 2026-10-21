import XCTest
@testable import OpenWallpaperEngine

/// WE's UI strings come with the assets (`locale/ui_*.json`, WE's files unchanged; `OWE_ASSETS`),
/// so property labels keyed as `ui_editor_properties_*` read as WE shows them.
final class WallpaperEngineLabelsTests: XCTestCase {
    private func bundledAssets() throws -> URL {
        try Fixtures.assets()
    }

    func testTheBundledEnglishTableResolvesAPropertyKey() throws {
        let labels = WallpaperEngineLabels.load(assets: try bundledAssets(), languages: ["en-US"])
        XCTAssertEqual(labels.translation("ui_editor_properties_speed"), "Speed")
        XCTAssertEqual(labels.translation("UI_Editor_Properties_Blend_Mode"), "Blend mode")
        XCTAssertNil(labels.translation("My own label"))
    }

    /// The user's language overlays English; a key the language lacks stays English.
    func testTheUsersLanguageOverlaysEnglish() throws {
        let english = WallpaperEngineLabels.load(assets: try bundledAssets(), languages: ["en"])
        let german = WallpaperEngineLabels.load(assets: try bundledAssets(), languages: ["de-DE", "en"])
        XCTAssertEqual(german.translation("ui_editor_properties_speed"), "Geschwindigkeit")
        let lithuanian = WallpaperEngineLabels.load(assets: try bundledAssets(), languages: ["lt"])
        XCTAssertEqual(lithuanian.translation("ui_editor_properties_blend_mode"),
                       english.translation("ui_editor_properties_blend_mode"),
                       "Lithuanian has 320 keys; the rest read in English")
    }

    /// An install keeps `locale` beside `assets`; the bundled tree keeps it inside.
    func testAnInstallsLocaleBesideItsAssetsIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "owe-labels-\(UUID().uuidString)")
        let locale = root.appending(path: "locale")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        try Data(#"{ "ui_editor_properties_speed" : "Speed" }"#.utf8).write(to: locale.appending(path: "ui_en-us.json"))
        let labels = WallpaperEngineLabels.load(assets: root.appending(path: "assets"), languages: ["en"])
        XCTAssertEqual(labels.translation("ui_editor_properties_speed"), "Speed")
    }

    func testLanguageIdentifiersMapToWEsFileCodes() {
        let available: [String] = ["de-de", "en-us", "pt-br", "pt-pt", "zh-chs", "zh-cht", "nb-no"]
        XCTAssertEqual(WallpaperEngineLabels.weLanguage(for: "de", available: available), "de-de")
        XCTAssertEqual(WallpaperEngineLabels.weLanguage(for: "de-AT", available: available), "de-de")
        XCTAssertEqual(WallpaperEngineLabels.weLanguage(for: "pt-PT", available: available), "pt-pt")
        XCTAssertEqual(WallpaperEngineLabels.weLanguage(for: "pt-BR", available: available), "pt-br")
        XCTAssertEqual(WallpaperEngineLabels.weLanguage(for: "zh-Hans-CN", available: available), "zh-chs")
        XCTAssertEqual(WallpaperEngineLabels.weLanguage(for: "zh-Hant-TW", available: available), "zh-cht")
        XCTAssertEqual(WallpaperEngineLabels.weLanguage(for: "zh-HK", available: available), "zh-cht")
        XCTAssertEqual(WallpaperEngineLabels.weLanguage(for: "nb", available: available), "nb-no")
        XCTAssertNil(WallpaperEngineLabels.weLanguage(for: "xx", available: available))
    }
}
