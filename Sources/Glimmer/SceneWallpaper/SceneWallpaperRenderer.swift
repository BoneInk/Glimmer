import Foundation
import CoreGraphics
import ImageIO

/// Static CPU composition using public CoreGraphics. It consumes actual decoded
/// image layers and refuses every blocking inspection diagnostic.
struct SceneWallpaperRenderer {
    static func render(inspection: SceneWallpaperInspection, pixelSize: CGSize, runtime: Double = 0, cursorWorldPosition:SceneVector3? = nil) throws -> CGImage {
        try Task.checkCancellation()
        guard !inspection.textures.values.contains(where:{$0.video != nil}) else {throw SceneWallpaperFailure(message:"Embedded Scene video-texture playback is not implemented; static substitution is refused.")}
        guard inspection.isRenderableSubset else { throw SceneWallpaperFailure(message: "Scene has blocking diagnostics or no complete image layers; partial rendering is refused.") }
        if inspection.requiresAdvancedRendering {return try SceneAdvancedRenderer.shared.get().render(inspection,pixelSize:pixelSize,runtime:runtime,cursor:cursorWorldPosition)}
        let cameraTransform=try inspection.camera.validatedTransform()
        let worldStates=try SceneHierarchy.worldStates(layers:inspection.layers)
        guard pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width >= 1, pixelSize.height >= 1,
              pixelSize.width <= 8192, pixelSize.height <= 8192 else { throw SceneWallpaperFailure(message: "Unsafe Scene render size.") }
        let width=Int(pixelSize.width.rounded()),height=Int(pixelSize.height.rounded())
        guard width*height <= 16*1024*1024, inspection.canvasSize.x > 0, inspection.canvasSize.y > 0,
              inspection.canvasSize.x.isFinite, inspection.canvasSize.y.isFinite,
              [inspection.clearColor.x,inspection.clearColor.y,inspection.clearColor.z].allSatisfy({$0.isFinite && (0...1).contains($0)}) else { throw SceneWallpaperFailure(message:"Invalid Scene canvas/color or render pixel limit.") }
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let info=CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:info) else {throw SceneWallpaperFailure(message:"Could not allocate Scene canvas.")}
        context.setFillColor(red:inspection.clearColor.x,green:inspection.clearColor.y,blue:inspection.clearColor.z,alpha:1)
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        let fit=min(Double(width)/inspection.canvasSize.x,Double(height)/inspection.canvasSize.y)
        context.translateBy(x:(Double(width)-inspection.canvasSize.x*fit)/2,y:(Double(height)-inspection.canvasSize.y*fit)/2)
        context.scaleBy(x:fit,y:fit)
        context.clip(to:CGRect(x:0,y:0,width:inspection.canvasSize.x,height:inspection.canvasSize.y))
        var particleTintWork=0
        for layer in inspection.layers where !layer.isTransformOnly {
            try Task.checkCancellation()
            guard let world=worldStates[layer.id] else {throw SceneWallpaperFailure(message:"Missing Scene world transform.")}
            if !world.isVisible {continue}
            guard let texture=inspection.textures[layer.texturePath], layer.anglesDegrees.x==0,layer.anglesDegrees.y==0,layer.scale.z==1,
                  [layer.origin.x,layer.origin.y,layer.anglesDegrees.z,layer.scale.x,layer.scale.y,layer.size.x,layer.size.y].allSatisfy({$0.isFinite && abs($0)<=1_000_000}),
                  layer.size.x>0,layer.size.y>0,layer.opacity.isFinite,(0...1).contains(layer.opacity),
                  [layer.tint.x,layer.tint.y,layer.tint.z].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw SceneWallpaperFailure(message:"Invalid or unsupported image layer in render input.")}
            if let system=layer.particleSystem {
                let sprites=try system.sprites(runtime:runtime,seed:layer.id)
                // This CPU backend tints actual source texels. Bound that cost as
                // well as live count rather than hanging on oversized sprite maps.
                let work=texture.imageWidth*texture.imageHeight*sprites.count
                guard work<=128*1024*1024-particleTintWork else {throw SceneWallpaperFailure(message:"Particle texture/tint work budget exceeded.")}
                particleTintWork+=work
                for sprite in sprites {
                    let tint=SceneVector3(x:layer.tint.x*sprite.color.x,y:layer.tint.y*sprite.color.y,z:layer.tint.z*sprite.color.z)
                    let image=try tintedImage(texture,tint:tint,space:space)
                    context.saveGState()
                    let matrix=cameraTransform.concatenating(world.transform)
                    context.concatenate(CGAffineTransform(a:matrix.a,b:matrix.b,c:matrix.c,d:matrix.d,tx:matrix.tx,ty:matrix.ty))
                    context.translateBy(x:sprite.position.x,y:sprite.position.y);context.rotate(by:sprite.rotationRadians)
                    context.setAlpha(layer.opacity*sprite.alpha);context.setBlendMode(layer.blend == .additive ? .plusLighter : .normal)
                    context.interpolationQuality=texture.flags & 1 != 0 ? .none : .high
                    context.draw(image,in:CGRect(x:-sprite.size/2,y:-sprite.size/2,width:sprite.size,height:sprite.size))
                    context.restoreGState()
                }
                continue
            }
            let image=try tintedImage(texture,tint:layer.tint,space:space)
            context.saveGState()
            let matrix=cameraTransform.concatenating(world.transform)
            context.concatenate(CGAffineTransform(a:matrix.a,b:matrix.b,c:matrix.c,d:matrix.d,tx:matrix.tx,ty:matrix.ty))
            context.setAlpha(layer.opacity)
            context.setBlendMode(layer.blend == .additive ? .plusLighter : .normal)
            context.interpolationQuality=texture.flags & 1 != 0 ? .none : .high
            context.draw(image,in:CGRect(x:-layer.size.x/2,y:-layer.size.y/2,width:layer.size.x,height:layer.size.y))
            context.restoreGState()
        }
        guard let image=context.makeImage() else {throw SceneWallpaperFailure(message:"Scene composition produced no image.")}
        return image
    }
    static func decodedImage(_ texture:SceneTextureAsset)throws->CGImage {try tintedImage(texture,tint:.init(x:1,y:1,z:1),space:CGColorSpace(name:CGColorSpace.sRGB)!)}
    private static func tintedImage(_ texture:SceneTextureAsset,tint:SceneVector3,space:CGColorSpace)throws->CGImage {
        guard texture.video == nil,texture.flags & ~UInt32(3 | (texture.animation != nil ? 4:0) | (texture.verifiedStorageVariant ? 0x80000:0)) == 0, texture.storageWidth>0,texture.storageHeight>0,texture.storageWidth<=16_384,texture.storageHeight<=16_384,
              texture.storageWidth*texture.storageHeight<=32*1024*1024,
              texture.imageWidth>0,texture.imageHeight>0,texture.imageWidth<=texture.storageWidth,texture.imageHeight<=texture.storageHeight else {throw SceneWallpaperFailure(message:"Unsafe texture render dimensions.")}
        let source:CGImage
        if texture.format == .rgba8888 {
            guard texture.data.count==texture.storageWidth*texture.storageHeight*4,
                  let provider=CGDataProvider(data:texture.data as CFData),
                  let image=CGImage(width:texture.storageWidth,height:texture.storageHeight,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:texture.storageWidth*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw SceneWallpaperFailure(message:"Invalid raw RGBA texture.")}
            source=image
        } else {
            guard texture.data.count <= 64*1024*1024,
                  let sourceData=CGImageSourceCreateWithData(texture.data as CFData,nil),CGImageSourceGetCount(sourceData)==1,
                  let type=CGImageSourceGetType(sourceData) as String?,type == (texture.format == .png ? "public.png" : "public.jpeg"),
                  let metadata=CGImageSourceCopyPropertiesAtIndex(sourceData,0,nil) as? [CFString:Any],
                  metadata[kCGImagePropertyPixelWidth] as? Int == texture.storageWidth,metadata[kCGImagePropertyPixelHeight] as? Int == texture.storageHeight,
                  let image=CGImageSourceCreateImageAtIndex(sourceData,0,nil) else {throw SceneWallpaperFailure(message:"Could not decode bounded Scene image texture.")}
            source=image
        }
        guard let cropped=source.cropping(to:CGRect(x:0,y:0,width:texture.imageWidth,height:texture.imageHeight)) else {throw SceneWallpaperFailure(message:"Could not crop padded Scene texture.")}
        if tint == SceneVector3(x:1,y:1,z:1) {return cropped}
        let width=cropped.width,height=cropped.height,info=CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let buffer=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:info),let raw=buffer.data else {throw SceneWallpaperFailure(message:"Could not allocate texture tint buffer.")}
        buffer.setBlendMode(.copy);buffer.draw(cropped,in:CGRect(x:0,y:0,width:width,height:height))
        let bytes=raw.assumingMemoryBound(to:UInt8.self)
        for row in 0..<height {
            try Task.checkCancellation()
            for index in stride(from:row*width*4,to:(row+1)*width*4,by:4) {
                bytes[index]=UInt8((Double(bytes[index])*tint.x).rounded())
                bytes[index+1]=UInt8((Double(bytes[index+1])*tint.y).rounded())
                bytes[index+2]=UInt8((Double(bytes[index+2])*tint.z).rounded())
            }
        }
        guard let image=buffer.makeImage() else {throw SceneWallpaperFailure(message:"Texture tint produced no image.")};return image
    }
}
