import Foundation
import CoreText
import CoreGraphics

/// Private, in-memory font use only. Fonts are never installed or substituted.
enum SceneTextRenderer {
    static func validate(_ text:SceneTextLayer,size:SceneVector2)throws {
        guard text.value.utf8.count<=4096,text.value.unicodeScalars.count<=1024,
              !text.value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}),
              !text.fontData.isEmpty,text.fontData.count<=2*1024*1024,
              text.pointSize.isFinite,(1...512).contains(text.pointSize),
              [size.x,size.y].allSatisfy({$0.isFinite && $0>=1 && $0<=4096}),size.x*size.y<=4*1024*1024,
              [text.padding.x,text.padding.y].allSatisfy({$0.isFinite && $0>=0 && $0<=1024}),
              text.padding.x*2<size.x,text.padding.y*2<size.y,
              ["left","center","right"].contains(text.horizontalAlignment),
              ["top","center","bottom"].contains(text.verticalAlignment),
              let provider=CGDataProvider(data:text.fontData as CFData),CGFont(provider) != nil else {
            throw SceneWallpaperFailure(message:"Unsupported or invalid bounded single-line text/font layout.")
        }
    }
    static func texture(_ text:SceneTextLayer,size:SceneVector2,path:String)throws->SceneTextureAsset {
        try validate(text,size:size);try Task.checkCancellation()
        let width=Int(ceil(size.x)),height=Int(ceil(size.y))
        guard let provider=CGDataProvider(data:text.fontData as CFData),let graphicsFont=CGFont(provider),
              let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue),let raw=context.data else {
            throw SceneWallpaperFailure(message:"Cannot render the project's actual font.")
        }
        let font=CTFontCreateWithGraphicsFont(graphicsFont,text.pointSize,nil,nil)
        let attributes:[NSAttributedString.Key:Any]=[
            .init(kCTFontAttributeName as String):font,
            .init(kCTForegroundColorAttributeName as String):CGColor(red:1,green:1,blue:1,alpha:1)
        ]
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:text.value,attributes:attributes))
        var ascent:CGFloat=0,descent:CGFloat=0,leading:CGFloat=0
        let lineWidth=CTLineGetTypographicBounds(line,&ascent,&descent,&leading)
        guard lineWidth<=Double(width)-text.padding.x*2,ascent+descent<=Double(height)-text.padding.y*2 else {
            throw SceneWallpaperFailure(message:"Text exceeds its supported single-line authored bounds.")
        }
        let x:Double
        switch text.horizontalAlignment {case "left":x=text.padding.x;case "right":x=Double(width)-text.padding.x-lineWidth;default:x=(Double(width)-lineWidth)/2}
        let y:Double
        switch text.verticalAlignment {case "top":y=Double(height)-text.padding.y-ascent;case "bottom":y=text.padding.y+descent;default:y=(Double(height)-ascent-descent)/2+descent}
        context.textMatrix = .identity;context.textPosition = .init(x:x,y:y)
        CTLineDraw(line,context)
        var bytes=Data(bytes:raw,count:width*height*4)
        bytes.withUnsafeMutableBytes { memory in
            let pixels=memory.bindMemory(to:UInt8.self)
            for index in stride(from:0,to:pixels.count,by:4) {let white:UInt8=pixels[index+3]>0 ? 255:0;pixels[index]=white;pixels[index+1]=white;pixels[index+2]=white}
        }
        return .init(path:path,format:.rgba8888,flags:2,data:bytes,storageWidth:width,storageHeight:height,imageWidth:width,imageHeight:height)
    }
}
