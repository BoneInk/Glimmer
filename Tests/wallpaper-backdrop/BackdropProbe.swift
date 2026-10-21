import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main struct BackdropProbe {
    static func main() async {
        let resolverRoot = URL(
            fileURLWithPath: "/private/tmp/gw-backdrop-resolver-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: resolverRoot) }
        do {
            try FileManager.default.createDirectory(at: resolverRoot, withIntermediateDirectories: true)
            let project = resolverRoot.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: project.appendingPathComponent("index.html"))
            func writePNG(_ url: URL, red: CGFloat, green: CGFloat, blue: CGFloat) throws {
                let context = CGContext(
                    data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                precondition(CGImageDestinationFinalize(destination))
            }
            func setStamp(_ url: URL, _ seconds: TimeInterval) throws {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: seconds)],
                    ofItemAtPath: url.path)
            }
            let projectURL = project.appendingPathComponent("project.json")
            let posterA = project.appendingPathComponent("poster-a.png")
            let posterB = project.appendingPathComponent("poster-b.png")
            let thumbnail = resolverRoot.appendingPathComponent("thumbnail.png")
            try writePNG(posterA, red: 1, green: 0, blue: 0)
            try writePNG(posterB, red: 0, green: 0, blue: 1)
            func writeProject(preview: String) throws {
                let data = try JSONSerialization.data(withJSONObject: [
                    "type": "web", "file": "index.html", "preview": preview
                ], options: [.sortedKeys])
                try data.write(to: projectURL)
            }
            try writeProject(preview: "poster-a.png")
            try setStamp(projectURL, 1_700_000_100)
            try setStamp(posterA, 1_700_000_101)
            let fallback = WallpaperBackdropPosterSource(
                url: resolverRoot.appendingPathComponent("fallback.png"),
                isCanonicalWebRepresentative: false)
            let request = WallpaperBackdropRepresentativeRequest(
                kind: .web, projectURL: projectURL, thumbnailURL: thumbnail,
                fallbackSources: [fallback])
            let resolver = WallpaperBackdropRepresentativeResolver()
            let initial = await resolver.resolve(request)
            precondition(initial.sources == [
                .init(url: posterA, isCanonicalWebRepresentative: true), fallback
            ], "Project preview is resolved before the known thumbnail and system fallback")
            let unchanged = await resolver.resolve(request)
            precondition(unchanged.revision == initial.revision && unchanged.sources == initial.sources,
                         "Stable project/poster/thumbnail stamps reuse the cached descriptor")

            try writeProject(preview: "poster-b.png")
            try setStamp(projectURL, 1_700_000_200)
            let projectChanged = await resolver.resolve(request)
            precondition(projectChanged.sources.first?.url == posterB &&
                         projectChanged.revision != initial.revision,
                         "project.json changes invalidate the cached preview descriptor")

            try writePNG(posterB, red: 0, green: 1, blue: 0)
            try setStamp(posterB, 1_700_000_300)
            let posterChanged = await resolver.resolve(request)
            precondition(posterChanged.sources.first?.url == posterB &&
                         posterChanged.revision != projectChanged.revision,
                         "Poster content revisions invalidate the representative source snapshot")

            try writePNG(thumbnail, red: 1, green: 1, blue: 0)
            try setStamp(thumbnail, 1_700_000_400)
            let thumbnailAdded = await resolver.resolve(request)
            precondition(thumbnailAdded.sources == [
                .init(url: posterB, isCanonicalWebRepresentative: true),
                .init(url: thumbnail, isCanonicalWebRepresentative: true), fallback
            ] && thumbnailAdded.revision != posterChanged.revision,
                         "A newly created library thumbnail joins the cached Web source list")

            try writePNG(thumbnail, red: 1, green: 0, blue: 1)
            try setStamp(thumbnail, 1_700_000_500)
            let thumbnailChanged = await resolver.resolve(request)
            precondition(thumbnailChanged.revision != thumbnailAdded.revision &&
                         thumbnailChanged.sources == thumbnailAdded.sources,
                         "Thumbnail content revision forces revalidation without losing source order")

            try FileManager.default.removeItem(at: thumbnail)
            let thumbnailRemoved = await resolver.resolve(request)
            precondition(thumbnailRemoved.sources == [
                .init(url: posterB, isCanonicalWebRepresentative: true), fallback
            ] && thumbnailRemoved.revision != thumbnailChanged.revision,
                         "Deleting a thumbnail removes it on the next source resolution")
            print("PASS: representative resolver source order, project/poster/thumbnail invalidation and stable reuse (6 checks)")
        } catch {
            fatalError("Backdrop representative resolver probe failed: \(error)")
        }
        let active: Set<String> = ["primary", "secondary"]
        precondition(WallpaperBackdropSourceRouting.sessionDisplayID(screenIsKnown: true, windowDisplayID: "secondary", primaryDisplayID: "primary", activeSessionDisplayIDs: active) == "secondary")
        precondition(WallpaperBackdropSourceRouting.sessionDisplayID(screenIsKnown: true, windowDisplayID: "unassigned", primaryDisplayID: "primary", activeSessionDisplayIDs: active) == nil)
        precondition(WallpaperBackdropSourceRouting.sessionDisplayID(screenIsKnown: true, windowDisplayID: nil, primaryDisplayID: "primary", activeSessionDisplayIDs: active) == nil)
        precondition(WallpaperBackdropSourceRouting.sessionDisplayID(screenIsKnown: false, windowDisplayID: nil, primaryDisplayID: "primary", activeSessionDisplayIDs: active) == "primary")
        precondition(WallpaperBackdropSourceRouting.sessionDisplayID(screenIsKnown: false, windowDisplayID: nil, primaryDisplayID: "primary", activeSessionDisplayIDs: []) == nil)
        var cache = WallpaperBackdropFrameCache<String>()
        precondition(cache.select("applied-A"))
        cache.frame = "deterministic-poster-A"
        // A source identity stays unchanged for focus/play/pause/occlusion/viewport events.
        precondition(!cache.select("applied-A") && cache.frame == "deterministic-poster-A")
        precondition(cache.select("applied-B") && cache.frame == nil)
        cache.frame = "deterministic-poster-B"
        cache.releaseFrame()
        precondition(cache.sourceKey == "applied-B" && cache.frame == nil)
        precondition(!cache.select("applied-B"))
        cache.frame = "same-regenerated-poster-B"
        cache.reset()
        precondition(cache.sourceKey == nil && cache.frame == nil)
        precondition(cache.select("applied-B"))
        cache.frame = "project-poster"
        precondition(!cache.replaceWebSnapshot("hidden-web-black", isPainted: false))
        precondition(cache.frame == "project-poster", "Blank Web snapshot must retain project poster")
        precondition(cache.replaceWebSnapshot("painted-web", isPainted: true))
        precondition(cache.frame == "painted-web")
        precondition(WallpaperBackdropPosterPolicy.seconds(duration: 60) == 1)
        precondition(WallpaperBackdropPosterPolicy.seconds(duration: 2) == 0.3)
        precondition(WallpaperBackdropPosterPolicy.seconds(duration: 0) == 0)
        precondition(WallpaperBackdropPosterPolicy.seconds(duration: .nan) == 0)
        print("PASS: static source cache lifecycle (7 checks), blank Web retention (4 checks), deterministic poster time (4 checks)")
        precondition(WallpaperBackdropViewportPolicy.resolved(
            probeBounds: CGSize(width: 1600, height: 900),
            windowBounds: CGSize(width: 1200, height: 800)
        ) == CGSize(width: 1600, height: 900))
        precondition(WallpaperBackdropViewportPolicy.resolved(
            probeBounds: .zero,
            windowBounds: CGSize(width: 1200, height: 800)
        ) == CGSize(width: 1200, height: 800))
        precondition(WallpaperBackdropViewportPolicy.resolved(
            probeBounds: CGSize(width: CGFloat.nan, height: 900),
            windowBounds: CGSize(width: CGFloat.infinity, height: 800)
        ) == .zero)
        print("PASS: laid-out probe viewport, window fallback and invalid-size rejection (3 checks)")
        var ownership = WallpaperBackdropProbeOwnership<String>()
        ownership.claim("old")
        ownership.claim("new")
        precondition(!ownership.release("old") && ownership.activeID == "new",
                     "A dismantled stale probe must not clear the replacement probe's model")
        precondition(ownership.release("new") && ownership.activeID == nil,
                     "The active probe still owns final cleanup")
        print("PASS: replacement probe survives stale dismantle; active probe owns cleanup (2 checks)")
        let roi = WallpaperBackdropComposition.sourceRegion(in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        precondition(roi == CGRect(x: 0, y: 300, width: 1000, height: 580))
        let offsetROI = WallpaperBackdropComposition.sourceRegion(in: CGRect(x: 20, y: 40, width: 800, height: 500))
        precondition(offsetROI == CGRect(x: 20, y: 190, width: 800, height: 290))
        let width = 1920, height = 1280
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = ((x / 8 + y / 8) % 2) == 0 ? 0 : 255
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
            }
        }
        let data = Data(pixels) as CFData
        let source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        precondition(WallpaperBackdropVisibilityPolicy.canRender(eligible: true, unoccluded: false, firstPoster: true))
        precondition(!WallpaperBackdropVisibilityPolicy.canRender(eligible: true, unoccluded: false, firstPoster: false))
        precondition(WallpaperBackdropVisibilityPolicy.canRender(eligible: true, unoccluded: true, firstPoster: false))
        precondition(!WallpaperBackdropVisibilityPolicy.canRender(eligible: false, unoccluded: true, firstPoster: true))
        precondition(!WallpaperBackdropVisibilityPolicy.canRender(eligible: false, unoccluded: false, firstPoster: true))
        print("PASS: first-poster eligibility without visible occlusion bit; existing-poster resize throttling (5 checks)")
        var policy = WallpaperBackdropWebPosterPolicy()
        precondition(!policy.update(ready: false, visible: true))
        precondition(policy.update(ready: true, visible: true))
        precondition(!policy.update(ready: true, visible: true))
        precondition(!policy.update(ready: true, visible: false))
        precondition(policy.update(ready: true, visible: true))
        policy.didCapture()
        precondition(!policy.update(ready: false, visible: false))
        precondition(!policy.update(ready: true, visible: true))
        print("PASS: one-shot Web poster ready/visibility retry and captured freeze (7 checks)")
        precondition(!WallpaperBackdropWebSourcePolicy.canAttemptSnapshot(representativeResolved:false,ready:true,visible:true))
        precondition(WallpaperBackdropWebSourcePolicy.canAttemptSnapshot(representativeResolved:true,ready:true,visible:true))
        precondition(!WallpaperBackdropWebSourcePolicy.canAttemptSnapshot(representativeResolved:true,ready:false,visible:true))
        precondition(!WallpaperBackdropWebSourcePolicy.canAttemptSnapshot(representativeResolved:true,ready:true,visible:false))
        print("PASS: canonical representative resolution gates ready Web snapshot (4 checks)")
        func solidImage(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> CGImage {
            let pixels = [red, green, blue, alpha]
            return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        }
        precondition(!WallpaperBackdropPosterQuality.isPainted(solidImage(red: 0, green: 0, blue: 0, alpha: 255)))
        precondition(!WallpaperBackdropPosterQuality.isPainted(solidImage(red: 0, green: 0, blue: 0, alpha: 0)))
        precondition(!WallpaperBackdropPosterQuality.isPainted(solidImage(red: 12, green: 10, blue: 8, alpha: 255)))
        precondition(WallpaperBackdropPosterQuality.isPainted(solidImage(red: 255, green: 0, blue: 0, alpha: 255)))
        let flatNavy = solidImage(red: 8, green: 24, blue: 38, alpha: 255)
        precondition(WallpaperBackdropPosterQuality.isPainted(flatNavy),
                     "A visible flat authored color is painted, not globally invalid")
        precondition(!WallpaperBackdropPosterQuality.shouldReplaceRuntimeSnapshot(flatNavy,hasRepresentative:true),
                     "A flat HTML body must retain an existing representative")
        precondition(WallpaperBackdropPosterQuality.shouldReplaceRuntimeSnapshot(flatNavy,hasRepresentative:false),
                     "A flat authored wallpaper remains valid when no representative exists")
        precondition(WallpaperBackdropPosterQuality.shouldReplaceRuntimeSnapshot(source,hasRepresentative:true),
                     "A detailed runtime frame may upgrade an existing representative")
        if let posterPath = ProcessInfo.processInfo.environment["GW_BACKDROP_POSTER_PROBE"] {
            let posterURL = URL(fileURLWithPath: posterPath)
            let imageSource = CGImageSourceCreateWithURL(posterURL as CFURL, nil)
            let poster = imageSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            precondition(poster.map(WallpaperBackdropPosterQuality.isPainted) == true,
                         "Real assigned project poster must be accepted")
            precondition(poster.map { WallpaperBackdropPosterQuality.shouldReplaceRuntimeSnapshot($0,hasRepresentative:true) } == true,
                         "Real assigned project poster contains painted detail")
            let loader = WallpaperBackdropPosterLoader()
            let missing = posterURL.deletingLastPathComponent().appendingPathComponent("missing-poster.invalid")
            let loaded = await loader.load(videoURL:nil,desktopSources:[
                .init(url:missing,isCanonicalWebRepresentative:true),
                .init(url:posterURL,isCanonicalWebRepresentative:true)
            ])
            precondition(loaded?.isCanonicalWebRepresentative == true && loaded?.image.width ?? 0 > 0,
                         "Missing project poster falls through to the known representative thumbnail")
            let systemFallback = await loader.load(videoURL:nil,desktopSources:[
                .init(url:missing,isCanonicalWebRepresentative:true),
                .init(url:posterURL,isCanonicalWebRepresentative:false)
            ])
            precondition(systemFallback?.isCanonicalWebRepresentative == false && systemFallback?.image.width ?? 0 > 0,
                         "Poster/thumbnail decode failure can use system fallback without misclassifying it as representative")
            print("PASS: actual assigned project poster is painted: \(posterPath)")
        }
        print("PASS: blank/near-black rejected; representative-aware flat placeholder policy preserves valid authored flat content (8 checks)")
        let renderer = WallpaperBackdropRenderer()
        guard let output = await renderer.render(frame: source, desktopURL: nil) else { fatalError("CI render returned no output") }
        precondition(output.width == 960 && output.height == 640, "Render must downsample before variable blur")
        let context = CIContext()
        func variance(_ image: CGImage, y: CGFloat) -> Double {
            let ci = CIImage(cgImage: image)
            let crop = CGRect(x: 64, y: y, width: CGFloat(image.width - 128), height: 32)
            let sample = context.createCGImage(ci, from: crop)!
            var bytes = [UInt8](repeating: 0, count: sample.width * sample.height * 4)
            let bitmap = CGContext(data: &bytes, width: sample.width, height: sample.height, bitsPerComponent: 8,
                                   bytesPerRow: sample.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
            let values = stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        }
        let bottom = variance(output, y: 32), top = variance(output, y: 592)
        let clearOutput = await renderer.render(frame: source, desktopURL: nil, blurAmount: 0)!
        precondition(variance(clearOutput, y: 592) > 1000 && top < 100,
                     "Blur setting must visibly soften the same cached source without replacing it")
        precondition(top < 100 && bottom <= top + 1, "Backdrop must soften upper detail and increase blur below: top=\(top) bottom=\(bottom)")
        let center = variance(output, y: 304)
        precondition(center < 100, "High-frequency center texture must not compete with controls: \(center)")
        // Asset preferred-transform normalization handles a rotated source without clipping.
        let rotated = await renderer.render(frame: source, desktopURL: nil, transform: CGAffineTransform(rotationAngle: .pi / 2))!
        precondition(rotated.width == 640 && rotated.height == 960)
        let wide = await renderer.render(frame: source, desktopURL: nil,
                                         transform: CGAffineTransform(rotationAngle: .pi / 2),
                                         viewportSize: CGSize(width: 1600, height: 900))!
        precondition(wide.width == 960 && wide.height == 540, "Portrait input must be cropped to wide viewport BEFORE masking")
        let wideTop = variance(wide, y: 492), wideBottom = variance(wide, y: 32)
        precondition(wideTop < 100 && wideBottom <= wideTop + 1)
        let wideCenter = variance(wide, y: 254)
        precondition(wideCenter < 100, "Portrait-to-wide background remains softly defocused")
        // RGB bands identify source coordinates: top12% red, upper-middle58% green,
        // bottom30% blue. Full-poster center-fill would incorrectly include the blue band.
        var bands = [UInt8](repeating: 0, count: 1000 * 1000 * 4)
        for y in 0..<1000 {
            for x in 0..<1000 {
                let offset = (y * 1000 + x) * 4
                let channel = y < 120 ? 0 : (y < 700 ? 1 : 2)
                bands[offset + channel] = 255
                bands[offset + 3] = 255
            }
        }
        let bandImage = CGImage(width: 1000, height: 1000, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: CGDataProvider(data: Data(bands) as CFData)!, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)!
        let bandOutput = await renderer.render(frame: bandImage, desktopURL: nil,
                                               viewportSize: CGSize(width: 1600, height: 900))!
        var bandPixels = [UInt8](repeating: 0, count: bandOutput.width * bandOutput.height * 4)
        let bandContext = CGContext(data: &bandPixels, width: bandOutput.width, height: bandOutput.height,
                                    bitsPerComponent: 8, bytesPerRow: bandOutput.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bandContext.draw(bandOutput, in: CGRect(x: 0, y: 0, width: bandOutput.width, height: bandOutput.height))
        var sums = [Double](repeating: 0, count: 3)
        for i in stride(from: 0, to: bandPixels.count, by: 4) {
            for channel in 0..<3 { sums[channel] += Double(bandPixels[i + channel]) }
        }
        let count = Double(bandOutput.width * bandOutput.height)
        let means = sums.map { $0 / count }
        precondition(means[1] > means[0] + 80 && means[1] > means[2] + 80,
                     "Only upper-middle source region should remain; RGB means=\(means)")
        print("PASS: upper-middle source ROI geometry (2 checks) and RGB band crop means \(means)")
        print("PASS: central-band variance \(center), portrait-to-wide central-band variance \(wideCenter)")
        print("PASS: portrait-to-wide top variance \(wideTop), bottom variance \(wideBottom)")
        print("PASS: source routing (5 cases), size bound 960, top variance \(top), bottom variance \(bottom), 90-degree transform dimensions")
    }
}
