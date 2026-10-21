import Foundation
import CoreGraphics
import ImageIO

extension MetalSceneCompositor {
    /// Experimental adapter for the ALREADY accepted image subset. It does not
    /// broaden inspector capabilities. Scene fit/affine/order are preserved.
    func render(inspection: SceneWallpaperInspection, pixelSize: CGSize) throws -> MetalSceneReadback {
        try withExclusiveRender { try renderInspectionLocked(inspection: inspection, pixelSize: pixelSize) }
    }
    private func renderInspectionLocked(inspection: SceneWallpaperInspection, pixelSize: CGSize) throws -> MetalSceneReadback {
        try Task.checkCancellation()
        guard inspection.isRenderableSubset, inspection.textures.count <= 512, inspection.layers.count <= 512,
              pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width >= 1, pixelSize.height >= 1, pixelSize.width <= 8192, pixelSize.height <= 8192,
              inspection.canvasSize.x.isFinite, inspection.canvasSize.y.isFinite,
              inspection.canvasSize.x > 0, inspection.canvasSize.y > 0,
              inspection.canvasSize.x <= 1e6, inspection.canvasSize.y <= 1e6 else { throw SceneWallpaperFailure(message:"Invalid or unsupported inspection/viewport.") }
        guard !inspection.requiresAdvancedRendering, !inspection.layers.contains(where:{$0.particleSystem != nil}) else {throw SceneWallpaperFailure(message:"Experimental Metal inspection adapter does not evaluate particles, lightshafts or bloom; use SceneWallpaperRenderer.")}
        let cameraTransform=try inspection.camera.validatedTransform()
        let width = Int(pixelSize.width.rounded()), height = Int(pixelSize.height.rounded())
        guard width * height <= 16 * 1024 * 1024 else { throw SceneWallpaperFailure(message:"Viewport pixel budget exceeded.") }
        let world = try SceneHierarchy.worldStates(layers: inspection.layers)
        for layer in inspection.layers { try SceneScriptLayerState(layer: layer).validate() }
        let fit = min(Double(width)/inspection.canvasSize.x, Double(height)/inspection.canvasSize.y)
        let offsetX = (Double(width)-inspection.canvasSize.x*fit)/2, offsetY = (Double(height)-inspection.canvasSize.y*fit)/2
        var textures: [String:MetalSceneTexture] = [:], draws: [MetalSceneDraw] = []
        var textureBytes = 0, sourceBytes = 0
        for texture in inspection.textures.values {
            try Task.checkCancellation()
            try Self.checkPeak([sourceBytes, texture.data.count])
            sourceBytes += texture.data.count
        }
        for layer in inspection.layers where !layer.isTransformOnly {
            try Task.checkCancellation()
            guard let state = world[layer.id] else { throw SceneWallpaperFailure(message:"Missing world transform.") }
            guard state.isVisible else { continue }
            if textures[layer.texturePath] == nil {
                guard let texture = inspection.textures[layer.texturePath] else { throw SceneWallpaperFailure(message:"Missing texture.") }
                let byteCount = try Self.validateTexture(texture)
                guard byteCount <= 128 * 1024 * 1024 - textureBytes else { throw SceneWallpaperFailure(message:"Decoded texture budget exceeded before decode.") }
                // ImageIO can hold the full storage image plus a cropped bitmap and
                // straight-alpha copy. Reserve that estimate before any decode/allocation.
                let decodeScratch = texture.format == .rgba8888 ? byteCount : texture.storageWidth * texture.storageHeight * 4 + byteCount * 2
                try Self.checkPeak([sourceBytes, textureBytes, decodeScratch])
                let decoded = try Self.decode(texture)
                textureBytes += byteCount
                textures[layer.texturePath] = decoded
            }
            let m = cameraTransform.concatenating(state.transform)
            let transform = SceneAffineTransform(a:m.a*fit,b:m.b*fit,c:m.c*fit,d:m.d*fit,tx:m.tx*fit+offsetX,ty:m.ty*fit+offsetY)
            let texture = inspection.textures[layer.texturePath]!
            draws.append(.init(source:layer.texturePath,transform:transform,size:layer.size,tint:layer.tint,opacity:layer.opacity,sampling:texture.flags & 1 != 0 ? .nearest : .linear,blend:layer.blend == .additive ? .additive : .sourceOver))
        }
        // The graph's texture identifiers are opaque. Pick an unused output ID.
        var output = "__gw_metal_output__"
        while textures[output] != nil { output += "_" }
        let c = inspection.clearColor
        return try renderLocked(textures:textures,passes:[.init(target:output,width:width,height:height,clear:SIMD4(c.x,c.y,c.z,1),clip:SIMD4(offsetX,offsetY,Double(width)-offsetX,Double(height)-offsetY),draws:draws)], additionalResidentBytes: sourceBytes)
    }
    private static func validateTexture(_ texture: SceneTextureAsset) throws -> Int {
        guard texture.flags & ~UInt32(3) == 0,
              texture.storageWidth > 0, texture.storageHeight > 0,
              texture.storageWidth <= 16384, texture.storageHeight <= 16384,
              texture.storageWidth * texture.storageHeight <= 32 * 1024 * 1024,
              texture.imageWidth > 0, texture.imageHeight > 0,
              texture.imageWidth <= texture.storageWidth, texture.imageHeight <= texture.storageHeight,
              texture.imageWidth <= 8192, texture.imageHeight <= 8192 else { throw SceneWallpaperFailure(message:"Unsafe texture dimensions/flags.") }
        return texture.imageWidth * texture.imageHeight * 4
    }
    private static func decode(_ texture: SceneTextureAsset) throws -> MetalSceneTexture {
        _ = try validateTexture(texture)
        try Task.checkCancellation()
        let width = texture.imageWidth, height = texture.imageHeight
        let rgba: Data
        if texture.format == .rgba8888 {
            guard texture.data.count == texture.storageWidth * texture.storageHeight * 4 else { throw SceneWallpaperFailure(message:"Invalid RGBA source byte count.") }
            var cropped = Data(count:width*height*4)
            try cropped.withUnsafeMutableBytes { out in try texture.data.withUnsafeBytes { input in
                for y in 0..<height {
                    try Task.checkCancellation()
                    out.baseAddress!.advanced(by:y*width*4).copyMemory(from:input.baseAddress!.advanced(by:y*texture.storageWidth*4),byteCount:width*4)
                }
            } }
            rgba = cropped
        } else {
            guard texture.data.count <= 64 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(texture.data as CFData,nil), CGImageSourceGetCount(source) == 1,
                  CGImageSourceGetType(source) as String? == (texture.format == .png ? "public.png" : "public.jpeg"),
                  let meta = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  meta[kCGImagePropertyPixelWidth] as? Int == texture.storageWidth,
                  meta[kCGImagePropertyPixelHeight] as? Int == texture.storageHeight,
                  let original = CGImageSourceCreateImageAtIndex(source,0,nil),
                  let image = original.cropping(to:CGRect(x:0,y:0,width:width,height:height)),
                  let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data else { throw SceneWallpaperFailure(message:"Bounded encoded texture decode failed.") }
            try Task.checkCancellation()
            context.setBlendMode(.copy); context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            try Task.checkCancellation()
            let input = bytes.assumingMemoryBound(to:UInt8.self)
            var straight = Data(bytes:input,count:width*height*4)
            try straight.withUnsafeMutableBytes { raw in
                let output = raw.bindMemory(to:UInt8.self)
                for row in 0..<height {
                    try Task.checkCancellation()
                    for i in stride(from:row*width*4,to:(row+1)*width*4,by:4) {
                        let alpha = Int(output[i+3])
                        for c in 0..<3 { output[i+c] = alpha == 0 ? 0 : UInt8(min(255,(Int(output[i+c])*255+alpha/2)/alpha)) }
                    }
                }
            }
            rgba = straight
        }
        return .init(width:width,height:height,rgba:rgba)
    }
}
