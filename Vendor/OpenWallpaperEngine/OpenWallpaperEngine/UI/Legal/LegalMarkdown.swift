import Foundation

/// The block structure of the legal documents' Markdown: enough for what they use (headings,
/// paragraphs, bullet and numbered lists, block quotes, tables and rules).
enum LegalMarkdown {
    indirect enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([String])
        case quote([Block])
        case table([[String]])
        case rule
    }

    static func blocks(of text: String) -> [Block] {
        blocks(of: text.components(separatedBy: "\n"))
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^\s*(-|\*|\d+\.)\s"#, options: .regularExpression) != nil
    }

    private static func listItemText(_ line: String) -> String {
        line.replacingOccurrences(of: #"^\s*(-|\*|\d+\.)\s+"#, with: "", options: .regularExpression)
    }

    private static func blocks(of lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
            } else if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var content = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    inner.append(String(content))
                    index += 1
                }
                blocks.append(.quote(self.blocks(of: inner)))
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
                      trimmed[hashes] == " " {
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(level: level, text: String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
                index += 1
            } else if trimmed == "---" {
                blocks.append(.rule)
                index += 1
            } else if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = lines[index].trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let isSeparator = cells.allSatisfy { $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }
                    if !isSeparator { rows.append(cells) }
                    index += 1
                }
                blocks.append(.table(rows))
            } else if isListItem(line) {
                var items: [String] = []
                while index < lines.count, isListItem(lines[index]) {
                    var item = listItemText(lines[index])
                    index += 1
                    while index < lines.count, lines[index].hasPrefix("  "), !isListItem(lines[index]),
                          !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        item += " " + lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                    }
                    items.append(item)
                }
                blocks.append(.list(items))
            } else {
                var paragraph: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    if current.isEmpty || current.hasPrefix("#") || current.hasPrefix(">") || current.hasPrefix("|")
                        || current == "---" || isListItem(lines[index]) { break }
                    paragraph.append(current)
                    index += 1
                }
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
            }
        }
        return blocks
    }
}
