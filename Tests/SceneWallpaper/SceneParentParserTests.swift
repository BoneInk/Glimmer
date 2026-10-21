import Foundation

@main struct SceneParentParserTests {
    static func main() throws {
        let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent("GW-Parent-Parser-\(UUID())")
        try fm.createDirectory(at:root.appendingPathComponent("models"),withIntermediateDirectories:true)
        try fm.createDirectory(at:root.appendingPathComponent("materials"),withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:root)}
        func json(_ value:[String:Any]) throws -> Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])}
        func write(_ value:[String:Any],_ path:String) throws {try json(value).write(to:root.appendingPathComponent(path))}
        func u32(_ n:UInt32)->Data {var v=n.littleEndian;return withUnsafeBytes(of:&v){Data($0)}}
        try write(["type":"scene","file":"scene.json","general":["properties":["offset":["type":"textinput","value":"10 20 0"],"angle":["type":"textinput","value":"0 0 30"],"stretch":["type":"textinput","value":"2 3 1"],"shown":["type":"bool","value":true]]]],"project.json")
        try write(["material":"materials/image.json"],"models/image.json")
        try write(["passes":[["shader":"genericimage2","textures":["image"],"blending":"translucent"]]],"materials/image.json")
        var tex=Data("TEXV0005\0TEXI0001\0".utf8);for n:UInt32 in [0,0,2,2,2,2,0]{tex+=u32(n)}
        tex+=Data("TEXB0001\0".utf8);for n:UInt32 in [1,1,2,2,16]{tex+=u32(n)};tex+=Data(repeating:255,count:16)
        try tex.write(to:root.appendingPathComponent("materials/image.tex"))
        var checks=0
        func check(_ value:Bool,_ name:String) throws {guard value else{throw SceneWallpaperFailure(message:name)};checks+=1;print("PASS \(name)")}
        func image(_ id:Int,_ parent:Int?=nil)->[String:Any] {var v:[String:Any]=["id":id,"image":"models/image.json","origin":"0 0 0","size":"20 20"];if let parent{v["parent"]=parent};return v}
        func group(_ id:Int,_ parent:Int?=nil)->[String:Any] {var v:[String:Any]=["id":id,"name":"Group \(id)","origin":"10 20 0","angles":"0 0 30","scale":"2 3 1","visible":true,"effects":[]];if let parent{v["parent"]=parent};return v}
        func inspect(_ objects:[[String:Any]],_ parallax:Any?=false) throws -> SceneWallpaperInspection {
            var general:[String:Any]=["orthogonalprojection":["width":64,"height":48],"clearcolor":"0 0 0"]
            if let parallax{general["cameraparallax"]=parallax}
            try write(["general":general,"objects":objects],"scene.json")
            return try SceneWallpaperInspector.inspect(projectURL:root.appendingPathComponent("project.json"))
        }
        func rejects(_ objects:[[String:Any]],_ name:String,_ parallax:Any?=false) throws {
            do {let inspected=try inspect(objects,parallax);try check(!inspected.isRenderableSubset && !inspected.diagnostics.isEmpty,name)}
            catch let failure as SceneWallpaperFailure {if failure.message == name{throw failure};checks+=1;print("PASS \(name)")}
        }
        var result=try inspect([image(3,2),group(2,1),image(1)])
        try check(result.isRenderableSubset,"child before parent, transform-only intermediate and image parent parse")
        try check(result.layers.map(\.id)==[3,2,1] && result.layers.map(\.parentID)==[2,1,nil],"scene draw array and numeric parent identity preserved")
        let node=result.layers[1]
        try check(node.isTransformOnly && node.modelPath.isEmpty && node.texturePath.isEmpty && node.size==SceneVector2(x:1,y:1) && node.tint==SceneVector3(x:1,y:1,z:1) && node.opacity==1,"group has fixed non-drawing transport placeholders")
        try check(!result.layers[0].isTransformOnly && !result.layers[2].isTransformOnly && result.textures.count==1,"image parents and children retain actual texture dependencies")
        let legacy=try JSONEncoder().encode(result.layers[0]);var old=try JSONSerialization.jsonObject(with:legacy) as! [String:Any]
        old.removeValue(forKey:"parentID");old.removeValue(forKey:"isTransformOnly")
        let decoded=try JSONDecoder().decode(SceneImageLayer.self,from:json(old))
        try check(decoded.parentID==nil && !decoded.isTransformOnly,"legacy layer JSON missing new fields decodes with old defaults")
        let round=try JSONDecoder().decode(SceneImageLayer.self,from:JSONEncoder().encode(node))
        try check(round.parentID==1 && round.isTransformOnly,"parent and node kind survive Codable roundtrip")
        result=try inspect([["id":1],image(2,1)])
        try check(result.isRenderableSubset && result.layers[0].origin==SceneVector3(x:0,y:0,z:0) && result.layers[0].scale==SceneVector3(x:1,y:1,z:1),"empty common node gets zero origin and unit scale")
        var bound=group(1)
        for (target,key,value) in [("origin","offset","0 0 0"),("angles","angle","0 0 0"),("scale","stretch","1 1 1")] {bound[target]=["user":key,"value":value]}
        bound["visible"]=["user":"shown","value":false]
        result=try inspect([bound,image(2,1)])
        try check(result.isRenderableSubset && Set(result.layers[0].bindings.map(\.target))==Set(["origin","angles","scale","visible"]),"only four common direct bindings are editable on transform-only nodes")
        try check(result.layers[0].origin.x==10 && result.layers[0].anglesDegrees.z==30 && result.layers[0].scale.y==3 && result.layers[0].isVisible,"common direct bindings resolve actual project defaults")
        let changed=try SceneWallpaperInspector.inspect(projectURL:root.appendingPathComponent("project.json"),propertiesJSON:json(["shown":false,"offset":"30 40 0"]))
        try check(changed.isRenderableSubset && changed.layers[0].origin.x==30 && !changed.layers[0].isVisible,"common group author overrides change actual parsed transform and visibility")
        var parentImage=image(1);parentImage["alpha"]=0.2;parentImage["color"]="1 0 0";parentImage["size"]="50 60"
        result=try inspect([parentImage,image(2,1)])
        try check(result.layers[1].opacity==1 && result.layers[1].tint==SceneVector3(x:1,y:1,z:1) && result.layers[1].size==SceneVector2(x:20,y:20),"image-parent alpha color and size remain local values, not CSS inheritance")
        try check(try inspect([group(0),image(1,0)]).isRenderableSubset,"parent ID zero is a real existing node ID")
        try rejects([image(1,0)],"absent parent zero is not guessed to be a root sentinel")
        var scripted=group(1)
        for target in ["origin","angles","scale","visible"] {scripted[target]=["script":"export function update(value){return value;}","value":scripted[target]!]}
        result=try inspect([scripted,image(2,1)])
        try check(result.isRenderableSubset && result.scriptProgram?.bindings.count==4 && Set(result.scriptProgram!.bindings.map(\.target))==Set(["origin","angles","scale","visible"]),"four common script targets extracted without image-only fields")
        for key in ["alpha","color","size"] {
            var bad=group(1);bad[key]=key == "alpha" ? 0.5 : "1 1 1"
            try rejects([bad,image(2,1)],"group \(key) is refused instead of inherited or fake editable")
            bad[key]=["script":"export function update(value){return value;}","value":key == "alpha" ? 0.5 : "1 1 1"]
            try rejects([bad,image(2,1)],"group image-only \(key) script is refused")
        }
        for key in ["text","particle","sound","light","model","shape","unknownDrawable","group","attachment"] {
            var bad=group(1);bad[key]="unsupported"
            try rejects([bad,image(2,1)],"missing image cannot swallow drawable or unknown field \(key)")
        }
        try rejects([group(1)],"group-only project is not declared drawable")
        for (name,parent) in [("negative",-1 as Any),("fractional",1.5 as Any),("string","1" as Any),("boolean",true as Any),("null",NSNull() as Any),("too large",Double(Int32.max)+1)] {
            var bad=image(2);bad["parent"]=parent;try rejects([group(1),bad],"invalid parent \(name) rejected")
        }
        try rejects([image(2,99)],"missing referenced parent rejected")
        try rejects([image(2,2)],"self parent rejected")
        try rejects([group(1,2),image(2,1)],"two-node cycle rejected")
        try rejects([group(1,3),group(2,1),image(3,2)],"long cycle rejected")
        try rejects([group(1),image(1)],"duplicate group/image ID rejected")
        var chain=(1...63).map{group($0,$0 == 1 ? nil : $0-1)};chain.append(image(64,63))
        // Unit scales isolate the depth boundary from the composed matrix budget.
        for i in chain.indices{chain[i]["scale"]="1 1 1"}
        try check(try inspect(chain).isRenderableSubset,"64-level hierarchy accepted")
        chain.append(image(65,64));try rejects(chain,"65-level hierarchy rejected independent of array order")
        chain.reverse();try rejects(chain,"65-level reversed hierarchy rejected")
        for (key,value) in [("origin","0 0 1"),("angles","1 0 0"),("scale","1 1 2")] {var bad=group(1);bad[key]=value;try rejects([bad,image(2,1)],"group non-2D \(key) rejected")}
        var zero=group(1);zero["scale"]="0 -2 1";try check(try inspect([zero,image(2,1)]).isRenderableSubset,"zero and negative scale remain valid rendering transforms")
        var depthGroup=group(1),depthImage=image(2,1);depthGroup["parallaxDepth"]="1 1";depthImage["parallaxDepth"]="1 1"
        try check(try inspect([depthGroup,depthImage],false).isRenderableSubset,"group and image default depth 1 1 inert when camera parallax explicitly false")
        try rejects([depthGroup,depthImage],"enabled camera parallax remains unsupported",true)
        try rejects([depthGroup,depthImage],"missing camera flag does not grant inert-depth exception",nil)
        try rejects([depthGroup,depthImage],"numeric false is not explicit boolean false",0)
        for value in ["nan 1","inf 1","1000001 1","1 1 1"] {var bad=depthGroup;bad["parallaxDepth"]=value;try rejects([bad,depthImage],"unsafe parallax depth \(value) rejected even when disabled")}
        print("RESULT \(checks) passed; real project parser, graph validation and legacy JSON compatibility")
    }
}
