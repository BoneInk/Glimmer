import CryptoKit
import Foundation
import ImageIO
import WEFormat

/// Generated depth maps by the layer texture they came from: `<key>.png`, the depth map at the
/// source's resolution before smoothing. The key hashes the source's pixels (whatever layer or
/// wallpaper they belong to), the model's version and the processing's revision, so the same
/// picture never runs through the model twice and a new model or processing never reuses an old
/// result. A cache in Caches: losing it only costs a new generation.
public struct DepthMapCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The key of `source`'s pixels for `modelVersion`.
    public static func key(for source: CGImage, modelVersion: String) -> String? {
        guard let pixels = DepthMapBuffer.rgba(of: source) else { return nil }
        return key(pixels: pixels, width: source.width, height: source.height, modelVersion: modelVersion)
    }

    static func key(pixels: [UInt8], width: Int, height: Int, modelVersion: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(width)x\(height)|\(modelVersion)|\(DepthMapProcessing.revision)|".utf8))
        pixels.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return Digest.hex(hasher.finalize().prefix(16))
    }

    public func url(for key: String) -> URL {
        directory.appending(path: "\(key).png")
    }

    public func depth(for key: String) -> DepthMapBuffer? {
        let url = url(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return DepthMapBuffer.gray(of: image)
    }

    public func store(_ depth: DepthMapBuffer, for key: String) throws {
        guard let png = depth.pngData() else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: url(for: key), options: .atomic)
    }
}
