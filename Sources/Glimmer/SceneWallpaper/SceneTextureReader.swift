// TEX layout reference: MIT RePKG TexReader/TexHeaderReader/TexImageReader,
// pinned in README. Static LZ4 + DXT1/3/5 decode only; no shader/animation/video runtime.
import Foundation
import ImageIO
import CryptoKit

struct SceneTextureReader {
    static func read(_ data: Data, path: String, limits: SceneReadLimits = SceneReadLimits(), maximumDecodedBytes: Int? = nil) throws -> SceneTextureAsset {
        guard data.count <= limits.maximumEntryBytes else { throw SceneWallpaperFailure(message: "Texture exceeds byte limit.") }
        if !path.lowercased().hasSuffix(".tex") { return try encoded(data, path: path, expected: nil, limits: limits, maximumDecodedBytes: maximumDecodedBytes) }
        var cursor = SceneByteCursor(data: data)
        guard try cursor.cString() == "TEXV0005", try cursor.cString() == "TEXI0001" else { throw SceneWallpaperFailure(message: "Unsupported TEX version; expected TEXV0005/TEXI0001.") }
        let format = try cursor.u32(), flags = try cursor.u32()
        let storageWidth = try dimension(cursor.u32()), storageHeight = try dimension(cursor.u32())
        let imageWidth = try dimension(cursor.u32()), imageHeight = try dimension(cursor.u32())
        _ = try cursor.u32()
        guard storageWidth * storageHeight <= limits.maximumTexturePixels, imageWidth <= storageWidth, imageHeight <= storageHeight else { throw SceneWallpaperFailure(message: "Invalid/pixel-limit TEX dimensions.") }
        // Current official RG88 beams carry the reference-named AlphaChannelPriority bit.
        // Accept only these exact verified variants; this is not a global flag relaxation.
        let storageVariants:[String:String] = ["materials/particle/beam/beam_1.tex":"f5171493fa36d05a6d884e1914aaeaa2865cb0cb7077dd4d8ab4931fad4416bc","materials/particle/beam/hose_2.tex":"c021c439d5ab9c187ea2cd20f4be01e3aafadbd184310f5f2f6206ec3e1fd7e0"]
        let storageVariant = flags & 0x80000 != 0 && format==8 && storageVariants[path] == SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        guard flags & ~UInt32(7 | 32 | (storageVariant ? 0x80000:0)) == 0 else { throw SceneWallpaperFailure(message: "Unsupported TEX flags (unknown storage behavior).") }
        let block = try cursor.cString()
        guard ["TEXB0001", "TEXB0002", "TEXB0003", "TEXB0004"].contains(block) else { throw SceneWallpaperFailure(message: "Unsupported TEX image container: \(block)") }
        guard try cursor.u32() == 1 else { throw SceneWallpaperFailure(message: "Only one static TEX image is supported.") }
        let encodedFormat: UInt32 = ["TEXB0003", "TEXB0004"].contains(block) ? try cursor.u32() : UInt32.max
        // B4 carries an additional container field before its B3-style mip
        // layout. A zero field alone does NOT prove static media: header flag32
        // selects embedded video. It is parsed as metadata below, never as RGBA.
        if block == "TEXB0004" {
            guard try cursor.u32() == 0 else { throw SceneWallpaperFailure(message: "TEXB0004 video/unknown media flag is unsupported.") }
        }
        guard [UInt32.max, 2, 13].contains(encodedFormat) else { throw SceneWallpaperFailure(message: "Unsupported embedded TEX image codec.") }
        let mipCount = try cursor.u32()
        guard (1...16).contains(mipCount) else { throw SceneWallpaperFailure(message: "Unsafe TEX mipmap count.") }
        var first: SceneTextureAsset?
        for index in 0..<mipCount {
            let width = try dimension(cursor.u32()), height = try dimension(cursor.u32())
            guard width * height <= limits.maximumTexturePixels else { throw SceneWallpaperFailure(message: "TEX mipmap exceeds pixel limit.") }
            var decodedSize: UInt32 = 0
            var compressed: UInt32 = 0
            if block != "TEXB0001" {
                compressed = try cursor.u32(); decodedSize = try cursor.u32()
                guard compressed <= 1 else { throw SceneWallpaperFailure(message: "Invalid TEX compression flag.") }
            }
            let size = try cursor.u32()
            guard size <= limits.maximumEntryBytes, decodedSize <= limits.maximumEntryBytes else { throw SceneWallpaperFailure(message: "Unsafe TEX mipmap byte count.") }
            let storedBytes = try cursor.bytes(Int(size))
            if flags & 32 != 0 {
                guard block=="TEXB0004",encodedFormat==UInt32.max,mipCount==1,index==0,flags & 4==0,
                      compressed==0,decodedSize==0,width==storageWidth,height==storageHeight,
                      width*height*4<=min(maximumDecodedBytes ?? limits.maximumTextureBytes,limits.maximumTextureBytes),
                      storedBytes.count>=12,storedBytes.subdata(in:4..<8)==Data("ftyp".utf8) else {throw SceneWallpaperFailure(message:"Unsupported embedded video TEX layout or MP4 signature.")}
                first = .init(path:path,format:.rgba8888,flags:flags,video:.init(data:storedBytes,declaredWidth:width,declaredHeight:height),data:storedBytes,storageWidth:width,storageHeight:height,imageWidth:imageWidth,imageHeight:imageHeight)
                continue
            }
            let dxt: SceneDXTDecoder.Format?
            switch format { case 4: dxt = .dxt5; case 6: dxt = .dxt3; case 7: dxt = .dxt1; default: dxt = nil }
            let isEncoded = encodedFormat == 2 || encodedFormat == 13
            guard isEncoded || [0,8,9].contains(format) || dxt != nil else { throw SceneWallpaperFailure(message: "Unsupported raw TEX pixel codec.") }
            let expectedRaw = try dxt.map { try SceneDXTDecoder.byteCount(width: width, height: height, format: $0) } ?? width * height * (format == 9 ? 1 : format == 8 ? 2 : 4)
            let payloadSize = compressed == 1 ? Int(decodedSize) : storedBytes.count
            guard isEncoded || payloadSize == expectedRaw else { throw SceneWallpaperFailure(message: "TEX decoded payload size does not match pixel codec/dimensions.") }
            if compressed == 1 { try SceneLZ4Block.validate(storedBytes, decodedByteCount: Int(decodedSize), maximumBytes: limits.maximumEntryBytes) }
            // Validate skipped mip blocks, but only allocate/decode the top-level image.
            if index != 0 { continue }
            let outputBudget = min(maximumDecodedBytes ?? limits.maximumTextureBytes, limits.maximumTextureBytes)
            guard width * height <= outputBudget / 4, !isEncoded || payloadSize <= outputBudget else { throw SceneWallpaperFailure(message: "Decoded TEX exceeds remaining texture byte budget.") }
            let bytes = compressed == 1 ? try SceneLZ4Block.decode(storedBytes, decodedByteCount: Int(decodedSize), maximumBytes: limits.maximumEntryBytes) : storedBytes
            if index == 0 {
                guard width == storageWidth, height == storageHeight else { throw SceneWallpaperFailure(message: "TEX storage/mipmap dimensions disagree.") }
                if encodedFormat == 2 || encodedFormat == 13 {
                    let image = try encoded(bytes, path: path, expected: encodedFormat == 13 ? .png : .jpeg, limits: limits, maximumDecodedBytes: outputBudget)
                    guard image.storageWidth == width, image.storageHeight == height else { throw SceneWallpaperFailure(message: "TEX encoded image dimensions disagree.") }
                    first = SceneTextureAsset(path: path, format: image.format, flags: flags, data: bytes, storageWidth: width, storageHeight: height, imageWidth: imageWidth, imageHeight: imageHeight)
                } else {
                    var rgba = try dxt.map { try SceneDXTDecoder.decode(bytes, width: width, height: height, format: $0, maximumBytes: outputBudget) } ?? bytes
                    if format==8 || format==9 {
                        let stride=format==9 ? 1 : 2
                        var expanded=Data(count:width*height*4)
                        try expanded.withUnsafeMutableBytes { out in
                            let target=out.bindMemory(to:UInt8.self)
                            for row in 0..<height {
                                try Task.checkCancellation()
                                for x in 0..<width {
                                    let pixel=row*width+x;target[pixel*4]=bytes[pixel*stride]
                                    target[pixel*4+1]=stride==2 ? bytes[pixel*stride+1] : 0
                                    target[pixel*4+2]=0;target[pixel*4+3]=255
                                }
                            }
                        }
                        rgba=expanded
                    }
                    guard rgba.count == width * height * 4 else { throw SceneWallpaperFailure(message: "RGBA TEX payload size does not match dimensions.") }
                    first = SceneTextureAsset(path: path, format: .rgba8888, flags: flags, channelCount:format==9 ? 1:format==8 ? 2:4, data: rgba, storageWidth: width, storageHeight: height, imageWidth: imageWidth, imageHeight: imageHeight)
                }
            }
        }
        guard var first else {throw SceneWallpaperFailure(message:"Missing TEX image payload.")}
        if flags & 4 != 0 {
            // Pinned RePKG TexFrameInfoContainerReader: TEXS0003 contains
            // imageId, frame duration and an affine cell rectangle per frame.
            guard try cursor.cString()=="TEXS0003" else {throw SceneWallpaperFailure(message:"Only bounded TEXS0003 particle atlases are supported.")}
            let count=try cursor.u32(),cellWidth=try dimension(cursor.u32()),cellHeight=try dimension(cursor.u32())
            guard (1...256).contains(count),imageWidth==storageWidth,imageHeight==storageHeight,cellWidth<=storageWidth,cellHeight<=storageHeight else {throw SceneWallpaperFailure(message:"Unsafe TEX atlas frame dimensions/count.")}
            var frames:[SceneTextureAnimation.Frame]=[]
            func scalar(_ bits:UInt32)throws->Double {let value=Double(Float(bitPattern:bits));guard value.isFinite else {throw SceneWallpaperFailure(message:"Nonfinite TEX atlas frame.")};return value}
            for _ in 0..<count {
                let imageID=try cursor.u32(),duration=try scalar(cursor.u32()),x=try scalar(cursor.u32()),y=try scalar(cursor.u32()),w=try scalar(cursor.u32()),wy=try scalar(cursor.u32()),hx=try scalar(cursor.u32()),h=try scalar(cursor.u32())
                guard imageID==0,(0.000001...60).contains(duration),wy==0,hx==0,w==Double(cellWidth),h==Double(cellHeight),x>=0,y>=0,x.rounded()==x,y.rounded()==y,x+w<=Double(storageWidth),y+h<=Double(storageHeight) else {throw SceneWallpaperFailure(message:"Unsupported TEX atlas affine frame or out-of-bounds rectangle.")}
                frames.append(.init(x:Int(x),y:Int(y),width:cellWidth,height:cellHeight,duration:duration))
            }
            first.animation = .init(frames:frames)
        }
        first.verifiedStorageVariant=storageVariant
        guard cursor.offset == data.count else { throw SceneWallpaperFailure(message: "Unexpected trailing or missing TEX sections.") }
        return first
    }
    private static func dimension(_ value: UInt32) throws -> Int {
        guard value > 0, value <= 16_384 else { throw SceneWallpaperFailure(message: "Unsafe texture dimension.") }
        return Int(value)
    }
    private static func encoded(_ data: Data, path: String, expected: SceneTextureAsset.Format?, limits: SceneReadLimits, maximumDecodedBytes: Int?) throws -> SceneTextureAsset {
        let budget = min(maximumDecodedBytes ?? limits.maximumTextureBytes, limits.maximumTextureBytes)
        guard data.count <= budget, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, type == "public.png" || type == "public.jpeg",
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int, let height = metadata[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= limits.maximumTexturePixels, width * height <= budget / 4,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
            throw SceneWallpaperFailure(message: "Only bounded, decodable static PNG/JPEG textures are supported.")
        }
        let format: SceneTextureAsset.Format = type == "public.png" ? .png : .jpeg
        guard expected == nil || expected == format else { throw SceneWallpaperFailure(message: "Embedded TEX codec marker disagrees with image bytes.") }
        return SceneTextureAsset(path: path, format: format, flags: 0, data: data, storageWidth: width, storageHeight: height, imageWidth: width, imageHeight: height)
    }
}
