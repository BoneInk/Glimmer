import Foundation
import ImageIO

/// A volume (3D) `.tex`, such as the colour-correction LUTs in `materials/lut` (32×32×32).
///
/// TEXI flag 0x40 marks a volume. Its header carries one more word than a 2D texture's, and so
/// does each mipmap: `width, height, depth, compression, uncompressed size, stored size`. WE's
/// LUTs store one PNG (FreeImage format 13) of `width × (height · depth)` pixels: the slices
/// stacked top to bottom, slice `z` holding blue `z`, rows green and columns red. That is the
/// order a 3D texture's texels are laid out in, so the decoded rows upload as they are.
struct TEXVolume: Equatable {
    let width: Int
    let height: Int
    let depth: Int
    /// Tightly packed RGBA8 texels: x fastest, then y, then z.
    let rgba: [UInt8]

    /// The TEXI flag that marks a volume texture.
    static let volumeFlag = TEXHeader.volumeFlag

    enum ParseError: Error, CustomStringConvertible, Equatable {
        case notVolume
        case malformed(String)
        case unsupported(String)

        var description: String {
            switch self {
            case .notVolume: return "not a volume texture"
            case .malformed(let what): return "malformed volume texture: \(what)"
            case .unsupported(let what): return "unsupported volume texture: \(what)"
            }
        }
    }

    /// Whether `data` is a `.tex` whose TEXI flags mark a volume.
    static func isVolume(_ data: Data) -> Bool {
        TEXFlags(texData: data).map { $0.rawValue & volumeFlag != 0 } ?? false
    }

    init(width: Int, height: Int, depth: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.depth = depth
        self.rgba = rgba
    }

    init(texData data: Data) throws {
        guard Self.isVolume(data) else { throw ParseError.notVolume }
        guard var reader = TEXReader(data) else { throw ParseError.malformed("header") }
        let header = reader.header
        guard header.imageCount > 0 else { throw ParseError.malformed("TEXB") }
        guard header.containerVersion >= 3 else { throw ParseError.unsupported("container TEXB000\(header.containerVersion)") }
        let format = header.format, freeImageFormat = header.freeImageFormat
        guard let mipmaps = reader.word(), mipmaps > 0, let mipmap = reader.mipmap(), let depth = mipmap.depth else {
            throw ParseError.malformed("mipmap")
        }
        let width = UInt32(mipmap.width), height = UInt32(mipmap.height), compression = mipmap.compression
        let payload = reader.bytes[mipmap.stored]
        guard (1...256).contains(width), (1...256).contains(height), (1...256).contains(depth) else {
            throw ParseError.malformed("size \(width)×\(height)×\(depth)")
        }
        guard compression == 0 else { throw ParseError.unsupported("compressed mipmap") }
        let count = Int(width * height * depth) * 4
        if freeImageFormat == -1 {
            // Raw texels: only RGBA8888 (format 0) is a plain copy.
            guard format == 0, payload.count >= count else { throw ParseError.unsupported("raw format \(format)") }
            rgba = Array(payload.prefix(count))
        } else {
            rgba = try Self.decodeImage(Array(payload), width: Int(width), height: Int(height * depth))
        }
        self.width = Int(width)
        self.height = Int(height)
        self.depth = Int(depth)
    }

    /// The stacked slices as RGBA8, with their stored values (no colour management).
    private static func decodeImage(_ payload: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(Data(payload) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ParseError.malformed("image payload")
        }
        guard image.width == width, image.height == height else {
            throw ParseError.malformed("image is \(image.width)×\(image.height), header says \(width)×\(height)")
        }
        do {
            return try SceneTextureUpload.straightRGBA(image)
        } catch {
            throw ParseError.unsupported("image payload: \(error)")
        }
    }
}
