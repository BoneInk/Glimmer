import Foundation

/// Steam HTML 工具：转义解码、标签抓取。
///
/// Steam 社区页面混用「内嵌 JSON（SSR）」与「传统 HTML 元素」两种结构，
/// 这里只做最小、可测的文本处理，不做完整 HTML 解析器。
enum SteamHTML {
    /// 解码 HTML 实体（数字实体 + 常见命名实体）。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character != "&" {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            // 查找实体结束位置（最多 12 个字符）
            var probe = text.index(after: index)
            var token = ""
            var steps = 0
            while probe < text.endIndex, text[probe] != ";", steps < 12 {
                token.append(text[probe])
                probe = text.index(after: probe)
                steps += 1
            }
            guard probe < text.endIndex, text[probe] == ";" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let end = text.index(after: probe)
            if let decoded = decodeEntityToken(token) {
                result.append(decoded)
            } else {
                result.append(contentsOf: text[index..<end])
            }
            index = end
        }
        return result
    }

    private static func decodeEntityToken(_ token: String) -> Character? {
        if token.hasPrefix("#") {
            let digits = token.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            if let value, let scalar = Unicode.Scalar(value) {
                return Character(scalar)
            }
            return nil
        }
        switch token.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        case "ndash": return "–"
        case "mdash": return "—"
        case "hellip": return "…"
        case "times": return "×"
        case "copy": return "©"
        case "reg": return "®"
        case "trade": return "™"
        case "lsquo": return "‘"
        case "rsquo": return "’"
        case "ldquo": return "“"
        case "rdquo": return "”"
        case "middot": return "·"
        case "laquo": return "«"
        case "raquo": return "»"
        default: return nil
        }
    }

    /// 去掉标签，压缩空白。
    static func stripTags(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var insideTag = false
        for character in html {
            if character == "<" {
                insideTag = true
                continue
            }
            if character == ">" {
                insideTag = false
                result.append(" ")
                continue
            }
            if !insideTag { result.append(character) }
        }
        return collapseWhitespace(decodeEntities(result))
    }

    static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提取 `id="..."` 或 `id='...'` 的 `<script>` 内容（不区分 id 大小写）。
    static func scriptContent(in html: String, id: String) -> String? {
        guard let scriptRange = firstScriptRange(in: html, id: id) else { return nil }
        return String(html[scriptRange])
    }

    private static func firstScriptRange(in html: String, id: String) -> Range<String.Index>? {
        // Case conversion can change UTF-8 length (e.g. İ -> i + combining
        // dot). Indices from a lowercased COPY cannot slice the original HTML.
        // Search case-insensitively in the same string we eventually slice.
        var searchStart = html.startIndex
        let idPattern = "\\sid\\s*=\\s*([\"'])" + NSRegularExpression.escapedPattern(for: id) + "\\1(?=\\s|/|$)"
        while let scriptStart = html.range(of: "<script", options: .caseInsensitive, range: searchStart..<html.endIndex) {
            guard let tagEnd = html.range(of: ">", range: scriptStart.upperBound..<html.endIndex) else { return nil }
            let tag = String(html[scriptStart.lowerBound..<tagEnd.lowerBound])
            let matchesID = tag.range(of: idPattern, options: [.regularExpression, .caseInsensitive]) != nil
            if matchesID {
                // 找到 </script>
                if let contentEnd = html.range(of: "</script", options: .caseInsensitive, range: tagEnd.upperBound..<html.endIndex) {
                    return tagEnd.upperBound..<contentEnd.lowerBound
                }
                return tagEnd.upperBound..<html.endIndex
            }
            searchStart = tagEnd.upperBound
        }
        return nil
    }

    /// 提取 `class="..."` 中包含给定类名的标签内部文本（第一个匹配）。
    static func elementContent(in html: String, className: String, tagLimit: Int = 60_000) -> String? {
        let pattern = "class=\"[^\"]*\\b\(NSRegularExpression.escapedPattern(for: className))\\b[^\"]*\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              let matchRange = Range(match.range, in: html) else { return nil }
        let content = html[matchRange.upperBound...].prefix(tagLimit)
        return String(content)
    }

    /// 抓取所有 `<div class="workshopTags">…</div>` 形式的「键: 值」标签块。
    static func workshopTagPairs(in html: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        let scheme = "workshopTags"
        var searchStart = html.startIndex
        while let found = html.range(of: scheme, range: searchStart..<html.endIndex) {
            // 定位该 div 的结尾
            guard let divEnd = html.range(of: ">", range: found.upperBound..<html.endIndex) else { break }
            guard let closing = html.range(of: "</div>", range: divEnd.upperBound..<html.endIndex) else { break }
            let block = String(html[divEnd.upperBound..<closing.lowerBound])
            // 键在 <span class="workshopTagsTitle">Key:&nbsp;</span>
            var key = ""
            var value = ""
            if let spanStart = block.range(of: "workshopTagsTitle"), let spanEnd = block.range(of: ">", range: spanStart.upperBound..<block.endIndex) {
                if let spanClose = block.range(of: "</span>", range: spanEnd.upperBound..<block.endIndex) {
                    key = collapseWhitespace(stripTags(String(block[spanEnd.upperBound..<spanClose.lowerBound])))
                }
            }
            if let anchorStart = block.range(of: "<a ", range: block.startIndex..<block.endIndex),
               let anchorOpenEnd = block.range(of: ">", range: anchorStart.upperBound..<block.endIndex),
               let anchorClose = block.range(of: "</a>", range: anchorOpenEnd.upperBound..<block.endIndex) {
                value = collapseWhitespace(stripTags(String(block[anchorOpenEnd.upperBound..<anchorClose.lowerBound])))
            }
            key = key.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            if !key.isEmpty || !value.isEmpty {
                pairs.append((key: key, value: value))
            }
            searchStart = closing.upperBound
        }
        return pairs
    }

    /// 抓取 `id` 属性等于给定值的元素内部文本（例如 `workshopItemTitle` / `workshopItemDescription`）。
    static func elementByIDContent(in html: String, elementID: String, limit: Int = 200_000) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "id=\"\(NSRegularExpression.escapedPattern(for: elementID))\"[^>]*>",
            options: [.caseInsensitive]
        ) else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              let matchRange = Range(match.range, in: html) else { return nil }
        let tail = html[matchRange.upperBound...].prefix(limit)
        // 截到下一个同层 div 结束的保守做法：取到第一个 "</div>"（详情页字段是纯文本）。
        if let closing = tail.range(of: "</div>") {
            return String(tail[tail.startIndex..<closing.lowerBound])
        }
        return String(tail)
    }

    /// 用正则捕获第一个匹配组。
    static func firstMatch(in text: String, pattern: String, group: Int = 1, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > group,
              let matchRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[matchRange])
    }
}
