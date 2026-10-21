import Foundation

/// The little of HTTP/1.1 the Wi-Fi send server speaks: a request line and headers (no body is
/// read), one response per connection, then the connection closes.
enum AndroidWiFiHTTP {
    /// A request's line and headers are refused beyond this.
    static let maximumHeaderBytes = 16 * 1024
    private static let headerEnd = Data("\r\n\r\n".utf8)

    struct Request: Equatable, Sendable {
        var method: String
        var target: String
        /// Lowercased names; a repeated header keeps its last value.
        var headers: [String: String]

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    enum Parsed: Equatable {
        /// The headers haven't all arrived.
        case incomplete
        case invalid
        case request(Request)
    }

    /// Reads the request line and headers from what the connection received so far.
    static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: headerEnd) else {
            return data.count > maximumHeaderBytes ? .invalid : .incomplete
        }
        guard end.lowerBound <= maximumHeaderBytes,
              let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              parts[1].hasPrefix("/") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .invalid }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return .request(Request(method: String(parts[0]), target: String(parts[1]), headers: headers))
    }

    /// One response: its status, headers and what follows them.
    struct Response: Equatable, Sendable {
        enum Body: Equatable, Sendable {
            case none
            case data(Data)
            /// `range` of the file at `url` (`index` in the batch, for progress).
            case file(url: URL, index: Int, range: ClosedRange<Int64>)
            /// A preview picture, read whole.
            case picture(URL)
        }

        var status: Int
        var headers: [(String, String)] = []
        var body: Body = .none

        static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body
                && lhs.headers.map { "\($0.0): \($0.1)" } == rhs.headers.map { "\($0.0): \($0.1)" }
        }

        func header(_ name: String) -> String? {
            headers.last { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }

        /// The status line and headers, with `Connection: close`.
        var head: Data {
            var text = "HTTP/1.1 \(status) \(AndroidWiFiHTTP.reason(status))\r\n"
            for (name, value) in headers + [("Connection", "close")] {
                text += "\(name): \(AndroidWiFiHTTP.headerValue(value))\r\n"
            }
            return Data((text + "\r\n").utf8)
        }

        /// A short plain-text answer (an error).
        static func text(_ status: Int, _ extra: [(String, String)] = []) -> Response {
            let body = Data("\(status) \(AndroidWiFiHTTP.reason(status))\n".utf8)
            return Response(status: status, headers: AndroidWiFiHTTP.commonHeaders + extra + [
                ("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", "\(body.count)"),
            ], body: .data(body))
        }
    }

    /// Every response's: nothing is cached or framed, and the token in the path never leaves in a
    /// Referer.
    static let commonHeaders: [(String, String)] = [
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Frame-Options", "DENY"),
    ]

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    /// A header value without line breaks or other control characters (no response splitting).
    static func headerValue(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    }

    // MARK: Ranges

    enum RangeRequest: Equatable {
        /// No usable Range: the whole file.
        case whole
        case partial(ClosedRange<Int64>)
        /// Nothing of the file is in the range.
        case unsatisfiable
    }

    /// One `bytes=` range of a file of `size` bytes (`a-b`, `a-`, `-n`). Several ranges, other
    /// units or a malformed header are ignored and the whole file is sent, as RFC 9110 allows.
    static func range(_ header: String?, size: Int64) -> RangeRequest {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        func number(_ text: String) -> Int64? {
            guard !text.isEmpty, text.count <= 18, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return nil }
            return Int64(text)
        }
        if first.isEmpty {
            guard let suffix = number(last) else { return .whole }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix)...(size - 1))
        }
        guard let start = number(first) else { return .whole }
        let end: Int64
        if last.isEmpty {
            end = size - 1
        } else {
            guard let value = number(last), value >= start else { return .whole }
            end = min(value, size - 1)
        }
        guard start < size else { return .unsatisfiable }
        return .partial(start...end)
    }
}
