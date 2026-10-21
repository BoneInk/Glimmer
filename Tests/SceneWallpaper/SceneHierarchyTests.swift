import Foundation
import CoreGraphics

@main @MainActor enum SceneHierarchyTests {
    static var checks=0
    static func check(_ value:Bool,_ name:String) throws {guard value else {throw SceneWallpaperFailure(message:name)};checks += 1;print("PASS \(name)")}
    static func rejects(_ name:String,_ body:()throws->Void)throws {do {try body()}catch {try check(true,name);return};throw SceneWallpaperFailure(message:"Unexpected success: "+name)}
    static func layer(_ id:Int,parent:Int?=nil,group:Bool=false,x:Double=0,y:Double=0,angle:Double=0,sx:Double=1,sy:Double=1,visible:Bool=true,alpha:Double=1,color:SceneVector3 = .init(x:1,y:0,z:0),size:SceneVector2 = .init(x:10,y:6))->SceneImageLayer {
        .init(id:id,name:"node \(id)",modelPath:"model",materialPath:"material",texturePath:group ? "":"texture",origin:.init(x:x,y:y,z:0),anglesDegrees:.init(x:0,y:0,z:angle),scale:.init(x:sx,y:sy,z:1),size:group ? .init(x:1,y:1):size,tint:group ? .init(x:1,y:1,z:1):color,opacity:group ? 1:alpha,isVisible:visible,bindings:[],parentID:parent,isTransformOnly:group)
    }
    static func inspection(_ layers:[SceneImageLayer])->SceneWallpaperInspection {
        let texture=SceneTextureAsset(path:"texture",format:.rgba8888,flags:1,data:Data([255,255,255,255]),storageWidth:1,storageHeight:1,imageWidth:1,imageHeight:1)
        return .init(canvasSize:.init(x:64,y:64),clearColor:.init(x:0,y:0,z:0),layers:layers,textures:["texture":texture],diagnostics:[])
    }
    static func render(_ layers:[SceneImageLayer])throws->CGImage {try SceneWallpaperRenderer.render(inspection:inspection(layers),pixelSize:.init(width:64,height:64))}
    static func bytes(_ image:CGImage)->[UInt8] {Array(image.dataProvider!.data! as Data)}
    static func polygonReference(_ points:[CGPoint])throws->CGImage {
        guard let c=CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else {throw SceneWallpaperFailure(message:"Reference canvas failed")}
        c.setFillColor(red:0,green:0,blue:0,alpha:1);c.fill(.init(x:0,y:0,width:64,height:64))
        c.setFillColor(red:1,green:0,blue:0,alpha:1);c.move(to:points[0]);for p in points.dropFirst(){c.addLine(to:p)};c.closePath();c.fillPath();return c.makeImage()!
    }
    static func compareInterior(_ actual:CGImage,_ expected:CGImage)throws {
        let a=bytes(actual),b=bytes(expected);var covered=0,background=0
        for y in 1..<63 {for x in 1..<63 {
            let p=(y*64+x)*4, value=b[p]
            guard value==0 || value==255 else {continue}
            let stable=(-1...1).allSatisfy {dy in (-1...1).allSatisfy {dx in b[((y+dy)*64+x+dx)*4]==value}}
            if stable {guard abs(Int(a[p])-Int(value))<=2 else {throw SceneWallpaperFailure(message:"Actual affine pixels differ from independently drawn polygon at \(x),\(y)")};if value==255 {covered += 1}else {background += 1}}
        }}
        try check(covered>20 && background>3000,"sheared actual pixels match independent polygon interior and exterior")
    }
    static func main()throws {
        let parent=layer(1,group:true,x:32,y:32,sx:2,sy:1),child=layer(2,parent:1,angle:45)
        let world=try SceneHierarchy.worldStates(layers:[child,parent])[2]!.transform
        let r=sqrt(2.0),q=sqrt(0.5)
        try check(abs(world.a-r)<1e-10 && abs(world.b-q)<1e-10 && abs(world.c+r)<1e-10 && abs(world.d-q)<1e-10 && world.tx==32 && world.ty==32,"parent nonuniform scale times child rotation retains full affine shear")
        try check(abs(world.a*world.c+world.b*world.d)>1,"world basis is genuinely nonorthogonal rather than decomposed TRS")
        let expected=try polygonReference([.init(x:32-2*r,y:32-8*q),.init(x:32+8*r,y:32+2*q),.init(x:32+2*r,y:32+8*q),.init(x:32-8*r,y:32-2*q)])
        try compareInterior(render([child,parent]),expected)
        let rotated=try SceneHierarchy.worldStates(layers:[layer(1,group:true,x:32,y:32,angle:90),layer(2,parent:1,x:10)])[2]!.transform
        try check(abs(rotated.tx-32)<1e-10 && abs(rotated.ty-42)<1e-10,"ancestor rotation transforms child translation")
        try compareInterior(render([layer(1,group:true,x:32,y:32,angle:90),layer(2,parent:1,x:10)]),polygonReference([.init(x:29,y:37),.init(x:35,y:37),.init(x:35,y:47),.init(x:29,y:47)]))
        let mirror=[layer(1,group:true,x:32,y:32,sx:-1),layer(2,parent:1,group:true,x:10,sy:-1),layer(3,parent:2,x:2,y:3)]
        let m=try SceneHierarchy.worldStates(layers:mirror)[3]!.transform
        try check(m.a == -1 && m.d == -1 && m.tx == 20 && m.ty == 29,"multilevel negative scales preserve reflection and local translations")
        let mirrorPixels=try render(mirror)
        let referenceMirror=try polygonReference([.init(x:15,y:26),.init(x:25,y:26),.init(x:25,y:32),.init(x:15,y:32)])
        try compareInterior(mirrorPixels,referenceMirror)
        let hidden=try render([layer(1,group:true,x:32,y:32,visible:false),layer(2,parent:1)])
        try check(stride(from:0,to:bytes(hidden).count,by:4).allSatisfy{bytes(hidden)[$0]==0},"hidden ancestor suppresses real child pixels")
        let zero=try render([layer(1,group:true,x:32,y:32,sx:0),layer(2,parent:1)])
        try check(bytes(zero)==bytes(hidden),"zero scale is valid and collapses rendered geometry without inversion")
        // Parent is an image here: its alpha and tint must not multiply children.
        let faintParent=layer(1,x:32,y:32,alpha:0,color:.init(x:0,y:1,z:0),size:.init(x:1,y:1))
        let opaqueChild=layer(2,parent:1,size:.init(x:20,y:20))
        try check(bytes(render([faintParent,opaqueChild]))==bytes(render([layer(2,x:32,y:32,size:.init(x:20,y:20))])),"image parent alpha and color do not inherit into child pixels")
        let red=layer(2,parent:1,size:.init(x:20,y:20)),green=layer(3,x:32,y:32,color:.init(x:0,y:1,z:0),size:.init(x:20,y:20)),group=layer(1,group:true,x:32,y:32)
        try check(bytes(render([red,green,group]))==bytes(render([green])),"scene array order remains draw order even when parent occurs last")
        try check(bytes(render([green,red,group]))==bytes(render([layer(2,x:32,y:32,size:.init(x:20,y:20))])),"tree grouping never reorders image composition")
        try rejects("missing parent rejected") {try SceneHierarchy.validate(layers:[layer(1,parent:9)])}
        try rejects("self parent rejected") {try SceneHierarchy.validate(layers:[layer(1,parent:1)])}
        try rejects("cycle rejected") {try SceneHierarchy.validate(layers:[layer(1,parent:2),layer(2,parent:1)])}
        try rejects("duplicate IDs rejected before dictionary construction") {try SceneHierarchy.validate(layers:[layer(1),layer(1)])}
        try SceneHierarchy.validate(layers:(1...64).map{layer($0,parent:$0==1 ? nil:$0-1,group:true)})
        try check(true,"exact 64-node hierarchy accepted")
        try SceneHierarchy.validate(layers:Array((1...64).map{layer($0,parent:$0==1 ? nil:$0-1,group:true)}.reversed()))
        try check(true,"reverse-order 64-node recursion is accepted without relying on cache order")
        try rejects("65-node hierarchy rejected including cached ancestors") {try SceneHierarchy.validate(layers:(1...65).map{layer($0,parent:$0==1 ? nil:$0-1,group:true)})}
        try rejects("unbounded world scale rejected") {try SceneHierarchy.validate(layers:(1...4).map{layer($0,parent:$0==1 ? nil:$0-1,group:true,sx:1_000_000)})}
        try check(try SceneHierarchy.worldStates(layers:[layer(1,group:true,sx:1_000_000),layer(2,parent:1,sx:1_000_000)])[2]?.transform.a == 1_000_000_000_000,"exact finite world matrix budget accepted")
        try rejects("nonfinite local transform rejected") {try SceneHierarchy.validate(layers:[layer(1,x:.nan)])}
        let old=SceneScriptLayerState(layer:layer(7,x:32,y:32))
        var legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any];legacy.removeValue(forKey:"parentID");legacy.removeValue(forKey:"isTransformOnly")
        let decoded=try JSONDecoder().decode(SceneScriptLayerState.self,from:JSONSerialization.data(withJSONObject:legacy))
        try check(decoded.parentID == nil && !decoded.isTransformOnly,"old worker layer Codable defaults retain image kind and root parent")
        let base=inspection([group,layer(2),layer(3,group:true,x:10)])
        let reparented=base.layers.map {node->SceneScriptLayerState in let s=SceneScriptLayerState(layer:node);return .init(id:s.id,name:s.name,origin:s.origin,angles:s.angles,scale:s.scale,size:s.size,color:s.color,alpha:s.alpha,visible:s.visible,parentID:s.id==2 ? 3:s.parentID,isTransformOnly:s.isTransformOnly)}
        let updated=try base.applyingScriptFrame(.init(layers:reparented,hasUpdateHandlers:true,canApplyUserProperties:false))
        try check(updated.layers[1].parentID==3 && updated.layers.map(\.id)==base.layers.map(\.id),"valid dynamic reparent changes only parent and preserves original array order")
        var states=reparented
        let g=states[0];states[0] = .init(id:g.id,name:g.name,origin:g.origin,angles:g.angles,scale:g.scale,size:g.size,color:g.color,alpha:g.alpha,visible:g.visible,isTransformOnly:false)
        try rejects("helper cannot change node kind") {_ = try base.applyingScriptFrame(.init(layers:states,hasUpdateHandlers:true,canApplyUserProperties:false))}
        let badGroup=SceneScriptLayerState(id:1,name:"node 1",origin:.init(x:0,y:0,z:0),angles:.init(x:0,y:0,z:0),scale:.init(x:1,y:1,z:1),size:.init(x:2,y:1),color:.init(x:1,y:1,z:1),alpha:1,visible:true,isTransformOnly:true)
        try rejects("helper cannot change dummy group size") {try badGroup.validate()}
        let cyclic=base.layers.map {node->SceneScriptLayerState in let s=SceneScriptLayerState(layer:node);return .init(id:s.id,name:s.name,origin:s.origin,angles:s.angles,scale:s.scale,size:s.size,color:s.color,alpha:s.alpha,visible:s.visible,parentID:s.id==1 ? 2:s.id==2 ? 1:nil,isTransformOnly:s.isTransformOnly)}
        try rejects("dynamic cycle rejected before frame publication") {_ = try base.applyingScriptFrame(.init(layers:cyclic,hasUpdateHandlers:true,canApplyUserProperties:false))}
        print("RESULT \(checks) hierarchy/affine/actual-pixel/untrusted-frame checks passed")
    }
}
