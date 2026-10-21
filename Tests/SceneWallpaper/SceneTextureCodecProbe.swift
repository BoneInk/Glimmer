import Foundation
import Compression
import CoreGraphics
import ImageIO
import Darwin

@main struct SceneTextureCodecProbe {
    static func main() throws {
        var checks = [String]()
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw SceneWallpaperFailure(message: "FAILED: " + name) }; checks.append(name)
        }
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            var rejected = false; do { try operation() } catch { rejected = true }
            try check(rejected, name)
        }
        func le(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }
        func encode(_ data: Data) throws -> Data {
            var destination = Data(count: data.count * 2 + 1024)
            let capacity = destination.count
            let count = destination.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in
                compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZ4_RAW)
            }}
            guard count > 0 else { throw SceneWallpaperFailure(message: "Independent native LZ4 encoder failed") }
            return destination.prefix(count)
        }
        func tex(_ payload: Data, format: UInt32 = 0, width: Int = 4, height: Int = 4,
                 imageWidth: Int? = nil, imageHeight: Int? = nil, compression: UInt32 = 0,
                 decodedSize: Int? = nil, container: String = "TEXB0002", encodedFormat: UInt32 = UInt32.max,
                 extraMips: Data = Data()) -> Data {
            var header = Data("TEXV0005\0TEXI0001\0".utf8)
            for value in [format,UInt32(1),UInt32(width),UInt32(height),UInt32(imageWidth ?? width),UInt32(imageHeight ?? height),0] { header += le(UInt64(value),4) }
            header += Data((container + "\0").utf8) + le(1,4)
            if container == "TEXB0003" { header += le(UInt64(encodedFormat),4) }
            header += le(extraMips.isEmpty ? 1 : 2,4) + le(UInt64(width),4) + le(UInt64(height),4)
            if container != "TEXB0001" { header += le(UInt64(compression),4) + le(UInt64(decodedSize ?? payload.count),4) }
            return header + le(UInt64(payload.count),4) + payload + extraMips
        }
        func colorBlock(_ c0: UInt16, _ c1: UInt16, _ indices: UInt32 = 0) -> Data {
            le(UInt64(c0),2) + le(UInt64(c1),2) + le(UInt64(indices),4)
        }
        func pixel(_ data: Data, _ index: Int) -> [UInt8] { Array(data[(index*4)..<(index*4+4)]) }
        let red = colorBlock(0xf800,0x07e0)
        let green = colorBlock(0x07e0,0), blue = colorBlock(0x001f,0), yellow = colorBlock(0xffe0,0)
        // Microsoft BC1: RGB565 red/green endpoints; indices 0,1,2,3.
        let fourColors = try SceneDXTDecoder.decode(colorBlock(0xf800,0x07e0,0xe4), width: 4, height: 4, format: .dxt1, maximumBytes: 64)
        try check((0..<4).map { pixel(fourColors,$0) } == [[255,0,0,255],[0,255,0,255],[170,85,0,255],[85,170,0,255]], "BC1 primary endpoint/interpolation/index order matches Microsoft format arithmetic")
        let transparent = try SceneDXTDecoder.decode(colorBlock(0,0xffff,0xe4),width:4,height:4,format:.dxt1,maximumBytes:64)
        try check(pixel(transparent,2) == [127,127,127,255] && pixel(transparent,3) == [0,0,0,0], "BC1 ascending endpoints select midpoint and transparent black")
        let equal = try SceneDXTDecoder.decode(colorBlock(0xf800,0xf800,3),width:4,height:4,format:.dxt1,maximumBytes:64)
        try check(pixel(equal,0) == [0,0,0,0], "BC1 equal endpoints retain three-color transparency mode")
        let bc2 = try SceneDXTDecoder.decode(le(0xfedcba9876543210,8)+colorBlock(0,0xffff,0xffffffff),width:4,height:4,format:.dxt3,maximumBytes:64)
        try check((0..<16).map { pixel(bc2,$0)[3] } == (0..<16).map { UInt8($0*17) }, "BC2 explicit 4-bit alpha expands all 16 values with correct row order")
        try check(pixel(bc2,15) == [170,170,170,255], "BC2 color always uses four-color mode even with ascending endpoints")
        let alphaIndices = (0..<16).reduce(UInt64(0)) { $0 | (UInt64($1 % 8) << (3*$1)) }
        for (first,second,expected) in [(UInt8(255),UInt8(0),[255,0,218,182,145,109,72,36]),(UInt8(0),UInt8(255),[0,255,51,102,153,204,0,255]),(UInt8(100),UInt8(100),[100,100,100,100,100,100,0,255])] {
            let block = Data([first,second])+le(alphaIndices,6)+colorBlock(0,0xffff,0xffffffff)
            let value = try SceneDXTDecoder.decode(block,width:4,height:4,format:.dxt5,maximumBytes:64)
            try check((0..<16).map { Int(pixel(value,$0)[3]) } == (0..<16).map { expected[$0 % 8] }, "BC3 alpha endpoint mode \(first)/\(second) including 48-bit selector boundary")
            try check(Array(pixel(value,1).prefix(3)) == [170,170,170], "BC3 \(first)/\(second) uses four-color RGB independently of alpha")
        }
        let edge = try SceneDXTDecoder.decode(red+green+blue+yellow,width:5,height:5,format:.dxt1,maximumBytes:100)
        try check(pixel(edge,0) == [255,0,0,255] && pixel(edge,4) == [0,255,0,255] && pixel(edge,20) == [0,0,255,255] && pixel(edge,24) == [255,255,0,255], "BC1 5x5 ceil-block dimensions preserve stride and crop padded right/bottom texels")
        for format: SceneDXTDecoder.Format in [.dxt1,.dxt3,.dxt5] {
            let block = format == .dxt1 ? red : (format == .dxt3 ? Data(repeating:255,count:8) : Data([255,0])+Data(repeating:0,count:6))+red
            let single = try SceneDXTDecoder.decode(block,width:1,height:1,format:format,maximumBytes:4)
            try check(single == Data([255,0,0,255]), "\(format) tiny mip still consumes a full compressed block")
            try rejects("\(format) rejects truncated input") { _ = try SceneDXTDecoder.decode(block.dropLast(),width:4,height:4,format:format,maximumBytes:64) }
            try rejects("\(format) rejects trailing blocks") { _ = try SceneDXTDecoder.decode(block+Data([0]),width:4,height:4,format:format,maximumBytes:64) }
            try rejects("\(format) output allocation obeys byte budget") { _ = try SceneDXTDecoder.decode(block,width:4,height:4,format:format,maximumBytes:63) }
        }
        try rejects("DXT oversized dimensions fail before multiplication/allocation") { _ = try SceneDXTDecoder.decode(Data(),width:Int.max,height:4,format:.dxt1,maximumBytes:64) }
        let literal = Data([0x80])+Data("abcdefgh".utf8)
        try check(try SceneLZ4Block.decode(literal,decodedByteCount:8,maximumBytes:8) == Data("abcdefgh".utf8), "Published LZ4 literal token vector decodes exactly")
        let overlap = Data([0x1a,65,1,0,0x50])+Data("12345".utf8)
        try check(try SceneLZ4Block.decode(overlap,decodedByteCount:20,maximumBytes:20) == Data(repeating:65,count:15)+Data("12345".utf8), "Published LZ4 match semantics support overlap offset1 and terminal literals")
        let invalidBlocks: [(String, Data, Int)] = [("trailing bytes",literal+Data([0]),8),("truncation",Data(literal.dropLast()),8),("zero offset",Data([0x1a,65,0,0,0x50])+Data("12345".utf8),20),("offset before output",Data([0x1a,65,2,0,0x50])+Data("12345".utf8),20),("short declared output",literal,7),("long declared output",literal,9),("missing terminal literals",Data([0x10,65,1,0]),5),("length extension overflow",Data([0xf0,255,255]),16)]
        for (name,bytes,count) in invalidBlocks {
            try rejects("LZ4 rejects \(name)") { _ = try SceneLZ4Block.decode(bytes,decodedByteCount:count,maximumBytes:64) }
        }
        try rejects("LZ4 declared expansion exceeds budget before allocation") { _ = try SceneLZ4Block.decode(literal,decodedByteCount:8,maximumBytes:7) }
        let rgba = Data((0..<8192).map { UInt8(($0/4)%17) })
        let compressed = try encode(rgba)
        try check(compressed.count < rgba.count && (try SceneLZ4Block.decode(compressed,decodedByteCount:rgba.count,maximumBytes:rgba.count)) == rgba, "Independent Apple raw LZ4 encoder cross-check covers repeated matches and extended lengths")
        let rawTex = try SceneTextureReader.read(tex(compressed,width:64,height:32,compression:1,decodedSize:rgba.count),path:"fixture.tex")
        try check(rawTex.data == rgba && rawTex.format == .rgba8888, "Real encoder LZ4 TEXB0002 RGBA integrates through reader")
        for (format,block) in [(UInt32(7),red),(UInt32(6),Data(repeating:255,count:8)+red),(UInt32(4),Data([255,0])+Data(repeating:0,count:6)+red)] {
            let encoded = try encode(block)
            let texture = try SceneTextureReader.read(tex(encoded,format:format,compression:1,decodedSize:block.count),path:"dxt.tex")
            try check(texture.format == .rgba8888 && pixel(texture.data,0) == [255,0,0,255], "TEX format \(format) independently encoded LZ4 then DXT becomes real straight RGBA")
        }
        let crop = try SceneTextureReader.read(tex(red+green+blue+yellow,format:7,width:5,height:5,imageWidth:4,imageHeight:4),path:"crop.tex")
        let layer = SceneImageLayer(id:1,name:"Compressed image",modelPath:"",materialPath:"",texturePath:"crop",origin:SceneVector3(x:2,y:2,z:0),anglesDegrees:SceneVector3(x:0,y:0,z:0),scale:SceneVector3(x:1,y:1,z:1),size:SceneVector2(x:4,y:4),tint:SceneVector3(x:0.5,y:1,z:1),opacity:0.5,isVisible:true,bindings:[])
        let render = try SceneWallpaperRenderer.render(inspection:SceneWallpaperInspection(canvasSize:SceneVector2(x:4,y:4),clearColor:SceneVector3(x:0,y:0,z:0),layers:[layer],textures:["crop":crop],diagnostics:[]),pixelSize:CGSize(width:4,height:4))
        var pixels = [UInt8](repeating:0,count:64)
        let context = CGContext(data:&pixels,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(render,in:CGRect(x:0,y:0,width:4,height:4))
        try check((0..<16).allSatisfy { abs(Int(pixels[$0*4])-64) <= 2 && pixels[$0*4+1] == 0 && pixels[$0*4+2] == 0 }, "DXT decoded pixels compose with top-left crop, tint and opacity in existing CoreGraphics renderer")
        let translucent = try SceneTextureReader.read(tex(Data([128,0])+Data(repeating:0,count:6)+red,format:4),path:"alpha.tex")
        let alphaLayer = SceneImageLayer(id:2,name:"Straight alpha",modelPath:"",materialPath:"",texturePath:"alpha",origin:SceneVector3(x:2,y:2,z:0),anglesDegrees:SceneVector3(x:0,y:0,z:0),scale:SceneVector3(x:1,y:1,z:1),size:SceneVector2(x:4,y:4),tint:SceneVector3(x:1,y:1,z:1),opacity:1,isVisible:true,bindings:[])
        let alphaRender = try SceneWallpaperRenderer.render(inspection:SceneWallpaperInspection(canvasSize:SceneVector2(x:4,y:4),clearColor:SceneVector3(x:0,y:0,z:0),layers:[alphaLayer],textures:["alpha":translucent],diagnostics:[]),pixelSize:CGSize(width:4,height:4))
        context.draw(alphaRender,in:CGRect(x:0,y:0,width:4,height:4))
        try check(abs(Int(pixels[0])-128) <= 2 && pixels[1] == 0 && pixels[2] == 0, "BC3 alpha remains straight and is premultiplied exactly once during real composition")
        try rejects("TEX decoded output exceeds remaining aggregate byte budget") { _ = try SceneTextureReader.read(tex(red,format:7),path:"a.tex",maximumDecodedBytes:63) }
        try rejects("TEX DXT decodedSize cannot hide truncated expanded payload") { _ = try SceneTextureReader.read(tex(try encode(red),format:7,compression:1,decodedSize:7),path:"a.tex") }
        try rejects("TEX rejects unknown compression enum") { _ = try SceneTextureReader.read(tex(red,format:7,compression:2),path:"a.tex") }
        let badMip = le(1,4)+le(1,4)+le(1,4)+le(8,4)+le(2,4)+Data([0,0])
        try rejects("Skipped TEX mipmaps still validate complete LZ4 structure") { _ = try SceneTextureReader.read(tex(red,format:7,extraMips:badMip),path:"a.tex") }
        // Real ImageIO PNG -> independent native compressor -> TEXB3 image decoder.
        let image = CGImage(width:4,height:4,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:16,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:Data(repeating:255,count:64) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        for (uti,marker) in [("public.png",UInt32(13)),("public.jpeg",UInt32(2))] {
            let buffer = NSMutableData(), destination = CGImageDestinationCreateWithData(buffer,uti as CFString,1,nil)!
            CGImageDestinationAddImage(destination,image,nil)
            try check(CGImageDestinationFinalize(destination), "Independent ImageIO \(uti) fixture encoding succeeds")
            let encoded = buffer as Data
            try rejects("Loose \(uti) image decoded allocation obeys caller byte budget") { _ = try SceneTextureReader.read(encoded,path:uti == "public.png" ? "a.png" : "a.jpg",maximumDecodedBytes:63) }
            let texture = try SceneTextureReader.read(tex(try encode(encoded),compression:1,decodedSize:encoded.count,container:"TEXB0003",encodedFormat:marker),path:"image.tex")
            try rejects("Embedded \(uti) retained bytes obey remaining budget before decompression") { _ = try SceneTextureReader.read(tex(try encode(encoded),compression:1,decodedSize:encoded.count,container:"TEXB0003",encodedFormat:marker),path:"image.tex",maximumDecodedBytes:64) }
            try check(texture.data == encoded && texture.storageWidth == 4, "LZ4 TEXB3 embedded \(uti) preserves real decodable payload")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gw-scene-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let fifo = root.appendingPathComponent("pipe")
        guard mkfifo(fifo.path,0o600) == 0 else { throw SceneWallpaperFailure(message:"Cannot create own FIFO fixture") }
        let start = Date()
        try rejects("Loose FIFO rejected without blocking open") { _ = try SceneAssetSource(rootURL:root,limits:SceneReadLimits()).read("pipe") }
        try rejects("Archive FIFO rejected without blocking open") { _ = try ScenePackageArchive(url:fifo) }
        try check(Date().timeIntervalSince(start) < 1, "Own FIFO probes finish within one second without writers")
        let report:[String:Any] = ["success":true,"checkCount":checks.count,"checks":checks,"primarySources":["https://raw.githubusercontent.com/lz4/lz4/v1.10.0/doc/lz4_Block_format.md","https://learn.microsoft.com/en-us/windows/win32/direct3d10/d3d10-graphics-programming-guide-resources-block-compression","https://github.com/notscuffed/repkg/blob/8005eb271f4cb5b9e375bafa912029a0d67b5eb8/RePKG.Core/Texture/Enums/TexFormat.cs"],"boundary":"Original format vectors plus independent native Compression/ImageIO encoders, real CoreGraphics pixels and filesystem FIFO. No Workshop wallpaper, Windows-renderer parity, effects, animation or full Scene compatibility claim."]
        let output = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count > 1 { try output.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        print(String(decoding:output,as:UTF8.self))
    }
}
