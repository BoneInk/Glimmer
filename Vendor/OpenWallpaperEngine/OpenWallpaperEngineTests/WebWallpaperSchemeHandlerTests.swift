import WebKit
import XCTest
@testable import OpenWallpaperEngine

/// Local web wallpapers load through `owe-wallpaper://`, confined to their own folder.
final class WebWallpaperSchemeHandlerTests: XCTestCase {
    private var root: URL!
    private var wallpaper: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-scheme-\(UUID().uuidString)")
        wallpaper = root.appending(path: "123456")
        outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: wallpaper.appending(path: "js"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: wallpaper.appending(path: "index.html"))
        try Data("var a = 1;".utf8).write(to: wallpaper.appending(path: "js/app.js"))
        try Data("secret".utf8).write(to: outside.appending(path: "secret.txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func request(_ path: String) -> URL {
        URL(string: "owe-wallpaper://local/\(path)")!
    }

    func testServesAFileOfTheWallpaper() throws {
        let target = try XCTUnwrap(WebWallpaperSchemeHandler.fileURL(for: request("js/app.js"), in: wallpaper))
        XCTAssertEqual(target.relativePath, "js/app.js")
        let reply = WebWallpaperSchemeHandler.reply(to: URLRequest(url: request("js/app.js")), directory: wallpaper,
                                                    patches: WebCompatPatches(actions: []))
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.headers["Content-Length"], "10")
        XCTAssertEqual(reply.headers["Access-Control-Allow-Origin"], "*")
    }

    func testRefusesParentComponents() {
        XCTAssertNil(WebWallpaperSchemeHandler.fileURL(for: request("../outside/secret.txt"), in: wallpaper))
        XCTAssertNil(WebWallpaperSchemeHandler.fileURL(for: request("js/../../outside/secret.txt"), in: wallpaper))
        XCTAssertNil(WebWallpaperSchemeHandler.fileURL(for: request("%2E%2E/outside/secret.txt"), in: wallpaper))
    }

    func testRefusesASymlinkThatLeavesTheFolder() throws {
        try FileManager.default.createSymbolicLink(at: wallpaper.appending(path: "link.txt"),
                                                   withDestinationURL: outside.appending(path: "secret.txt"))
        try FileManager.default.createSymbolicLink(at: wallpaper.appending(path: "dir"), withDestinationURL: outside)
        XCTAssertNil(WebWallpaperSchemeHandler.fileURL(for: request("link.txt"), in: wallpaper))
        XCTAssertNil(WebWallpaperSchemeHandler.fileURL(for: request("dir/secret.txt"), in: wallpaper))
        let reply = WebWallpaperSchemeHandler.reply(to: URLRequest(url: request("link.txt")), directory: wallpaper,
                                                    patches: WebCompatPatches(actions: []))
        XCTAssertEqual(reply.status, 404)
    }

    func testServesRegularFilesOnly() {
        XCTAssertNil(WebWallpaperSchemeHandler.fileURL(for: request("js"), in: wallpaper))
        XCTAssertNil(WebWallpaperSchemeHandler.fileURL(for: request("missing.js"), in: wallpaper))
    }

    func testAnswersByteRanges() {
        XCTAssertEqual(WebWallpaperSchemeHandler.rangeRequest(nil, fileSize: 10), .whole)
        XCTAssertEqual(WebWallpaperSchemeHandler.rangeRequest("bytes=0-1", fileSize: 10), .partial(0..<2))
        XCTAssertEqual(WebWallpaperSchemeHandler.rangeRequest("bytes=4-", fileSize: 10), .partial(4..<10))
        XCTAssertEqual(WebWallpaperSchemeHandler.rangeRequest("bytes=-3", fileSize: 10), .partial(7..<10))
        XCTAssertEqual(WebWallpaperSchemeHandler.rangeRequest("bytes=5-100", fileSize: 10), .partial(5..<10))
        XCTAssertEqual(WebWallpaperSchemeHandler.rangeRequest("bytes=10-", fileSize: 10), .unsatisfiable)
        var ranged = URLRequest(url: request("js/app.js"))
        ranged.setValue("bytes=4-", forHTTPHeaderField: "Range")
        let reply = WebWallpaperSchemeHandler.reply(to: ranged, directory: wallpaper, patches: WebCompatPatches(actions: []))
        XCTAssertEqual(reply.status, 206)
        XCTAssertEqual(reply.headers["Content-Range"], "bytes 4-9/10")
    }

    func testAppliesPatchesToServedFiles() throws {
        let patches = WebCompatPatches(actions: [.init(file: "js/app.js", replace: "1", insert: "2")])
        let reply = WebWallpaperSchemeHandler.reply(to: URLRequest(url: request("js/app.js")), directory: wallpaper,
                                                    patches: patches)
        guard case .data(let data) = reply.body else { return XCTFail("expected patched data") }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "var a = 2;")
    }

    func testLocalPagesLoadThroughTheScheme() {
        let load = WebWallpaperView.pageLoad(pageFile: wallpaper.appending(path: "index.html"), relativePath: "index.html")
        XCTAssertEqual(load, .scheme(URL(string: "owe-wallpaper://local/index.html")!))
    }

    func testRemoteEmbedsKeepTheirHTTPSOrigin() throws {
        let html = "<iframe src=\"https://www.youtube.com/embed/x\"></iframe>"
        try Data(html.utf8).write(to: wallpaper.appending(path: "index.html"))
        let load = WebWallpaperView.pageLoad(pageFile: wallpaper.appending(path: "index.html"), relativePath: "index.html")
        XCTAssertEqual(load, .remoteEmbed(html: html))
    }

    @MainActor
    func testConfigurationKeepsFileURLAccessOff() {
        let preferences = WebWallpaperView.makeConfiguration().preferences
        for key in ["allowFileAccessFromFileURLs", "allowUniversalAccessFromFileURLs"] {
            var value: Any?
            // A WebKit without the key has nothing turned on.
            _ = ObjCExceptionCatcher.performSafe { value = preferences.value(forKey: key) }
            XCTAssertNotEqual(value as? Bool, true, key)
        }
    }

    func testZCompatIsChosenByTheFolderNotProjectJSON() {
        let project = WEProject(file: "index.html", title: "Web", workshopid: .string("999"), type: "web")
        XCTAssertEqual(WebWallpaperViewModel.compatWorkshopId(of: WEWallpaper(using: project, where: wallpaper)), "123456")
        XCTAssertNil(WebWallpaperViewModel.compatWorkshopId(of: WEWallpaper(using: project, where: outside)))
    }
}
