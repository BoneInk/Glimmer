import AppKit
import CoreImage
import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// "Send over Wi-Fi": the router's token, method and index rules, ranges, the phone's page, the
/// QR code, and the real listener on loopback (tests only; the app never listens there) driven by
/// URLSession, including its expiry.
@MainActor
final class AndroidWiFiSendTests: XCTestCase {
    private var directory: URL!
    private let token = "abcdefgh23"
    private static let loopback = AndroidLANAddress(interface: "lo0", displayName: nil, address: 0x7F00_0001, netmask: 0xFF00_0000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-wifi-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    /// Two packages (the first with a preview) of known bytes.
    private func files() throws -> [AndroidWiFiFile] {
        let first = directory.appending(path: "Rain.mpkg"), second = directory.appending(path: "City.mpkg")
        let preview = directory.appending(path: "preview.jpg")
        try Data((0..<1000).map { UInt8($0 % 251) }).write(to: first)
        try Data(repeating: 7, count: 300_000).write(to: second)
        try Data([0xFF, 0xD8, 0xFF]).write(to: preview)
        return [
            AndroidWiFiFile(index: 0, title: "Rain <b>& \"Snow\"", kind: .sceneDynamic, url: first, size: 1000, previewURL: preview,
                            downloadName: "Rain & Snow.mpkg"),
            AndroidWiFiFile(index: 1, title: "City", kind: .video, url: second, size: 300_000, previewURL: nil, downloadName: "City.mpkg"),
        ]
    }

    private func request(_ target: String, method: String = "GET", headers: [String: String] = [:]) -> AndroidWiFiHTTP.Request {
        AndroidWiFiHTTP.Request(method: method, target: target, headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }))
    }

    // MARK: Router

    func testTokensAreRandom50BitBase32AndCheckedWhole() throws {
        let made = (0..<200).map { _ in try? AndroidWiFiRouter.makeToken() }.compactMap { $0 }
        XCTAssertEqual(made.count, 200)
        XCTAssertEqual(Set(made).count, 200, "random")
        for token in made {
            XCTAssertEqual(token.count, 10, "50 bits, 5 per character")
            XCTAssertTrue(token.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) }, token)
        }
        XCTAssertEqual(Set(made.joined()).count, 32, "the whole alphabet comes up")
        let router = AndroidWiFiRouter(token: token, files: try files(), expiry: .distantFuture)
        XCTAssertEqual(router.route(request("/\(token)/"), now: Date()), .page)
        XCTAssertEqual(router.route(request("/\(token)"), now: Date()), .page)
        for wrong in ["/", "/abcdefgh22/", "/abcdefgh2/", "/\(token)a/", "/\(token.uppercased())/", "/favicon.ico"] {
            XCTAssertEqual(router.route(request(wrong), now: Date()), .notFound, wrong)
            XCTAssertEqual(router.response(to: request(wrong), now: Date()).status, 404, wrong)
        }
    }

    /// Without a random nonce the page isn't served (a fixed one would weaken its CSP): 500, plain text.
    func testThePageFailsWithoutANonce() throws {
        struct NoRandom: Error {}
        let router = AndroidWiFiRouter(token: token, files: try files(), expiry: .distantFuture,
                                       nonceSource: { throw NoRandom() })
        let response = router.response(to: request("/\(token)/"), now: Date())
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(response.header("Content-Type"), "text/plain; charset=utf-8")
        XCTAssertNil(response.header("Content-Security-Policy"))
        XCTAssertEqual(response.body, .data(Data("500 Internal Server Error\n".utf8)))
        XCTAssertEqual(router.response(to: request("/\(token)/list"), now: Date()).status, 200, "only the page needs a nonce")
        let working = AndroidWiFiRouter(token: token, files: try files(), expiry: .distantFuture, nonceSource: { "n0nce" })
        XCTAssertEqual(working.response(to: request("/\(token)/"), now: Date()).header("Content-Security-Policy")?
            .contains("script-src 'nonce-n0nce'"), true)
    }

    func testAnExpiredTokenIsNotFound() throws {
        let expiry = Date()
        let router = AndroidWiFiRouter(token: token, files: try files(), expiry: expiry)
        XCTAssertEqual(router.route(request("/\(token)/file/0"), now: expiry.addingTimeInterval(-1)), .file(0))
        XCTAssertEqual(router.route(request("/\(token)/file/0"), now: expiry), .notFound)
        XCTAssertEqual(router.response(to: request("/\(token)/"), now: expiry.addingTimeInterval(60)).status, 404)
    }

    func testOnlyGETIsAccepted() throws {
        let router = AndroidWiFiRouter(token: token, files: try files(), expiry: .distantFuture)
        for method in ["POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "CONNECT", "TRACE"] {
            let response = router.response(to: request("/\(token)/file/0", method: method), now: Date())
            XCTAssertEqual(response.status, 405, method)
            XCTAssertEqual(response.header("Allow"), "GET")
        }
        XCTAssertEqual(router.response(to: request("/\(token)/file/0"), now: Date()).status, 200)
    }

    func testFilesAreServedByIndexOnly() throws {
        let router = AndroidWiFiRouter(token: token, files: try files(), expiry: .distantFuture)
        XCTAssertEqual(router.route(request("/\(token)/file/1"), now: Date()), .file(1))
        XCTAssertEqual(router.route(request("/\(token)/preview/0"), now: Date()), .preview(0))
        XCTAssertEqual(router.route(request("/\(token)/preview/1"), now: Date()), .notFound, "no preview")
        for target in ["/\(token)/file/2", "/\(token)/file/-1", "/\(token)/file/01x", "/\(token)/file/../../etc/passwd",
                       "/\(token)/file/%2e%2e%2fetc%2fpasswd", "/\(token)/file/Rain.mpkg", "/\(token)/../\(token)/file/0",
                       "/\(token)/file/0/", "/\(token)/file/9999999", "/\(token)/file/", "/\(token)//file/0", "/\(token)/files/0",
                       "/\(token)/file/\(directory.appending(path: "Rain.mpkg").path)"] {
            XCTAssertEqual(router.route(request(target), now: Date()), .notFound, target)
        }
        let response = router.response(to: request("/\(token)/file/0?x=1"), now: Date())
        XCTAssertEqual(response.body, .file(url: directory.appending(path: "Rain.mpkg"), index: 0, range: 0...999))
        XCTAssertEqual(response.header("Content-Type"), "application/octet-stream")
        XCTAssertEqual(response.header("Content-Length"), "1000")
        XCTAssertEqual(response.header("Accept-Ranges"), "bytes")
        XCTAssertEqual(response.header("Content-Disposition"),
                       "attachment; filename=\"Rain & Snow.mpkg\"; filename*=UTF-8''Rain%20&%20Snow.mpkg")
        XCTAssertEqual(AndroidWiFiRouter.disposition("Ünicode \"x\".mpkg"),
                       "attachment; filename=\"_nicode _x_.mpkg\"; filename*=UTF-8''%C3%9Cnicode%20%22x%22.mpkg")
    }

    func testRangeRequests() throws {
        XCTAssertEqual(AndroidWiFiHTTP.range("bytes=0-99", size: 1000), .partial(0...99))
        XCTAssertEqual(AndroidWiFiHTTP.range("bytes=500-", size: 1000), .partial(500...999))
        XCTAssertEqual(AndroidWiFiHTTP.range("bytes=-100", size: 1000), .partial(900...999))
        XCTAssertEqual(AndroidWiFiHTTP.range("bytes=-5000", size: 1000), .partial(0...999))
        XCTAssertEqual(AndroidWiFiHTTP.range("bytes=900-5000", size: 1000), .partial(900...999))
        XCTAssertEqual(AndroidWiFiHTTP.range("bytes=1000-", size: 1000), .unsatisfiable)
        XCTAssertEqual(AndroidWiFiHTTP.range("bytes=-0", size: 1000), .unsatisfiable)
        for ignored in [nil, "", "items=0-1", "bytes=0-1,5-6", "bytes=5-1", "bytes=a-b", "bytes=-"] {
            XCTAssertEqual(AndroidWiFiHTTP.range(ignored, size: 1000), .whole, ignored ?? "nil")
        }
        let router = AndroidWiFiRouter(token: token, files: try files(), expiry: .distantFuture)
        let partial = router.response(to: request("/\(token)/file/0", headers: ["Range": "bytes=100-199"]), now: Date())
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(partial.header("Content-Range"), "bytes 100-199/1000")
        XCTAssertEqual(partial.header("Content-Length"), "100")
        let tag = try XCTUnwrap(partial.header("ETag"))
        let resumed = router.response(to: request("/\(token)/file/0", headers: ["Range": "bytes=100-", "If-Range": tag]), now: Date())
        XCTAssertEqual(resumed.status, 206)
        let changed = router.response(to: request("/\(token)/file/0", headers: ["Range": "bytes=100-", "If-Range": "\"other\""]), now: Date())
        XCTAssertEqual(changed.status, 200, "a changed file is sent whole")
        let outside = router.response(to: request("/\(token)/file/0", headers: ["Range": "bytes=2000-"]), now: Date())
        XCTAssertEqual(outside.status, 416)
        XCTAssertEqual(outside.header("Content-Range"), "bytes */1000")
    }

    func testRequestParsing() {
        let parsed = AndroidWiFiHTTP.parse(Data("GET /a/b HTTP/1.1\r\nHost: x\r\nRange: bytes=0-1\r\n\r\n".utf8))
        XCTAssertEqual(parsed, .request(.init(method: "GET", target: "/a/b", headers: ["host": "x", "range": "bytes=0-1"])))
        XCTAssertEqual(AndroidWiFiHTTP.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)), .incomplete)
        XCTAssertEqual(AndroidWiFiHTTP.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(AndroidWiFiHTTP.parse(Data("GET / HTTP/2\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(AndroidWiFiHTTP.parse(Data("get / HTTP/1.1\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(AndroidWiFiHTTP.parse(Data(repeating: 65, count: AndroidWiFiHTTP.maximumHeaderBytes + 1)), .invalid)
        let split = AndroidWiFiHTTP.Response(status: 200, headers: [("X", "a\r\nSet-Cookie: b")])
        XCTAssertFalse(String(decoding: split.head, as: UTF8.self).contains("\r\nSet-Cookie"), "no response splitting")
    }

    // MARK: Page

    func testThePageListsEveryFileWithDownloadAll() throws {
        let files = try files()
        let router = AndroidWiFiRouter(token: token, files: files, expiry: .distantFuture)
        let response = router.response(to: request("/\(token)/"), now: Date())
        XCTAssertEqual(response.status, 200)
        guard case .data(let body) = response.body else { return XCTFail("the page") }
        let html = String(decoding: body, as: UTF8.self)
        for file in files {
            XCTAssertTrue(html.contains("href=\"/\(token)/file/\(file.index)\""), "file \(file.index)")
        }
        XCTAssertEqual(html.components(separatedBy: "class=\"button download\"").count - 1, files.count)
        XCTAssertTrue(html.contains("src=\"/\(token)/preview/0\""))
        XCTAssertFalse(html.contains("/preview/1"))
        XCTAssertTrue(html.contains("Rain &lt;b&gt;&amp; &quot;Snow&quot;"), "titles are escaped")
        XCTAssertFalse(html.contains("<b>&"))
        XCTAssertTrue(html.contains("id=\"all\""), "Download All")
        XCTAssertFalse(html.contains("http://") || html.contains("https://"), "no outside resources")
        let csp = try XCTUnwrap(response.header("Content-Security-Policy"))
        let nonce = try XCTUnwrap(csp.components(separatedBy: "'nonce-").last?.components(separatedBy: "'").first)
        XCTAssertTrue(html.contains("<script nonce=\"\(nonce)\">"))
        XCTAssertFalse(html.contains(AndroidWiFiPage.noncePlaceholder))
        XCTAssertEqual(response.header("Referrer-Policy"), "no-referrer")
    }

    func testFilesOfABatchAreNamedByTitle() {
        var batch = AndroidExportBatch(folder: directory)
        for (title, type, mode) in [("Rain", "scene", AndroidExportOptions.Mode.balanced), ("Rain", "scene", .preRendered), ("Sea", "video", nil)] {
            batch.outputs.append(.init(wallpaperID: title, title: title, type: type, mode: mode,
                                       url: directory.appending(path: "\(title).mpkg"), size: 1, previewURL: nil))
        }
        let files = AndroidWiFiFile.files(of: batch)
        XCTAssertEqual(files.map(\.downloadName), ["Rain.mpkg", "Rain 2.mpkg", "Sea.mpkg"])
        XCTAssertEqual(files.map(\.kind), [.sceneDynamic, .scenePreRendered, .video])
        XCTAssertEqual(files.map(\.index), [0, 1, 2])
    }

    // MARK: QR code and addresses

    /// The code with the app icon at its centre still decodes to the exact address, for short and
    /// long addresses, with the icon as light and dark mode draw it.
    func testTheQRCodeWithTheLogoHoldsTheURL() throws {
        let logo = try XCTUnwrap(NSImage(named: "AppIcon"), "the About window's icon")
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let urls = [
            "http://10.0.0.5:8080/\(token)/",
            "http://owe-fileshare.pyxis.local:52731/\(token)/",
            "http://owe-fileshare-9.deepratnas-macbook-pro-16-inch-2024.local:65535/\(token)/",
            "http://owe-fileshare-2.\(String(repeating: "a", count: 63)).local:65535/\(token)/",
            "http://192.168.100.200:52731/\(token)/",
        ]
        for url in urls {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let image = try XCTUnwrap(AndroidWiFiQRCode.image(for: url, logo: logo, appearance: NSAppearance(named: appearance)))
                XCTAssertNotEqual(try XCTUnwrap(AndroidWiFiQRCode.image(for: url, logo: nil)).dataProvider?.data as Data?,
                                  image.dataProvider?.data as Data?, "the logo is drawn")
                let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                XCTAssertEqual(found, [url], "\(url) \(appearance.rawValue)")
            }
        }
    }

    // MARK: The .local name

    func testTheNameIsAdvertisedAndRenamedOnAConflict() async throws {
        let registrar = FakeNameRegistrar()
        registrar.taken = ["owe-fileshare.pyxis", "owe-fileshare-2.pyxis"]
        let session = AndroidWiFiSession(files: try files(), addresses: { [Self.loopback] },
                                         localName: AndroidWiFiLocalName(registrar: registrar, localHostName: "Pyxis"))
        await session.start()
        XCTAssertEqual(session.state, .serving)
        XCTAssertEqual(registrar.attempts, ["owe-fileshare.pyxis", "owe-fileshare-2.pyxis", "owe-fileshare-3.pyxis"])
        XCTAssertEqual(registrar.active, "owe-fileshare-3.pyxis")
        XCTAssertEqual(registrar.address, Self.loopback)
        XCTAssertEqual(registrar.port, session.port)
        XCTAssertEqual(session.hostName, "owe-fileshare-3.pyxis.local")

        // Another device claims the name later: the next free one replaces it.
        registrar.taken.insert("owe-fileshare-3.pyxis")
        registrar.loseName()
        try await sleepUntil("the fourth name") { session.hostName == "owe-fileshare-4.pyxis.local" }
        XCTAssertEqual(registrar.active, "owe-fileshare-4.pyxis")

        session.stop()
        XCTAssertNil(registrar.active, "stopping withdraws the name")
        XCTAssertNil(session.hostName)
        XCTAssertNil(session.url)
    }

    func testANameWithNoAnswerIsTriedAgain() async throws {
        let registrar = FakeNameRegistrar()
        registrar.unanswered = 1
        let session = AndroidWiFiSession(files: try files(), addresses: { [Self.loopback] },
                                         localName: AndroidWiFiLocalName(registrar: registrar, localHostName: "Pyxis",
                                                                         timeout: .milliseconds(200), retryDelay: .milliseconds(300)))
        await session.start()
        defer { session.stop() }
        XCTAssertEqual(session.state, .serving)
        XCTAssertNil(session.hostName, "the IP address meanwhile")
        XCTAssertEqual(session.url, session.ipURL)
        try await sleepUntil("the plain name") { session.hostName == "owe-fileshare.pyxis.local" }
        XCTAssertEqual(registrar.attempts, ["owe-fileshare.pyxis", "owe-fileshare.pyxis"])
    }

    func testWithoutANameTheShareUsesItsIPAddress() async throws {
        let registrar = FakeNameRegistrar()
        registrar.taken = Set((1...AndroidWiFiLocalName.attempts).map { AndroidWiFiLocalName.name(attempt: $0, macName: "pyxis") })
        let session = AndroidWiFiSession(files: try files(), addresses: { [Self.loopback] },
                                         localName: AndroidWiFiLocalName(registrar: registrar, localHostName: "Pyxis"))
        await session.start()
        defer { session.stop() }
        XCTAssertEqual(registrar.attempts.count, AndroidWiFiLocalName.attempts)
        XCTAssertNil(registrar.active)
        XCTAssertNil(session.hostName)
        XCTAssertEqual(session.url, session.ipURL)
        XCTAssertEqual(session.qrURL(usesIPAddress: false), session.ipURL)
    }

    func testTheURLsUseTheNameOrTheIPAddress() async throws {
        let session = AndroidWiFiSession(files: try files(), addresses: { [Self.loopback] },
                                         localName: AndroidWiFiLocalName(registrar: FakeNameRegistrar(), localHostName: "Pyxis"))
        await session.start()
        defer { session.stop() }
        let port = try XCTUnwrap(session.port)
        let local = "http://owe-fileshare.pyxis.local:\(port)/\(session.token)/", ip = "http://127.0.0.1:\(port)/\(session.token)/"
        XCTAssertEqual(session.url?.absoluteString, local)
        XCTAssertEqual(session.localURL?.absoluteString, local)
        XCTAssertEqual(session.ipURL?.absoluteString, ip)
        XCTAssertEqual(session.qrURL(usesIPAddress: false)?.absoluteString, local)
        XCTAssertEqual(session.qrURL(usesIPAddress: true)?.absoluteString, ip)
        XCTAssertEqual(AndroidWiFiSession.link(host: "owe-fileshare-2.pyxis.local", port: 80, token: "abcdefgh23")?.absoluteString,
                       "http://owe-fileshare-2.pyxis.local:80/abcdefgh23/")
        XCTAssertEqual(AndroidWiFiLocalName.name(attempt: 1, macName: "pyxis"), "owe-fileshare.pyxis")
        XCTAssertEqual(AndroidWiFiLocalName.name(attempt: 2, macName: "pyxis"), "owe-fileshare-2.pyxis")
        XCTAssertEqual(AndroidWiFiLocalName.name(attempt: 1, macName: nil), "owe-fileshare")
        // The Mac's LocalHostName as one DNS label.
        XCTAssertEqual(AndroidWiFiLocalName.label("Pyxis"), "pyxis")
        XCTAssertEqual(AndroidWiFiLocalName.label("Deep's MacBook Pro"), "deep-s-macbook-pro")
        XCTAssertEqual(AndroidWiFiLocalName.label("--Mac_mini.2--"), "mac-mini-2")
        XCTAssertEqual(AndroidWiFiLocalName.label(String(repeating: "a", count: 62) + "-bc"), String(repeating: "a", count: 62))
        XCTAssertNil(AndroidWiFiLocalName.label("ÄÖÜ"))
        XCTAssertNil(AndroidWiFiLocalName.label(""))
    }

    func testOnlyLocalNetworkAddressesCount() throws {
        for local in ["10.0.0.5", "172.16.1.1", "172.31.255.1", "192.168.1.23", "169.254.3.4"] {
            XCTAssertTrue(AndroidLANAddress.isLocalNetwork(try XCTUnwrap(AndroidLANAddress.parse(local))), local)
        }
        for other in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "127.0.0.1", "192.169.0.1"] {
            XCTAssertFalse(AndroidLANAddress.isLocalNetwork(try XCTUnwrap(AndroidLANAddress.parse(other))), other)
        }
        let home = AndroidLANAddress(interface: "en0", displayName: "Wi-Fi", address: try XCTUnwrap(AndroidLANAddress.parse("192.168.1.23")),
                                     netmask: 0xFFFF_FF00)
        XCTAssertTrue(home.contains(try XCTUnwrap(AndroidLANAddress.parse("192.168.1.80"))))
        XCTAssertFalse(home.contains(try XCTUnwrap(AndroidLANAddress.parse("192.168.2.80"))))
        XCTAssertEqual(home.host, "192.168.1.23")
        let wired = AndroidLANAddress(interface: "en1", displayName: nil, address: 0x0A00_0001, netmask: 0xFF00_0000)
        XCTAssertEqual(AndroidLANAddress.order([home, wired], primary: "en1"), [wired, home], "the primary interface first")
        XCTAssertTrue(AndroidLANAddress.current().allSatisfy { AndroidLANAddress.isLocalNetwork($0.address) })
    }

    // MARK: The listener

    private func session(lifetime: TimeInterval = 60) throws -> AndroidWiFiSession {
        AndroidWiFiSession(files: try files(), lifetime: lifetime, addresses: { [Self.loopback] },
                           localName: AndroidWiFiLocalName(registrar: FakeNameRegistrar(), localHostName: "Pyxis"))
    }

    private static func get(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    func testURLSessionDownloadsFromTheListener() async throws {
        let session = try session()
        await session.start()
        defer { session.stop() }
        XCTAssertEqual(session.state, .serving)
        let base = try XCTUnwrap(session.ipURL)
        XCTAssertTrue(base.absoluteString.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(base.absoluteString.hasSuffix("/\(session.token)/"))

        let (page, pageResponse) = try await Self.get(base)
        XCTAssertEqual(pageResponse.statusCode, 200)
        XCTAssertEqual(pageResponse.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertEqual(String(decoding: page, as: UTF8.self).components(separatedBy: "class=\"button download\"").count - 1, 2)

        let file = base.appending(path: "file/1")
        let (whole, wholeResponse) = try await Self.get(file)
        XCTAssertEqual(wholeResponse.statusCode, 200)
        XCTAssertEqual(whole, try Data(contentsOf: directory.appending(path: "City.mpkg")), "every chunk, in order")
        XCTAssertEqual(wholeResponse.value(forHTTPHeaderField: "Content-Disposition")?.hasPrefix("attachment; filename=\"City.mpkg\""), true)

        let (part, partResponse) = try await Self.get(base.appending(path: "file/0"), headers: ["Range": "bytes=10-19"])
        XCTAssertEqual(partResponse.statusCode, 206)
        XCTAssertEqual(part, try Data(contentsOf: directory.appending(path: "Rain.mpkg"))[10...19])

        let (_, preview) = try await Self.get(base.appending(path: "preview/0"))
        XCTAssertEqual(preview.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")

        let wrong = try XCTUnwrap(URL(string: base.absoluteString.replacingOccurrences(of: session.token, with: String(repeating: "b", count: 10))))
        let (_, missing) = try await Self.get(wrong.appending(path: "file/0"))
        XCTAssertEqual(missing.statusCode, 404)
        let (_, posted) = try await Self.get(file, method: "POST")
        XCTAssertEqual(posted.statusCode, 405)

        // The sheet's progress comes from the server's reports on the main actor.
        try await sleepUntil("the completed download") { session.progress[1]?.completedBy == ["127.0.0.1"] }
        XCTAssertEqual(session.progress[1]?.position, 300_000)
        XCTAssertEqual(session.devices, ["127.0.0.1"])
        XCTAssertNil(session.progress[0]?.completedBy.first, "a range short of the end isn't a completed download")
    }

    func testABurstOfRequestsIsRateLimited() async throws {
        var limits = AndroidWiFiServer.Limits()
        limits.requestBurst = 3
        limits.requestsPerSecond = 0.01
        let session = AndroidWiFiSession(files: try files(), limits: limits, addresses: { [Self.loopback] },
                                         localName: AndroidWiFiLocalName(registrar: FakeNameRegistrar(), localHostName: "Pyxis"))
        await session.start()
        defer { session.stop() }
        let base = try XCTUnwrap(session.ipURL)
        var statuses: [Int] = []
        for _ in 0..<5 { statuses.append(try await Self.get(base).1.statusCode) }
        XCTAssertEqual(statuses, [200, 200, 200, 429, 429])
    }

    func testExpiryStopsTheListener() async throws {
        let session = try session(lifetime: 0.5)
        await session.start()
        let base = try XCTUnwrap(session.ipURL)
        let (_, before) = try await Self.get(base)
        XCTAssertEqual(before.statusCode, 200)
        try await sleepUntil("the expiry") { session.state == .stopped(.expired) }
        XCTAssertNil(session.url)
        do {
            let (_, after) = try await Self.get(base)
            XCTFail("the listener still answers: \(after.statusCode)")
        } catch {
            XCTAssertTrue(error is URLError, "\(error)")
        }
    }

    func testStoppingClosesTheListenerAndANewStartHasANewToken() async throws {
        let session = try session()
        await session.start()
        let first = session.token
        let base = try XCTUnwrap(session.ipURL)
        session.stop()
        XCTAssertEqual(session.state, .stopped(.closed))
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await Self.get(base)
            XCTFail("the listener still answers")
        } catch {}
        await session.start()
        defer { session.stop() }
        XCTAssertNotEqual(session.token, first)
        XCTAssertEqual(session.state, .serving)
    }

    func testNoNetworkSaysSo() async throws {
        let session = AndroidWiFiSession(files: try files(), addresses: { [] },
                                         localName: AndroidWiFiLocalName(registrar: FakeNameRegistrar(), localHostName: "Pyxis"))
        await session.start()
        XCTAssertEqual(session.state, .noNetwork)
        XCTAssertNil(session.url)
    }

    // MARK: Android exports list

    /// A batch of the two test packages, the first with a preview.
    private func batch() throws -> AndroidExportBatch {
        let files = try files()
        var batch = AndroidExportBatch(folder: directory)
        batch.outputs = [
            .init(wallpaperID: "1", title: "Rain", type: "scene", mode: .preRendered, url: files[0].url, size: files[0].size,
                  previewURL: files[0].previewURL),
            .init(wallpaperID: "2", title: "City", type: "video", mode: nil, url: files[1].url, size: files[1].size, previewURL: nil),
        ]
        return batch
    }

    func testTheExportsListIsKeptAndDropsMissingPackages() throws {
        let folder = directory.appending(path: "outbox", directoryHint: .isDirectory)
        let outbox = AndroidExportOutbox(directory: folder)
        outbox.record(try batch(), device: "Galaxy Tab S9")
        XCTAssertEqual(outbox.entries.map(\.title), ["City", "Rain"], "newest first")
        let rain = try XCTUnwrap(outbox.entries.first { $0.title == "Rain" })
        XCTAssertEqual(rain.kind, .scenePreRendered)
        XCTAssertEqual(rain.device, "Galaxy Tab S9")
        let preview = try XCTUnwrap(outbox.previewURL(of: rain))
        XCTAssertEqual(try Data(contentsOf: preview), Data([0xFF, 0xD8, 0xFF]), "a copy of the wallpaper's preview")
        outbox.markDownloaded(rain.number, by: "192.168.1.80")

        let reloaded = AndroidExportOutbox(directory: folder)
        XCTAssertEqual(reloaded.entries, outbox.entries)
        XCTAssertEqual(reloaded.entries.first { $0.title == "Rain" }?.downloadedBy, ["192.168.1.80"])

        // Exporting the same file again replaces its entry with a new number.
        reloaded.record(try batch())
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertFalse(reloaded.entries.contains { $0.number == rain.number })

        try FileManager.default.removeItem(at: directory.appending(path: "Rain.mpkg")) // test fixture
        let pruned = AndroidExportOutbox(directory: folder)
        XCTAssertEqual(pruned.entries.map(\.title), ["City"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pruned.previews.path(percentEncoded: false)), [],
                       "its preview goes with it")
        pruned.remove([try XCTUnwrap(pruned.entries.first).number])
        XCTAssertTrue(AndroidExportOutbox(directory: folder).entries.isEmpty)
    }

    /// Only the chosen entries are served; choosing more while it runs serves them too, and the
    /// page's list tells it to reload. Previews need the token.
    func testTheSelectionIsServedAndChangesWhileRunning() async throws {
        let outbox = AndroidExportOutbox(directory: directory.appending(path: "outbox", directoryHint: .isDirectory))
        outbox.record(try batch())
        let rain = try XCTUnwrap(outbox.entries.first { $0.title == "Rain" }).number
        let city = try XCTUnwrap(outbox.entries.first { $0.title == "City" }).number
        let session = try session()
        session.update(files: outbox.wifiFiles([rain]))
        await session.start()
        defer { session.stop() }
        let base = try XCTUnwrap(session.ipURL)
        let status1 = try await Self.get(base.appending(path: "file/\(rain)")).1.statusCode
        XCTAssertEqual(status1, 200)
        let status2 = try await Self.get(base.appending(path: "file/\(city)")).1.statusCode
        XCTAssertEqual(status2, 404, "not chosen")
        let (page, _) = try await Self.get(base)
        XCTAssertFalse(String(decoding: page, as: UTF8.self).contains("/file/\(city)"))
        let (before, _) = try await Self.get(base.appending(path: "list"))
        XCTAssertEqual(String(decoding: before, as: UTF8.self), #"{"version":0,"downloaded":[\#(rain)]}"#, "marks what this device downloaded")

        session.update(files: outbox.wifiFiles([rain, city]))
        try await sleepUntil("the file to be served") { (try? await Self.get(base.appending(path: "file/\(city)")).1.statusCode) == 200 }
        let (after, _) = try await Self.get(base.appending(path: "list"))
        XCTAssertTrue(String(decoding: after, as: UTF8.self).hasPrefix(#"{"version":1,"#), "the page reloads")
        let (newPage, _) = try await Self.get(base)
        XCTAssertTrue(String(decoding: newPage, as: UTF8.self).contains("href=\"/\(session.token)/file/\(city)\""))

        let preview = base.appending(path: "preview/\(rain)")
        let status3 = try await Self.get(preview).1.statusCode
        XCTAssertEqual(status3, 200)
        let wrong = try XCTUnwrap(URL(string: preview.absoluteString.replacingOccurrences(of: session.token, with: "aaaaaaaaaa")))
        let status4 = try await Self.get(wrong).1.statusCode
        XCTAssertEqual(status4, 404, "previews need the token")
        let bare = try XCTUnwrap(URL(string: preview.absoluteString.replacingOccurrences(of: "/\(session.token)", with: "")))
        let status5 = try await Self.get(bare).1.statusCode
        XCTAssertEqual(status5, 404)
    }

    func testRequestsRestartTheExpiry() async throws {
        let session = try session(lifetime: 1.5)
        await session.start()
        defer { session.stop() }
        let base = try XCTUnwrap(session.ipURL)
        let first = session.expiry
        try await Task.sleep(for: .milliseconds(1000))
        let status6 = try await Self.get(base).1.statusCode
        XCTAssertEqual(status6, 200)
        try await sleepUntil("the extended expiry") { session.expiry > first.addingTimeInterval(0.5) }
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(session.state, .serving, "past the first expiry, still serving")
        let status7 = try await Self.get(base.appending(path: "list")).1.statusCode
        XCTAssertEqual(status7, 200)
        try await sleepUntil("the expiry", timeout: 4) { session.state == .stopped(.expired) }
    }
}

/// DNS-SD as the share sees it: names in `taken` belong to another device.
@MainActor
private final class FakeNameRegistrar: AndroidWiFiNameRegistering {
    var taken: Set<String> = []
    /// Registrations that get no answer (macOS asking about the local network).
    var unanswered = 0
    private(set) var attempts: [String] = []
    private(set) var active: String?
    private(set) var address: AndroidLANAddress?
    private(set) var port: UInt16?
    private var onLost: (@MainActor () -> Void)?

    func register(host: String, address: AndroidLANAddress, port: UInt16,
                  completion: @escaping @MainActor (AndroidWiFiNameOutcome) -> Void,
                  onLost: @escaping @MainActor () -> Void) {
        attempts.append(host)
        guard unanswered == 0 else {
            unanswered -= 1
            return
        }
        guard !taken.contains(host) else { return completion(.conflict) }
        active = host
        self.address = address
        self.port = port
        self.onLost = onLost
        completion(.registered)
    }

    func unregister() {
        active = nil
        onLost = nil
    }

    /// Another device claims the active name.
    func loseName() {
        let onLost = onLost
        active = nil
        onLost?()
    }
}
