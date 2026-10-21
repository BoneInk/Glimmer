import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The production cache still references the finite legacy Scene types. These
// deterministic stubs record any fallback attempt; valid posters must never
// reach them.
struct SceneWallpaperInspection: Sendable {}

enum SceneWallpaperInspector {
    static func inspectUsingAvailableEngineAssets(projectURL: URL) throws -> SceneWallpaperInspection {
        markLegacyRendererAttempt()
        throw TestFailure(message: "legacy Scene inspector must not run when project.json.preview is valid")
    }
}

enum SceneWallpaperRenderer {
    static func render(inspection: SceneWallpaperInspection, pixelSize: CGSize) throws -> CGImage {
        markLegacyRendererAttempt()
        throw TestFailure(message: "legacy Scene renderer must not run when project.json.preview is valid")
    }
}

private func markLegacyRendererAttempt() {
    guard let path = ProcessInfo.processInfo.environment["GW_LEGACY_RENDER_MARKER"] else { return }
    FileManager.default.createFile(atPath: path, contents: Data("legacy".utf8))
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@main @MainActor
enum SceneThumbnailPosterTests {
    static let fm = FileManager.default
    static var passed = 0
    static var fixtureRoot: URL!
    static var legacyMarkerURL: URL!
    static let cacheStorage = AppStorage(root: URL(fileURLWithPath: "/private/tmp/GW-Scene-Poster-Cache-\(UUID())"))

    static func main() async throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 4 else {
            throw TestFailure(message: "usage: probe FIXTURE_ROOT REAL_GIF_PROJECT REAL_JPEG_PROJECT")
        }
        fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        legacyMarkerURL = fixtureRoot.appendingPathComponent("legacy-renderer-marker")
        setenv("GW_LEGACY_RENDER_MARKER", legacyMarkerURL.path, 1)
        defer {
            try? fm.removeItem(at: fixtureRoot)
            try? fm.removeItem(at: cacheStorage.root)
        }

        try await testGIFAndCache()
        try await testJPEGAndOutputBound()
        try await testWebPathUnchanged()
        try await testDeduplication()
        try await testMissingAndInvalidPreviews()
        try testPathAndFileRejections()
        try testReadAndDecodeLimits()
        try await testRealProject(projectPath: CommandLine.arguments[2], expectedID: UUID(uuidString: "FB00AA6D-DA88-4C1D-8EA8-49E5A51E3C35")!, label: "real Scene GIF poster", expectedNonBlack: true)
        try await testRealProject(projectPath: CommandLine.arguments[3], expectedID: UUID(), label: "real Scene JPEG poster", expectedNonBlack: true)

        print("SceneThumbnailPosterTests: \(passed) passed; fixtures and cache stayed under temporary paths")
    }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw TestFailure(message: label) }
        passed += 1
        print("PASS \(label)")
    }

    static func expectFailure(_ label: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            passed += 1
            print("PASS \(label)")
            return
        }
        throw TestFailure(message: label + " unexpectedly succeeded")
    }

    static func resetLegacyMarker() {
        try? fm.removeItem(at: legacyMarkerURL)
    }

    static func legacyRan() -> Bool {
        fm.fileExists(atPath: legacyMarkerURL.path)
    }

    static func project(_ directory: URL, _ object: [String: Any]) throws -> URL {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = directory.appendingPathComponent("project.json")
        try data.write(to: url)
        return url
    }

    static func sceneItem(id: UUID, projectURL: URL) -> WallpaperItem {
        WallpaperItem(id: id, title: "Scene poster fixture", filePath: projectURL.path, contentKind: .scene)
    }

    static func image(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let color = CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [red, green, blue, 1]
        ) else {
            throw TestFailure(message: "Cannot create test bitmap")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestFailure(message: "Cannot finalize test bitmap")
        }
        return image
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw TestFailure(message: "Cannot create \(type.identifier) destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestFailure(message: "Cannot write \(type.identifier) fixture")
        }
    }

    static func writeAnimatedGIF(to url: URL, frames: [CGImage]) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw TestFailure(message: "Cannot create animated GIF destination")
        }
        let properties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.05,
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, properties)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw TestFailure(message: "Cannot write animated GIF fixture")
        }
    }

    static func sample(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return bytes }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }

    static func hasNonBlackPixels(_ image: CGImage) -> Bool {
        let width = 16, height = 16
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if max(max(bytes[offset], bytes[offset + 1]), bytes[offset + 2]) > 8 { return true }
        }
        return false
    }

    static func cachedCGImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func assertJPEG(_ url: URL, maximumDimension: CGFloat) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              type == UTType.jpeg.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw TestFailure(message: "Cached thumbnail is not a decodable JPEG")
        }
        try check(max(image.width, image.height) <= Int(maximumDimension), "cached JPEG respects output dimension bound")
    }

    static func testGIFAndCache() async throws {
        let directory = fixtureRoot.appendingPathComponent("GIF")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let red = try image(width: 48, height: 32, red: 0.95, green: 0.02, blue: 0.02)
        let green = try image(width: 48, height: 32, red: 0.02, green: 0.95, blue: 0.02)
        try writeAnimatedGIF(to: directory.appendingPathComponent("preview.gif"), frames: [red, green])
        let projectURL = try project(directory, ["type": "scene", "file": "scene.json", "preview": "preview.gif"])

        resetLegacyMarker()
        let direct = try ProjectPosterLoader.firstFrame(projectURL: projectURL, maximumPixelSize: 320)
        let color = sample(direct)
        try check(color[0] > 180 && color[1] < 60 && color[2] < 60, "animated GIF poster decodes its red first frame")
        try check(max(direct.width, direct.height) <= 320, "direct GIF decode respects the requested bound")
        try check(!legacyRan(), "valid GIF poster never invokes the legacy Scene renderer")

        let id = UUID()
        let cache = ThumbnailCache(storage: cacheStorage)
        resetLegacyMarker()
        let thumbnail = await cache.thumbnail(
            for: sceneItem(id: id, projectURL: projectURL),
            targetSize: CGSize(width: 200, height: 200)
        )
        guard let cgImage = thumbnail.flatMap(cachedCGImage) else {
            throw TestFailure(message: "Scene GIF cache thumbnail missing")
        }
        let cachedColor = sample(cgImage)
        try check(cachedColor[0] > 180 && cachedColor[1] < 60, "cached Scene thumbnail keeps the GIF first frame")
        try check(max(cgImage.width, cgImage.height) <= 200, "cached GIF thumbnail respects the target size")
        try check(!legacyRan(), "cached GIF path bypasses legacy Scene inspection")
        let diskURL = cacheStorage.thumbnailURL(for: id)
        try check(fm.fileExists(atPath: diskURL.path), "Scene GIF thumbnail writes its JPEG cache in the temporary storage")
        try assertJPEG(diskURL, maximumDimension: 200)
    }

    static func testJPEGAndOutputBound() async throws {
        let directory = fixtureRoot.appendingPathComponent("JPEG")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let blue = try image(width: 1_024, height: 512, red: 0.02, green: 0.05, blue: 0.95)
        try writeImage(blue, to: directory.appendingPathComponent("preview.jpg"), type: .jpeg)
        let projectURL = try project(directory, ["type": "scene", "file": "scene.json", "preview": "preview.jpg"])

        let direct = try ProjectPosterLoader.firstFrame(projectURL: projectURL, maximumPixelSize: 180)
        try check(max(direct.width, direct.height) <= 180, "large JPEG poster is downscaled to the requested bound")
        try check(direct.width > direct.height && direct.height > 0, "JPEG poster preserves its aspect ratio")

        let id = UUID()
        let cache = ThumbnailCache(storage: cacheStorage)
        resetLegacyMarker()
        let thumbnail = await cache.thumbnail(
            for: sceneItem(id: id, projectURL: projectURL),
            targetSize: CGSize(width: 160, height: 160)
        )
        guard let cgImage = thumbnail.flatMap(cachedCGImage) else {
            throw TestFailure(message: "Scene JPEG cache thumbnail missing")
        }
        try check(max(cgImage.width, cgImage.height) <= 160, "cached JPEG thumbnail is bounded")
        try check(!legacyRan(), "valid JPEG poster bypasses legacy Scene inspection")
        try assertJPEG(cacheStorage.thumbnailURL(for: id), maximumDimension: 160)
    }

    static func testWebPathUnchanged() async throws {
        let directory = fixtureRoot.appendingPathComponent("Web")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<!doctype html><html><body>web</body></html>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))
        let poster = try image(width: 96, height: 64, red: 0.95, green: 0.85, blue: 0.1)
        try writeImage(poster, to: directory.appendingPathComponent("preview.jpg"), type: .jpeg)
        let projectURL = try project(directory, ["type": "web", "file": "index.html", "preview": "preview.jpg"])
        let item = WallpaperItem(id: UUID(), title: "Web fixture", filePath: projectURL.path, contentKind: .web)

        resetLegacyMarker()
        let thumbnail = await ThumbnailCache(storage: cacheStorage).thumbnail(for: item)
        try check(thumbnail != nil, "existing Web poster path still returns an image")
        try check(!legacyRan(), "Web poster path does not touch Scene fallback")
    }

    static func testDeduplication() async throws {
        let directory = fixtureRoot.appendingPathComponent("Dedup")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try image(width: 128, height: 128, red: 0.1, green: 0.7, blue: 0.2)
        try writeImage(image, to: directory.appendingPathComponent("preview.jpg"), type: .jpeg)
        let projectURL = try project(directory, ["type": "scene", "file": "scene.json", "preview": "preview.jpg"])
        let item = sceneItem(id: UUID(), projectURL: projectURL)
        let cache = ThumbnailCache(storage: cacheStorage)

        resetLegacyMarker()
        async let first = cache.thumbnail(for: item, targetSize: CGSize(width: 96, height: 96))
        async let second = cache.thumbnail(for: item, targetSize: CGSize(width: 96, height: 96))
        let pair = await (first, second)
        guard let left = pair.0, let right = pair.1 else {
            throw TestFailure(message: "Concurrent Scene thumbnail requests failed")
        }
        try check(left === right, "concurrent requests share one in-flight Scene thumbnail result")
        try check(!legacyRan(), "deduplicated valid poster does not enumerate legacy work")
    }

    static func testMissingAndInvalidPreviews() async throws {
        let missingDirectory = fixtureRoot.appendingPathComponent("Missing")
        let missingProject = try project(missingDirectory, ["type": "scene", "file": "scene.json"])
        try expectFailure("missing preview is rejected without touching an image") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: missingProject, maximumPixelSize: 100)
        }
        resetLegacyMarker()
        let missingThumbnail = await ThumbnailCache(storage: cacheStorage).thumbnail(
            for: sceneItem(id: UUID(), projectURL: missingProject)
        )
        try check(missingThumbnail == nil, "missing preview returns nil when legacy fallback also fails")
        try check(legacyRan(), "missing poster falls back to the existing legacy path")

        let invalidDirectory = fixtureRoot.appendingPathComponent("Invalid")
        try fm.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: invalidDirectory.appendingPathComponent("preview.gif"))
        let invalidProject = try project(invalidDirectory, ["type": "scene", "file": "scene.json", "preview": "preview.gif"])
        try expectFailure("invalid preview bytes are rejected") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: invalidProject, maximumPixelSize: 100)
        }
        resetLegacyMarker()
        let invalidThumbnail = await ThumbnailCache(storage: cacheStorage).thumbnail(
            for: sceneItem(id: UUID(), projectURL: invalidProject)
        )
        try check(invalidThumbnail == nil, "invalid preview returns nil when legacy fallback also fails")
        try check(legacyRan(), "invalid poster falls back to the existing legacy path")
    }

    static func testPathAndFileRejections() throws {
        let outside = fixtureRoot.appendingPathComponent("outside.gif")
        try writeAnimatedGIF(
            to: outside,
            frames: [try image(width: 8, height: 8, red: 0.9, green: 0.1, blue: 0.1)]
        )

        let absoluteDirectory = fixtureRoot.appendingPathComponent("Absolute")
        try fm.createDirectory(at: absoluteDirectory, withIntermediateDirectories: true)
        let absoluteProject = try project(
            absoluteDirectory,
            ["type": "scene", "file": "scene.json", "preview": outside.path]
        )
        try expectFailure("absolute preview path is rejected") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: absoluteProject, maximumPixelSize: 100)
        }

        let traversalDirectory = fixtureRoot.appendingPathComponent("Traversal/Project")
        try fm.createDirectory(at: traversalDirectory, withIntermediateDirectories: true)
        try Data(contentsOf: outside).write(to: fixtureRoot.appendingPathComponent("Traversal/outside.gif"))
        let traversalProject = try project(
            traversalDirectory,
            ["type": "scene", "file": "scene.json", "preview": "../outside.gif"]
        )
        try expectFailure("dot-dot preview traversal is rejected") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: traversalProject, maximumPixelSize: 100)
        }

        let symlinkDirectory = fixtureRoot.appendingPathComponent("Symlink")
        try fm.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: symlinkDirectory.appendingPathComponent("preview.gif"),
            withDestinationURL: outside
        )
        let symlinkProject = try project(
            symlinkDirectory,
            ["type": "scene", "file": "scene.json", "preview": "preview.gif"]
        )
        try expectFailure("symlink escape preview is rejected") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: symlinkProject, maximumPixelSize: 100)
        }

        let nestedDirectory = fixtureRoot.appendingPathComponent("Nested")
        try fm.createDirectory(
            at: nestedDirectory.appendingPathComponent("previews"),
            withIntermediateDirectories: true
        )
        try writeAnimatedGIF(
            to: nestedDirectory.appendingPathComponent("previews/preview.gif"),
            frames: [try image(width: 8, height: 8, red: 0.1, green: 0.2, blue: 0.9)]
        )
        let nestedProject = try project(
            nestedDirectory,
            ["type": "scene", "file": "scene.json", "preview": "previews/preview.gif"]
        )
        let nestedImage = try ProjectPosterLoader.firstFrame(projectURL: nestedProject, maximumPixelSize: 100)
        try check(nestedImage.width == 8 && nestedImage.height == 8, "nested relative preview inside the project root is accepted")

        let symlinkComponentDirectory = fixtureRoot.appendingPathComponent("SymlinkComponent/Project")
        try fm.createDirectory(at: symlinkComponentDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: symlinkComponentDirectory.appendingPathComponent("assets"),
            withDestinationURL: fixtureRoot
        )
        let symlinkComponentProject = try project(
            symlinkComponentDirectory,
            ["type": "scene", "file": "scene.json", "preview": "assets/outside.gif"]
        )
        try expectFailure("symlink directory component is rejected") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: symlinkComponentProject, maximumPixelSize: 100)
        }

        let directoryDirectory = fixtureRoot.appendingPathComponent("Directory")
        try fm.createDirectory(
            at: directoryDirectory.appendingPathComponent("preview.gif"),
            withIntermediateDirectories: true
        )
        let directoryProject = try project(
            directoryDirectory,
            ["type": "scene", "file": "scene.json", "preview": "preview.gif"]
        )
        try expectFailure("directory preview is rejected as a non-regular file") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: directoryProject, maximumPixelSize: 100)
        }

        let fifoDirectory = fixtureRoot.appendingPathComponent("FIFO")
        try fm.createDirectory(at: fifoDirectory, withIntermediateDirectories: true)
        let fifo = fifoDirectory.appendingPathComponent("preview.gif")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw TestFailure(message: "Cannot create FIFO fixture")
        }
        let fifoProject = try project(
            fifoDirectory,
            ["type": "scene", "file": "scene.json", "preview": "preview.gif"]
        )
        try expectFailure("FIFO preview is rejected without an unbounded read") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: fifoProject, maximumPixelSize: 100)
        }
    }

    static func testReadAndDecodeLimits() throws {
        let oversizedProjectDirectory = fixtureRoot.appendingPathComponent("OversizedProject")
        try fm.createDirectory(at: oversizedProjectDirectory, withIntermediateDirectories: true)
        let oversizedProject = oversizedProjectDirectory.appendingPathComponent("project.json")
        try writeSparseFile(at: oversizedProject, bytes: Int64(ProjectPosterLoader.maximumProjectJSONBytes + 1))
        try expectFailure("oversized project.json is rejected before parsing") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: oversizedProject, maximumPixelSize: 100)
        }

        let oversizedPreviewDirectory = fixtureRoot.appendingPathComponent("OversizedPreview")
        try fm.createDirectory(at: oversizedPreviewDirectory, withIntermediateDirectories: true)
        try writeSparseFile(
            at: oversizedPreviewDirectory.appendingPathComponent("preview.gif"),
            bytes: Int64(ProjectPosterLoader.maximumPreviewBytes + 1)
        )
        let oversizedPreviewProject = try project(
            oversizedPreviewDirectory,
            ["type": "scene", "file": "scene.json", "preview": "preview.gif"]
        )
        try expectFailure("oversized preview is rejected before image decoding") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: oversizedPreviewProject, maximumPixelSize: 100)
        }

        let wideDirectory = fixtureRoot.appendingPathComponent("Wide")
        try fm.createDirectory(at: wideDirectory, withIntermediateDirectories: true)
        let wide = try image(
            width: ProjectPosterLoader.maximumSourceDimension + 1,
            height: 1,
            red: 0.8,
            green: 0.2,
            blue: 0.1
        )
        try writeImage(wide, to: wideDirectory.appendingPathComponent("preview.png"), type: .png)
        let wideProject = try project(
            wideDirectory,
            ["type": "scene", "file": "scene.json", "preview": "preview.png"]
        )
        try expectFailure("over-dimension image is rejected before decoding") {
            _ = try ProjectPosterLoader.firstFrame(projectURL: wideProject, maximumPixelSize: 100)
        }
    }

    static func writeSparseFile(at url: URL, bytes: Int64) throws {
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw TestFailure(message: "Cannot create sparse fixture")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    static func testRealProject(projectPath: String, expectedID: UUID, label: String, expectedNonBlack: Bool) async throws {
        let projectURL = URL(fileURLWithPath: projectPath)
        guard fm.fileExists(atPath: projectURL.path) else {
            throw TestFailure(message: "Required read-only \(label) is unavailable: \(PathRedaction.short(projectURL))")
        }
        let directory = projectURL.deletingLastPathComponent()
        let beforeEntries = try fm.contentsOfDirectory(atPath: directory.path).sorted()
        let projectBefore = try Data(contentsOf: projectURL)
        guard let object = try JSONSerialization.jsonObject(with: projectBefore) as? [String: Any],
              let preview = object["preview"] as? String
        else {
            throw TestFailure(message: "\(label) has no usable preview declaration")
        }
        let previewBefore = try Data(contentsOf: directory.appendingPathComponent(preview))

        resetLegacyMarker()
        let id = expectedID
        let cache = ThumbnailCache(storage: cacheStorage)
        let thumbnail = await cache.thumbnail(
            for: sceneItem(id: id, projectURL: projectURL),
            targetSize: CGSize(width: 320, height: 320)
        )
        guard let cgImage = thumbnail.flatMap(cachedCGImage) else {
            throw TestFailure(message: "\(label) produced no thumbnail")
        }
        try check(max(cgImage.width, cgImage.height) <= 320, "\(label) respects the 320 px bound")
        if expectedNonBlack {
            try check(hasNonBlackPixels(cgImage), "\(label) contains non-black image content")
        }
        try check(!legacyRan(), "\(label) does not invoke legacy Scene rendering")
        try assertJPEG(cacheStorage.thumbnailURL(for: id), maximumDimension: 320)
        try check((try fm.contentsOfDirectory(atPath: directory.path).sorted()) == beforeEntries,
                  "\(label) does not create files in the read-only project")
        try check(try Data(contentsOf: projectURL) == projectBefore,
                  "\(label) project.json remains byte-identical")
        try check(try Data(contentsOf: directory.appendingPathComponent(preview)) == previewBefore,
                  "\(label) preview remains byte-identical")
    }
}
