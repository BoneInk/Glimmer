import XCTest
@testable import OpenWallpaperEngine

/// WE's `assets/zcompat/web`: text patches for web wallpapers, applied as files are served.
final class WebCompatPatchesTests: XCTestCase {
    func testWebPatchesLoadElementByElement() throws {
        let patches = try WebCompatPatches(json: Fixtures.data("ZCompat/web/1234567890.json"))
        XCTAssertEqual(patches.actions.count, 2)
        XCTAssertTrue(patches.hasPatches(for: "js\\index.min.js"))
        XCTAssertFalse(patches.hasPatches(for: "js/broken.js"))
    }

    func testWebPatchesLookUpByWorkshopId() throws {
        // `zcompat` sits in the assets folder, next to `effects`, `shaders`…
        let assetsDirectory = FileManager.default.temporaryDirectory.appending(path: "owe-zcompat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assetsDirectory) }
        try FileManager.default.copyItem(at: Fixtures.url("ZCompat"), to: assetsDirectory.appending(path: "zcompat"))
        XCTAssertNotNil(WebCompatPatches(workshopId: "1234567890", assetsDirectory: assetsDirectory))
        XCTAssertNil(WebCompatPatches(workshopId: "999", assetsDirectory: assetsDirectory))
        XCTAssertNil(WebCompatPatches(workshopId: nil, assetsDirectory: assetsDirectory))
        XCTAssertNil(WebCompatPatches(workshopId: "../x", assetsDirectory: assetsDirectory))
    }

    func testWebPatchReplacesTextInTheNamedFileOnly() throws {
        let patches = try WebCompatPatches(json: Fixtures.data("ZCompat/web/1234567890.json"))
        let source = Data("function u(t,e){t.texImage2D(e)};function v(t,e){t.texImage2D(e)}".utf8)
        let patched = String(decoding: patches.apply(to: source, relativePath: "js/index.min.js"), as: UTF8.self)
        XCTAssertEqual(patched, "function u(t,e){if(e!=null)t.texImage2D(e)};function v(t,e){t.texImage2D(e)}")
        XCTAssertEqual(patches.apply(to: source, relativePath: "js/index2.min.js"), source)
        // Text that isn't there leaves the file as it was.
        let other = Data("zzz".utf8)
        XCTAssertEqual(patches.apply(to: other, relativePath: "js/other.js"), other)
    }

    func testBundledWebPatchesParse() throws {
        let root = try Fixtures.assets().appending(path: "zcompat/web")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".json") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let patches = try WebCompatPatches(json: Data(contentsOf: root.appending(path: file)))
            XCTAssertFalse(patches.isEmpty, file)
        }
    }

    func testSchemeHandlerStaysInsideTheWallpaperFolder() throws {
        // Only files that exist are served.
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-web-\(UUID().uuidString)/123")
        for file in ["js/index.min.js", "my files/a b.js"] {
            let url = directory.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) } // scratch cleanup
        let url = try XCTUnwrap(WebWallpaperSchemeHandler.url(forRelativePath: "js/index.min.js"))
        XCTAssertEqual(url.absoluteString, "owe-wallpaper://local/js/index.min.js")
        let target = try XCTUnwrap(WebWallpaperSchemeHandler.fileURL(for: url, in: directory))
        XCTAssertEqual(target.relativePath, "js/index.min.js")
        XCTAssertEqual(target.url.lastPathComponent, "index.min.js")
        XCTAssertNil(WebWallpaperSchemeHandler.fileURL(for: URL(string: "owe-wallpaper://local/../../etc/passwd")!, in: directory))
        let spaced = try XCTUnwrap(WebWallpaperSchemeHandler.url(forRelativePath: "my files/a b.js"))
        XCTAssertEqual(WebWallpaperSchemeHandler.fileURL(for: spaced, in: directory)?.relativePath, "my files/a b.js")
    }
}
