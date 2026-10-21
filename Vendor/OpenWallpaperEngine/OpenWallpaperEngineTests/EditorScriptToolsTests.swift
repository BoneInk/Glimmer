import XCTest
@testable import OpenWallpaperEngine

/// The script editor's reads of the user's Wallpaper Engine copy: WE's snippet scripts (in an
/// install's `ui/dist/monaco/snippets`, or the assets cache's copy) and the modules besides the
/// base ones.
final class EditorScriptToolsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-script-tools-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testSnippetsAreReadFromAnInstallOrTheCache() throws {
        let install = scratch.appending(path: "wallpaper_engine")
        try write("// rainbow", to: "ui/dist/monaco/snippets/script_vec3_color_rainbow.js", in: install)
        try write("{}", to: "assets/shaders/common.h", in: install)
        try write("{}", to: "assets/effects/tint/effect.json", in: install)
        let assets = install.appending(path: "assets")
        XCTAssertEqual(EditorShaderSnippets.snippet(named: "script_vec3_color_rainbow", assets: assets), "// rainbow")
        XCTAssertNil(EditorShaderSnippets.snippet(named: "script_click_wiggle", assets: assets), "not in WE's copy")
        XCTAssertNil(EditorShaderSnippets.snippet(named: "../../../../etc/passwd", assets: assets), "a file name only")
        XCTAssertNil(EditorShaderSnippets.snippet(named: "script_vec3_color_rainbow", assets: nil))

        // The cache keeps a copy, so a cache filled from the install has them too.
        let cache = WallpaperEngineAssets.cacheDirectory(in: scratch.appending(path: "storage"))
        let info = WallpaperEngineAssetsCache.Info(origin: .folder, installedAt: .now, steamBuildID: nil)
        try WallpaperEngineAssetsCache.fill(cache, from: install, info: info)
        XCTAssertEqual(EditorShaderSnippets.snippet(named: "script_vec3_color_rainbow", assets: cache), "// rainbow")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appending(path: "snippets/script_vec3_color_rainbow.js").path))
    }

    /// WE's own snippets (`ui/dist/monaco/snippets`, beside the assets of `OWE_ASSETS`, or the
    /// cache's copy) are what the script and shader editors insert.
    func testWEsSnippetsComeWithTheAssets() throws {
        let assets = try Fixtures.assets()
        let rainbow = try XCTUnwrap(EditorShaderSnippets.snippet(named: "script_vec3_color_rainbow", assets: assets),
                                    "WE's snippets for \(assets.path)")
        XCTAssertTrue(rainbow.contains("createScriptProperties"), rainbow)
        XCTAssertNotNil(EditorShaderSnippets.snippet(named: "shader_vert_passthrough", assets: assets), "a shader snippet")
    }

    func testCustomModulesAreWEsOtherJSModules() throws {
        let assets = scratch.appending(path: "assets")
        for name in ["wemath.js", "WEColor.js", "wevector.js", "easing.js", "notes.txt"] {
            try write("export var x = 1;", to: "scripts/jsmodules/\(name)", in: assets)
        }
        XCTAssertEqual(EditorScriptTools.customModules(assets: assets), ["easing"])
        XCTAssertEqual(EditorScriptTools.customModules(assets: scratch.appending(path: "none")), [])
    }
}
