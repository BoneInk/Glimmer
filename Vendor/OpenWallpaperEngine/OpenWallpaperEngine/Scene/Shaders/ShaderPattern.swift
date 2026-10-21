import Foundation

/// Shorthands over a precompiled `NSRegularExpression` for the shader text passes. Compiling a
/// pattern per call (`String.range(of:options: .regularExpression)`) dominated translation time.
extension NSRegularExpression {
    /// Compiles a pattern that is a literal in the source; an invalid one is a programming error.
    static func shader(_ pattern: String, options: Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("invalid shader pattern \(pattern): \(error)")
        }
    }

    /// Whether the pattern matches anywhere in `text`.
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The range of the first match in `text`.
    func firstRange(in text: String) -> Range<String.Index>? {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range, in: text) }
    }
}
