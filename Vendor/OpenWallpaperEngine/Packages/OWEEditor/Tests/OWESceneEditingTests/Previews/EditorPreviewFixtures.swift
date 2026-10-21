import Foundation

/// A small asset tree laid out like WE's: built-in effects (one internal), default particle
/// systems and one more file in `particles/`, and presets: particle ones with variants, one with
/// trailing commas (as WE's `water` is), one adding text only and a folder without a preset.
enum EditorPreviewFixtures {
    static let effects = ["blur", "shake", "tint", "waterripple"]

    static func assetsTree() throws -> URL {
        let root = try Fixtures.temporaryDirectory().appending(path: "assets", directoryHint: .isDirectory)
        for name in effects + ["_empty"] {
            try write(#"{"name": "ui_editor_effect_\#(name)_title", "group": "blur", "passes": [{"material": "materials/effects/\#(name).json"}]}"#,
                      to: "effects/\(name)/effect.json", in: root)
        }
        // A folder without effect.json isn't an effect.
        try write("x", to: "effects/broken/readme.txt", in: root)
        for file in ["example.json", "examplecursorfollow.json", "examplecursoravoid.json", "exampleturbolence.json",
                     "example3d.json", "exampleturbolence3d.json", "sparkle.json"] {
            try write(#"{"material": "materials/particle/halo.json", "maxcount": 10, "emitter": []}"#, to: "particles/\(file)", in: root)
        }
        try write(#"""
        {"name": "ui_rain", "description": "ui_rain_description", "tag": "scene2d", "group": "preset",
         "options": {"droplistOptions": [{"label": "ui_rain_1", "value": 0}, {"label": "ui_rain_2", "value": 1}]},
         "variants": [
           {"objects": [{"name": "Rain", "particle": "particles/presets/rain.json", "origin": "0 100 0"}],
            "dependencies": ["particles/presets/rain.json"]},
           {"objects": [{"name": "Downpour", "particle": "particles/presets/downpour.json"}],
            "dependencies": ["particles/presets/downpour.json"]}
         ]}
        """#, to: "presets/rain/preset.json", in: root)
        try write(#"""
        {
          "name" : "ui_water",
          "tag" : "scene2d",
          "variants" :
          [
            {
              "objects" : [ { "particle" : "particles/presets/drip.json", "instanceoverride" : { "count" : 2, }, } ],
              "dependencies" : [ "particles/presets/drip.json", ],
            },
          ],
        }
        """#, to: "presets/water/preset.json", in: root)
        try write(#"{"name": "ui_clock", "variants": [{"objects": [{"text": "12:00"}]}]}"#, to: "presets/clock/preset.json", in: root)
        try write("x", to: "presets/empty/readme.txt", in: root)
        return root
    }

    static func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
