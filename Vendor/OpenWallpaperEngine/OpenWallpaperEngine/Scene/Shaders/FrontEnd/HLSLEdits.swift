import Foundation

/// Text edits of the HLSL front end, by UTF-16 offset into the original text. Conversions wrap an
/// expression in a prefix and a suffix; inner expressions are converted first, so at one offset an
/// outer prefix goes before an inner one and an outer suffix after an inner one.
struct HLSLEdits {
    enum Kind: Int {
        case suffix, prefix, replacement
    }

    struct Edit {
        let start: Int
        let end: Int
        let kind: Kind
        let text: String
        let order: Int
    }

    private(set) var list: [Edit] = []
    private var next = 0
    /// Edits before this offset (the prelude) are dropped.
    let editableFrom: Int

    init(editableFrom: Int) {
        self.editableFrom = editableFrom
    }

    var count: Int { list.count }

    mutating func prefix(_ offset: Int, _ text: String) { add(Edit(start: offset, end: offset, kind: .prefix, text: text, order: next)) }
    mutating func suffix(_ offset: Int, _ text: String) { add(Edit(start: offset, end: offset, kind: .suffix, text: text, order: next)) }
    mutating func replace(_ start: Int, _ end: Int, _ text: String) {
        add(Edit(start: start, end: end, kind: .replacement, text: text, order: next))
    }

    /// Wraps `start..<end` in `prefix` and `suffix`.
    mutating func wrap(_ start: Int, _ end: Int, _ prefix: String, _ suffix: String) {
        self.prefix(start, prefix)
        self.suffix(end, suffix)
    }

    /// Drops the edits made since `count` was `mark` (a statement that couldn't be typed).
    mutating func rollBack(to mark: Int) {
        if list.count > mark { list.removeLast(list.count - mark) }
    }

    private mutating func add(_ edit: Edit) {
        next += 1
        guard edit.start >= editableFrom else { return }
        list.append(edit)
    }

    /// `code[start..<end]` with the edits inside it applied; with `consume` they are removed, for a
    /// replacement of the whole range that contains them.
    mutating func render(_ code: [UInt16], _ start: Int, _ end: Int, consume: Bool) -> String {
        let inside = list.filter { $0.start >= start && $0.end <= end && !($0.kind == .suffix && $0.start == start)
            && !($0.kind == .prefix && $0.start == end) }
        if consume {
            let orders = Set(inside.map(\.order))
            list.removeAll { orders.contains($0.order) }
        }
        return String(decoding: Self.apply(inside, to: code, from: start, to: end), as: UTF16.self)
    }

    func apply(to code: [UInt16]) -> [UInt16] {
        Self.apply(list, to: code, from: 0, to: code.count)
    }

    private static func apply(_ edits: [Edit], to code: [UInt16], from start: Int, to end: Int) -> [UInt16] {
        let ordered = edits.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            // Suffixes: inner (earlier) first. Prefixes: outer (later) first.
            return a.kind == .prefix ? a.order > b.order : a.order < b.order
        }
        var result: [UInt16] = []
        result.reserveCapacity(end - start + edits.count * 8)
        var copied = start
        for edit in ordered {
            guard edit.start >= copied else { continue } // inside a replaced range
            result.append(contentsOf: code[copied..<edit.start])
            result.append(contentsOf: edit.text.utf16)
            copied = edit.kind == .replacement ? edit.end : edit.start
        }
        if copied < end { result.append(contentsOf: code[copied..<end]) }
        return result
    }
}
