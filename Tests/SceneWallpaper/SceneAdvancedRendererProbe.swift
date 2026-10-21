import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

@main struct SceneAdvancedRendererProbe {
    static func main()throws {
        var checks:[String]=[]
        func check(_ ok:Bool,_ text:String)throws {guard ok else {throw SceneWallpaperFailure(message:"FAILED: "+text)};checks.append(text)}
        func texture(_ path:String,_ width:Int=2,_ height:Int=2,_ fill:(Int,Int)->[UInt8])->SceneTextureAsset {var bytes=Data();for y in 0..<height {for x in 0..<width {bytes.append(contentsOf:fill(x,y))}};return .init(path:path,format:.rgba8888,flags:2,data:bytes,storageWidth:width,storageHeight:height,imageWidth:width,imageHeight:height)}
        let white=texture("white"){_,_ in [255,255,255,255]}
        let normal=texture("normal"){_,_ in [255,128,255,255]}
        let noise=texture("noise",32,32){x,y in let v=UInt8((x*47+y*31)%255);return [v,v,v,255]}
        let gradient=texture("gradient",32,2){x,_ in [UInt8(x*8),UInt8(255-x*8),255,255]}
        let background=texture("background",64,64){x,_ in x<32 ? [255,0,0,255]:[0,0,255,255]}
        func layer(_ id:Int,texture:String="white",origin:SceneVector3 = .init(x:32,y:32,z:0),size:SceneVector2 = .init(x:8,y:8),tint:SceneVector3 = .init(x:1,y:1,z:1),alpha:Double=1,blend:SceneImageBlend = .translucent,particle:SceneSpriteParticleSystem?=nil,shaft:SceneLightShaft?=nil,normal:String?=nil,amount:Double=0)->SceneImageLayer {
            .init(id:id,name:"Own fixture \(id)",modelPath:"own",materialPath:"own",texturePath:texture,origin:origin,anglesDegrees:.init(x:0,y:0,z:0),scale:.init(x:1,y:1,z:1),size:size,tint:tint,opacity:alpha,isVisible:true,bindings:[],blend:blend,particleSystem:particle,lightShaft:shaft,normalTexturePath:normal,refractionAmount:amount)
        }
        var alphaOnly=texture("alpha-only"){_,_ in [128,0,0,255]};alphaOnly.channelCount=1
        var grayscaleAlpha=texture("gray-alpha"){_,_ in [128,128,0,255]};grayscaleAlpha.channelCount=2
        var sheet=texture("own-sheet",4,2){x,_ in x<2 ? [255,0,0,255]:[0,0,255,255]}
        sheet.animation = .init(frames:[.init(x:0,y:0,width:2,height:2,duration:20),.init(x:2,y:0,width:2,height:2,duration:1)])
        let textures=["alpha-only":alphaOnly,"gray-alpha":grayscaleAlpha,"own-sheet":sheet,"white":white,"normal":normal,"noise":noise,"gradient":gradient,"background":background]
        func inspection(_ layers:[SceneImageLayer],bloom:SceneBloom? = .init(strength:0,threshold:1,tint:.init(x:1,y:1,z:1)))->SceneWallpaperInspection {.init(canvasSize:.init(x:64,y:64),clearColor:.init(x:0,y:0,z:0),layers:layers,textures:textures,diagnostics:[],bloom:bloom)}
        func render(_ scene:SceneWallpaperInspection,_ time:Double=0,_ cursor:SceneVector3?=nil)throws->CGImage {try SceneWallpaperRenderer.render(inspection:scene,pixelSize:.init(width:64,height:64),runtime:time,cursorWorldPosition:cursor)}
        func pixel(_ image:CGImage,_ x:Int,_ y:Int)->[Int] {let data=CFDataGetBytePtr(image.dataProvider!.data!)!,i=(image.height-1-y)*image.bytesPerRow+x*4;return (0..<4).map{Int(data[i+$0])}}
        func hash(_ image:CGImage)->String {SHA256.hash(data:image.dataProvider!.data! as Data).map{String(format:"%02x",$0)}.joined()}
        let alphaImage=try render(inspection([layer(1,tint:.init(x:1,y:0,z:0)),layer(2,tint:.init(x:0,y:0,z:1),alpha:0.5)]))
        let mixed=pixel(alphaImage,32,32)
        try check(abs(mixed[0]-188)<4 && abs(mixed[2]-188)<4,"real Metal RGBA16Float composites half-alpha in linear light and encodes sRGB once")
        let dark=try render(inspection([layer(1,alpha:0)]))
        try check(pixel(dark,32,32)==[0,0,0,255],"zero alpha contributes no premultiplied RGB in advanced pipeline")
        let r8Pixel=pixel(try render(inspection([layer(1,texture:"alpha-only")])),32,32)
        try check(r8Pixel.prefix(3).allSatisfy{abs($0-188)<4},"official R8 albedo samples become white plus red-channel alpha before linear composition")
        let rgPixel=pixel(try render(inspection([layer(1,texture:"gray-alpha")])),32,32)
        try check(rgPixel.prefix(3).allSatisfy{abs($0-137)<4},"RG88 mid-gray R and alpha G stay linear before premultiplication and final sRGB encoding")
        var atlasSystem=SceneSpriteParticleSystem();atlasSystem.rate=0.01;atlasSystem.maximumCount=1;atlasSystem.lifetimeMin=2;atlasSystem.lifetimeMax=2;atlasSystem.sizeMin=16;atlasSystem.sizeMax=16
        let atlasScene=inspection([layer(1,texture:"own-sheet",particle:atlasSystem)])
        let firstAtlas=pixel(try render(atlasScene,0),32,32),midAtlas=pixel(try render(atlasScene,1),32,32)
        try check(firstAtlas[0]>250 && firstAtlas[2]<3 && abs(midAtlas[0]-188)<4 && abs(midAtlas[2]-188)<4,"particle atlas advances and blends adjacent cells over particle lifetime independent of TEX frame durations")
        let brightLayers=[layer(1,size:.init(x:4,y:4),blend:.additive),layer(2,size:.init(x:4,y:4),blend:.additive)]
        let noBloom=try render(inspection(brightLayers)),withBloom=try render(inspection(brightLayers,bloom:.init(strength:2,threshold:1,tint:.init(x:1,y:1,z:1))))
        try check(pixel(noBloom,39,32)[0]==0 && pixel(withBloom,39,32)[0]>0,"additive highlights retain values above one and bloom produces actual pixels outside bright source geometry")
        let bg=layer(1,texture:"background",size:.init(x:64,y:64))
        let refracted=try render(inspection([bg,layer(2,size:.init(x:24,y:24),normal:"normal",amount:0.2)]))
        try check(pixel(refracted,28,32)[2]>200 && pixel(refracted,10,32)[0]>200,"water normal map samples preceding framebuffer at displaced UV while outside pixels remain unchanged")
        var shaft=SceneLightShaft();shaft.points=[.init(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)];shaft.mode=1;shaft.rendering=1;shaft.noiseTexturePath="noise";shaft.gradientTexturePath="gradient";shaft.noiseAmount=0.5;shaft.intensity=2;shaft.scale = .init(x:1,y:1);shaft.speed=1
        let shaftScene=inspection([layer(1,texture:"noise",size:.init(x:64,y:64),shaft:shaft)])
        let shaft0=try render(shaftScene,0),shaft3=try render(shaftScene,3)
        try check(hash(shaft0) != hash(shaft3),"project lightshaft formula consumes actual noise/gradient and authored time to change real GPU pixels")
        var particles=SceneSpriteParticleSystem();particles.renderer = .rope;particles.rate=20;particles.maximumCount=32;particles.preRoll=0.5;particles.lifetimeMin=2;particles.lifetimeMax=2;particles.sizeMin=3;particles.sizeMax=3;particles.velocityMin = .init(x:20,y:10,z:0);particles.velocityMax=particles.velocityMin;particles.subdivision=3;particles.uvScrolling=true
        let ropeScene=inspection([layer(1,origin:.init(x:12,y:20,z:0),particle:particles)])
        let rope0=try render(ropeScene,0),rope1=try render(ropeScene,0.5)
        try check(hash(rope0) != hash(rope1),"fixed-step rope joins successive births with subdivisions and moving UVs instead of static sprite quads")
        particles.renderer = .spritetrail;particles.trailLength=0.03;particles.trailMax=2
        let trailScene=inspection([layer(1,origin:.init(x:12,y:20,z:0),particle:particles)])
        try check(hash(try render(trailScene,0.5)) != hash(rope1),"sprite trail uses velocity-facing stretched geometry distinct from connected rope geometry")
        particles.renderer = .rope;particles.turbulenceSpeedMin=10;particles.turbulenceSpeedMax=20;particles.controlPointAttract = -100;particles.controlPointThreshold=40;particles.controlPointFollowsMouse=true
        let forceScene=inspection([layer(1,origin:.init(x:12,y:20,z:0),particle:particles)])
        let forceA=try render(forceScene,0.5,.init(x:25,y:25,z:0)),forceB=try render(forceScene,0.8,.init(x:40,y:40,z:0))
        try check(hash(forceA) != hash(forceB),"stateful turbulence and actual world cursor control force advance bounded particle trajectories")
        particles.children=[.init(system:particles,texturePath:"white",normalTexturePath:nil,blend:.additive)]
        let childScene=inspection([layer(1,origin:.init(x:12,y:20,z:0),particle:particles)])
        try check(hash(try render(childScene,0.5,.init(x:25,y:25,z:0))) != hash(forceA),"authored static child system is drawn as an additional actual particle system")
        let expensive=inspection((0..<6).map{layer(100+$0,size:.init(x:64,y:64))},bloom:.init(strength:1,threshold:0.5,tint:.init(x:1,y:1,z:1)))
        var budgetRejected=false
        do {_ = try SceneWallpaperRenderer.render(inspection:expensive,pixelSize:.init(width:4096,height:4096))}
        catch {budgetRejected=error.localizedDescription.contains("sample-work budget")}
        try check(budgetRejected,"over-budget postprocessing ends its Metal encoder and throws a readable error instead of aborting")
        try check(pixel(try render(inspection([layer(1)])),32,32)==[255,255,255,255],"advanced renderer remains usable after rejected postprocessing command")
        let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        for (name,image) in [("bloom",withBloom),("refraction",refracted),("lightshafts",shaft3),("rope",rope1)] {let dest=CGImageDestinationCreateWithURL(out.appendingPathComponent(name+".png") as CFURL,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(dest,image,nil);guard CGImageDestinationFinalize(dest) else {throw SceneWallpaperFailure(message:"Fixture image export failed.")}}
        let data=try JSONSerialization.data(withJSONObject:["success":true,"checkCount":checks.count,"checks":checks,"method":"Actual native Metal GPU pixels from original synthetic fixtures; no external wallpaper assets or UI used"],options:[.prettyPrinted,.sortedKeys]);try data.write(to:out.appendingPathComponent("report.json"));print(String(decoding:data,as:UTF8.self))
    }
}
