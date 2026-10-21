import XCTest
import OWEInspectorKit
@testable import OWEEditor
@testable import OWESceneEditing

/// The package's own string catalogs, one row each: every key a module's sources pass to the
/// catalog's helper (`G("…")`, `T("…")`…) is in it, every key is translated into every language
/// the app ships with the key's format arguments, and, where the row says so, every key is used.
@MainActor
final class CatalogCoverageTests: XCTestCase {
    /// How a source's `\(…)` turns into the catalog key's specifier.
    enum Interpolation {
        /// Kept as written: the catalog's key holds no specifiers.
        case raw
        /// `\(number)` is an integer (`%lld`), anything else a string (`%@`).
        case numberOrString
        /// Every interpolation is a string (`%@`).
        case string
    }

    struct Row {
        /// The catalog, from the package root.
        var catalog: String
        /// The helper whose literal keys are collected from every source of `OWEEditor`; nil for a
        /// catalog whose keys come from `keys` only.
        var helper: String?
        var interpolation: Interpolation = .raw
        /// Whether every key in the catalog must be used.
        var everyKeyUsed = true
        /// At least this many keys are found, so a broken pattern can't pass.
        var minimumUsed = 1
        /// Keys the module builds at run time.
        var keys: () -> Set<String> = { [] }
    }

    static var rows: [Row] { [
        Row(catalog: "Sources/OWEEditor/Resources/Gizmos.xcstrings", helper: "G"),
        Row(catalog: "Sources/OWEEditor/Resources/Timeline.xcstrings", helper: "T", interpolation: .numberOrString),
        Row(catalog: "Sources/OWEEditor/Resources/LayerCommands.xcstrings", helper: "LC", interpolation: .numberOrString),
        Row(catalog: "Sources/OWEEditor/Resources/EffectGizmos.xcstrings", helper: "EG"),
        Row(catalog: "Sources/OWEEditor/Resources/ImageTools.xcstrings", helper: "IL", interpolation: .numberOrString,
            everyKeyUsed: false, minimumUsed: 11),
        Row(catalog: "Sources/OWEEditor/Resources/TextureVariants.xcstrings", helper: "TVL", interpolation: .string,
            everyKeyUsed: false, minimumUsed: 21),
        Row(catalog: "Sources/OWEEditor/Resources/CanvasView.xcstrings", helper: "CV"),
        Row(catalog: "Sources/OWEEditor/Resources/Thumbnail.xcstrings", helper: "TH", interpolation: .string),
        Row(catalog: "Sources/OWEEditor/Resources/DepthMaps.xcstrings", helper: "DL", everyKeyUsed: false, minimumUsed: 21),
        Row(catalog: "Sources/OWEInspectorKit/Resources/Stats.xcstrings", everyKeyUsed: false, keys: CatalogCoverageTests.statsKeys),
    ] }

    /// The stats overlay's texts: every row it can show, its modes and its badge.
    static func statsKeys() -> Set<String> {
        var stats = RenderStats()
        stats.lightCount = 1
        stats.expensiveEffects = 11
        stats.veryExpensiveEffects = 2
        stats.videoTextureCount = 1
        stats.clippingMaskPasses = 1
        var titles = stats.rows.map(\.title)
        stats.expensiveEffects = 1
        stats.veryExpensiveEffects = 1
        titles += stats.rows.map(\.title) + RenderStatsMode.allCases.map(\.title)
        return Set(titles + ["Stats per frame", "%lld FPS · GPU %@ ms · %@ MB"])
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func sourceTexts() throws -> [String] {
        let sources = packageRoot.appending(path: "Sources/OWEEditor")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return try enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    static func usedKeys(_ row: Row, in texts: [String]) throws -> Set<String> {
        var keys = row.keys()
        guard let helper = row.helper else { return keys }
        // A literal argument: plain characters, `\(…)` interpolations and other escapes.
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z])"# + helper + #"\("((?:[^"\\]|\\\([^)]*\)|\\.)*)"\)"#)
        for text in texts {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                var key = String(text[Range(match.range(at: 1), in: text)!])
                switch row.interpolation {
                case .raw:
                    break
                case .numberOrString:
                    key = key.replacingOccurrences(of: #"\\\(number\)"#, with: "%lld", options: .regularExpression)
                    key = key.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "%@", options: .regularExpression)
                case .string:
                    key = key.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "%@", options: .regularExpression)
                }
                keys.insert(key)
            }
        }
        return keys
    }

    private static func arguments(_ text: String) -> [String] {
        let specifier = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|@)"#)
        return specifier.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    func testEveryCatalogHasEveryKeyTranslated() throws {
        let texts = try Self.sourceTexts()
        XCTAssertGreaterThan(texts.count, 10)
        for row in Self.rows {
            let data = try Data(contentsOf: Self.packageRoot.appending(path: row.catalog))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], row.catalog)
            XCTAssertEqual(json["sourceLanguage"] as? String, "en", row.catalog)
            let catalog = try XCTUnwrap(json["strings"] as? [String: [String: Any]], row.catalog)
            let used = try Self.usedKeys(row, in: texts)
            XCTAssertGreaterThanOrEqual(used.count, row.minimumUsed, row.catalog)
            XCTAssertEqual(used.subtracting(catalog.keys).sorted(), [], "\(row.catalog): not in the catalog")
            if row.everyKeyUsed {
                XCTAssertEqual(Set(catalog.keys).subtracting(used).sorted(), [], "\(row.catalog): in the catalog but unused")
            }
            var problems: [String] = []
            for (key, entry) in catalog {
                let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
                for language in EditorLocalizationTests.languages {
                    let unit = localizations[language]?["stringUnit"] as? [String: Any]
                    guard let value = unit?["value"] as? String, !value.isEmpty, unit?["state"] as? String == "translated" else {
                        problems.append("\(language): “\(key)”")
                        continue
                    }
                    if Self.arguments(value) != Self.arguments(key) {
                        problems.append("\(language): “\(key)” has \(Self.arguments(value))")
                    }
                }
            }
            XCTAssertTrue(problems.isEmpty, "\(row.catalog):\n" + problems.sorted().joined(separator: "\n"))
        }
    }

    /// Each helper finds its table: the English text, not the key's fallback from another table.
    func testEnglishTextResolvesFromEachTable() {
        XCTAssertEqual(GizmoMode.translate.title, "Translate")
        XCTAssertEqual(GizmoSpace.local.title, "Local Space")
        XCTAssertEqual(LC("Rotate CW"), "Rotate CW")
        XCTAssertEqual(EG("Move Effect Handle"), "Move Effect Handle")
        XCTAssertEqual(IL("Normal Map"), "Normal Map")
        XCTAssertEqual(TVL("Add Variant Group"), "Add Variant Group")
        XCTAssertEqual(DL("Invert"), "Invert")
    }
}
