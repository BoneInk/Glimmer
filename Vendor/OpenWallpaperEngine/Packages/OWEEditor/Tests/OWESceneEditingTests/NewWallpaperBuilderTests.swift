import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OWESceneEditing

/// New Wallpaper's folders, as Wallpaper Engine's welcome page makes projects: a scene from a
/// picture (resized to one of WE's display sizes or not), an empty scene, a template with its
/// pictures replaced, and a web wallpaper from a folder; and the resize recommendations.
final class NewWallpaperBuilderTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appending(path: "Library", directoryHint: .isDirectory) }

    override func setUpWithError() throws {
        root = try Fixtures.temporaryDirectory()
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func png(width: Int, height: Int, red: CGFloat = 1, named name: String = "My Picture.png") throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = root.appending(path: name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func imageSize(_ url: URL) throws -> (Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    func testASceneFromAPictureAtItsOwnSize() throws {
        let picture = try NewWallpaperBuilder.Picture(url: try png(width: 1920, height: 1080))
        let folder = try NewWallpaperBuilder().scene(from: picture, title: "Red", in: library)
        XCTAssertEqual(folder.lastPathComponent, "Red")
        let project = try json(folder.appending(path: "project.json"))
        XCTAssertEqual(project["type"] as? String, "scene")
        XCTAssertEqual(project["file"] as? String, "scene.json")
        XCTAssertEqual(project["title"] as? String, "Red")
        XCTAssertEqual(project["preview"] as? String, "preview.jpg")
        let scheme = ((project["general"] as? [String: Any])?["properties"] as? [String: Any])?["schemecolor"] as? [String: Any]
        XCTAssertEqual(scheme?["value"] as? String, "1 0 0", "the picture's dominant colour")
        let scene = try json(folder.appending(path: "scene.json"))
        let projection = (scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Int]
        XCTAssertEqual(projection, ["width": 1920, "height": 1080])
        let object = try XCTUnwrap((scene["objects"] as? [[String: Any]])?.first)
        XCTAssertEqual(object["image"] as? String, "models/my_picture.json")
        XCTAssertEqual(object["size"] as? String, "1920 1080")
        XCTAssertEqual(try imageSize(folder.appending(path: "materials/my_picture.png")).0, 1920)
        XCTAssertNotNil(try json(folder.appending(path: "materials/my_picture.json"))["passes"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "preview.jpg").path))
        // A second one with the same title gets its own folder.
        XCTAssertEqual(try NewWallpaperBuilder().scene(from: picture, title: "Red", in: library).lastPathComponent, "Red 2")
    }

    func testResizingCoversTheChosenSize() throws {
        let picture = try NewWallpaperBuilder.Picture(url: try png(width: 1000, height: 500))
        let size = NewWallpaperResolution(width: 1280, height: 720, group: .widescreen)
        let folder = try NewWallpaperBuilder().scene(from: picture, title: "Wide", schemeColor: "0.1 0.2 0.3",
                                                     resize: size, in: library)
        let (width, height) = try imageSize(folder.appending(path: "materials/my_picture.png"))
        XCTAssertEqual(width, 1280)
        XCTAssertEqual(height, 720)
        let scene = try json(folder.appending(path: "scene.json"))
        XCTAssertEqual((scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Int], ["width": 1280, "height": 720])
        let project = try json(folder.appending(path: "project.json"))
        let scheme = ((project["general"] as? [String: Any])?["properties"] as? [String: Any])?["schemecolor"] as? [String: Any]
        XCTAssertEqual(scheme?["value"] as? String, "0.1 0.2 0.3", "the chosen scheme colour")
    }

    func testRecommendationsFollowThePicturesShape() {
        let wide = NewWallpaperResolution.recommendation(width: 2000, height: 1125)
        XCTAssertEqual(wide.options.first, NewWallpaperResolution(width: 1920, height: 1080, group: .widescreen),
                       "the largest size the picture fills")
        XCTAssertTrue(wide.options.allSatisfy { $0.group == .widescreen })
        XCTAssertTrue(wide.suggestsResize)
        XCTAssertFalse(wide.isPortrait)
        XCTAssertFalse(NewWallpaperResolution.recommendation(width: 2560, height: 1440).suggestsResize, "a display size already")
        XCTAssertEqual(NewWallpaperResolution.recommendation(width: 3440, height: 1440).options.first?.group, .ultrawide)
        let tall = NewWallpaperResolution.recommendation(width: 800, height: 1500)
        XCTAssertTrue(tall.isPortrait)
        XCTAssertEqual(tall.options.first, NewWallpaperResolution(width: 720, height: 1280, group: .portrait))
        XCTAssertEqual(NewWallpaperResolution.recommendation(width: 300, height: 170).options.first?.width, 1280,
                       "nothing smaller fits: the smallest")
    }

    func testAnEmptyScene() throws {
        let folder = try NewWallpaperBuilder().emptyScene(title: "Blank", width: 2560, height: 1440, in: library)
        let scene = try json(folder.appending(path: "scene.json"))
        XCTAssertEqual((scene["objects"] as? [Any])?.count, 0)
        XCTAssertEqual((scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Int], ["width": 2560, "height": 1440])
        XCTAssertEqual(try json(folder.appending(path: "project.json"))["type"] as? String, "scene")
    }

    func testATemplateWithItsPictureReplaced() throws {
        let template = root.appending(path: "templates/flag", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: template.appending(path: "materials"), withIntermediateDirectories: true)
        try Data(#"{"name": "Flag", "preview": "flag.png", "type": "scene2d"}"#.utf8).write(to: template.appending(path: "template.json"))
        try Data(#"""
        {"file": "scene.json", "templateoptions": [{"type": "replacetexture", "name": "Flag image", "description": "The flag.",
          "adjustprojection": true, "destination": "materials/flag.png"}, {"type": "other"}]}
        """#.utf8).write(to: template.appending(path: "project.json"))
        try Data(#"{"general": {"orthogonalprojection": {"width": 1920, "height": 1080}}, "objects": []}"#.utf8)
            .write(to: template.appending(path: "scene.json"))
        try FileManager.default.copyItem(at: try png(width: 10, height: 10, named: "flag.png"), to: template.appending(path: "flag.png"))
        try Data("{}".utf8).write(to: template.appending(path: "materials/flag.tex-json"))
        try Data(#"{"name": "App", "type": "application"}"#.utf8).write(to: try { () throws -> URL in
            let other = root.appending(path: "templates/app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            return other.appending(path: "template.json")
        }())

        let templates = WallpaperTemplate.templates(in: root.appending(path: "templates"))
        XCTAssertEqual(templates.map(\.name), ["Flag"], "a 2D scene template only")
        let flag = try XCTUnwrap(templates.first)
        XCTAssertEqual(flag.options.map(\.destination), ["materials/flag.png"])
        XCTAssertNotNil(flag.preview)
        XCTAssertThrowsError(try NewWallpaperBuilder().scene(from: flag, title: "My Flag", pictures: [:], in: library))

        let picture = try NewWallpaperBuilder.Picture(url: try png(width: 800, height: 600, named: "mine.png"))
        let folder = try NewWallpaperBuilder().scene(from: flag, title: "My Flag", pictures: ["materials/flag.png": picture],
                                                     in: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "template.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "materials/flag.tex-json").path))
        XCTAssertEqual(try imageSize(folder.appending(path: "materials/flag.png")).0, 800)
        let scene = try json(folder.appending(path: "scene.json"))
        XCTAssertEqual((scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Int], ["width": 800, "height": 600])
        let project = try json(folder.appending(path: "project.json"))
        XCTAssertNil(project["templateoptions"])
        XCTAssertEqual(project["type"] as? String, "scene")
        XCTAssertEqual(project["title"] as? String, "My Flag")
        XCTAssertEqual(project["preview"] as? String, "preview.jpg")
    }

    func testAWebWallpaperFromAFolder() throws {
        let site = root.appending(path: "Site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let builder = NewWallpaperBuilder()
        XCTAssertThrowsError(try builder.webWallpaper(from: site, title: "Site", in: library,
                                                      copy: { try FileManager.default.copyItem(at: $0, to: $1) })) {
            XCTAssertEqual($0 as? NewWallpaperBuilder.Failure, .noIndexPage)
        }
        try Data("<html></html>".utf8).write(to: site.appending(path: "index.html"))
        let folder = try builder.webWallpaper(from: site, title: "Site", in: library,
                                              copy: { try FileManager.default.copyItem(at: $0, to: $1) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "index.html").path))
        let project = try json(folder.appending(path: "project.json"))
        XCTAssertEqual(project["type"] as? String, "web")
        XCTAssertEqual(project["file"] as? String, "index.html")
    }
}
