import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Read-only audit of a caller-provided workshop project. Optional diagnostic
/// raster frames are explicitly incomplete evidence, never library imports.
@main struct SceneWorkshopCompatibilityProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("project.json output-directory worker-executable") }
        let projectURL = URL(fileURLWithPath:CommandLine.arguments[1])
        let output = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let workerURL = URL(fileURLWithPath:CommandLine.arguments[3])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let pkgURL=projectURL.deletingLastPathComponent().appendingPathComponent("scene.pkg")
        func hash(_ url:URL)throws->String { SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined() }
        let before=[try hash(projectURL),try hash(pkgURL)]
        let inspection=try SceneWallpaperInspector.inspect(projectURL:projectURL)
        guard !inspection.isRenderableSubset,inspection.layers.count == 4,inspection.textures.count == 3,
              inspection.scriptProgram == nil,inspection.layers.filter({$0.blend == .additive}).count == 2 else {
            throw SceneWallpaperFailure(message:"Expected complete project to remain blocked while all four actual image layers and three B4 textures decode.")
        }
        let archive=try ScenePackageArchive(url:pkgURL)
        let scene=try JSONSerialization.jsonObject(with:archive.read("scene.json")) as! [String:Any]
        let objects=scene["objects"] as! [[String:Any]]
        let particleCount=objects.filter{$0["particle"] is String}.count
        let shapeCount=objects.filter{$0["shape"] is String}.count
        guard particleCount==7,shapeCount==2 else {throw SceneWallpaperFailure(message:"Unexpected real workshop scene structure.")}
        // Isolate only authored alpha animation for diagnostic pixel evidence.
        // The full project is never passed to the renderer with diagnostics erased.
        // Particles, shafts and global bloom are omitted explicitly. The actual
        // authored mouse-position script is exercised with a typed input snapshot;
        // the report still records that this is NOT complete playback.
        var bindings:[SceneScriptBindingSpec]=[],mouseBindings:[SceneScriptBindingSpec]=[]
        for object in objects {
            guard let id=object["id"] as? Int,inspection.layers.contains(where:{$0.id==id}),
                  let layer=inspection.layers.first(where:{$0.id==id}) else {continue}
            if let wrapper=object["alpha"] as? [String:Any],let code=wrapper["script"] as? String {
                let initial=try JSONDecoder().decode(GWJSONValue.self,from:JSONSerialization.data(withJSONObject:wrapper["value"]!,options:.fragmentsAllowed))
                bindings.append(.init(id:"\(id).alpha",layerID:id,target:"alpha",source:code,initialValue:initial,scriptProperties:[:],scriptPropertyBindings:[:]))
            }
            if let wrapper=object["origin"] as? [String:Any],let code=wrapper["script"] as? String,
               code.contains("input.cursorWorldPosition") {
                let initial=GWJSONValue.string("\(layer.origin.x) \(layer.origin.y) \(layer.origin.z)")
                mouseBindings.append(.init(id:"\(id).origin",layerID:id,target:"origin",source:code,initialValue:initial,scriptProperties:[:],scriptPropertyBindings:[:]))
            }
        }
        guard bindings.count==3,mouseBindings.count==1 else {throw SceneWallpaperFailure(message:"Expected three original alpha scripts and one original mouse-position script.")}
        let program=SceneScriptProgram(bindings:bindings+mouseBindings,layers:inspection.layers.map(SceneScriptLayerState.init(layer:)),directBindings:[])
        let imageOnly=SceneWallpaperInspection(canvasSize:inspection.canvasSize,clearColor:inspection.clearColor,camera:inspection.camera,layers:inspection.layers,textures:inspection.textures,diagnostics:[],scriptProgram:program)
        let client=SceneScriptWorkerClient(executableURL:workerURL)
        var frames:[[String:Any]]=[]
        do {
            _ = try await client.configure(program:program,userProperties:Data("{}".utf8))
            for time in [0.0,0.6,2.0] {
                let cursor=SceneVector3(x:960+time*100,y:540-time*50,z:0)
                let frame=try await client.step(runtime:time,frameTime:time==0 ? 0 : 0.1,
                    input:.init(cursorWorldPosition:cursor))
                let current=try imageOnly.applyingScriptFrame(frame)
                let image=try SceneWallpaperRenderer.render(inspection:current,pixelSize:.init(width:960,height:540))
                let path=output.appendingPathComponent("INCOMPLETE-image-layers-t\(time).png")
                guard let destination=CGImageDestinationCreateWithURL(path as CFURL,"public.png" as CFString,1,nil) else {throw SceneWallpaperFailure(message:"Could not write diagnostic image.")}
                CGImageDestinationAddImage(destination,image,nil)
                guard CGImageDestinationFinalize(destination) else {throw SceneWallpaperFailure(message:"Could not finalize diagnostic image.")}
                let mouseLayerID=mouseBindings[0].layerID
                guard current.layers.first(where:{$0.id==mouseLayerID})?.origin == cursor else {
                    throw SceneWallpaperFailure(message:"Original mouse-position script did not consume the supplied world cursor.")
                }
                frames.append(["runtime":time,"image":path.lastPathComponent,"cursorWorldPosition":["x":cursor.x,"y":cursor.y,"z":cursor.z],"alphaByLayerID":Dictionary(uniqueKeysWithValues:current.layers.map{(String($0.id),$0.opacity)}),"sha256":try hash(path)])
            }
            await client.dispose()
        } catch {await client.dispose();throw error}
        guard Set(frames.compactMap{$0["sha256"] as? String}).count==3,before == [try hash(projectURL),try hash(pkgURL)] else {throw SceneWallpaperFailure(message:"Frame evidence failed to change or source files were modified.")}
        let report:[String:Any] = ["success":true,"fullProjectPlayable":false,"project":projectURL.path,"actualDecodedImageLayers":inspection.layers.count,"actualDecodedTextures":inspection.textures.count,"particleNodes":particleCount,"proceduralShapeNodes":shapeCount,"sourceFilesUnchanged":true,"diagnosticFramesOnly":true,"omittedFromDiagnosticFrames":["all 7 particle nodes","both lightshaft shapes","global bloom"],"executedOriginalAlphaScripts":bindings.count,"executedOriginalMouseInputScripts":mouseBindings.count,"fullPlaybackBlocker":"Referenced Wallpaper Engine builtin textures require an authenticated verified resource bundle.","implementedRendererCapabilitiesAwaitingActualResourceValidation":["linear bloom","hash-pinned procedural lightshafts","sprite trails and ropes","stateful particle turbulence, children and control points","water framebuffer refraction"],"unverifiedFidelity":["local deterministic particle sampling and curl field","rope spline and UV conventions","water response and bloom filters","no Windows pixel-parity reference"],"missingReferencedEngineResources":["materials/particle/halo.tex","materials/particle/beam/beam_1.tex","materials/particle/fog/fog1.tex","materials/particle/beam/hose_2.tex","materials/particle/beam/hose_2_normal.tex","materials/util/noise.tex","materials/gradient/gradient_iridescent.tex"],"frames":frames,"blockingDiagnostics":inspection.diagnostics.map{["path":$0.path,"severity":$0.severity.rawValue,"message":$0.message]},"textureSizes":inspection.textures.mapValues{["width":$0.imageWidth,"height":$0.imageHeight,"format":$0.format.rawValue]}]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:output.appendingPathComponent("report.json"))
        print(String(decoding:data,as:UTF8.self))
    }
}
