import Foundation
import Security

/// What the Wi-Fi send server answers, decided from the request alone:
///
/// - only `GET`; any other method is 405;
/// - only paths under the share's token, `/<token>/` (the page), `/<token>/list` (what the page
///   polls), `/<token>/file/<index>` and `/<token>/preview/<index>`; a wrong token, an expired
///   one, or anything else is 404, the same answer, so a guess learns nothing;
/// - a file is the shared package numbered `index` (a number, never a path from the request),
///   with `Range` for resumed downloads.
struct AndroidWiFiRouter: Sendable {
    /// 50 random bits, base32 (10 characters).
    let token: String
    var files: [AndroidWiFiFile]
    var expiry: Date
    /// Goes up each time `files` changes, so the page knows to reload.
    var version = 0
    /// Where each page's CSP nonce comes from (`makeNonce`; tests make it fail).
    let nonceSource: @Sendable () throws -> String

    init(token: String, files: [AndroidWiFiFile], expiry: Date,
         nonceSource: @escaping @Sendable () throws -> String = AndroidWiFiRouter.makeNonce) {
        self.token = token
        self.files = files
        self.expiry = expiry
        self.nonceSource = nonceSource
    }

    /// The file numbered `index`.
    func file(_ index: Int) -> AndroidWiFiFile? { files.first { $0.index == index } }

    /// The token's alphabet: RFC 4648 base32, lower case.
    static let tokenAlphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    static let tokenLength = 10

    /// A new random token: 50 bits from the system's secure generator, as 10 base32 characters.
    /// Short enough to type, and unguessable for a 15-minute share that refuses a device after 20
    /// wrong paths and limits its requests.
    static func makeToken() throws -> String {
        let bits = try randomBytes(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return String((0..<tokenLength).map { tokenAlphabet[Int(bits >> UInt64(5 * $0) & 31)] })
    }

    /// A page's CSP nonce: 128 random bits, base64url without padding.
    static func makeNonce() throws -> String {
        try Data(randomBytes(16)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return bytes
    }

    enum Route: Equatable {
        case page
        case list
        case file(Int)
        case preview(Int)
        case notFound
        case methodNotAllowed
    }

    /// The route of `request` at `now`.
    func route(_ request: AndroidWiFiHTTP.Request, now: Date) -> Route {
        guard request.method == "GET" else { return .methodNotAllowed }
        guard now < expiry else { return .notFound }
        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard let first = parts.first, Self.equalInConstantTime(first, token) else { return .notFound }
        switch parts.count {
        case 1: return .page
        case 2 where parts[1].isEmpty: return .page
        case 2 where parts[1] == "list": return .list
        case 3:
            guard let index = Self.index(parts[2]), let file = file(index) else { return .notFound }
            switch parts[1] {
            case "file": return .file(index)
            case "preview": return file.previewURL == nil ? .notFound : .preview(index)
            default: return .notFound
            }
        default: return .notFound
        }
    }

    /// The response to `request` at `now`; a file's size and date are read when it is asked for.
    /// `downloaded` are the files the asking device downloaded whole, which the page marks.
    func response(to request: AndroidWiFiHTTP.Request, now: Date, downloaded: Set<Int> = []) -> AndroidWiFiHTTP.Response {
        switch route(request, now: now) {
        case .methodNotAllowed:
            return .text(405, [("Allow", "GET")])
        case .notFound:
            return .text(404)
        case .page:
            let nonce: String
            do {
                nonce = try nonceSource()
            } catch {
                // A guessable nonce would let injected script run, so the page isn't served without one.
                OWELog.error(.app, "Send over Wi-Fi: no CSP nonce for the page, answering 500: \(error)")
                return .text(500)
            }
            let page = AndroidWiFiPage.html(files: files, token: token, version: version, downloaded: downloaded)
            let body = Data(page.replacingOccurrences(of: AndroidWiFiPage.noncePlaceholder, with: nonce).utf8)
            return .init(status: 200, headers: AndroidWiFiHTTP.commonHeaders + [
                ("Content-Type", "text/html; charset=utf-8"),
                ("Content-Length", "\(body.count)"),
                ("Content-Security-Policy", "default-src 'none'; img-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
            ], body: .data(body))
        case .list:
            let body = Data(AndroidWiFiPage.list(version: version, downloaded: downloaded).utf8)
            return .init(status: 200, headers: AndroidWiFiHTTP.commonHeaders + [
                ("Content-Type", "application/json"), ("Content-Length", "\(body.count)"),
            ], body: .data(body))
        case .preview(let index):
            guard let url = file(index)?.previewURL, let size = Self.size(of: url) else { return .text(404) }
            return .init(status: 200, headers: AndroidWiFiHTTP.commonHeaders + [
                ("Content-Type", Self.pictureType(url)), ("Content-Length", "\(size)"),
            ], body: .picture(url))
        case .file(let index):
            guard let file = file(index) else { return .text(404) }
            return fileResponse(file, request: request)
        }
    }

    private func fileResponse(_ file: AndroidWiFiFile, request: AndroidWiFiHTTP.Request) -> AndroidWiFiHTTP.Response {
        guard let size = Self.size(of: file.url) else { return .text(404) }
        let tag = Self.entityTag(file.url, size: size)
        var headers = AndroidWiFiHTTP.commonHeaders + [
            ("Content-Type", "application/octet-stream"),
            ("Content-Disposition", Self.disposition(file.downloadName)),
            ("Accept-Ranges", "bytes"),
            ("ETag", tag),
        ]
        var rangeHeader = request.header("Range")
        // A resumed download whose file changed since gets the whole file again.
        if let ifRange = request.header("If-Range"), ifRange != tag { rangeHeader = nil }
        switch AndroidWiFiHTTP.range(rangeHeader, size: size) {
        case .whole:
            headers.append(("Content-Length", "\(size)"))
            return .init(status: 200, headers: headers, body: size > 0 ? .file(url: file.url, index: file.index, range: 0...(size - 1)) : .none)
        case .partial(let range):
            headers += [("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"),
                        ("Content-Length", "\(range.upperBound - range.lowerBound + 1)")]
            return .init(status: 206, headers: headers, body: .file(url: file.url, index: file.index, range: range))
        case .unsatisfiable:
            return .text(416, [("Content-Range", "bytes */\(size)")])
        }
    }

    // MARK: Helpers

    /// A decimal index of at most six digits.
    static func index(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 6, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// Compares every byte, so the time taken doesn't say how much of a guess was right.
    static func equalInConstantTime(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    static func size(of url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else { return nil }
            return Int64(size)
        } catch {
            OWELog.error(.app, "Send over Wi-Fi: \(url.lastPathComponent) can't be read: \(error)")
            return nil
        }
    }

    /// The file's size and modification time: a resumed download checks it with `If-Range`.
    static func entityTag(_ url: URL, size: Int64) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0 // Optional: without a date the size alone tags it.
        return "\"\(String(size, radix: 16))-\(String(Int64(date * 1000), radix: 16))\""
    }

    /// `attachment` with an ASCII fallback name and the UTF-8 one (RFC 6266, RFC 8187).
    static func disposition(_ name: String) -> String {
        let fallback = String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7F && !"\"\\%;".unicodeScalars.contains(scalar) ? Character(scalar) : "_"
        })
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x7F)))
        allowed.insert(charactersIn: "!#$&+-.^_`|~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? fallback
        return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }

    static func pictureType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
