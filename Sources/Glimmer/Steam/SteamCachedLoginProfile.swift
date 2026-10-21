import Foundation
import Darwin

/// Bounded, read-only VDF discovery. Returned account names are transient stdin
/// arguments only; neither this parser nor its callers log cache contents.
enum SteamCachedLoginProfile {
    static func read(_ url: URL, layout: SteamCMDLayout) -> Data? {
        guard layout.isSafeProfileLocation(url) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 2 * 1024 * 1024 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer in
            Darwin.read(fd, buffer.baseAddress, buffer.count)
        }
        guard count == data.count else { return nil }
        return data
    }
    static func accountName(layout: SteamCMDLayout) -> String? {
        for url in layout.loginCacheFiles {
            guard let data = read(url, layout: layout), let text = String(data: data, encoding: .utf8) else { continue }
            if let candidate = parse(text) { return candidate }
        }
        return nil
    }
    private enum Token { case word(String), left, right }
    /// Structural paths matter: unrelated AccountName/Accounts keys are ignored.
    static func parse(_ text: String) -> String? {
        let chars = Array(text.utf8)
        guard chars.count <= 2 * 1024 * 1024 else { return nil }
        var tokens: [Token] = [], i = 0
        while i < chars.count {
            let c = chars[i]
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
            if c == 47, i + 1 < chars.count, chars[i + 1] == 47 {
                while i < chars.count && chars[i] != 10 { i += 1 }; continue
            }
            if c == 123 { tokens.append(.left); i += 1 }
            else if c == 125 { tokens.append(.right); i += 1 }
            else {
                var bytes: [UInt8] = []
                if c == 34 {
                    i += 1; var closed = false
                    while i < chars.count {
                        let next = chars[i]; i += 1
                        if next == 34 { closed = true; break }
                        if next == 92 {
                            guard i < chars.count else { return nil }
                            bytes.append(chars[i]); i += 1
                        } else { bytes.append(next) }
                    }
                    guard closed else { return nil }
                } else {
                    while i < chars.count, ![UInt8(32),9,10,13,123,125].contains(chars[i]) {
                        bytes.append(chars[i]); i += 1
                    }
                }
                guard let word = String(bytes: bytes, encoding: .utf8), !word.contains("\0") else { return nil }
                tokens.append(.word(word))
            }
            guard tokens.count <= 100_000 else { return nil }
        }
        var index = 0, candidates: [String] = []
        let accounts = ["installconfigstore", "software", "valve", "steam", "accounts"]
        func object(_ path: [String], nested: Bool) -> Bool {
            guard path.count <= 32 else { return false }
            while index < tokens.count {
                if case .right = tokens[index] { index += 1; return nested }
                guard case .word(let key) = tokens[index] else { return false }
                index += 1; guard index < tokens.count else { return false }
                switch tokens[index] {
                case .left:
                    index += 1
                    if path == accounts, SteamCMDCredentialPolicy.isValidAccountName(key) { candidates.append(key) }
                    guard object(path + [key.lowercased()], nested: true) else { return false }
                case .word(let value):
                    index += 1
                    if path.count == 2, path.first == "users", key.lowercased() == "accountname",
                       SteamCMDCredentialPolicy.isValidAccountName(value) { candidates.append(value) }
                case .right: return false
                }
            }
            return !nested
        }
        guard object([], nested: false), index == tokens.count else { return nil }
        return candidates.last
    }
}
