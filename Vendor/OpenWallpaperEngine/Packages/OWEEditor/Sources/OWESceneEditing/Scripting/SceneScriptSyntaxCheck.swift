import Foundation
import JavaScriptCore

/// A problem in a script, at a line of its source: a syntax error found before Apply, or an error
/// the running script reported.
public struct SceneScriptDiagnostic: Hashable, Sendable, Identifiable {
    public enum Severity: Sendable { case error, warning }

    /// 1-based; nil when the line isn't known.
    public let line: Int?
    public let message: String
    public let severity: Severity

    public var id: String { "\(line ?? 0):\(message)" }

    public init(line: Int?, message: String, severity: Severity = .error) {
        self.line = line
        self.message = message
        self.severity = severity
    }
}

/// Checks a script's syntax with JavaScriptCore (the engine the runtime runs it on) before it is
/// applied, so a typo shows at its line instead of disabling the script in the scene. A script is
/// an ES module (`import`, `export`); JavaScriptCore's syntax check reads classic scripts, so the
/// module statements are blanked first, keeping every other character where it was so lines and
/// columns stay the source's.
public enum SceneScriptSyntaxCheck {
    /// The syntax errors of `source` (JavaScriptCore reports the first).
    public static func diagnostics(of source: String) -> [SceneScriptDiagnostic] {
        let script = classicScript(fromModule: source)
        guard let context = JSContext() else { return [] }
        let contextRef = context.jsGlobalContextRef
        let text = JSStringCreateWithCFString(script as CFString)
        let url = JSStringCreateWithCFString("script.js" as CFString)
        defer {
            JSStringRelease(text)
            JSStringRelease(url)
        }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(contextRef, text, url, 1, &exception), let exception else { return [] }
        let error = JSValue(jsValueRef: exception, in: context)
        let line = error?.forProperty("line").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
        let message = error?.toString() ?? "SyntaxError"
        return [SceneScriptDiagnostic(line: line, message: message)]
    }

    /// `source` with `import … from '…';` statements and the `export` keywords replaced by spaces
    /// (an `export { … }` list too), so it parses as a classic script with the same layout.
    /// `export default <expression>` becomes an expression statement.
    static func classicScript(fromModule source: String) -> String {
        var text = source as NSString
        let patterns = [
            // import x from 'y'; import * as x from 'y'; import { a, b } from 'y'; import 'y';
            #"(?m)^[ \t]*import\b[^;'"]*?(?:from\s*)?(['"])[^'"\n]*\1[ \t]*;?"#,
            // export { a, b as c };
            #"(?m)^[ \t]*export\s*\{[^}]*\}[ \t]*;?"#,
            // export default
            #"(?m)^[ \t]*export\s+default\b"#,
            // export function / const / let / var / class / async
            #"(?m)^[ \t]*export\b(?=\s+(?:async\s+)?(?:function|const|let|var|class)\b)"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            let mutable = NSMutableString(string: text)
            for match in matches.reversed() {
                let original = text.substring(with: match.range)
                // `export default x` keeps an expression: `0,      x`.
                let replacement = index == 2
                    ? "0," + String(repeating: " ", count: max(0, (original as NSString).length - 2))
                    : blanked(original)
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
            text = mutable
        }
        return text as String
    }

    /// Spaces for every character but line breaks.
    private static func blanked(_ text: String) -> String {
        String(text.utf16.map { $0 == 0x0A || $0 == 0x0D ? Character(Unicode.Scalar($0)!) : " " })
    }
}
