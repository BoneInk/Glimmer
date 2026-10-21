import Foundation

/// Strips Steam secrets from text before it is logged or shown.
///
/// Removes the value of any `key=` query parameter and of an `x-webapi-key` header, the account
/// name in steamcmd's `Logging in user '…'` line, plus every literal secret passed in (a password,
/// a Steam Guard code, the API key itself).
enum SteamSecretRedactor {
    static let placeholder = "<redacted>"

    private static let patterns: [NSRegularExpression] = [
        // `key=` as a query parameter or form field, but not e.g. `apikey=` or `monkey=`.
        #"(?i)(?<![A-Za-z0-9_])(key=)[^&\s"'<>,;)}\]]+"#,
        #"(?i)(x-webapi-key"?\s*[:=]\s*"?)[^\s"',}]+"#,
        // steamcmd's login line names the account: `Logging in user 'name' [U:1:…] to Steam…`.
        #"(Logging in user ')[^'\n]+"#,
    ].map { pattern in
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid redaction pattern \(pattern): \(error)")
        }
    }

    static func redact(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: placeholder)
        }
        for regex in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1\(placeholder)")
        }
        return result
    }
}
