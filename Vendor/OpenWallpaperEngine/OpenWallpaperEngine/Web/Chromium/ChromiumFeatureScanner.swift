import CryptoKit
import Foundation

/// The static half of Chromium-feature detection: reads a web wallpaper's HTML and JavaScript
/// and reports the `ChromiumFeatureCatalog` APIs its code uses. Text inside string literals,
/// template literals, regular expression literals and comments is blanked first, so a page that
/// only mentions an API (a user-agent check, a comment, a message) isn't counted.
enum ChromiumFeatureScanner {
    /// Files read: the page and its scripts.
    static let scannedExtensions: Set<String> = ["html", "htm", "js", "mjs"]
    /// A file larger than this is skipped (a bundled data blob, not code anyone wrote by hand).
    static let maxFileSize = 16 << 20
    /// At most this much code is read per wallpaper, so one huge wallpaper can't stall a scan.
    static let maxTotalSize = 64 << 20
    /// At most this many files are read per wallpaper.
    static let maxFiles = 2_000

    /// The ids of the features `code` (JavaScript) uses, in catalog order.
    static func features(inJavaScript code: String) -> [String] {
        let stripped = stripLiteralsAndComments(code)
        let range = NSRange(stripped.startIndex..., in: stripped)
        return ChromiumFeatureCatalog.compiledPatterns.compactMap { entry in
            entry.patterns.contains { $0.firstMatch(in: stripped, range: range) != nil } ? entry.id : nil
        }
    }

    /// The ids of the features an HTML page's inline scripts and event handler attributes use.
    static func features(inHTML html: String) -> [String] {
        features(inJavaScript: scripts(inHTML: html).joined(separator: ";\n"))
    }

    private static let scriptElement = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"<script\b([^>]*)>([\s\S]*?)</script\s*>"#, options: [.caseInsensitive])
    private static let eventHandler = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\son[a-z]+\s*=\s*("([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])
    private static let htmlComment = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"<!--[\s\S]*?-->"#)

    /// The JavaScript in an HTML page: inline `<script>` bodies (not JSON or templates) and
    /// `on…=` attributes. Commented-out markup is ignored.
    static func scripts(inHTML html: String) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        let uncommented = htmlComment.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        let all = NSRange(uncommented.startIndex..., in: uncommented)
        var result: [String] = []
        for match in scriptElement.matches(in: uncommented, range: all) {
            guard let attributes = Range(match.range(at: 1), in: uncommented),
                  let body = Range(match.range(at: 2), in: uncommented) else { continue }
            let type = uncommented[attributes].lowercased()
            // Data blocks and templates aren't run.
            if type.contains("application/json") || type.contains("text/template") || type.contains("x-shader") {
                continue
            }
            result.append(String(uncommented[body]))
        }
        for match in eventHandler.matches(in: uncommented, range: all) {
            for group in [2, 3] {
                if let value = Range(match.range(at: group), in: uncommented) {
                    result.append(String(uncommented[value]))
                }
            }
        }
        return result
    }

    /// `code` with the contents of every string, template and regular expression literal and
    /// every comment replaced by spaces (newlines kept), so patterns only see code.
    static func stripLiteralsAndComments(_ code: String) -> String {
        let source = Array(code.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(source.count)
        var index = 0
        /// The last character that wasn't whitespace or inside a literal: decides whether `/`
        /// starts a regular expression or divides.
        var previous: Unicode.Scalar?
        var previousWord = ""
        var afterSpace = false
        func blank(_ scalar: Unicode.Scalar) -> Unicode.Scalar { scalar == "\n" ? "\n" : " " }
        let regexPrecedingWords: Set<String> = ["return", "typeof", "case", "in", "of", "new", "delete", "void",
                                                 "throw", "instanceof", "do", "else", "yield", "await"]
        while index < source.count {
            let scalar = source[index]
            let next: Unicode.Scalar? = index + 1 < source.count ? source[index + 1] : nil
            if scalar == "/" && next == "/" {
                while index < source.count && source[index] != "\n" { output.append(" "); index += 1 }
                continue
            }
            if scalar == "/" && next == "*" {
                output.append(" "); output.append(" "); index += 2
                while index < source.count && !(source[index] == "*" && index + 1 < source.count && source[index + 1] == "/") {
                    output.append(blank(source[index])); index += 1
                }
                if index < source.count { output.append(" "); output.append(" "); index += 2 }
                continue
            }
            if scalar == "\"" || scalar == "'" || scalar == "`" {
                let quote = scalar
                output.append(quote); index += 1
                while index < source.count && source[index] != quote {
                    if source[index] == "\\" && index + 1 < source.count {
                        output.append(" "); output.append(blank(source[index + 1])); index += 2
                        continue
                    }
                    // A plain string ends at a line break it can't contain.
                    if quote != "`" && source[index] == "\n" { break }
                    output.append(blank(source[index])); index += 1
                }
                if index < source.count && source[index] == quote { output.append(quote); index += 1 }
                previous = quote
                previousWord = ""
                continue
            }
            if scalar == "/" {
                let startsRegex: Bool
                if let previous {
                    startsRegex = "(,=:[!&|?{};+-*%<>~^".unicodeScalars.contains(previous)
                        || regexPrecedingWords.contains(previousWord)
                } else {
                    startsRegex = true
                }
                if startsRegex {
                    output.append("/"); index += 1
                    var inClass = false
                    while index < source.count && source[index] != "\n" {
                        let character = source[index]
                        if character == "\\" && index + 1 < source.count {
                            output.append(" "); output.append(" "); index += 2
                            continue
                        }
                        if character == "[" { inClass = true } else if character == "]" { inClass = false }
                        if character == "/" && !inClass { break }
                        output.append(" "); index += 1
                    }
                    if index < source.count && source[index] == "/" { output.append("/"); index += 1 }
                    previous = "/"
                    previousWord = ""
                    continue
                }
            }
            output.append(scalar)
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                afterSpace = true
            } else {
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" {
                    let continuesWord = !afterSpace
                        && (previous.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" } ?? false)
                    previousWord = continuesWord ? previousWord + String(scalar) : String(scalar)
                } else {
                    previousWord = ""
                }
                previous = scalar
                afterSpace = false
            }
            index += 1
        }
        return String(output)
    }

    /// What a scan of one wallpaper folder found.
    struct Result: Equatable {
        /// Changes when any scanned file is added, removed, resized or modified.
        var contentKey: String
        var features: [String]
    }

    /// The scanned files of a wallpaper folder, sorted, with their sizes and dates.
    private static func files(in directory: URL) -> [(url: URL, relativePath: String, size: Int, modified: Double)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let root = directory.standardizedFileURL.path
        var result: [(url: URL, relativePath: String, size: Int, modified: Double)] = []
        for case let url as URL in enumerator {
            guard scannedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
            result.append((url: url, relativePath: relative, size: values.fileSize ?? 0,
                           modified: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0))
            if result.count >= maxFiles { break }
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// The content key alone: cheap (file metadata only), to check a cached scan.
    static func contentKey(of directory: URL) -> String {
        contentKey(of: files(in: directory))
    }

    private static func contentKey(of files: [(url: URL, relativePath: String, size: Int, modified: Double)]) -> String {
        let lines = files.map { "\($0.relativePath)|\($0.size)|\($0.modified)" }.joined(separator: "\n")
        return Digest.hex(SHA256.hash(data: Data(lines.utf8)).prefix(8))
    }

    /// Scans every page and script in `directory`. Off the main thread: it reads files. A cap
    /// that cuts the scan short is logged.
    static func scan(directory: URL) -> Result {
        let files = files(in: directory)
        if files.count >= maxFiles {
            OWELog.debug(.web, "Feature scan of \(directory.lastPathComponent): stopped listing at \(maxFiles) files")
        }
        var found = Set<String>()
        var total = 0
        for file in files {
            guard file.size <= maxFileSize else {
                OWELog.debug(.web, "Feature scan of \(directory.lastPathComponent): skipped \(file.relativePath) (\(file.size) bytes, over \(maxFileSize))")
                continue
            }
            guard total + file.size <= maxTotalSize else {
                OWELog.debug(.web, "Feature scan of \(directory.lastPathComponent): stopped at \(file.relativePath), \(maxTotalSize) bytes read")
                break
            }
            total += file.size
            guard let data = try? Data(contentsOf: file.url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let ext = file.url.pathExtension.lowercased()
            found.formUnion(ext == "html" || ext == "htm" ? features(inHTML: text) : features(inJavaScript: text))
        }
        return Result(contentKey: contentKey(of: files), features: ChromiumFeatureCatalog.ordered(found).map(\.id))
    }
}
