import Foundation

/// Turns the small HTML subset WE allows in property labels (`<b>`, `<font>`, `<br>`, `<a>`,
/// `<img>` …) into plain text with line breaks and clickable links. Styling is dropped.
enum UserPropertyHTML {
    struct Segment: Equatable {
        var text: String
        var link: URL?
    }

    /// Plain text, tags removed and entities decoded.
    static func plainText(_ html: String) -> String {
        segments(html).map(\.text).joined()
    }

    static func attributed(_ html: String) -> AttributedString {
        var result = AttributedString()
        for segment in segments(html) {
            var part = AttributedString(segment.text)
            if let link = segment.link { part.link = link }
            result += part
        }
        return result
    }

    static func containsMarkup(_ text: String) -> Bool {
        text.range(of: #"<[a-zA-Z/!][^>]*>|&[a-zA-Z#0-9]+;"#, options: .regularExpression) != nil
    }

    static func segments(_ html: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var currentLink: URL?
        var linkHadText = false

        func flush() {
            guard !current.isEmpty else { return }
            let text = decodeEntities(current)
            if let last = segments.last, last.link == currentLink {
                segments[segments.count - 1].text += text
            } else {
                segments.append(Segment(text: text, link: currentLink))
            }
            if currentLink != nil { linkHadText = true }
            current = ""
        }

        var index = html.startIndex
        while index < html.endIndex {
            let c = html[index]
            guard c == "<", let close = html[index...].firstIndex(of: ">") else {
                current.append(c)
                index = html.index(after: index)
                continue
            }
            let tag = String(html[html.index(after: index)..<close])
            index = html.index(after: close)
            let name = tag.trimmingCharacters(in: .whitespaces)
                .prefix { $0.isLetter || $0.isNumber || $0 == "/" }.lowercased()
            switch name {
            case "br", "br/":
                current.append("\n")
            case "p", "/p", "div", "/div", "li":
                let atLineStart = current.isEmpty
                    ? (segments.last?.text.hasSuffix("\n") ?? true)
                    : current.hasSuffix("\n")
                if !atLineStart {
                    current.append("\n")
                }
            case "a":
                flush()
                currentLink = attribute("href", in: tag).flatMap { URL(string: $0) }
                    .flatMap { ["http", "https", "mailto"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
                linkHadText = false
            case "/a":
                flush()
                // An image-only link (a badge) still gets something to click.
                if let link = currentLink, !linkHadText {
                    segments.append(Segment(text: link.host ?? link.absoluteString, link: link))
                }
                currentLink = nil
            default:
                break
            }
        }
        flush()
        // Collapse the trailing/leading newlines authors pile up.
        if var first = segments.first {
            first.text = String(first.text.drop { $0 == "\n" })
            segments[0] = first
        }
        if var last = segments.last {
            while last.text.hasSuffix("\n") { last.text.removeLast() }
            segments[segments.count - 1] = last
        }
        return segments.filter { !$0.text.isEmpty }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result),
                      let hexRange = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[digits], radix: result[hexRange].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Slider semantics from project.json, as WE's browse sidebar applies them
/// (`ui/dist/scripts/scripts.js`: `rzslider … step:property.step||1, precision:property.precision||1`).
/// `fraction:false` means whole numbers; WE's editor then drops `step` and `precision`.
struct UserPropertySliderFormat: Equatable {
    var minimum: Double
    var maximum: Double
    var fraction: Bool = true
    var step: Double?
    var precision: Int?

    /// Snap step: the authored step, else 1, as in WE.
    var effectiveStep: Double {
        if let step, step > 0 { return step }
        return 1
    }

    /// Decimals shown. WE's editor saves `precision` as the decimals plus one (it adds 1 on save
    /// and derives `step = 0.1^(precision-1)`), so precision 3 is a 0.01 slider.
    var fractionDigits: Int {
        if !fraction { return 0 }
        return max(0, min((precision ?? 1) - 1, 6))
    }

    func snap(_ value: Double) -> Double {
        var result = min(max(value, minimum), max(maximum, minimum))
        let step = effectiveStep
        result = minimum + ((result - minimum) / step).rounded() * step
        result = min(max(result, minimum), max(maximum, minimum))
        if !fraction { result = result.rounded() }
        return result
    }

    /// The stored string: integers without a decimal point so scripts reading them see "30".
    func storedString(_ value: Double) -> String {
        let snapped = snap(value)
        if !fraction { return String(Int(saturating: snapped)) }
        // Remove float noise from the step multiplication (0.1 * 3 = 0.30000000000000004).
        let decimals = Int(saturating: (-log10(effectiveStep)).rounded(.up), in: -1...9) + 1
        let factor = pow(10, Double(decimals))
        return String((snapped * factor).rounded() / factor)
    }
}
