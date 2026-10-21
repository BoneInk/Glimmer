import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// The particle editor's catalog (`Particles/Resources/Particles.xcstrings`): every text it shows,
/// its own and the schema's (labels, options, component names, groups, hints), translated into
/// every language the app ships; and its bundled copy of WE's schema.
final class ParticleEditorLocalizationTests: XCTestCase {
    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/OWEEditor/Particles")
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func catalog() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.sources.appending(path: "Resources/Particles.xcstrings"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    /// `PL("…")` keys in the particle editor's sources, interpolations as the catalog's specifiers.
    private func usedKeys() throws -> Set<String> {
        var keys = Set<String>()
        let regex = try NSRegularExpression(pattern: #"PartL\("((?:[^"\\]|\\\([^)]*\))*)"\)"#)
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { (url: URL) -> Bool in url.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                var key = String(text[Range(match.range(at: 1), in: text)!])
                // Whole numbers are the frame count and the control point's slot.
                key = key.replacingOccurrences(of: #"\\\((texture\.frames|index)\)"#, with: "%lld", options: .regularExpression)
                key = key.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "%@", options: .regularExpression)
                keys.insert(key)
            }
        }
        return keys
    }

    /// The schema's texts the panel shows.
    private func schemaKeys() throws -> Set<String> {
        var keys = Set<String>()
        for component in try ParticleEditorServices.bundledSchema().components {
            keys.insert(component.title)
            for field in component.fields {
                keys.insert(field.label)
                keys.formUnion(field.options.map(\.label))
                keys.formUnion(field.components.filter { $0.count > 1 })
                if let group = field.group { keys.insert(group) }
                if let hint = field.hint { keys.insert(hint) }
            }
        }
        return keys
    }

    func testEveryTextIsInTheCatalog() throws {
        let catalog = try catalog()
        let used = try usedKeys()
        XCTAssertGreaterThan(used.count, 50)
        let missing = used.union(try schemaKeys()).filter { catalog[$0] == nil }
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
            for language in EditorLocalizationTests.languages {
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

    func testTheBundledSchemaIsWEsSchema() throws {
        let bundled = try Data(contentsOf: Self.sources.appending(path: "Resources/ParticleEditorSchema.json"))
        let documented = try Data(contentsOf: Self.repositoryRoot.appending(path: "docs/we-particle-editor-schema.json"))
        XCTAssertEqual(bundled, documented, "the module's copy of docs/we-particle-editor-schema.json is current")
        let schema = try ParticleEditorServices.bundledSchema()
        XCTAssertNotNil(schema.component(.operator, name: "movement"), "the module bundles and reads it")
    }

    func testTextsResolveInEnglish() {
        XCTAssertEqual(PL("Emitters"), "Emitters")
        XCTAssertEqual(PLSchema("Sphere random"), "Sphere random")
        XCTAssertEqual(ParticleEditorSchema.Section.controlpoint.title, "Control Points")
    }
}
