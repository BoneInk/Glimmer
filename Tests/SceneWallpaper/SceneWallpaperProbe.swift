import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

@main struct SceneWallpaperProbe {
    static func main() throws {
        let fm = FileManager.default, root = URL(fileURLWithPath: "/private/tmp/gw-scene-ap05-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        var checks:[String]=[]
        func check(_ value:Bool,_ name:String) throws { guard value else {throw SceneWallpaperFailure(message:"FAILED: "+name)};checks.append(name) }
        func rejects(_ name:String,_ body:()throws->Void) throws {
            var rejected=false
            do {try body()} catch {rejected=true}
            try check(rejected,name)
        }
        func json(_ object:Any)throws->Data {try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)}
        func u32(_ value:UInt32)->Data {var little=value.littleEndian;return withUnsafeBytes(of:&little){Data($0)}}
        func archive(_ entries:[(String,Data)], offsets:[UInt32]?=nil)->Data {
            let magic=Data("PKGV0005".utf8)
            var header=u32(UInt32(magic.count))+magic+u32(UInt32(entries.count)),payload=Data(),offset:UInt32=0
            for (index,entry) in entries.enumerated() {
                let path=Data(entry.0.utf8)
                header+=u32(UInt32(path.count))+path+u32(offsets?[index] ?? offset)+u32(UInt32(entry.1.count))
                payload+=entry.1;offset+=UInt32(entry.1.count)
            }
            return header+payload
        }
        let rgba=Data([255,0,0,255,0,255,0,255,0,0,255,255,255,255,255,255])
        func tex(_ payload:Data=Data(),block:String="TEXB0001",format:UInt32=0,flags:UInt32=0,compressed:UInt32=0,imageFormat:UInt32=13)->Data {
            var data=Data("TEXV0005\0TEXI0001\0".utf8)
            for value:UInt32 in [format,flags,2,2,2,2,0] {data+=u32(value)}
            data+=Data((block+"\0").utf8)+u32(1)
            if ["TEXB0003","TEXB0004"].contains(block) {data+=u32(imageFormat)}
            if block=="TEXB0004" {data+=u32(0)}
            data+=u32(1)+u32(2)+u32(2)
            if block != "TEXB0001" {data+=u32(compressed)+u32(UInt32(payload.count))}
            data+=u32(UInt32(payload.count))+payload
            return data
        }
        let model:[String:Any]=["material":"materials/picture.json","autosize":true]
        let material:[String:Any]=["passes":[["shader":"genericimage2","blending":"translucent","textures":["picture"]]]]
        var layer:[String:Any]=["id":7,"name":"Own synthetic image","image":"models/picture.json","origin":"500 300 0","angles":"0 0 15","scale":"2 0.5 1","size":"200 100","color":["user":"tint","value":"1 1 1"],"alpha":["user":"opacity","value":1],"visible":["user":"show","value":true],"effects":[]]
        let general:[String:Any]=["orthogonalprojection":["width":1000,"height":600],"clearcolor":"0.1 0.2 0.3","bloom":false,"hdr":false,"cameraparallax":false,"camerashake":false]
        var scene:[String:Any]=["version":1,"general":general,"objects":[layer]]
        let project:[String:Any]=["type":"scene","file":"scene.json","general":["properties":["show":["type":"bool","value":true],"opacity":["type":"slider","value":1],"tint":["type":"color","value":"1 1 1"]]]]
        let projectURL=root.appendingPathComponent("project.json"),pkgURL=root.appendingPathComponent("scene.pkg")
        try json(project).write(to:projectURL)
        func contents(_ customScene:[String:Any]?=nil,_ customModel:[String:Any]?=nil,_ customMaterial:[String:Any]?=nil,_ texture:Data?=nil)throws->[(String,Data)] {
            [("scene.json",try json(customScene ?? scene)),("models/picture.json",try json(customModel ?? model)),("materials/picture.json",try json(customMaterial ?? material)),("materials/picture.tex",texture ?? tex(rgba))]
        }
        try archive(contents()).write(to:pkgURL)
        let pkg=try ScenePackageArchive(url:pkgURL)
        try check(pkg.magic=="PKGV0005" && pkg.entries.count==4,"PKG header and direct entry index match upstream writer layout")
        try check(try pkg.read("MATERIALS\\picture.tex")==tex(rgba),"PKG lookup normalizes Windows separators and case without extraction")
        let before=try fm.contentsOfDirectory(atPath:root.path).sorted()
        let inspection=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(inspection.isRenderableSubset && inspection.layers.count==1,"packaged project resolves scene→image model→material→texture chain")
        try check(inspection.canvasSize==SceneVector2(x:1000,y:600) && inspection.clearColor==SceneVector3(x:0.1,y:0.2,z:0.3),"orthographic pixel canvas and clear color preserved")
        let image=inspection.layers[0]
        try check(image.origin==SceneVector3(x:500,y:300,z:0) && image.anglesDegrees.z==15 && image.scale.x==2 && image.size==SceneVector2(x:200,y:100),"image origin degree rotation scale and pixel size preserved")
        try check(image.bindings.map(\.propertyKey).sorted()==["opacity","show","tint"] && image.isVisible && image.opacity==1,"verified direct user/value wrappers expose bindings and defaults")
        try check(inspection.textures[image.texturePath]?.data==rgba && inspection.textures[image.texturePath]?.format == .rgba8888,"uncompressed RGBA TEX payload is executable image input")
        try check(try fm.contentsOfDirectory(atPath:root.path).sorted()==before,"inspection does not extract archive entries or create assets")
        var cameraGeneral=general
        cameraGeneral["zoom"]=1.5;cameraGeneral["nearz"]=0.01;cameraGeneral["farz"]=10_000;cameraGeneral["camerafade"]=true
        var cameraScene=scene
        cameraScene["general"]=cameraGeneral
        cameraScene["camera"]=["center":"-12 8 -1","eye":"-12 8 0","up":"-1 0 0"]
        try archive(contents(cameraScene)).write(to:pkgURL)
        let cameraInspection=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(cameraInspection.isRenderableSubset && cameraInspection.camera.eye==SceneVector3(x:-12,y:8,z:0) && cameraInspection.camera.up==SceneVector3(x:-1,y:0,z:0) && cameraInspection.camera.zoom==1.5,"translated rolled zoomed 2D camera plus near/far and camera-fade inspect as executable state")
        try check(cameraInspection.camera.cameraFade && cameraInspection.camera.nearZ==0.01 && cameraInspection.camera.farZ==10_000,"static camera-fade endpoint and 3D-only clip distances are preserved")
        try archive(contents()).write(to:pkgURL)
        let overrides=try json(["show":["value":false],"opacity":["value":0.25],"tint":["value":"0.2 0.4 0.6"]])
        let changed=try SceneWallpaperInspector.inspect(projectURL:projectURL,propertiesJSON:overrides)
        try check(!changed.layers[0].isVisible && changed.layers[0].opacity==0.25 && changed.layers[0].tint==SceneVector3(x:0.2,y:0.4,z:0.6),"bool tint opacity bindings consume actual override values")
        try rejects("unknown user override does not silently bind another property") {_ = try SceneWallpaperInspector.inspect(projectURL:projectURL,propertiesJSON:json(["unknown":true]))}
        for (path,data) in try contents() {
            let url=root.appendingPathComponent(path);try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url)
        }
        try check(try SceneWallpaperInspector.inspect(projectURL:projectURL).isRenderableSubset,"loose project dependency chain reads the same bounded 2D subset")
        try fm.removeItem(at:root.appendingPathComponent("scene.json"))
        func unsupported(_ name:String,_ changedScene:[String:Any]?=nil,_ changedModel:[String:Any]?=nil,_ changedMaterial:[String:Any]?=nil,_ texture:Data?=nil)throws {
            try archive(contents(changedScene,changedModel,changedMaterial,texture)).write(to:pkgURL)
            let result=try SceneWallpaperInspector.inspect(projectURL:projectURL)
            try check(!result.isRenderableSubset && !result.diagnostics.isEmpty,name)
        }
        let material4:[String:Any] = ["passes":[["shader":"genericimage4","blending":"additive","textures":["picture"],"combos":[:],"constantshadervalues":[:],"cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"]]]
        try archive(contents(nil,nil,material4)).write(to:pkgURL)
        let additiveInspection = try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(additiveInspection.isRenderableSubset && additiveInspection.layers[0].blend == .additive,"genericimage4 default state and additive material become executable blend state")
        for (key,value) in [("combos",["REFRACT":1] as Any),("depthtest","enabled" as Any),("cullmode","back" as Any),("constantshadervalues",["brightness":2] as Any)] {
            var pass = (material4["passes"] as! [[String:Any]])[0];pass[key]=value
            try unsupported("genericimage4 refuses active non-default material state: " + key,nil,nil,["passes":[pass]])
        }
        var particleScene=scene;particleScene["objects"]=[["id":123,"particle":"particles/missing.json","name":"Own missing particle"]]
        try archive(contents(particleScene)).write(to:pkgURL)
        let particleInspection=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(!particleInspection.isRenderableSubset && particleInspection.layers.isEmpty && particleInspection.diagnostics.contains(where:{$0.path.contains("particle")}),"particle drawable is diagnosed explicitly and never accepted as an inert transform node")
        let ownParticles:[String:Any] = ["material":"materials/own-particles.json","maxcount":8,"starttime":0,"emitter":[["name":"sphererandom","rate":2,"distancemin":0,"distancemax":0]],"initializer":[["name":"lifetimerandom","min":2,"max":2],["name":"sizerandom","min":2,"max":2],["name":"velocityrandom","min":"2 0 0","max":"2 0 0"]],"operator":[["name":"movement"]],"renderer":[["name":"sprite"]]]
        particleScene["objects"]=[["id":123,"particle":"particles/own.json","name":"Own sprite system","origin":"6 6 0"]]
        let particleMaterial:[String:Any] = ["passes":[["shader":"genericparticle","blending":"translucent","textures":["picture"]]]]
        let particleEntries=try contents(particleScene)+[("particles/own.json",json(ownParticles)),("materials/own-particles.json",json(particleMaterial))]
        try archive(particleEntries).write(to:pkgURL)
        let spriteInspection=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(spriteInspection.isRenderableSubset && spriteInspection.layers.first?.particleSystem != nil,"actual sphere sprite particle definition resolves material and texture into a drawable layer")
        let system=spriteInspection.layers[0].particleSystem!
        let sprites=try system.sprites(runtime:0.5,seed:123)
        try check(sprites.count==2 && sprites.contains(where:{abs($0.position.x-1)<1e-9}) && sprites.contains(where:{$0.position.x==0}),"bounded sprite evaluation emits actual births and analytically advances authored velocity")
        let deterministic=try system.sprites(runtime:0.5,seed:123)
        try check(sprites.map(\.position)==deterministic.map(\.position),"particle pause/seek has deterministic spawn samples without accumulating timer work")
        let particleImage0=try SceneWallpaperRenderer.render(inspection:spriteInspection,pixelSize:CGSize(width:1000,height:600),runtime:0)
        let particleImage1=try SceneWallpaperRenderer.render(inspection:spriteInspection,pixelSize:CGSize(width:1000,height:600),runtime:0.5)
        try check(particleImage0.dataProvider!.data! != particleImage1.dataProvider!.data!,"sprite particle runtime produces different actual rendered pixels at distinct authored times")
        var unsupportedParticles=ownParticles;unsupportedParticles["renderer"]=[["name":"rope"]]
        try archive(try contents(particleScene)+[("particles/own.json",json(unsupportedParticles)),("materials/own-particles.json",json(particleMaterial))]).write(to:pkgURL)
        let ropeInspection=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(ropeInspection.isRenderableSubset && ropeInspection.requiresAdvancedRendering && ropeInspection.layers[0].particleSystem?.renderer == .rope,"rope renderer retains its actual geometry mode and selects advanced backend")
        var inertVelocityParticles=ownParticles;inertVelocityParticles["operator"]=[]
        try archive(try contents(particleScene)+[("particles/own.json",json(inertVelocityParticles)),("materials/own-particles.json",json(particleMaterial))]).write(to:pkgURL)
        let inertVelocityInspection=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(!inertVelocityInspection.isRenderableSubset && inertVelocityInspection.layers.isEmpty && inertVelocityInspection.diagnostics.contains(where:{$0.message.contains("without a movement operator")}),"nonzero initialized velocity without Movement fails closed instead of creating unauthorized particle motion")
        var invalidSystem=system;invalidSystem.lifetimeMin=0
        try rejects("particle evaluator rejects zero lifetime before time arithmetic") {_ = try invalidSystem.sprites(runtime:1,seed:1)}
        try rejects("particle evaluator rejects nonfinite runtime") {_ = try system.sprites(runtime:.nan,seed:1)}
        let engineRoot=root.appendingPathComponent("verified-engine",isDirectory:true)
        try fm.createDirectory(at:engineRoot.appendingPathComponent("materials/particle"),withIntermediateDirectories:true)
        let engineData=tex(rgba),enginePath="materials/particle/halo.tex"
        try engineData.write(to:engineRoot.appendingPathComponent(enginePath))
        func sha(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
        let bundle=SceneEngineAssetBundle(rootURL:engineRoot,manifestIdentity:"synthetic-engine-fixture-only",verifiedFiles:[enginePath:sha(engineData)])
        let engineSource=try SceneAssetSource(rootURL:root,limits:.init(),engineAssets:bundle);try engineSource.useArchive("scene.pkg")
        try check(try engineSource.read(enginePath)==engineData,"missing workshop texture resolves only through explicitly verified engine asset digest")
        try Data([1,2,3]).write(to:engineRoot.appendingPathComponent(enginePath))
        let localEnginePath=root.appendingPathComponent(enginePath)
        try fm.createDirectory(at:localEnginePath.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data([10,20,30]).write(to:localEnginePath)
        try check(try engineSource.read(enginePath)==Data([10,20,30]),"loose workshop resource wins over engine fallback even when the project uses a package")
        try fm.removeItem(at:localEnginePath)
        try rejects("changed engine resource digest fails closed instead of accepting modified cache") {_ = try engineSource.read(enginePath)}
        let engineArchive=archive([(enginePath,engineData),("engine-only-config.json",Data("{}".utf8))])
        try engineArchive.write(to:engineRoot.appendingPathComponent("engine.pkg"))
        let archiveBundle=SceneEngineAssetBundle(rootURL:engineRoot,manifestIdentity:"synthetic-engine-archive-only",verifiedFiles:["engine.pkg":sha(engineArchive)],archivePaths:["engine.pkg"])
        let archivedEngineSource=try SceneAssetSource(rootURL:root,limits:.init(),engineAssets:archiveBundle);try archivedEngineSource.useArchive("scene.pkg")
        try check(try archivedEngineSource.read(enginePath)==engineData,"hash-pinned engine PKG is indexed in place without filesystem extraction")
        try rejects("project config cannot fall back to engine archive entries") {_ = try archivedEngineSource.read("engine-only-config.json")}
        layer["effects"]=[["file":"effects/own.json"]];scene["objects"]=[layer]
        try unsupported("nonempty effect produces explicit unsupported diagnostic",scene)
        layer["effects"]=[];layer["alpha"]=["value":1,"script":"own.js"];scene["objects"]=[layer]
        try archive(contents(scene)).write(to:pkgURL)
        let scripted = try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(scripted.isRenderableSubset && scripted.scriptProgram?.bindings.first?.source == "own.js", "SceneScript remains explicit inline program data, never a guessed file or silent static alpha")
        layer["alpha"]=["user":"opacity","value":1];layer["parent"]=99;scene["objects"]=[layer]
        try unsupported("parented geometry does not claim centered quad support",scene)
        layer.removeValue(forKey:"parent");scene["objects"]=[layer]
        try unsupported("unknown custom material shader is rejected",nil,nil,["passes":[["shader":"own-water","textures":["picture"]]]])
        try unsupported("missing material dependency blocks renderability",nil,["material":"materials/missing.json"])
        try unsupported("missing texture dependency blocks renderability",nil,nil,["passes":[["shader":"genericimage2","textures":["missing"]]]])
        try unsupported("malformed LZ4 TEX blocks renderability",nil,nil,nil,tex(rgba,block:"TEXB0002",compressed:1))
        for unsafe in ["../secret","/absolute","a/../b","C:\\outside","a//b","a/./b"] {
            try archive([(unsafe,Data([1]))]).write(to:pkgURL)
            try rejects("PKG rejects unsafe path "+unsafe) {_ = try ScenePackageArchive(url:pkgURL)}
        }
        try archive([("a",Data([1])),("A",Data([2]))]).write(to:pkgURL)
        try rejects("PKG rejects case-fold duplicate aliases") {_ = try ScenePackageArchive(url:pkgURL)}
        try archive([("a",Data([1,2])),("b",Data([3,4]))],offsets:[0,1]).write(to:pkgURL)
        try rejects("PKG rejects overlapping payload ranges") {_ = try ScenePackageArchive(url:pkgURL)}
        try archive([("a",Data([1]))],offsets:[UInt32.max]).write(to:pkgURL)
        try rejects("PKG rejects signed negative/overflow offset") {_ = try ScenePackageArchive(url:pkgURL)}
        let valid=archive([("a",Data(repeating:9,count:32))]);try valid.dropLast().write(to:pkgURL)
        try rejects("PKG rejects truncated declared payload") {_ = try ScenePackageArchive(url:pkgURL)}
        try valid.write(to:pkgURL)
        let bounded=try ScenePackageArchive(url:pkgURL)
        try rejects("PKG entry read obeys caller byte budget") {_ = try bounded.read("a",maximumBytes:8)}
        var tiny=SceneReadLimits();tiny.maximumIndexBytes=12
        try rejects("PKG bounded index never reads unbounded header") {_ = try ScenePackageArchive(url:pkgURL,limits:tiny)}
        try Data([0]).write(to:pkgURL)
        try rejects("already-open archive rejects later file truncation") {_ = try bounded.read("a")}
        try rejects("TEX rejects truncated raw RGBA count") {_ = try SceneTextureReader.read(tex(Data([1])),path:"a.tex")}
        try rejects("TEX rejects malformed DXT byte count rather than treating it as RGBA") {_ = try SceneTextureReader.read(tex(rgba,format:7),path:"a.tex")}
        try rejects("TEX animation flags cannot be silently treated as static") {_ = try SceneTextureReader.read(tex(rgba,flags:4),path:"a.tex")}
        func f32(_ x:Float)->Data {u32(x.bitPattern)}
        var atlas=tex(rgba,flags:4)+Data("TEXS0003\0".utf8)+u32(2)+u32(1)+u32(2)
        for x:Float in [0,1] {atlas+=u32(0)+f32(0.5)+f32(x)+f32(0)+f32(1)+f32(0)+f32(0)+f32(2)}
        let atlasAsset=try SceneTextureReader.read(atlas,path:"own-atlas.tex")
        try check(atlasAsset.animation?.frames.count==2 && atlasAsset.animation?.frames[1].x==1 && atlasAsset.animation?.frames[0].height==2,"bounded TEXS0003 atlas retains real frame rectangles rather than treating atlas as one static image")
        let section=tex(rgba,flags:4).count
        func malformedAtlas(_ offset:Int,_ value:UInt32)throws {var changed=atlas;changed.replaceSubrange((section+offset)..<(section+offset+4),with:u32(value));try rejects("atlas rejects malformed frame field at offset \(offset)") {_ = try SceneTextureReader.read(changed,path:"own-atlas.tex")}}
        try malformedAtlas(9,0)
        try malformedAtlas(9,257)
        try malformedAtlas(21,1)
        try malformedAtlas(25,Float.nan.bitPattern)
        try malformedAtlas(29,Float(2).bitPattern)
        try malformedAtlas(41,Float(1).bitPattern)
        var paddedAtlas=atlas;paddedAtlas.replaceSubrange(34..<38,with:u32(1))
        try rejects("animated atlas padded image crop is refused before UV normalization") {_ = try SceneTextureReader.read(paddedAtlas,path:"padded-atlas.tex")}
        try rejects("atlas trailing unknown sections reject") {_ = try SceneTextureReader.read(atlas+Data([0]),path:"own-atlas.tex")}
        try rejects("unknown bit19 is not globally accepted even at the engine beam logical path") {_ = try SceneTextureReader.read(tex(rgba,format:8,flags:0x80000),path:"materials/particle/beam/beam_1.tex")}
        try rejects("TEX trailing unparsed sections are rejected") {_ = try SceneTextureReader.read(tex(rgba)+Data([1]),path:"a.tex")}
        try rejects("TEX unknown marker is rejected") {_ = try SceneTextureReader.read(Data("TEXV9999\0".utf8),path:"a.tex")}
        let provider=CGDataProvider(data:rgba as CFData)!
        let cg=CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let encoded=NSMutableData();let destination=CGImageDestinationCreateWithData(encoded,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,cg,nil);try check(CGImageDestinationFinalize(destination),"own PNG fixture generated using public ImageIO")
        let staticB4=tex(encoded as Data,block:"TEXB0004")
        let pngB4=try SceneTextureReader.read(staticB4,path:"b4.tex")
        try check(pngB4.format == .png && pngB4.data == encoded as Data,"static TEXB0004 video-flag zero preserves real embedded PNG bytes")
        var videoB4=staticB4;videoB4[63]=1
        try rejects("TEXB0004 video flag is rejected without guessing image offsets") {_ = try SceneTextureReader.read(videoB4,path:"video.tex")}
        try rejects("static TEXB0004 truncated media flag is rejected") {_ = try SceneTextureReader.read(Data(staticB4.prefix(65)),path:"short-b4.tex")}
        let redOnly=try SceneTextureReader.read(tex(Data([128,64,32,0]),format:9),path:"r8.tex")
        try check(redOnly.data==Data([128,0,0,255,64,0,0,255,32,0,0,255,0,0,0,255]),"official format9 R8 expands bounded raw samples with GPU-equivalent zero missing channels and opaque alpha")
        let redGreen=try SceneTextureReader.read(tex(Data([128,64,32,16,8,4,2,1]),format:8),path:"rg8.tex")
        try check(redGreen.data==Data([128,64,0,255,32,16,0,255,8,4,0,255,2,1,0,255]),"official format8 RG88 preserves two-channel noise/normal payload samples")
        let pngTexture=try SceneTextureReader.read(tex(encoded as Data,block:"TEXB0003"),path:"image.tex")
        try check(pngTexture.format == .png && pngTexture.imageWidth==2,"TEXB0003 PNG codec marker resolves real decodable image payload")
        try archive(contents()).write(to:pkgURL)
        let outside=root.deletingLastPathComponent().appendingPathComponent("gw-scene-secret-\(UUID().uuidString).json");try json(model).write(to:outside)
        defer {try? fm.removeItem(at:outside)}
        let dependency=root.appendingPathComponent("models/picture.json");try fm.removeItem(at:dependency);try fm.createSymbolicLink(at:dependency,withDestinationURL:outside)
        try (try json(scene)).write(to:root.appendingPathComponent("scene.json"))
        let unsafe=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        try check(!unsafe.isRenderableSubset && !unsafe.diagnostics.isEmpty,"loose dependency symlink cannot cross the descriptor-backed resource boundary")
        // Deterministic hostile bytes exercise every bounded parser entry without
        // claiming compatibility with unknown real-world package versions.
        var seed:UInt64=0x12345678
        for length in 0..<128 {
            var bytes=Data()
            for _ in 0..<length {seed=seed &* 6364136223846793005 &+ 1;bytes.append(UInt8(truncatingIfNeeded:seed>>32))}
            try bytes.write(to:pkgURL)
            _ = try? ScenePackageArchive(url:pkgURL)
            _ = try? SceneTextureReader.read(bytes,path:"fuzz.tex")
        }
        try check(true,"128 deterministic malformed binary inputs terminate without unchecked reads or allocation")
        func pixel(_ image:CGImage,_ x:Int,_ y:Int)->[Int] {
            let bytes=CFDataGetBytePtr(image.dataProvider!.data!)!,index=(image.height-1-y)*image.bytesPerRow+x*4
            return (0..<4).map{Int(bytes[index+$0])}
        }
        func near(_ pixel:[Int],_ expected:[Int],tolerance:Int=3)->Bool {zip(pixel,expected).allSatisfy{abs($0-$1)<=tolerance}}
        let white=SceneTextureAsset(path:"white",format:.rgba8888,flags:1,data:Data(repeating:255,count:16),storageWidth:2,storageHeight:2,imageWidth:2,imageHeight:2)
        func renderedLayer(_ id:Int=1,texture:String="white",origin:SceneVector3=SceneVector3(x:6,y:6,z:0),size:SceneVector2=SceneVector2(x:4,y:4),scale:SceneVector3=SceneVector3(x:1,y:1,z:1),angle:Double=0,tint:SceneVector3=SceneVector3(x:1,y:1,z:1),opacity:Double=1,visible:Bool=true)->SceneImageLayer {
            SceneImageLayer(id:id,name:"Own render fixture",modelPath:"own",materialPath:"own",texturePath:texture,origin:origin,anglesDegrees:SceneVector3(x:0,y:0,z:angle),scale:scale,size:size,tint:tint,opacity:opacity,isVisible:visible,bindings:[])
        }
        func render(_ layers:[SceneImageLayer],textures:[String:SceneTextureAsset]=["white":white],camera:SceneCamera2D = .identity)throws->CGImage {
            try SceneWallpaperRenderer.render(inspection:SceneWallpaperInspection(canvasSize:SceneVector2(x:12,y:12),clearColor:SceneVector3(x:0,y:0,z:0),camera:camera,layers:layers,textures:textures,diagnostics:[]),pixelSize:CGSize(width:12,height:12))
        }
        let opaque=try render([renderedLayer(tint:SceneVector3(x:1,y:0,z:0))])
        try check(near(pixel(opaque,6,6),[255,0,0,255]) && near(pixel(opaque,1,1),[0,0,0,255]),"actual image quad tint and canvas clear produce expected pixels")
        let overlap=try render([renderedLayer(size:SceneVector2(x:6,y:6),tint:SceneVector3(x:1,y:0,z:0)),renderedLayer(2,tint:SceneVector3(x:0,y:0,z:1),opacity:0.5)])
        try check(near(pixel(overlap,6,6),[127,0,128,255]) && near(pixel(overlap,3,6),[255,0,0,255]),"draw order and half-alpha overlap use real source-over pixels")
        let glowBase = renderedLayer(tint:.init(x:0.4,y:0.1,z:0))
        let glow = SceneImageLayer(id:2,name:"Own additive",modelPath:"own",materialPath:"own",texturePath:"white",origin:.init(x:6,y:6,z:0),anglesDegrees:.init(x:0,y:0,z:0),scale:.init(x:1,y:1,z:1),size:.init(x:4,y:4),tint:.init(x:0.2,y:0.4,z:0.6),opacity:0.5,isVisible:true,bindings:[],blend:.additive)
        let glowImage = try render([glowBase,glow])
        try check(near(pixel(glowImage,6,6),[128,77,77,255]),"additive image material adds source RGB times opacity to actual destination pixels")
        let glowInspection = SceneWallpaperInspection(canvasSize:.init(x:12,y:12),clearColor:.init(x:0,y:0,z:0),layers:[glow],textures:["white":white],diagnostics:[])
        let scriptedGlow = try glowInspection.applyingScriptFrame(SceneScriptFrame(layers:[SceneScriptLayerState(layer:glow)],hasUpdateHandlers:false,canApplyUserProperties:false))
        try check(scriptedGlow.layers[0].blend == .additive,"isolated script frame preserves validated additive material metadata")
        let hidden=try render([renderedLayer(visible:false)])
        try check(near(pixel(hidden,6,6),[0,0,0,255]),"invisible image layer is absent from actual pixels")
        let rotated=try render([renderedLayer(size:SceneVector2(x:6,y:2),angle:90)])
        try check(near(pixel(rotated,6,8),[255,255,255,255]) && near(pixel(rotated,8,6),[0,0,0,255]),"90 degree rotation transforms actual quad geometry")
        let scaled=try render([renderedLayer(size:SceneVector2(x:2,y:2),scale:SceneVector3(x:3,y:1,z:1))])
        try check(near(pixel(scaled,8,6),[255,255,255,255]) && near(pixel(scaled,6,8),[0,0,0,255]),"nonuniform XY scale changes actual image coverage")
        let translatedCamera=SceneCamera2D(center:.init(x:2,y:0,z:-1),eye:.init(x:2,y:0,z:0),up:.init(x:0,y:1,z:0),zoom:1,nearZ:0.01,farZ:10_000,cameraFade:true)
        let translated=try render([renderedLayer()],camera:translatedCamera)
        try check(near(pixel(translated,4,6),[255,255,255,255]) && near(pixel(translated,7,6),[0,0,0,255]),"camera XY translation changes actual composed pixels")
        let rolledCamera=SceneCamera2D(center:.init(x:12,y:0,z:-1),eye:.init(x:12,y:0,z:0),up:.init(x:-1,y:0,z:0),zoom:1,nearZ:0.01,farZ:10_000,cameraFade:false)
        let rolled=try render([renderedLayer(size:.init(x:6,y:2))],camera:rolledCamera)
        try check(near(pixel(rolled,6,8),[255,255,255,255]) && near(pixel(rolled,8,6),[0,0,0,255]),"camera up vector rolls actual orthographic geometry")
        let zoomedCamera=SceneCamera2D(center:.init(x:0,y:0,z:-1),eye:.init(x:0,y:0,z:0),up:.init(x:0,y:1,z:0),zoom:2,nearZ:0.01,farZ:10_000,cameraFade:false)
        let zoomed=try render([renderedLayer(origin:.init(x:3,y:3,z:0),size:.init(x:2,y:2))],camera:zoomedCamera)
        try check(near(pixel(zoomed,6,6),[255,255,255,255]) && near(pixel(zoomed,8,6),[0,0,0,255]),"camera zoom scales and repositions actual orthographic geometry")
        for (name,badCamera) in [
            ("zero camera up",SceneCamera2D(center:.init(x:0,y:0,z:-1),eye:.init(x:0,y:0,z:0),up:.init(x:0,y:0,z:0),zoom:1,nearZ:0.01,farZ:10_000,cameraFade:false)),
            ("nonfinite camera",SceneCamera2D(center:.init(x:0,y:0,z:-1),eye:.init(x:.nan,y:0,z:0),up:.init(x:0,y:1,z:0),zoom:1,nearZ:0.01,farZ:10_000,cameraFade:false)),
            ("zero camera zoom",SceneCamera2D(center:.init(x:0,y:0,z:-1),eye:.init(x:0,y:0,z:0),up:.init(x:0,y:1,z:0),zoom:0,nearZ:0.01,farZ:10_000,cameraFade:false)),
            ("reversed camera clip",SceneCamera2D(center:.init(x:0,y:0,z:-1),eye:.init(x:0,y:0,z:0),up:.init(x:0,y:1,z:0),zoom:1,nearZ:10,farZ:1,cameraFade:false))
        ] { try rejects("renderer rejects "+name) { _ = try render([renderedLayer()],camera:badCamera) } }
        let split=SceneTextureAsset(path:"split",format:.rgba8888,flags:1,data:Data([255,0,0,255,0,255,0,255,255,0,0,255,0,255,0,255]),storageWidth:2,storageHeight:2,imageWidth:2,imageHeight:2)
        let mirrored=try render([renderedLayer(texture:"split",scale:SceneVector3(x:-1,y:1,z:1))],textures:["split":split])
        try check(near(pixel(mirrored,4,6),[0,255,0,255]) && near(pixel(mirrored,7,6),[255,0,0,255]),"negative scale mirrors real texture pixels")
        let directedRotation=try render([renderedLayer(texture:"split",angle:90)],textures:["split":split])
        try check(near(pixel(directedRotation,6,4),[255,0,0,255]) && near(pixel(directedRotation,6,7),[0,255,0,255]),"positive Z degrees rotate asymmetric texture counterclockwise in y-up coordinates")
        let vertical=SceneTextureAsset(path:"vertical",format:.rgba8888,flags:1,data:Data([255,0,0,255,255,0,0,255,0,0,255,255,0,0,255,255]),storageWidth:2,storageHeight:2,imageWidth:2,imageHeight:2)
        let oriented=try render([renderedLayer(texture:"vertical")],textures:["vertical":vertical])
        try check(near(pixel(oriented,6,7),[255,0,0,255]) && near(pixel(oriented,6,4),[0,0,255,255]),"top-down source rows preserve image orientation in y-up scene coordinates")
        let tintedVertical=try render([renderedLayer(texture:"vertical",tint:SceneVector3(x:0.5,y:1,z:1))],textures:["vertical":vertical])
        try check(near(pixel(tintedVertical,6,7),[128,0,0,255]) && near(pixel(tintedVertical,6,4),[0,0,255,255]),"CPU tint multiplication preserves source orientation")
        let padded=SceneTextureAsset(path:"padded",format:.rgba8888,flags:1,data:Data([255,0,0,255,0,255,0,255,0,0,255,255,255,255,255,255]),storageWidth:2,storageHeight:2,imageWidth:1,imageHeight:1)
        let cropped=try render([renderedLayer(texture:"padded")],textures:["padded":padded])
        try check(near(pixel(cropped,6,6),[255,0,0,255]),"real top-left image dimensions crop padded TEX storage")
        let encodedImage=SceneTextureAsset(path:"encoded",format:.png,flags:1,data:encoded as Data,storageWidth:2,storageHeight:2,imageWidth:2,imageHeight:2)
        let pngRendered=try render([renderedLayer(texture:"encoded")],textures:["encoded":encodedImage])
        try check(near(pixel(pngRendered,4,7),[255,0,0,255]),"encoded PNG layers are decoded into real renderer pixels")
        let halfAlpha=SceneTextureAsset(path:"alpha",format:.rgba8888,flags:1,data:Data([255,255,255,128,255,255,255,128,255,255,255,128,255,255,255,128]),storageWidth:2,storageHeight:2,imageWidth:2,imageHeight:2)
        let combinedAlpha=try render([renderedLayer(texture:"alpha",tint:SceneVector3(x:0.5,y:0,z:0),opacity:0.5)],textures:["alpha":halfAlpha])
        try check(near(pixel(combinedAlpha,6,6),[32,0,0,255]),"texture alpha tint and layer opacity combine without double premultiplication")
        let whiteProvider=CGDataProvider(data:white.data as CFData)!
        let whiteCG=CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:whiteProvider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let jpegData=NSMutableData(),jpegDestination=CGImageDestinationCreateWithData(jpegData,"public.jpeg" as CFString,1,nil)!
        CGImageDestinationAddImage(jpegDestination,whiteCG,[kCGImageDestinationLossyCompressionQuality:1] as CFDictionary)
        try check(CGImageDestinationFinalize(jpegDestination),"own JPEG fixture generated using public ImageIO")
        let jpegTexture=try SceneTextureReader.read(tex(jpegData as Data,block:"TEXB0003",imageFormat:2),path:"jpeg.tex")
        let jpegImage=try render([renderedLayer(texture:"jpeg.tex",tint:SceneVector3(x:0,y:0,z:1))],textures:["jpeg.tex":jpegTexture])
        try check(near(pixel(jpegImage,6,6),[0,0,255,255],tolerance:6),"TEX embedded JPEG is decoded and tinted into real pixels")
        let aspect=try SceneWallpaperRenderer.render(inspection:SceneWallpaperInspection(canvasSize:SceneVector2(x:12,y:12),clearColor:SceneVector3(x:0,y:0,z:0),layers:[renderedLayer()],textures:["white":white],diagnostics:[]),pixelSize:CGSize(width:24,height:12))
        try check(near(pixel(aspect,12,6),[255,255,255,255]) && near(pixel(aspect,7,6),[0,0,0,255]),"viewport aspect-fit preserves scene geometry without stretching")
        let blocked=SceneWallpaperInspection(canvasSize:SceneVector2(x:12,y:12),clearColor:SceneVector3(x:0,y:0,z:0),layers:[renderedLayer()],textures:["white":white],diagnostics:[SceneDiagnostic(severity:.unsupported,path:"effects",message:"Own unsupported fixture")])
        try rejects("renderer refuses entire scene with any blocking diagnostic") {_ = try SceneWallpaperRenderer.render(inspection:blocked,pixelSize:CGSize(width:12,height:12))}
        try rejects("renderer rejects oversized output allocation") {_ = try SceneWallpaperRenderer.render(inspection:inspection,pixelSize:CGSize(width:100_000,height:100_000))}
        // Reinspect the actual project bindings, then measure the composed output.
        try fm.removeItem(at:root.appendingPathComponent("scene.json"))
        layer["origin"]="6 6 0";layer["angles"]="0 0 0";layer["scale"]="1 1 1";layer["size"]="4 4"
        scene["objects"]=[layer];scene["general"]=["orthogonalprojection":["width":12,"height":12],"clearcolor":"0 0 0"]
        try archive(contents(scene,nil,nil,tex(Data(repeating:255,count:16),flags:1))).write(to:pkgURL)
        let boundDefault=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        let boundWhite=try SceneWallpaperRenderer.render(inspection:boundDefault,pixelSize:CGSize(width:12,height:12))
        let boundTint=try SceneWallpaperInspector.inspect(projectURL:projectURL,propertiesJSON:json(["tint":"1 0 0","opacity":0.5]))
        let boundRed=try SceneWallpaperRenderer.render(inspection:boundTint,pixelSize:CGSize(width:12,height:12))
        try check(near(pixel(boundWhite,6,6),[255,255,255,255]) && near(pixel(boundRed,6,6),[128,0,0,255]),"author color and slider overrides change real reinspected pixels")
        let boundHidden=try SceneWallpaperInspector.inspect(projectURL:projectURL,propertiesJSON:json(["show":false]))
        let boundHiddenImage=try SceneWallpaperRenderer.render(inspection:boundHidden,pixelSize:CGSize(width:12,height:12))
        try check(near(pixel(boundHiddenImage,6,6),[0,0,0,255]),"author bool override changes real reinspected visibility pixels")
        if CommandLine.arguments.count>1 {
            let evidence=URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent()
            let visualCamera=SceneCamera2D(center:.init(x:1,y:-2,z:-1),eye:.init(x:1,y:-2,z:0),up:.init(x:-0.5,y:0.8660254037844386,z:0),zoom:1.5,nearZ:0.01,farZ:10_000,cameraFade:true)
            let visual=SceneWallpaperInspection(canvasSize:boundDefault.canvasSize,clearColor:boundDefault.clearColor,camera:visualCamera,layers:boundDefault.layers,textures:boundDefault.textures,diagnostics:[])
            for (name,value) in [("default",boundDefault),("author-color-opacity",boundTint),("author-hidden",boundHidden),("camera-translate-roll-zoom",visual)] {
                let image=try SceneWallpaperRenderer.render(inspection:value,pixelSize:CGSize(width:240,height:240))
                let output=NSMutableData(),writer=CGImageDestinationCreateWithData(output,"public.png" as CFString,1,nil)!
                CGImageDestinationAddImage(writer,image,nil)
                guard CGImageDestinationFinalize(writer) else {throw SceneWallpaperFailure(message:"Could not export own renderer evidence")}
                try (output as Data).write(to:evidence.appendingPathComponent(name+".png"))
            }
        }
        let report:[String:Any]=["success":true,"checkCount":checks.count,"checks":checks,"fixtures":"new synthetic JSON/PKG/TEX/RGBA/PNG/JPEG generated by this test; no workshop assets","scope":"bounded static 2D Scene inspection plus real CoreGraphics image composition; no desktop/UI registration"]
        let output=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count>1 {try output.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
        print(String(decoding:output,as:UTF8.self))
    }
}
