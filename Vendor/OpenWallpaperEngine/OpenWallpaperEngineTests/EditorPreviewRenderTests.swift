import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import OWEEditor
import OWESceneEditing
import XCTest
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's previews, rendered through the real loader and renderer from WE's
/// assets (skipped without them): an effect on the test card, and a preset's particle system as a
/// loop on a dark background.
@MainActor
final class EditorPreviewRenderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "EditorPreviewRenderTests-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch) // Optional: a scratch folder.
    }

    func testTheHelpersDoneLinesAreRead() {
        XCTAssertEqual(EditorPreviewJob.doneIndex(fromLine: Substring(EditorPreviewJob.doneLine(3).dropLast())), 3)
        XCTAssertNil(EditorPreviewJob.doneIndex(fromLine: "progress 3"))
        XCTAssertNil(EditorPreviewJob.doneIndex(fromLine: "done x"))
    }

    func testTheTestCardShipsWithTheApp() throws {
        let url = try XCTUnwrap(EditorPreviewResources.testCard)
        let image = try XCTUnwrap(image(at: url))
        XCTAssertEqual(image.width, EditorPreviewScene.effectFrame.width)
        XCTAssertEqual(image.height, EditorPreviewScene.effectFrame.height)
    }

    func testAnEffectsPreviewIsRendered() async throws {
        let assets = try Fixtures.assets()
        let file = try XCTUnwrap(EffectCatalog.builtInEffectFiles(in: assets).first { $0 == "effects/tint/effect.json" }
                                    ?? EffectCatalog.builtInEffectFiles(in: assets).first)
        let subject = EditorPreviewSubject.effect(file: file, wallpaper: nil)
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: EditorPreviewCache.assetsBuild(of: assets))
        let url = try await EditorPreviewRenderer(scratch: scratch.appending(path: "work"))
            .render(subject, outputBase: cache.outputBase(for: subject))
        XCTAssertEqual(cache.cachedPreview(for: subject), url, "the cache finds what the renderer wrote")
        let picture: CGImage?
        if url.pathExtension == EditorPreviewCache.stillExtension {
            picture = image(at: url)
        } else {
            picture = try await firstFrame(of: url)
        }
        let frame = try XCTUnwrap(picture)
        XCTAssertEqual(frame.width, EditorPreviewScene.effectFrame.pixelWidth)
        XCTAssertEqual(frame.height, EditorPreviewScene.effectFrame.pixelHeight)
        XCTAssertGreaterThan(try colourSpread(frame), 0.1, "the test card shows through the effect")
    }

    func testAParticlePresetsPreviewIsALoop() async throws {
        let assets = try Fixtures.assets()
        let catalog = ParticleCatalog.load(assetsDirectory: assets, translate: { _ in nil })
        guard let item = catalog.items.first(where: { if case .preset = $0.source { return true }; return false }) else {
            throw XCTSkip("the assets have no particle presets")
        }
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: EditorPreviewCache.assetsBuild(of: assets))
        let url = try await EditorPreviewRenderer(scratch: scratch.appending(path: "work"))
            .render(item.previewSubject, outputBase: cache.outputBase(for: item.previewSubject))
        XCTAssertEqual(url.pathExtension, EditorPreviewCache.movieExtension)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let loop = EditorPreviewScene.particleLoopSeconds
        XCTAssertGreaterThanOrEqual(duration, loop.lowerBound - 0.1, "a whole cycle of the preset's systems")
        XCTAssertLessThanOrEqual(duration, loop.upperBound + 0.1)
        let decoded = try await firstFrame(of: url)
        let frame = try XCTUnwrap(decoded)
        XCTAssertEqual(frame.width, EditorPreviewScene.particleFrame.pixelWidth)
        var bounds = EditorPreviewScene.ContentBounds(pixelWidth: frame.width, pixelHeight: frame.height)
        bounds.add(frame)
        if let content = bounds.rect() {
            let centreX: Double = Double(content.midX) / Double(frame.width)
            let centreY: Double = Double(content.midY) / Double(frame.height)
            XCTAssertEqual(centreX, 0.5, accuracy: 0.25, "framed on what it draws")
            XCTAssertEqual(centreY, 0.5, accuracy: 0.25)
        }
    }

    func testAPeriodicEffectIsALoop() async throws {
        let assets = try Fixtures.assets()
        let file = "effects/shake/effect.json"
        guard EffectCatalog.builtInEffectFiles(in: assets).contains(file) else { throw XCTSkip("the assets have no \(file)") }
        let subject = EditorPreviewSubject.effect(file: file, wallpaper: nil)
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: EditorPreviewCache.assetsBuild(of: assets))
        let url = try await EditorPreviewRenderer(scratch: scratch.appending(path: "work"))
            .render(subject, outputBase: cache.outputBase(for: subject))
        XCTAssertEqual(url.pathExtension, EditorPreviewCache.movieExtension, "a small, slow motion is still motion")
    }

    func testShakeVisiblyMovesTheTestCard() async throws {
        let assets = try Fixtures.assets()
        let file = "effects/shake/effect.json"
        guard EffectCatalog.builtInEffectFiles(in: assets).contains(file) else { throw XCTSkip("the assets have no \(file)") }
        let frames = try await renderedFrames(of: .effect(file: file, wallpaper: nil), assets: assets)
        let size = EditorPreviewScene.effectFrame
        let card = try XCTUnwrap(EditorPreviewResources.testCard.flatMap(image(at:)))
        let base = try XCTUnwrap(redrawn(card, width: size.pixelWidth, height: size.pixelHeight))
        let shares: [Double] = frames.map { share(of: $0, differingFrom: base) }
        let most: Double = shares.max() ?? 0
        // The card scaled and encoded alone differs in about 2% (an effect that changes nothing);
        // shake at its defaults with a generated swirl reached 11%, with WE's own preview's
        // sideways direction map most of the card moves.
        XCTAssertGreaterThan(most, Self.shakeShare, "the shake shows: \(shares)")
    }

    func testAFireworksPresetsLoopShowsItsBursts() async throws {
        let frames = try await presetFrames(prefix: "preset:fireworks/")
        let coverage: [Double] = frames.map(contentShare)
        XCTAssertGreaterThan(coverage.max() ?? 0, Self.burstShare, "a burst, not only the launch's glow: \(coverage)")
        // Each burst lands somewhere else; the loop as a whole is framed on them.
        try assertCentred(frames, within: 0.25)
    }

    func testAFirePresetIsFramedOnItsFlame() async throws {
        let frames = try await presetFrames(prefix: "preset:fire/")
        let coverage: [Double] = frames.map(contentShare)
        XCTAssertGreaterThan(coverage.min() ?? 0, Self.flameShare, "the flame fills the tile: \(coverage)")
        for frame in frames { try assertCentred([frame], within: 0.15) }
    }

    func testALightningLoopIsFramedOnTheStrikesItShows() async throws {
        for prefix in ["preset:lightning/0", "preset:lightning/1"] {
            let frames = try await presetFrames(prefix: prefix)
            // Every strike of the loop, together: centred, and in frame (not cut at an edge).
            try assertCentred(frames, within: 0.2)
            for (index, frame) in frames.enumerated() {
                var bounds = EditorPreviewScene.ContentBounds(pixelWidth: frame.width, pixelHeight: frame.height)
                bounds.add(frame)
                guard let drawn = bounds.rect(trim: 0.002) else { continue }
                let inner = CGRect(x: 1, y: 1, width: frame.width - 2, height: frame.height - 2)
                XCTAssertTrue(inner.contains(drawn), "\(prefix) frame \(index): the strike stays inside the frame, \(drawn)")
            }
        }
    }

    // MARK: Preview content

    /// The share of the shake's frame differing from the plain card (a channel 48 of 255 apart).
    static let shakeShare = 0.14
    /// The share of a firework's fullest frame, and of a fire's every frame, that draws.
    static let burstShare = 0.012
    static let flameShare = 0.05

    /// The first variant of the preset whose catalog id starts with `prefix`, rendered.
    private func presetFrames(prefix: String) async throws -> [CGImage] {
        let assets = try Fixtures.assets()
        let catalog = ParticleCatalog.load(assetsDirectory: assets, translate: { _ in nil })
        guard let item = catalog.items.first(where: { $0.id == prefix || $0.id.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") })
                ?? catalog.items.first(where: { $0.id.hasPrefix(prefix) }) else {
            throw XCTSkip("the assets have no \(prefix) preset")
        }
        return try await renderedFrames(of: item.previewSubject, assets: assets)
    }

    /// Every frame of the subject's rendered loop (its still alone), every sixth written to
    /// `OWE_PREVIEW_OUT` as PNGs when it is set, to look at.
    private func renderedFrames(of subject: EditorPreviewSubject, assets: URL) async throws -> [CGImage] {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: EditorPreviewCache.assetsBuild(of: assets))
        let url = try await EditorPreviewRenderer(scratch: scratch.appending(path: "work"))
            .render(subject, outputBase: cache.outputBase(for: subject))
        var frames: [CGImage] = []
        if url.pathExtension == EditorPreviewCache.stillExtension {
            frames = [try XCTUnwrap(image(at: url))]
        } else {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let count = Int((duration * Double(EditorPreviewRenderer.particleFrameRate)).rounded())
            for index in 0..<count {
                let time = CMTime(seconds: duration * Double(index) / Double(count), preferredTimescale: 600)
                frames.append(try await generator.image(at: time).image)
            }
        }
        if let out = ProcessInfo.processInfo.environment["OWE_PREVIEW_OUT"] {
            let folder = URL(filePath: out, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, frame) in frames.enumerated() where index % 6 == 0 {
                let png = folder.appending(path: "\(subject.cacheName)-\(index).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, frame, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
        return frames
    }

    /// The share of the frame's pixels that differ from the particle background
    /// (`EditorPreviewScene.particleBackground`, 13 13 18 of 255) by more than 6.
    private func contentShare(_ frame: CGImage) -> Double {
        guard let pixels = rgba(frame, width: frame.width, height: frame.height) else { return 0 }
        var drawn = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red: Int = abs(Int(pixels[index]) - 13)
            let green: Int = abs(Int(pixels[index + 1]) - 13)
            let blue: Int = abs(Int(pixels[index + 2]) - 18)
            if max(red, green, blue) > 6 { drawn += 1 }
        }
        return Double(drawn) / Double(frame.width * frame.height)
    }

    /// The content of `frames` together is centred in them, to `accuracy` of their size.
    private func assertCentred(_ frames: [CGImage], within accuracy: Double, line: UInt = #line) throws {
        let first = try XCTUnwrap(frames.first, line: line)
        var bounds = EditorPreviewScene.ContentBounds(pixelWidth: first.width, pixelHeight: first.height)
        for frame in frames { bounds.add(frame) }
        let content = try XCTUnwrap(bounds.rect(), "something is drawn", line: line)
        let centreX: Double = Double(content.midX) / Double(first.width)
        let centreY: Double = Double(content.midY) / Double(first.height)
        XCTAssertEqual(centreX, 0.5, accuracy: accuracy, "framed on what it draws", line: line)
        XCTAssertEqual(centreY, 0.5, accuracy: accuracy, line: line)
    }

    /// The share of pixels with a channel more than 48 of 255 from `base`'s.
    private func share(of frame: CGImage, differingFrom base: CGImage) -> Double {
        guard let a = rgba(frame, width: base.width, height: base.height),
              let b = rgba(base, width: base.width, height: base.height) else { return 0 }
        var changed = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            let red: Int = abs(Int(a[index]) - Int(b[index]))
            let green: Int = abs(Int(a[index + 1]) - Int(b[index + 1]))
            let blue: Int = abs(Int(a[index + 2]) - Int(b[index + 2]))
            if max(red, green, blue) > 48 { changed += 1 }
        }
        return Double(changed) / Double(base.width * base.height)
    }

    private func redrawn(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    // MARK: Helpers

    private func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func firstFrame(of url: URL) async throws -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: .zero).image
    }

    /// The largest difference between the image's darkest and brightest channel values, 0…1.
    private func colourSpread(_ image: CGImage) throws -> Double {
        let width = 32, height = 20
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        let channels = pixels.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
        return Double((channels.max() ?? 0) - (channels.min() ?? 0)) / 255
    }
}
