import Foundation
import CoreGraphics
import ImageIO

private actor ReviewStartGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { started = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
}

@main enum MetalIndependentReviewProbe {
    static func image(_ bytes: Data, width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let value = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw SceneWallpaperFailure(message: "synthetic CGImage creation failed")
        }
        return value
    }
    static func encoded(_ bytes: Data, width: Int, height: Int, type: String) throws -> Data {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw SceneWallpaperFailure(message: "synthetic image destination failed")
        }
        CGImageDestinationAddImage(out, try image(bytes, width: width, height: height), nil)
        guard CGImageDestinationFinalize(out) else { throw SceneWallpaperFailure(message: "synthetic encode failed") }
        return data as Data
    }
    static func inspect(_ asset: SceneTextureAsset) -> SceneWallpaperInspection {
        .init(canvasSize: .init(x: 2, y: 2), clearColor: .init(x: 0, y: 0, z: 0),
              layers: [.init(id: 1, name: "original fixture", modelPath: "", materialPath: "", texturePath: "t",
                  origin: .init(x: 1, y: 1, z: 0), anglesDegrees: .init(x: 0, y: 0, z: 0),
                  scale: .init(x: 1, y: 1, z: 1), size: .init(x: 2, y: 2), tint: .init(x: 1, y: 1, z: 1),
                  opacity: 1, isVisible: true, bindings: [])], textures: ["t": asset], diagnostics: [])
    }
    static func draw(_ source: String) -> MetalSceneDraw {
        .init(source: source, transform: .init(a: 1, b: 0, c: 0, d: 1, tx: 4, ty: 0.5),
              size: .init(x: 8, y: 1), sampling: .linear, blend: .copy)
    }
    static func main() async throws {
        let gpu = try MetalSceneCompositor()
        var results: [String: Any] = ["device": gpu.deviceName]
        // Independently authored CGImage -> PNG. Not generated from Metal output,
        // so an encode/decode double flip cannot conceal a raw/PNG orientation mismatch.
        let colors = Data([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255])
        let png = try encoded(colors, width: 2, height: 2, type: "public.png")
        let raw = SceneTextureAsset(path: "t", format: .rgba8888, flags: 1, data: colors,
                                   storageWidth: 2, storageHeight: 2, imageWidth: 2, imageHeight: 2)
        let packed = SceneTextureAsset(path: "t", format: .png, flags: 1, data: png,
                                      storageWidth: 2, storageHeight: 2, imageWidth: 2, imageHeight: 2)
        let rawPixels = try gpu.render(inspection: inspect(raw), pixelSize: .init(width: 2, height: 2)).rgba
        let pngPixels = try gpu.render(inspection: inspect(packed), pixelSize: .init(width: 2, height: 2)).rgba
        results["rawTopToBottomRGBA"] = Array(rawPixels)
        results["pngTopToBottomRGBA"] = Array(pngPixels)
        results["rawPNGOrientationEqual"] = rawPixels == pngPixels && rawPixels == colors
        let alpha = Data([200,100,50,3, 20,180,40,32, 50,70,220,128, 255,255,255,255])
        let alphaPNG = try encoded(alpha, width: 2, height: 2, type: "public.png")
        let a = SceneTextureAsset(path: "t", format: .rgba8888, flags: 1, data: alpha, storageWidth: 2, storageHeight: 2, imageWidth: 2, imageHeight: 2)
        let b = SceneTextureAsset(path: "t", format: .png, flags: 1, data: alphaPNG, storageWidth: 2, storageHeight: 2, imageWidth: 2, imageHeight: 2)
        let ar = try gpu.render(inspection: inspect(a), pixelSize: .init(width: 2, height: 2)).rgba
        let br = try gpu.render(inspection: inspect(b), pixelSize: .init(width: 2, height: 2)).rgba
        let difference = zip(ar,br).map { abs(Int($0)-Int($1)) }.max() ?? 0
        results["rawPNGAlphaMaximumByteDifference"] = difference
        let inputs = ["edge": MetalSceneTexture(width: 2, height: 1, rgba: Data([255,0,0,0,0,0,255,255]))]
        let direct = try gpu.render(textures: inputs, passes: [.init(target: "direct", width: 8, height: 1, draws: [draw("edge")])])
        let chain = try gpu.render(textures: inputs, passes: [
            .init(target: "a", width: 8, height: 1, draws: [draw("edge")]),
            .init(target: "b", width: 8, height: 1, draws: [draw("a")])])
        results["bilinearPriorTargetMatchesDirect"] = direct.rgba == chain.rgba
        // Observe cancellation during bounded CPU upload, without a GUI and without
        // attempting to cancel a submitted GPU command. This is timing evidence, not
        // a deterministic claim that cancellation happened at an exact instruction.
        let gate = ReviewStartGate()
        let task = Task.detached { () throws -> Bool in
            let local = try MetalSceneCompositor()
            let bytes = Data(repeating: 128, count: 4096 * 2048 * 4)
            await gate.signal()
            do {
                _ = try local.render(textures: ["large": .init(width: 4096, height: 2048, rgba: bytes)],
                                     passes: [.init(target: "out", width: 1, height: 1, draws: [])])
                return false
            } catch is CancellationError { return true }
        }
        await gate.wait()
        try await Task.sleep(for: .milliseconds(15))
        let cancelledAt = Date(); task.cancel()
        results["uploadCancellationThrows"] = try await task.value
        results["uploadCancellationWaitSeconds"] = Date().timeIntervalSince(cancelledAt)
        results["scope"] = "Independent original synthetic pixels; actual Metal offscreen, no GUI/user media/account. No production modifications. Timing sample is not a cancellation deadline guarantee."
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(decoding: data, as: UTF8.self))
    }
}
