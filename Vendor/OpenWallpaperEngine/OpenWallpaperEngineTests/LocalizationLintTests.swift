import Foundation
import XCTest

/// A lint over the UI's source: a string literal that reads as text for people (a phrase or a
/// sentence) must be a key of `Localizable.xcstrings`, which the compiler only extracts when the
/// literal reaches a localizing API (`Text`, `Button`, `String(localized:)`, …). One passed as a
/// plain `String` into `Text`, a menu item or an alert shows in English in every language.
///
/// Literals that aren't UI text are skipped by context: log calls, defaults keys, comparisons,
/// `case` patterns, icon names, paths, `verbatim:` text and translator comments. A line that
/// really has to keep an English literal says so with `// l10n-ignore: <reason>`.
final class LocalizationLintTests: XCTestCase {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The UI's source: views, menus, alerts, panels and the errors they show.
    static let scannedFolders = ["UI", "Settings", "Scene/UI", "App/Menus"]
    static let scannedFiles = ["App/AppDelegate.swift", "App/AppDelegate+SceneInspector.swift", "App/SafeRestart.swift", "App/SafeRestartNotice.swift",
                               "Library/Import/ImportPanels.swift"]
    /// Data, not text: English option ids and the table that maps them to labels.
    static let exemptFiles: Set<String> = ["UI/Explorer/FilterResultsOptions.swift", "UI/Components/LocalizedLabels.swift"]
    /// The product name and people's names are never translated.
    static let allowedLiterals: Set<String> = ["Open Wallpaper Engine", "Open Wallpaper Engine \u{1}", "Haren Chen",
                                               "Chen Chia Yang", "Deepratna Awale", "Klaus Zhu"]

    static let skippedLine = try! NSRegularExpression(pattern:
        #"OWELog|forKey:|@AppStorage\(|Notification\.Name\(|fatalError\(|precondition|assert|debugDescription:|\.contains\(|hasPrefix\(|hasSuffix\(|==|!=|case "|l10n-ignore|print\(|isExpanded\(|expandedSections"#)
    static let skippedArgument = try! NSRegularExpression(pattern:
        #"(systemName|systemImage|verbatim|identifier|named|withExtension|comment|helpAnchor|forResource|path):\s*$"#)
    static let formatArgument = try! NSRegularExpression(pattern:
        #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|hh|h|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]"#)

    func testUITextComesFromTheCatalog() throws {
        let keys = try catalogKeys()
        var violations: [String] = []
        for file in try scannedSources() {
            let text = try String(contentsOf: Self.repository.appending(path: "OpenWallpaperEngine/\(file)"), encoding: .utf8)
            var inMultilineLiteral = false
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if line.components(separatedBy: "\"\"\"").count % 2 == 0 {
                    inMultilineLiteral.toggle()
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if inMultilineLiteral || trimmed.hasPrefix("//") || Self.matches(Self.skippedLine, line) { continue }
                for literal in Self.literals(in: line) {
                    if Self.matches(Self.skippedArgument, String(line[..<literal.start])) { continue }
                    let text = Self.normalized(literal.content)
                    guard Self.readsAsText(text), !Self.allowedLiterals.contains(text), !keys.contains(text) else { continue }
                    violations.append("\(file):\(index + 1): \(text.replacingOccurrences(of: "\u{1}", with: "\\(…)"))")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "UI text outside Localizable.xcstrings:\n" + violations.joined(separator: "\n"))
    }

    /// The lint itself: it finds a plain-String label and accepts localized and non-UI literals.
    func testLintRecognisesTextAndSkipsNonText() {
        XCTAssertEqual(Self.literals(in: #"Text(title.isEmpty ? "No wallpaper" : title)"#).map(\.content), ["No wallpaper"])
        XCTAssertEqual(Self.literals(in: #"Text("Delete \(name ?? "x")?")"#).map { Self.normalized($0.content) },
                       ["Delete \u{1}?"])
        XCTAssertTrue(Self.readsAsText("No wallpaper"))
        XCTAssertTrue(Self.readsAsText("Please wait."))
        XCTAssertFalse(Self.readsAsText("\u{1}:combo:\u{1}"))
        XCTAssertFalse(Self.readsAsText("project.json"))
        XCTAssertFalse(Self.readsAsText("\u{1}_musicSync"))
        XCTAssertFalse(Self.readsAsText("arrow.down.circle"))
        XCTAssertTrue(Self.matches(Self.skippedArgument, "Image(systemName: "))
    }

    // MARK: Helpers

    private func catalogKeys() throws -> Set<String> {
        let data = try Data(contentsOf: LocalizationCatalogTests.catalogURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        return Set(strings.keys.map { key in
            let range = NSRange(key.startIndex..., in: key)
            return Self.formatArgument.stringByReplacingMatches(in: key, range: range, withTemplate: "\u{1}")
                .replacingOccurrences(of: "%%", with: "%")
        })
    }

    /// Split out of the scanned files: `AppDelegate`'s extensions and the window types it had, and
    /// the Workshop views whose names don't end in "View".
    static let scannedSplitFiles = ["App/AppDelegate+Lifecycle.swift", "App/AppDelegate+Actions.swift",
                                    "App/AppDelegate+SettingsWindow.swift", "App/AppDelegate+WallpaperWindows.swift",
                                    "App/WorkshopPreviewWindow.swift",
                                    "Workshop/WorkshopItemCard.swift", "Workshop/WorkshopItemMenu.swift"]

    private func scannedSources() throws -> [String] {
        let root = Self.repository.appending(path: "OpenWallpaperEngine")
        let manager = FileManager.default
        var files: [String] = Self.scannedFiles + Self.scannedSplitFiles
        for folder in Self.scannedFolders {
            let enumerator = try XCTUnwrap(manager.enumerator(atPath: root.appending(path: folder).path))
            for case let path as String in enumerator where path.hasSuffix(".swift") {
                files.append("\(folder)/\(path)")
            }
        }
        // Workshop views are scanned; its services are not (their literals are protocol text).
        let workshop = try manager.contentsOfDirectory(atPath: root.appending(path: "Workshop").path)
        files += workshop.filter { $0.hasSuffix("View.swift") }.map { "Workshop/\($0)" }
        return files.filter { !Self.exemptFiles.contains($0) }.sorted()
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Several words, with a capitalised one or ending in punctuation: a phrase or a sentence.
    /// Interpolations don't count as words, so ids like `"\(id)_musicSync"` don't read as text.
    static func readsAsText(_ text: String) -> Bool {
        let words = text.replacingOccurrences(of: "\u{1}", with: " ").trimmingCharacters(in: .whitespaces)
        guard words.contains(" "), words.range(of: #"[A-Za-z]{2}"#, options: .regularExpression) != nil else { return false }
        return words.range(of: #"[A-Z][a-z]"#, options: .regularExpression) != nil
            || words.range(of: #"[a-z][.!?…:]$"#, options: .regularExpression) != nil
    }

    /// The single-line string literals of a line, with interpolations (and the literals nested in
    /// them) kept as written. Raw strings (`#"…"#`) are regexes here and are skipped.
    static func literals(in line: String) -> [(start: String.Index, content: String)] {
        let characters = Array(line)
        var found: [(String.Index, String)] = []
        var index = 0
        func skipLiteral(from start: Int) -> Int {
            var cursor = start + 1
            while cursor < characters.count, characters[cursor] != "\"" {
                cursor += characters[cursor] == "\\" ? 2 : 1
            }
            return cursor + 1
        }
        while index < characters.count {
            if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" { break }
            if characters[index] == "#", index + 1 < characters.count, characters[index + 1] == "\"" {
                // A raw string: skip to its closing `"#`.
                var cursor = index + 2
                while cursor + 1 < characters.count, !(characters[cursor] == "\"" && characters[cursor + 1] == "#") { cursor += 1 }
                index = cursor + 2
                continue
            }
            guard characters[index] == "\"" else { index += 1; continue }
            var cursor = index + 1
            var depth = 0
            var content = ""
            while cursor < characters.count {
                let character = characters[cursor]
                if depth == 0, character == "\\", cursor + 1 < characters.count, characters[cursor + 1] == "(" {
                    depth = 1
                    content += "\\("
                    cursor += 2
                    continue
                }
                if depth > 0 {
                    if character == "\"" {
                        let end = skipLiteral(from: cursor)
                        content += String(characters[cursor..<min(end, characters.count)])
                        cursor = end
                        continue
                    }
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1 }
                    content.append(character)
                    cursor += 1
                    continue
                }
                if character == "\\", cursor + 1 < characters.count {
                    content += String(characters[cursor...cursor + 1])
                    cursor += 2
                    continue
                }
                if character == "\"" { break }
                content.append(character)
                cursor += 1
            }
            found.append((line.index(line.startIndex, offsetBy: index), content))
            index = cursor + 1
        }
        return found
    }

    /// A literal as its key would read: interpolations become one placeholder, escapes their characters.
    static func normalized(_ literal: String) -> String {
        let characters = Array(literal)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "\\", index + 1 < characters.count else {
                result.append(character)
                index += 1
                continue
            }
            let next = characters[index + 1]
            switch next {
            case "(":
                var depth = 1
                index += 2
                while index < characters.count, depth > 0 {
                    if characters[index] == "\"" {
                        index += 1
                        while index < characters.count, characters[index] != "\"" {
                            index += characters[index] == "\\" ? 2 : 1
                        }
                    } else if characters[index] == "(" {
                        depth += 1
                    } else if characters[index] == ")" {
                        depth -= 1
                    }
                    index += 1
                }
                result += "\u{1}"
            case "u":
                if let close = characters[index...].firstIndex(of: "}"),
                   let scalar = UInt32(String(characters[(index + 3)..<close]), radix: 16).flatMap(Unicode.Scalar.init) {
                    result.unicodeScalars.append(scalar)
                    index = close + 1
                } else {
                    index += 2
                }
            case "n":
                result += "\n"
                index += 2
            case "t":
                result += "\t"
                index += 2
            default:
                result.append(next)
                index += 2
            }
        }
        return result
    }
}
