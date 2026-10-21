import Foundation

/// The script editor's edits of a script's text, as WE's editor makes them (`scripteditor`
/// directive: Snippets › Insert Function / Insert Property / Import Base Module, Edit › Format
/// Document / Comment Selection / Uncomment Selection). Pure text in, text out; selections are
/// UTF-16 ranges (`NSString`'s, as the text view has them).
public enum SceneScriptSourceEdits {
    // MARK: Insert Function

    /// The callbacks WE's Insert Function menu adds, in its order (dividers between the groups).
    public enum Callback: String, CaseIterable, Sendable {
        case initialize = "init", update, resizeScreen, applyUserProperties, applyGeneralSettings, destroy, animationEvent
        case cursorEnter, cursorLeave, cursorMove, cursorClick, cursorDown, cursorUp
        case mediaStatusChanged, mediaPlaybackChanged, mediaPropertiesChanged, mediaThumbnailChanged, mediaTimelineChanged

        public var name: String { rawValue }

        /// The menu's groups: the script's life, the cursor, media.
        public static let groups: [[Callback]] = [
            [.initialize, .update, .resizeScreen, .applyUserProperties, .applyGeneralSettings, .destroy, .animationEvent],
            [.cursorEnter, .cursorLeave, .cursorMove, .cursorClick, .cursorDown, .cursorUp],
            [.mediaStatusChanged, .mediaPlaybackChanged, .mediaPropertiesChanged, .mediaThumbnailChanged, .mediaTimelineChanged],
        ]
    }

    /// `text` with an empty `callback` added at its end, documented as WE documents it; unchanged
    /// when the script exports it already. `valueType` is the bound field's JSDoc type (`Vec3`,
    /// `Number`…) for `init`, `update` and `animationEvent`.
    public static func inserting(_ callback: Callback, into text: String, valueType: String? = nil) -> String {
        guard !exports(callback.name, in: text) else { return text }
        let type = valueType ?? "*"
        let snippet: String
        switch callback {
        case .initialize:
            snippet = doc(["@param {\(type)} value - the field's value", "@return {\(type)} the value to start with"])
                + "export function init(value) {\n\treturn value;\n}\n"
        case .update:
            snippet = doc(["@param {\(type)} value - the field's value", "@return {\(type)} the value for this frame"])
                + "export function update(value) {\n\treturn value;\n}\n"
        case .resizeScreen:
            snippet = doc(["@param {Vec2} size"]) + "export function resizeScreen(size) {\n\t\n}\n"
        case .applyUserProperties:
            snippet = doc(["@param {Object} changedUserProperties - only the user properties that changed"])
                + "export function applyUserProperties(changedUserProperties) {\n\t\n}\n"
        case .applyGeneralSettings:
            snippet = doc(["@param {Object} generalSettings"]) + "export function applyGeneralSettings(generalSettings) {\n\t\n}\n"
        case .destroy:
            snippet = "export function destroy() {\n\t\n}\n"
        case .animationEvent:
            snippet = doc(["@param {AnimationEvent} event - the event", "@param {\(type)} value - the field's value",
                           "@return {\(type)} the field's value"])
                + "export function animationEvent(event, value) {\n\treturn value;\n}\n"
        case .cursorEnter, .cursorLeave, .cursorMove, .cursorClick, .cursorDown, .cursorUp:
            snippet = doc(["@param {CursorEvent} event"]) + "export function \(callback.name)(event) {\n\t\n}\n"
        case .mediaStatusChanged:
            snippet = doc(["@param {MediaStatusEvent} event"]) + "export function mediaStatusChanged(event) {\n\t\n}\n"
        case .mediaPlaybackChanged:
            snippet = doc(["@param {MediaPlaybackEvent} event"]) + "export function mediaPlaybackChanged(event) {\n\t\n}\n"
        case .mediaPropertiesChanged:
            snippet = doc(["@param {MediaPropertiesEvent} event"]) + "export function mediaPropertiesChanged(event) {\n\t\n}\n"
        case .mediaThumbnailChanged:
            snippet = doc(["@param {MediaThumbnailEvent} event"]) + "export function mediaThumbnailChanged(event) {\n\t\n}\n"
        case .mediaTimelineChanged:
            snippet = doc(["@param {MediaTimelineEvent} event"]) + "export function mediaTimelineChanged(event) {\n\t\n}\n"
        }
        var result = text
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        return result + "\n" + snippet
    }

    /// Whether the script exports a function `name` (outside comments and strings).
    public static func exports(_ name: String, in text: String) -> Bool {
        let code = codeOnly(text)
        guard let regex = try? NSRegularExpression(pattern: #"\bexport\s+(?:async\s+)?function\s+"# + name + #"\s*\("#) else {
            return false
        }
        return regex.firstMatch(in: code, range: NSRange(location: 0, length: (code as NSString).length)) != nil
    }

    private static func doc(_ lines: [String]) -> String {
        "/**\n" + lines.map { " * \($0)\n" }.joined() + " */\n"
    }

    // MARK: Insert Property

    /// The script property kinds WE's Insert Property menu adds, in its order.
    public enum PropertyKind: String, CaseIterable, Sendable {
        case slider, checkbox, text, color, combo

        var baseName: String {
            switch self {
            case .slider: return "newSlider"
            case .checkbox: return "newCheckbox"
            case .text: return "newText"
            case .color: return "newColor"
            case .combo: return "newCombo"
            }
        }
    }

    static let propertiesStart = "export var scriptProperties = createScriptProperties()"
    static let propertiesEnd = "\t.finish();"

    /// `text` with a property of `kind` declared: added before `.finish()` of its
    /// `createScriptProperties()` chain, or a new chain after `'use strict';` and the imports, as
    /// WE's editor inserts one. The name is unique among the declared properties.
    public static func inserting(_ kind: PropertyKind, into text: String) -> String {
        let taken = Set(SceneScriptPropertyDeclaration.declarations(in: text).map(\.name))
        var name = kind.baseName
        var number = 2
        while taken.contains(name) { name = kind.baseName + String(number); number += 1 }
        let builder = builder(kind, name: name)
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.contains(propertiesStart) }),
           let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".finish()") }) {
            lines.insert(builder, at: end)
            return lines.joined(separator: "\n")
        }
        let at = headerEnd(of: lines)
        lines.insert(contentsOf: ["", propertiesStart, builder, propertiesEnd], at: at)
        return lines.joined(separator: "\n")
    }

    static func builder(_ kind: PropertyKind, name: String) -> String {
        switch kind {
        case .slider:
            return "\t.addSlider({ name: '\(name)', label: 'New Slider', value: 0.5, min: 0, max: 1, integer: false })"
        case .checkbox:
            return "\t.addCheckbox({ name: '\(name)', label: 'New Checkbox', value: false })"
        case .text:
            return "\t.addText({ name: '\(name)', label: 'New Text', value: '' })"
        case .color:
            return "\t.addColor({ name: '\(name)', label: 'New Color', value: new Vec3(1, 1, 1) })"
        case .combo:
            return "\t.addCombo({ name: '\(name)', label: 'New Combo', options: [{ label: 'First', value: 'first' }, { label: 'Second', value: 'second' }] })"
        }
    }

    /// The line after the script's leading blank lines, `'use strict';` and imports.
    static func headerEnd(of lines: [String]) -> Int {
        var index = 0
        func skipBlank() { while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 } }
        skipBlank()
        if index < lines.count, isUseStrict(lines[index]) {
            index += 1
            let afterStrict = index
            skipBlank()
            if index < lines.count, lines[index].hasPrefix("import ") {
                while index < lines.count, lines[index].hasPrefix("import ") { index += 1 }
            } else {
                index = afterStrict
            }
        } else if index < lines.count, lines[index].hasPrefix("import ") {
            while index < lines.count, lines[index].hasPrefix("import ") { index += 1 }
        } else {
            index = 0
        }
        return index
    }

    private static func isUseStrict(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "'use strict';" || trimmed == "\"use strict\";" || trimmed == "'use strict'"
    }

    // MARK: Import Base Module

    /// WE's base modules (`assets/scripts/jsmodules`), as Import Base Module lists them.
    public static let baseModules = ["WEColor", "WEMath", "WEVector"]

    /// `text` importing `module` (`import * as WEMath from 'WEMath';`): after the other imports,
    /// else after `'use strict';`; unchanged when it imports it already.
    public static func importing(_ module: String, into text: String) -> String {
        let statement = "import * as \(module) from '\(module)';"
        guard !text.contains(statement) else { return text }
        var lines = text.components(separatedBy: "\n")
        if let last = lines.lastIndex(where: { $0.hasPrefix("import ") }) {
            lines.insert(statement, at: last + 1)
            return lines.joined(separator: "\n")
        }
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        if index < lines.count, isUseStrict(lines[index]) {
            lines.insert(contentsOf: ["", statement], at: index + 1)
        } else {
            lines.insert(contentsOf: [statement, ""], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Format Document

    /// The script re-indented with tabs: one level per line that leaves a bracket open (however
    /// many it opens), a method chain's `.` lines one level in, trailing spaces removed and runs of
    /// blank lines kept to one. Lines inside a template literal or a block comment stay as they are.
    public static func formatted(_ text: String) -> String {
        let source = text as NSString
        var lineStarts: [Int] = [0]
        for index in 0..<source.length where source.character(at: index) == 0x0A { lineStarts.append(index + 1) }
        func line(of location: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
            }
            return low
        }
        /// Per line, its brackets in order (true: opens), and how many closers start it.
        var brackets = [[Bool]](repeating: [], count: lineStarts.count)
        var leadingCloses = [Int](repeating: 0, count: lineStarts.count)
        var leading = [Bool](repeating: true, count: lineStarts.count)
        var verbatim = Set<Int>()
        for token in JavaScriptTokenizer.tokens(in: text) {
            let first = line(of: token.range.location)
            if token.kind == .template || token.kind == .blockComment || token.kind == .string {
                let last = line(of: max(token.range.location, NSMaxRange(token.range) - 1))
                if last > first { for inner in (first + 1)...last { verbatim.insert(inner) } }
            }
            let character = token.kind == .punctuation ? source.character(at: token.range.location) : 0
            switch character {
            case 0x7B, 0x5B, 0x28: // { [ (
                brackets[first].append(true)
                leading[first] = false
            case 0x7D, 0x5D, 0x29: // } ] )
                brackets[first].append(false)
                if leading[first] { leadingCloses[first] += 1 }
            default:
                leading[first] = false
            }
        }
        /// The line of each open bracket; a line's level is how many lines have one open.
        var open: [Int] = []
        func level() -> Int {
            var lines = 0
            var previous: Int?
            for opener in open where opener != previous {
                lines += 1
                previous = opener
            }
            return lines
        }
        func apply(_ events: ArraySlice<Bool>, line number: Int) {
            for opens in events {
                if opens { open.append(number) } else if !open.isEmpty { open.removeLast() }
            }
        }
        var output: [String] = []
        var blankRun = 0
        /// The level a method chain started at, while it lasts.
        var chainLevel: Int?
        for (number, start) in lineStarts.enumerated() {
            let end = number + 1 < lineStarts.count ? lineStarts[number + 1] - 1 : source.length
            let raw = source.substring(with: NSRange(location: start, length: max(0, end - start)))
            if verbatim.contains(number) {
                output.append(raw)
                blankRun = 0
                apply(brackets[number][...], line: number)
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun <= 1 { output.append("") }
                continue
            }
            blankRun = 0
            let closers = leadingCloses[number]
            // A chain ends at a line of its own level that doesn't continue it.
            if let chain = chainLevel, level() <= chain, !trimmed.hasPrefix(".") { chainLevel = nil }
            apply(brackets[number].prefix(closers), line: number)
            let base = level()
            if chainLevel == nil, trimmed.hasPrefix(".") { chainLevel = base }
            output.append(String(repeating: "\t", count: base + (chainLevel == nil ? 0 : 1)) + trimmed)
            apply(brackets[number].dropFirst(closers), line: number)
            if let chain = chainLevel, level() <= chain, trimmed.hasSuffix(";") { chainLevel = nil }
        }
        return output.joined(separator: "\n")
    }

    // MARK: Comment Selection

    /// The lines `selection` touches commented with `// ` at their shallowest indentation, and the
    /// selection over the same lines.
    public static func commenting(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        editLines(text, selection: selection) { lines in
            let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(indentation)
            let column = indents.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let index = line.index(line.startIndex, offsetBy: column)
                return String(line[..<index]) + "// " + String(line[index...])
            }
        }
    }

    /// The lines `selection` touches with one leading `//` (and the space after it) removed.
    public static func uncommenting(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        editLines(text, selection: selection) { lines in
            lines.map { line in
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                var rest = line.dropFirst(indent.count)
                guard rest.hasPrefix("//") else { return line }
                rest = rest.dropFirst(2)
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                return String(indent) + String(rest)
            }
        }
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func editLines(_ text: String, selection: NSRange,
                                  _ change: ([String]) -> [String]) -> (text: String, selection: NSRange) {
        let source = text as NSString
        let clamped = NSRange(location: min(selection.location, source.length),
                              length: min(selection.length, max(0, source.length - selection.location)))
        // A selection ending at a line's start doesn't take that line.
        var covered = clamped
        if covered.length > 0, NSMaxRange(covered) <= source.length, NSMaxRange(covered) > 0,
           source.character(at: NSMaxRange(covered) - 1) == 0x0A {
            covered.length -= 1
        }
        var range = source.lineRange(for: covered)
        // Keep the final newline out of the edited lines.
        if range.length > 0, source.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
        let lines = source.substring(with: range).components(separatedBy: "\n")
        let replaced = change(lines).joined(separator: "\n")
        let result = source.replacingCharacters(in: range, with: replaced)
        return (result, NSRange(location: range.location, length: (replaced as NSString).length))
    }

    // MARK: Helpers

    /// The source with comments and strings blanked (same length), for searches in code alone.
    static func codeOnly(_ text: String) -> String {
        let source = NSMutableString(string: text)
        for token in JavaScriptTokenizer.tokens(in: text)
        where [.lineComment, .blockComment, .string, .template, .regex].contains(token.kind) {
            let blank = String(repeating: " ", count: token.range.length)
            source.replaceCharacters(in: token.range, with: blank)
        }
        return source as String
    }
}
