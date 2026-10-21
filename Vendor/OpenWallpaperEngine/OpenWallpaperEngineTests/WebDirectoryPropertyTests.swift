import WebKit
import XCTest
@testable import OpenWallpaperEngine

/// WE's `directory` user property on web wallpapers: the declared modes and file types, the
/// listing and its changes, the feed's fetchall deliveries and ondemand answers, serving the
/// chosen files, and a real WebKit page reading them as `'file:///' + path`.
@MainActor
final class WebDirectoryPropertyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "pictures/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "wallpaper"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var pictures: URL { root.appending(path: "pictures") }

    private func write(_ name: String, _ text: String = "x") throws {
        try Data(text.utf8).write(to: pictures.appending(path: name))
    }

    // MARK: Declaration and listing

    func testDeclaredModesAndFileTypes() {
        let root: [String: Any] = ["general": ["properties": [
            "folder": ["type": "directory", "mode": "fetchall"],
            "videos": ["type": "directory", "mode": "ondemand", "fileType": "video"],
            "broken": ["type": "directory"],
            "image": ["type": "file"],
        ]]]
        let declared = WebDirectoryProperty.declared(projectRoot: root)
        XCTAssertEqual(declared, [
            WebDirectoryProperty(key: "folder", mode: .fetchAll, fileType: .image),
            WebDirectoryProperty(key: "videos", mode: .onDemand, fileType: .video),
        ], "a directory without a mode isn't configured correctly and is left out, as in WE")
    }

    func testListsWEsFileTypesInTheWholeTree() throws {
        for name in ["a.png", "b.JPG", "c.apng", "d.svg", "e.webp", "f.gif", "g.bmp", "h.jpeg", "clip.webm",
                     "clip.ogv", "clip.mp4", "notes.txt", ".hidden.png", "sub/i.png"] {
            try write(name)
        }
        let images = Set(WebDirectoryProperty.files(in: pictures, type: .image).keys.map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertEqual(images, ["a.png", "b.JPG", "c.apng", "d.svg", "e.webp", "f.gif", "g.bmp", "h.jpeg", "i.png"])
        let videos = Set(WebDirectoryProperty.files(in: pictures, type: .video).keys.map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertEqual(videos, ["clip.webm", "clip.ogv"], "WE's video list has no .mp4")
    }

    func testChangesAndPagePaths() {
        let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 2)
        let changes = WebDirectoryProperty.changes(from: ["/a": old, "/b": old, "/c": old], to: ["/a": old, "/b": new, "/d": old])
        XCTAssertEqual(changes.changed, ["/b", "/d"])
        XCTAssertEqual(changes.removed, ["/c"])
        XCTAssertEqual(WebDirectoryProperty.pagePath("/Users/me/a.png"), "Users/me/a.png",
                       "'file:///' + path is a well-formed URL, as with WE's C:/ paths")
        XCTAssertEqual(WebWallpaperPropertyBridge.jsonValue(type: "directory", value: "/Users/me") as? String, "Users/me")
        XCTAssertEqual(WebWallpaperPropertyBridge.jsonValue(type: "file", value: "/Users/me/a.png") as? String, "Users/me/a.png")
        XCTAssertEqual(WebWallpaperPropertyBridge.jsonValue(type: "file", value: "") as? String, "")
    }

    // MARK: Feed

    func testFetchAllSendsEveryFileOnLoadThenAdditionsAndRemovals() throws {
        try write("a.png")
        try write("notes.txt")
        let feed = WebDirectoryFeed()
        var scripts: [String] = []
        feed.send = { scripts.append($0) }
        var served: [(path: String, type: WebDirectoryProperty.FileType)] = []
        feed.onFoldersChange = { served = $0 }
        let property = WebDirectoryProperty(key: "folder", mode: .fetchAll, fileType: .image)
        feed.pageWillLoad()
        feed.update(properties: [property], values: ["folder": pictures.path])
        XCTAssertEqual(served.map(\.path), [pictures.standardizedFileURL.path(percentEncoded: false)])
        feed.pageDidLoad()
        waitUntil("the first listing") { !scripts.isEmpty }
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].hasPrefix("window.__oweDirectoryFilesChanged&&window.__oweDirectoryFilesChanged(\"folder\",[\""))
        XCTAssertTrue(scripts[0].contains("pictures/a.png\"]"), "every matching file, without the leading slash")
        XCTAssertFalse(scripts[0].contains("notes.txt"))

        scripts.removeAll()
        try write("sub/b.png")
        waitUntil("the added file") { !scripts.isEmpty }
        XCTAssertTrue(scripts.last?.contains("__oweDirectoryFilesChanged") == true)
        XCTAssertTrue(scripts.last?.contains("sub/b.png") == true)

        scripts.removeAll()
        try FileManager.default.removeItem(at: pictures.appending(path: "a.png"))
        waitUntil("the removal") { scripts.contains { $0.contains("__oweDirectoryFilesRemoved") } }
        XCTAssertTrue(scripts.first { $0.contains("__oweDirectoryFilesRemoved") }?.contains("a.png") == true)

        // Clearing the folder takes every file away from the page.
        scripts.removeAll()
        feed.update(properties: [property], values: ["folder": ""])
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("__oweDirectoryFilesRemoved") && scripts[0].contains("sub/b.png"))
        XCTAssertTrue(served.isEmpty)
    }

    func testANewPageGetsTheWholeSetAgain() throws {
        try write("a.png")
        let feed = WebDirectoryFeed()
        var scripts: [String] = []
        feed.send = { scripts.append($0) }
        feed.update(properties: [WebDirectoryProperty(key: "folder", mode: .fetchAll, fileType: .image)],
                    values: ["folder": pictures.path])
        feed.pageDidLoad()
        waitUntil("the first listing") { scripts.count == 1 }
        feed.pageWillLoad()
        XCTAssertEqual(scripts.count, 1, "nothing is sent while the page loads")
        feed.pageDidLoad()
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(scripts[0], scripts[1])
    }

    func testOnDemandAnswersWithARandomFileOrNothing() throws {
        try write("a.png")
        try write("b.png")
        let feed = WebDirectoryFeed()
        var scripts: [String] = []
        feed.send = { scripts.append($0) }
        feed.pick = { $0.sorted().last }
        feed.update(properties: [WebDirectoryProperty(key: "slides", mode: .onDemand, fileType: .image)],
                    values: ["slides": pictures.path])
        feed.pageDidLoad()
        // Asked before the listing is ready: answered once it is.
        feed.receiveRequest(["id": 1, "property": "slides"])
        waitUntil("the answer") { !scripts.isEmpty }
        XCTAssertEqual(scripts.count, 1, "ondemand never sends the file list")
        XCTAssertTrue(scripts[0].hasPrefix("window.__oweRandomFileResponse&&window.__oweRandomFileResponse(1,\"slides\",\""))
        XCTAssertTrue(scripts[0].hasSuffix("pictures/b.png\");"))
        XCTAssertFalse(scripts[0].contains("(1,\"slides\",\"/"), "the path has no leading slash")
        feed.receiveRequest(["id": 2, "property": "other"])
        XCTAssertEqual(scripts.last, WebDirectoryFeed.responseScript(id: 2, property: "other", path: ""))
    }

    // MARK: Serving

    func testServesOnlyChosenFilesAndFolderFilesOfTheType() throws {
        try write("a.png")
        try write("notes.txt")
        let chosen = root.appending(path: "chosen.mp4")
        try Data("v".utf8).write(to: chosen)
        try Data("s".utf8).write(to: root.appending(path: "secret.png"))
        let files = WebUserFiles()
        files.allow(filePaths: [chosen.path], folders: [(pictures.path, .image)])
        func served(_ url: URL) -> Bool {
            files.file(forServedPath: WebUserFiles.pathPrefix + url.standardizedFileURL.path(percentEncoded: false)) != nil
        }
        XCTAssertTrue(served(pictures.appending(path: "a.png")))
        XCTAssertTrue(served(chosen))
        XCTAssertFalse(served(pictures.appending(path: "notes.txt")), "not one of the property's file types")
        XCTAssertFalse(served(root.appending(path: "secret.png")), "outside the chosen folder")
        XCTAssertNil(files.file(forServedPath: WebUserFiles.pathPrefix + pictures.path + "/../secret.png"))
        files.allow(filePaths: [], folders: [])
        XCTAssertFalse(served(pictures.appending(path: "a.png")), "a folder no longer chosen isn't served")
    }

    func testTheSchemeHandlerServesUserFilesBesideTheWallpaper() throws {
        try write("a.png", "picture")
        let files = WebUserFiles()
        files.allow(filePaths: [], folders: [(pictures.path, .image)])
        let path = pictures.appending(path: "a.png").standardizedFileURL.path(percentEncoded: false)
        let url = try XCTUnwrap(URL(string: "owe-wallpaper://local/\(WebUserFiles.pathPrefix)\(path)"))
        let reply = WebWallpaperSchemeHandler.reply(to: URLRequest(url: url), directory: root.appending(path: "wallpaper"),
                                                    patches: WebCompatPatches(actions: []), userFiles: files)
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.headers["Content-Type"], "image/png")
        let denied = WebWallpaperSchemeHandler.reply(to: URLRequest(url: url), directory: root.appending(path: "wallpaper"),
                                                     patches: WebCompatPatches(actions: []))
        XCTAssertEqual(denied.status, 404, "without the property's files nothing outside the folder is served")
    }

    // MARK: A real page

    /// The page does what WE's docs say: `'file:///' + path` from the listener and from the random
    /// file callback, into an image, a CSS background and fetch.
    func testAWebKitPageReadsTheFilesAsWEsDocsShow() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
        try png.write(to: pictures.appending(path: "a.png"))
        let html = """
        <html><body><div id="bg"></div><script>
        window.results = {};
        window.wallpaperPropertyListener = {
          userDirectoryFilesAddedOrChanged: function(name, files){
            var img = new Image();
            img.onload = function(){ results.img = img.naturalWidth; };
            img.onerror = function(){ results.img = 'error'; };
            img.src = 'file:///' + files[0];
            document.getElementById('bg').style.backgroundImage = "url('file:///" + files[0] + "')";
            results.css = document.getElementById('bg').style.backgroundImage;
            fetch('file:///' + files[0]).then(function(r){ return r.arrayBuffer(); })
              .then(function(b){ results.fetch = b.byteLength; }, function(){ results.fetch = 'error'; });
          }
        };
        window.wallpaperRequestRandomFileForProperty('folder', function(name, path){ results.random = [name, path]; });
        </script></body></html>
        """
        try Data(html.utf8).write(to: root.appending(path: "wallpaper/index.html"))

        let handler = WebWallpaperSchemeHandler()
        handler.directory = root.appending(path: "wallpaper")
        let files = WebUserFiles()
        handler.userFiles = files
        let feed = WebDirectoryFeed()
        feed.onFoldersChange = { files.allow(filePaths: [], folders: $0) }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: WebWallpaperSchemeHandler.scheme)
        let messages = MessageRecorder()
        for script in WebWallpaperViewModel.documentStartScripts {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController.add(messages, name: WebDirectoryFeed.randomFileMessageName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 32, height: 32), configuration: configuration)
        feed.send = { webView.evaluateJavaScript($0, completionHandler: nil) }
        messages.onMessage = { feed.receiveRequest($0) }
        feed.update(properties: [WebDirectoryProperty(key: "folder", mode: .fetchAll, fileType: .image)],
                    values: ["folder": pictures.path])
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: WebWallpaperSchemeHandler.url(forRelativePath: "index.html")!))
        await delegate.wait()
        feed.pageDidLoad()

        var results: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let json = try await webView.evaluateJavaScript("JSON.stringify(window.results)") as? String ?? "{}"
            results = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
            if results["img"] != nil, results["fetch"] != nil, results["random"] != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(results["img"] as? Int, 1, "the image loads from file:///")
        XCTAssertEqual(results["fetch"] as? Int, png.count, "fetch reads the file")
        XCTAssertTrue((results["css"] as? String)?.contains("owe-wallpaper://local/\(WebUserFiles.pathPrefix)/") == true)
        XCTAssertEqual((results["random"] as? [String])?.first, "folder")
        XCTAssertTrue((results["random"] as? [String])?.last?.hasSuffix("pictures/a.png") == true,
                      "a fetchall property still answers a random request")
    }
}

private final class MessageRecorder: NSObject, WKScriptMessageHandler {
    var onMessage: (Any) -> Void = { _ in }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message.body)
    }
}

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var loaded = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if loaded { return }
        await withCheckedContinuation { continuation = $0 }
    }

    private func finish() {
        loaded = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
}
