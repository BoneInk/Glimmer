import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// The editor module's catalog: every text the editor shows is a key of it, translated into
/// every language the app ships, with the source's format arguments.
final class EditorLocalizationTests: XCTestCase {
    static let languages = ["de", "fr", "es", "pt-BR", "it", "ja", "ko", "zh-Hans", "zh-Hant",
                            "ru", "pl", "tr", "uk", "ar", "hi"]

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/OWEEditor")
    }

    private func catalog() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.sources.appending(path: "Resources/Localizable.xcstrings"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    /// `L("…")` keys in the sources, interpolations turned into the catalog's specifiers.
    private func usedKeys() throws -> Set<String> {
        var keys = Set<String>()
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z])L\("((?:[^"\\]|\\\([^)]*\))*)"\)"#)
        // The module's folders too (Effects, Layers, Assets, Scripting, Properties).
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { (item: Any) -> URL? in item as? URL }.filter { (url: URL) -> Bool in url.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                var key = String(text[Range(match.range(at: 1), in: text)!])
                // Numbers in this module are `number`; everything else is a string.
                key = key.replacingOccurrences(of: #"\\\(number\)"#, with: "%lld", options: .regularExpression)
                key = key.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "%@", options: .regularExpression)
                keys.insert(key)
            }
        }
        return keys
    }

    func testEveryKeyUsedIsInTheCatalog() throws {
        let catalog = try catalog()
        let missing = try usedKeys().filter { catalog[$0] == nil }
        XCTAssertTrue(missing.isEmpty, "not in the catalog: \(missing.sorted())")
    }

    func testEveryKeyIsTranslatedIntoEveryLanguage() throws {
        var problems: [String] = []
        let specifier = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|@)"#)
        func arguments(_ text: String) -> [String] {
            specifier.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for (key, entry) in try catalog() {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                let unit = localizations[language]?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty, unit?["state"] as? String == "translated" else {
                    problems.append("\(language): “\(key)”")
                    continue
                }
                if arguments(value) != arguments(key) { problems.append("\(language): “\(key)” has \(arguments(value))") }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.sorted().joined(separator: "\n"))
    }

    func testEnglishTextResolves() {
        XCTAssertEqual(L("Layers"), "Layers")
        XCTAssertEqual(SceneLayer.Kind.particle.title, "Particle System")
    }

    func testLayerTreeListsTheTopmostFirst() throws {
        let scene = Data(#"""
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "image": "a"}, {"id": 2, "image": "b", "parent": 1}, {"id": 3, "image": "c", "parent": 1},
                     {"id": 4, "text": "x"}, {"id": 5, "image": "d", "parent": 5}]}
        """#.utf8)
        let tree = LayerNode.tree(try SceneOutline(sceneData: scene))
        XCTAssertEqual(tree.map(\.id), [5, 4, 1], "a layer that is its own parent is listed at the top level")
        XCTAssertEqual(tree.last?.children?.map(\.id), [3, 2])
        XCTAssertNil(tree.first?.children)
    }
}
