import Foundation

@main @MainActor struct SceneScriptParserTests {
    static var checks = 0
    static let fm = FileManager.default
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SceneWallpaperFailure(message: name) }; checks += 1; print("PASS \(name)")
    }
    static func rejects(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { try check(true,name); return }; throw SceneWallpaperFailure(message: name + " unexpectedly passed")
    }
    static func u32(_ value: UInt32) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object,options: [.sortedKeys,.fragmentsAllowed]) }
    static func project(_ root: URL, layers: [[String:Any]], packaged: Bool = false, sceneExtra: [String:Any] = [:]) throws -> URL {
        try fm.createDirectory(at: root,withIntermediateDirectories: true)
        let props: [String:Any] = ["pos":["type":"textinput","value":"3 4 0"],"speed":["type":"slider","min":0,"max":10,"fraction":true,"value":2.5]]
        try json(["type":"scene","file":"scene.json","general":["properties":props]]).write(to: root.appendingPathComponent("project.json"))
        var scene: [String:Any] = ["general":["orthogonalprojection":["width":16,"height":16]],"objects":layers]
        for (key,value) in sceneExtra { scene[key] = value }
        var tex = Data("TEXV0005\0TEXI0001\0".utf8)
        for n: UInt32 in [0,0,2,2,2,2,0] { tex += u32(n) }
        tex += Data("TEXB0001\0".utf8)
        for n: UInt32 in [1,1,2,2,16] { tex += u32(n) }; tex += Data(repeating:255,count:16)
        let entries:[(String,Data)] = [("scene.json",try json(scene)),("model.json",try json(["material":"material.json"])),
            ("material.json",try json(["passes":[["shader":"genericimage2","blending":"translucent","textures":["image"]]]])),("materials/image.tex",tex)]
        if packaged {
            let magic = Data("PKGV0005".utf8); var header = u32(UInt32(magic.count)) + magic + u32(UInt32(entries.count)), payload = Data(), offset:UInt32 = 0
            for (path,data) in entries { let name = Data(path.utf8); header += u32(UInt32(name.count)) + name + u32(offset) + u32(UInt32(data.count)); offset += UInt32(data.count); payload += data }
            try (header+payload).write(to: root.appendingPathComponent("scene.pkg"))
        } else {
            for (name,data) in entries { let file = root.appendingPathComponent(name);try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:file) }
        }
        return root.appendingPathComponent("project.json")
    }
    static func layer(_ id:Int = 7, code:String? = nil) -> [String:Any] {
        var layer:[String:Any] = ["id":id,"name":"image \(id)","image":"model.json","origin":"8 8 0","size":"16 16"]
        if let code {
            let defaults:[String:Any] = ["origin":"8 8 0","angles":"0 0 0","scale":"1 1 1","size":"16 16","visible":true,"color":"1 1 1","alpha":1]
            for (key,value) in defaults { layer[key] = ["script":code,"value":value] }
        }
        return layer
    }
    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("GW-SceneScript-Parser-\(UUID())")
        defer { try? fm.removeItem(at:root) }
        let code = "'use strict'; export function update(value) { return value; }"
        let staticURL = try project(root.appendingPathComponent("static"),layers:[layer()])
        let staticInspection = try SceneWallpaperInspector.inspect(projectURL:staticURL)
        try check(staticInspection.isRenderableSubset && staticInspection.scriptProgram == nil,"static Scene preserves nil script program")
        for packaged in [false,true] {
            var item = layer(code:code)
            item["origin"] = ["script":code,"value":"8 8 0","user":"pos","scriptproperties":["speed":["user":"speed","value":1],"literal":true]]
            let url = try project(root.appendingPathComponent(packaged ? "pkg":"loose"),layers:[item],packaged:packaged)
            let payload = try json(["pos":["value":"5 6 0"],"speed":["value":4.5]])
            let inspected = try SceneWallpaperInspector.inspect(projectURL:url,propertiesJSON:payload)
            guard let program = inspected.scriptProgram else { throw SceneWallpaperFailure(message:"No program: \(inspected.diagnostics)") }
            try check(inspected.isRenderableSubset && program.bindings.count == 7,"\(packaged ? "PKG":"loose") extracts seven supported property wrappers")
            try check(program.bindings.map(\.target).sorted() == ["alpha","angles","color","origin","scale","size","visible"],"only exact recognized layer targets become executable bindings")
            let origin = program.bindings.first { $0.target == "origin" }!
            try check(origin.id == "7.origin" && origin.layerID == 7 && origin.source == code && origin.initialValue == .string("5 6 0"),"inline source and user-resolved initial value preserved exactly")
            try check(origin.scriptProperties == ["speed":.number(4.5),"literal":.bool(true)] && origin.scriptPropertyBindings == ["speed":"speed"],"lowercase scriptproperties user/value binding uses actual current properties")
            try check(program.directBindings.count == 1 && program.directBindings[0].target == "origin" && program.directBindings[0].propertyKey == "pos","hybrid direct binding retained for same target")
            let roundTrip = try JSONDecoder().decode(SceneScriptProgram.self,from:JSONEncoder().encode(program))
            try check(roundTrip.bindings.map(\.id) == program.bindings.map(\.id) && roundTrip.layers[0].origin == .init(x:5,y:6,z:0),"Foundation Codable program round trip preserves ordered IDs and layer states")
            let convenience = SceneScriptProgram(inspection:inspected)
            try check(convenience.directBindings.count == 1 && convenience.layers.count == 1,"inspection convenience captures all direct bindings and layers")
        }
        func invalid(_ name:String,_ layers:[[String:Any]],extra:[String:Any] = [:]) throws {
            let url = try project(root.appendingPathComponent(UUID().uuidString),layers:layers,sceneExtra:extra)
            let inspected = try SceneWallpaperInspector.inspect(projectURL:url)
            try check(!inspected.isRenderableSubset && inspected.scriptProgram == nil && !inspected.diagnostics.isEmpty,name)
        }
        var bad = layer();bad["origin"] = ["script":code,"value":"8 8 0","expression":"1+2"]
        try invalid("unknown wrapper field blocks program rather than silently ignoring",[bad])
        bad = layer();bad["origin"] = ["script":42,"value":"8 8 0"]
        try invalid("non-string script source is rejected",[bad])
        bad = layer();bad["origin"] = ["script":code]
        try invalid("script wrapper requires explicit fallback value",[bad])
        bad = layer();bad["origin"] = ["script":code,"value":"8 8 1"]
        try invalid("script fallback cannot hide unsupported 3D depth",[bad])
        bad = layer();bad["origin"] = ["script":code,"value":"8 8 0","scriptproperties":["x":["user":["name":"speed","condition":"1"],"value":1]]]
        try invalid("conditional user object remains unsupported",[bad])
        bad = layer();bad["origin"] = ["script":code,"value":"8 8 0","scriptproperties":["x":["user":"missing","value":1]]]
        try invalid("unknown script property user binding is rejected",[bad])
        bad = layer();bad["origin"] = ["script":code,"value":"8 8 0","scriptProperties":[:]]
        try invalid("unverified camel-case metadata wrapper is rejected",[bad])
        bad = layer(code:code);bad["effects"] = [["file":"effect.json"]]
        try invalid("valid script does not permit unsupported effects",[bad])
        bad = layer(code:code);bad["parent"] = 2
        try invalid("valid script does not permit parent transforms",[bad])
        bad = layer();bad["script"] = code
        try invalid("layer-level script outside recognized property wrapper is rejected",[bad])
        try invalid("scene-level scripts object remains unsupported",[layer()],extra:["scripts":["test":code]])
        bad = layer();bad["origin"] = ["script":"","value":"8 8 0"]
        try invalid("empty inline source rejected",[bad])
        bad = layer();bad["origin"] = ["script":"x\0y","value":"8 8 0"]
        try invalid("NUL inline source rejected",[bad])
        bad = layer();bad["origin"] = ["script":String(repeating:"x",count:256*1024+1),"value":"8 8 0"]
        try invalid("per-script 256 KiB cap enforced",[bad])
        let maximum = "/*"+String(repeating:"x",count:256*1024-4)+"*/"
        var maximumLayer = layer();maximumLayer["origin"] = ["script":maximum,"value":"8 8 0"]
        let maxURL = try project(root.appendingPathComponent("maximum"),layers:[maximumLayer])
        try check(try SceneWallpaperInspector.inspect(projectURL:maxURL).scriptProgram?.bindings.first?.source.utf8.count == 256*1024,"exact per-script byte boundary accepted")
        try invalid("aggregate source cap enforced before execution",(1...8).map { layer($0,code:String(repeating:" ",count:20_000)+code) })
        try invalid("64 binding cap enforced across layers",(1...10).map { layer($0,code:code) })
        var many:[String:Any] = [:];for i in 0..<129 { many["key\(i)"] = i }
        bad = layer();bad["origin"] = ["script":code,"value":"8 8 0","scriptproperties":many]
        try invalid("script property map count bounded",[bad])
        bad = layer();bad["origin"] = ["script":code,"value":"8 8 0","scriptproperties":["large":String(repeating:"x",count:70_000)]]
        try invalid("script property byte size bounded",[bad])
        var deeplyNested: Any = "leaf"
        for _ in 0..<18 { deeplyNested = [deeplyNested] }
        bad = layer();bad["origin"] = ["script":code,"value":"8 8 0","scriptproperties":["nested":deeplyNested]]
        try invalid("script property nested JSON depth bounded",[bad])
        let largeMaps = (1...36).map { id -> [String:Any] in
            var item = layer(id); item["origin"] = ["script":code,"value":"8 8 0","scriptproperties":["text":String(repeating:"x",count:60_000)]]
            return item
        }
        try invalid("entire serialized program capped at two MiB",largeMaps)
        let shaderURL = try project(root.appendingPathComponent("shader"),layers:[layer(code:code)])
        try json(["passes":[["shader":"custom-water","blending":"translucent","textures":["image"]]]]).write(to:shaderURL.deletingLastPathComponent().appendingPathComponent("material.json"))
        let shader = try SceneWallpaperInspector.inspect(projectURL:shaderURL)
        try check(!shader.isRenderableSubset && shader.scriptProgram == nil,"script bindings never permit unknown custom shader")
        var fileLike = layer();fileLike["origin"] = ["script":"../../not-opened.js","value":"8 8 0"]
        let fileLikeURL = try project(root.appendingPathComponent("filelike"),layers:[fileLike])
        try check(try SceneWallpaperInspector.inspect(projectURL:fileLikeURL).scriptProgram?.bindings.first?.source == "../../not-opened.js","path-looking source stays inline and never opens a file")
        // JavaScript syntax/capabilities belong to the real worker AST. The
        // structural parser must not mistake literal/comment words for imports.
        for text in ["export function update(v){return v;} // import foo", "const s='import'; const r=/import/; const t=`import`; export function update(v){return v;}", "import * as X from 'module';"] {
            try SceneScriptSourcePolicy.validateInline(text)
            try check(true,"source policy does not implement a competing JS lexer or capability grep")
        }
        var directLayer = layer(8)
        directLayer["origin"] = ["user":"pos","value":"8 8 0"]
        let hybridURL = try project(root.appendingPathComponent("hybrid"),layers:[layer(code:code),directLayer])
        let hybrid = try SceneWallpaperInspector.inspect(projectURL:hybridURL)
        try check(hybrid.scriptProgram?.directBindings.contains { $0.layerID == 8 && $0.propertyKey == "pos" } == true,
            "dynamic program retains direct bindings on non-scripted layers")
        let reversed = SceneScriptFrame(layers:hybrid.layers.reversed().map(SceneScriptLayerState.init(layer:)),hasUpdateHandlers:false,canApplyUserProperties:false)
        try check(try hybrid.applyingScriptFrame(reversed).layers.map(\.id) == [7,8],"frame order cannot reorder original Scene composition")
        let legacyBinding = try json(["id":"x","layerID":7,"target":"alpha","source":code,"initialValue":1,"scriptProperties":[:]])
        try check(try JSONDecoder().decode(SceneScriptBindingSpec.self,from:legacyBinding).scriptPropertyBindings.isEmpty,"missing script property associations default safely on decode")
        let legacyProgram = try json(["bindings":[],"layers":[]])
        try check(try JSONDecoder().decode(SceneScriptProgram.self,from:legacyProgram).directBindings.isEmpty,"missing direct bindings default safely on decode")
        let initial = SceneScriptLayerState(layer:staticInspection.layers[0])
        let changed = SceneScriptLayerState(id:initial.id,name:initial.name,origin:.init(x:4,y:5,z:0),angles:.init(x:0,y:0,z:90),scale:.init(x:2,y:1,z:1),size:.init(x:8,y:4),color:.init(x:1,y:0,z:0),alpha:0.5,visible:false)
        let frame = SceneScriptFrame(layers:[changed],hasUpdateHandlers:true,canApplyUserProperties:true)
        let patched = try staticInspection.applyingScriptFrame(frame)
        try check(patched.layers[0].origin == changed.origin && patched.layers[0].opacity == 0.5 && !patched.layers[0].isVisible,"validated frame applies actual image layer values")
        try check(patched.layers[0].modelPath == staticInspection.layers[0].modelPath && patched.textures.keys == staticInspection.textures.keys && patched.canvasSize == staticInspection.canvasSize,"frame cannot replace model/material/texture/canvas dependencies")
        try rejects("missing frame IDs rejected") { _ = try staticInspection.applyingScriptFrame(.init(layers:[],hasUpdateHandlers:false,canApplyUserProperties:false)) }
        try rejects("duplicate frame IDs rejected") { _ = try staticInspection.applyingScriptFrame(.init(layers:[initial,initial],hasUpdateHandlers:false,canApplyUserProperties:false)) }
        func state(id:Int = 7,name:String = "image 7",origin:SceneVector3 = .init(x:8,y:8,z:0),angles:SceneVector3 = .init(x:0,y:0,z:0),scale:SceneVector3 = .init(x:1,y:1,z:1),size:SceneVector2 = .init(x:16,y:16),color:SceneVector3 = .init(x:1,y:1,z:1),alpha:Double = 1) -> SceneScriptLayerState {
            .init(id:id,name:name,origin:origin,angles:angles,scale:scale,size:size,color:color,alpha:alpha,visible:true)
        }
        let invalidStates:[SceneScriptLayerState] = [state(id:99),state(name:"renamed"),state(origin:.init(x:0,y:0,z:1)),state(angles:.init(x:1,y:0,z:0)),state(scale:.init(x:1,y:1,z:0)),state(size:.init(x:0,y:16)),state(color:.init(x:2,y:1,z:1)),state(alpha:2),state(alpha:.nan),state(origin:.init(x:.infinity,y:0,z:0)),state(origin:.init(x:1_000_001,y:0,z:0))]
        for (i,bad) in invalidStates.enumerated() { try rejects("invalid or non-2D helper frame #\(i) rejected") { _ = try staticInspection.applyingScriptFrame(.init(layers:[bad],hasUpdateHandlers:true,canApplyUserProperties:true)) } }
        let decoded = try JSONDecoder().decode(SceneScriptFrame.self,from:JSONEncoder().encode(frame))
        try check(decoded.hasUpdateHandlers && decoded.canApplyUserProperties && decoded.layers[0].alpha == 0.5,"frame capability booleans and pixels state are Codable data only")
        print("SceneScriptParserTests: \(checks) passed; bounded inline extraction and untrusted frame validation, no JavaScript execution")
    }
}
