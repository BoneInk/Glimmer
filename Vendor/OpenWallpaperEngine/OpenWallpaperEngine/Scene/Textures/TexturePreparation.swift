import AppKit
import CryptoKit
import Foundation
import Metal

/// "Optimise textures": colour images that a scene draws (an image layer's or particle's own
/// texture) are compressed once to BC7 (`TextureCompressor`), with their mipmaps, and kept as a
/// blob file that later loads map straight from disk instead of decoding the image again.
///
/// - Only colour textures: masks, flow maps, normal maps, noise, lookup tables and anything else an
///   effect or material reads as data never come here (the loader asks only for a layer's or a
///   particle's base texture), and nor do one- or two-channel images.
/// - A texture keeps its size, so `g_Texture*Resolution` and every layer size stay as they were.
///   It keeps the mipmap count its `.tex` stores from the loaded level on.
/// - The first load draws the decoded image as before and compresses it in the background on the
///   `PreparationPool`; the load after uses the blob. A blob whose decoded texels miss the quality
///   bar (`accepts`) is stored as "keep the original", so the check isn't repeated.
/// - Blobs are content-addressed (a hash of the `.tex` file and the loaded level), so identical
///   textures share one, across wallpapers and across scene cache keys (Inspector edits, user
///   properties and displays don't recompress anything).
/// - Blob layout: one header page, then each mipmap at a 16 KiB-aligned offset, uncompressed on
///   disk, so a mapped file's levels upload without a copy into process memory.
/// - The blob also records the texture's content class and whether it is opaque, which the layer
///   analysis reads instead of sampling the image (it can't sample a block-compressed one).
enum TexturePreparation {
    static let fileExtension = "owetex"
    static let magic: UInt64 = 0x3130_5845_5445_574F // "OWETEX01"
    static let pageSize = 16384
    /// Textures smaller than this many texels aren't worth a blob.
    static let minimumTexels = 256 * 256

    enum Status: UInt32 { case compressed = 1, keptOriginal = 2 }

    /// What a finished preparation records.
    struct Header: Equatable {
        var revision: UInt32
        var status: Status
        var width: Int
        var height: Int
        var contentClass: SceneLayerContentClass?
        var opaque: Bool
        var lumaSSIM: Double
        var deltaE99: Double
        /// (offset, length) of each mipmap in the file.
        var levels: [(offset: Int, length: Int)]

        static func == (a: Header, b: Header) -> Bool {
            a.revision == b.revision && a.status == b.status && a.width == b.width && a.height == b.height
                && a.contentClass == b.contentClass && a.opaque == b.opaque && a.lumaSSIM == b.lumaSSIM
                && a.deltaE99 == b.deltaE99 && a.levels.map(\.offset) == b.levels.map(\.offset)
                && a.levels.map(\.length) == b.levels.map(\.length)
        }
    }

    static var defaultRoot: URL { WallpaperStorage.directory.appending(path: ".owe-cache/textures", directoryHint: .isDirectory) }

    /// Where blobs live; tests point it elsewhere.
    nonisolated(unsafe) static var root: URL = defaultRoot

    /// Apple GPUs on macOS sample BC7; without that the feature stays off.
    static let deviceSupportsBC7: Bool = MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression ?? false

    // MARK: Keys

    /// The blob name for the `.tex` file `texData` loaded at mipmap `level`.
    static func key(texData: Data, level: Int) -> String {
        let digest = Digest.hex(SHA256.hash(data: texData).prefix(16))
        return "\(digest)-l\(level)"
    }

    static func url(key: String) -> URL { root.appending(path: "\(key).\(fileExtension)") }

    // MARK: Lookup

    /// The compressed texture for `key`, mapped from its blob; nil when there is none yet, it was
    /// kept original, or it can't be read (then it is deleted and rebuilt next time).
    static func cachedTexture(key: String) -> TEXCompressedTexture? {
        let url = url(key: key)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            let header = try decodeHeader(data)
            guard header.status == .compressed else { return nil }
            var texture = TEXCompressedTexture(format: TEXCompressedTexture.bc7Format, width: header.width,
                                               height: header.height, data: [], contentWidth: header.width,
                                               contentHeight: header.height)
            texture.storedLevels = header.levels.map { data[$0.offset..<($0.offset + $0.length)] }
            texture.contentClass = header.contentClass
            texture.opaque = header.opaque
            texture.sourceKey = key
            CacheEntryUse.markUsed(url)
            return texture
        } catch {
            OWELog.info(.scene, "Texture cache: dropping unreadable \(url.lastPathComponent): \(error)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Whether a blob (compressed or kept original) exists for `key` with this encoder's revision.
    static func isPrepared(key: String) -> Bool {
        // Optional: no blob, or one an older encoder wrote, is simply not prepared yet.
        guard let data = try? Data(contentsOf: url(key: key), options: .alwaysMapped) else { return false }
        return (try? decodeHeader(data)) != nil
    }

    // MARK: Preparation

    private static let inFlightLock = NSLock()
    nonisolated(unsafe) private static var inFlight: Set<String> = []

    /// Compresses `image` into the blob for `key` on the preparation pool, unless it is already
    /// prepared or being prepared. `mipmaps` is the number of levels to store (the `.tex`'s own
    /// count from the loaded level on).
    @discardableResult
    static func schedule(_ image: NSImage, key: String, mipmaps: Int,
                         pool: PreparationPool = .shared) -> PreparationPool.Job? {
        guard deviceSupportsBC7, let texels = straightTexels(image),
              texels.width * texels.height >= minimumTexels else { return nil }
        inFlightLock.lock()
        let fresh = inFlight.insert(key).inserted
        inFlightLock.unlock()
        guard fresh else { return nil }
        return pool.submit(priority: .library, estimatedBytes: texels.width * texels.height * 12,
                           onCancel: { finish(key) }) { job in
            defer { finish(key) }
            guard !job.isCancelled, !isPrepared(key: key) else { return }
            do {
                try prepare(texels.bytes, width: texels.width, height: texels.height, mipmaps: mipmaps, key: key)
            } catch {
                OWELog.info(.scene, "Texture cache: \(key) not prepared: \(error)")
            }
        }
    }

    private static func finish(_ key: String) {
        inFlightLock.lock()
        inFlight.remove(key)
        inFlightLock.unlock()
    }

    /// Straight-alpha RGBA8 texels of a colour image; nil for one- and two-channel images (data
    /// textures such as masks) and anything unreadable.
    static func straightTexels(_ image: NSImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        if let raw = TEXRawImageRep.of(image) {
            guard raw.channels == .rgba else { return nil }
            let width = raw.pixelsWide, height = raw.pixelsHigh
            if raw.rowPixels == width { return (raw.bytes, width, height) }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                let source = row * raw.rowPixels * 4
                bytes[(row * width * 4)..<((row + 1) * width * 4)] = raw.bytes[source..<(source + width * 4)]
            }
            return (bytes, width, height)
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bytes = try? SceneTextureUpload.straightRGBA(cgImage) else { return nil }
        return (bytes, cgImage.width, cgImage.height)
    }

    /// Whether a compressed texture's quality passes: the efficiency plan's lossy bar (ΔE2000 99th
    /// percentile ≤ 2), with SSIM ≥ 0.995 for text and line art and ≥ 0.985 for photos (margin over
    /// the scene-level 0.98), alpha SSIM ≥ 0.995 so edges keep their shape, and SSIM ≥ 0.99 over
    /// the windows with hard edges, so outlines, line art and lettering inside an image hold the
    /// plan's text bar once drawn.
    static func accepts(_ quality: TextureCompressor.Quality, contentClass: SceneLayerContentClass) -> Bool {
        let lumaBar = contentClass == .photo ? 0.985 : 0.995
        return quality.lumaSSIM >= lumaBar && quality.alphaSSIM >= 0.995 && quality.edgeSSIM >= 0.99
            && quality.deltaE99 <= 2.0
    }

    /// Compresses `bytes` and writes the blob for `key`; returns its header.
    @discardableResult
    static func prepare(_ bytes: [UInt8], width: Int, height: Int, mipmaps: Int, key: String) throws -> Header {
        ThreadGuards.assertBackground("texture preparation")
        let contentClass = classify(bytes, width: width, height: height)
        let opaque = stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 }
        let base = bytes.withUnsafeBytes { TextureCompressor.encodeBC7($0, width: width, height: height, rowBytes: width * 4) }
        let decoded = base.withUnsafeBytes { TextureCompressor.decodeBC7($0, width: width, height: height) }
        let quality = TextureCompressor.quality(reference: bytes, candidate: decoded, width: width, height: height)
        let accepted = accepts(quality, contentClass: contentClass)
        var levels: [[UInt8]] = []
        if accepted {
            levels.append(base)
            var level = (texels: bytes, width: width, height: height)
            for _ in 1..<max(1, mipmaps) where level.width > 1 || level.height > 1 {
                level = TextureCompressor.halfSize(level.texels, width: level.width, height: level.height)
                levels.append(level.texels.withUnsafeBytes {
                    TextureCompressor.encodeBC7($0, width: level.width, height: level.height, rowBytes: level.width * 4)
                })
            }
        }
        var header = Header(revision: UInt32(TextureCompressor.revision), status: accepted ? .compressed : .keptOriginal,
                            width: width, height: height, contentClass: contentClass, opaque: opaque,
                            lumaSSIM: quality.lumaSSIM, deltaE99: quality.deltaE99, levels: [])
        var offset = pageSize
        for level in levels {
            header.levels.append((offset, level.count))
            offset += (level.count + pageSize - 1) / pageSize * pageSize
        }
        var file = Data(count: offset)
        file.replaceSubrange(0..<pageSize, with: encodeHeader(header))
        for (index, level) in levels.enumerated() {
            let start = header.levels[index].offset
            file.replaceSubrange(start..<(start + level.count), with: level)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = url(key: key)
        let temporary = root.appending(path: ".\(key).\(UUID().uuidString).tmp")
        try file.write(to: temporary)
        if rename(temporary.path(percentEncoded: false), destination.path(percentEncoded: false)) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        OWELog.info(.scene, String(format: "Texture cache: %@ %d×%d %@ (%@, SSIM %.4f, edges %.4f, ΔE99 %.2f)", key,
                                   width, height, accepted ? "compressed to BC7" : "kept original", contentClass.rawValue,
                                   quality.lumaSSIM, quality.edgeSSIM, quality.deltaE99))
        return header
    }

    /// The layer analysis's class of an RGBA8 image, from its 128² luma sample.
    static func classify(_ bytes: [UInt8], width: Int, height: Int) -> SceneLayerContentClass {
        let scale = min(1, 128 / Float(max(width, height)))
        let w = max(1, Int((Float(width) * scale).rounded())), h = max(1, Int((Float(height) * scale).rounded()))
        var luma = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let sy = min(height - 1, Int(Float(y) / scale))
            for x in 0..<w {
                let sx = min(width - 1, Int(Float(x) / scale))
                let o = (sy * width + sx) * 4
                let a = Float(bytes[o + 3]) / 255
                luma[y * w + x] = (0.2126 * Float(bytes[o]) + 0.7152 * Float(bytes[o + 1]) + 0.0722 * Float(bytes[o + 2])) / 255 * a
            }
        }
        return SceneLayerAnalysis.classify(luma: luma, width: w, height: h)
    }

    // MARK: Header coding

    enum BlobError: Error { case truncated, foreign, revision }

    static func encodeHeader(_ header: Header) -> Data {
        var data = Data(count: pageSize)
        var cursor = 0
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(cursor..<(cursor + $0.count), with: $0) }
            cursor += MemoryLayout<T>.size
        }
        put(magic)
        put(header.revision)
        put(header.status.rawValue)
        put(UInt32(header.width))
        put(UInt32(header.height))
        put(UInt32(header.contentClass.map { ["text", "lineArt", "photo"].firstIndex(of: $0.rawValue) ?? 255 } ?? 255))
        put(UInt32(header.opaque ? 1 : 0))
        put(header.lumaSSIM.bitPattern)
        put(header.deltaE99.bitPattern)
        put(UInt32(header.levels.count))
        for level in header.levels {
            put(UInt64(level.offset))
            put(UInt64(level.length))
        }
        return data
    }

    static func decodeHeader(_ data: Data) throws -> Header {
        guard data.count >= pageSize else { throw BlobError.truncated }
        var cursor = data.startIndex
        func get<T: FixedWidthInteger>(_: T.Type) -> T {
            let value = data[cursor..<(cursor + MemoryLayout<T>.size)].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            cursor += MemoryLayout<T>.size
            return T(littleEndian: value)
        }
        guard get(UInt64.self) == magic else { throw BlobError.foreign }
        let revision = get(UInt32.self)
        guard revision == UInt32(TextureCompressor.revision) else { throw BlobError.revision }
        guard let status = Status(rawValue: get(UInt32.self)) else { throw BlobError.foreign }
        let width = Int(get(UInt32.self)), height = Int(get(UInt32.self))
        let classIndex = Int(get(UInt32.self))
        let classes: [SceneLayerContentClass] = [.text, .lineArt, .photo]
        let contentClass = classes.indices.contains(classIndex) ? classes[classIndex] : nil
        let opaque = get(UInt32.self) == 1
        let ssim = Double(bitPattern: get(UInt64.self))
        let deltaE = Double(bitPattern: get(UInt64.self))
        let count = Int(get(UInt32.self))
        guard count <= 32 else { throw BlobError.foreign }
        var levels: [(offset: Int, length: Int)] = []
        for _ in 0..<count {
            let offset = Int(get(UInt64.self)), length = Int(get(UInt64.self))
            guard offset % pageSize == 0, offset + length <= data.count else { throw BlobError.truncated }
            levels.append((offset, length))
        }
        let blocks = TextureCompressor.blockCount(width: width, height: height) * 16
        guard status == .keptOriginal || (levels.first?.length == blocks) else { throw BlobError.truncated }
        return Header(revision: revision, status: status, width: width, height: height, contentClass: contentClass,
                      opaque: opaque, lumaSSIM: ssim, deltaE99: deltaE, levels: levels)
    }
}
