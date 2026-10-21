import Foundation
import CoreGraphics

@main struct SceneInspectionUIProbe {
    @MainActor static func main() async throws {
        let fm=FileManager.default,root=URL(fileURLWithPath:"/private/tmp/gw-scene-ui-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:root)}
        var checks:[String]=[]
        func check(_ condition:Bool,_ text:String)throws {guard condition else {throw SceneWallpaperFailure(message:"FAILED: "+text)};checks.append(text)}
        func json(_ value:Any)throws->Data {try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)}
        func u32(_ number:UInt32)->Data {var value=number.littleEndian;return withUnsafeBytes(of:&value){Data($0)}}
        func fixture(_ name:String)throws->URL {
            let folder=root.appendingPathComponent(name,isDirectory:true)
            try fm.createDirectory(at:folder.appendingPathComponent("models"),withIntermediateDirectories:true)
            try fm.createDirectory(at:folder.appendingPathComponent("materials"),withIntermediateDirectories:true)
            let project:[String:Any]=["type":"scene","file":"scene.json","general":["properties":["show":["type":"bool","value":true],"tint":["type":"color","value":"1 1 1"],"opacity":["type":"slider","value":1,"min":0,"max":1,"fraction":true],"unbound":["type":"bool","value":true],"combo":["type":"combo","value":"a","options":[["label":"A","value":"a"]]]]]]
            try json(project).write(to:folder.appendingPathComponent("project.json"))
            let layer:[String:Any]=["id":1,"name":name,"image":"models/own.json","origin":"6 6 0","size":"4 4","visible":["user":"show","value":true],"color":["user":"tint","value":"1 1 1"],"alpha":["user":"opacity","value":1]]
            try json(["general":["orthogonalprojection":["width":12,"height":12],"clearcolor":"0 0 0"],"objects":[layer]]).write(to:folder.appendingPathComponent("scene.json"))
            try json(["material":"materials/own.json","autosize":true]).write(to:folder.appendingPathComponent("models/own.json"))
            try json(["passes":[["shader":"genericimage2","blending":"translucent","textures":["own"]]]]).write(to:folder.appendingPathComponent("materials/own.json"))
            var texture=Data("TEXV0005\0TEXI0001\0".utf8)
            for number:UInt32 in [0,1,2,2,2,2,0] {texture+=u32(number)}
            texture+=Data("TEXB0001\0".utf8)
            for number:UInt32 in [1,1,2,2,16] {texture+=u32(number)}
            texture+=Data(repeating:255,count:16)
            try texture.write(to:folder.appendingPathComponent("materials/own.tex"))
            return folder
        }
        func wait(_ predicate:()->Bool) async throws {
            let deadline=Date().addingTimeInterval(8)
            while !predicate(),Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
            try check(predicate(),"bounded async operation completed")
        }
        let a=try fixture("A"),b=try fixture("B"),sourceBefore=try Data(contentsOf:a.appendingPathComponent("project.json"))
        let model=SceneInspectionModel()
        model.select(folder:a)
        try await wait{model.context != nil || model.error != nil}
        try check(model.error==nil && model.context?.inspection.isRenderableSubset == true,"selected real folder is inspected and rendered in isolated model")
        var context=model.context
        try check(context?.editableKeys==["show","opacity","tint"],"only actual bound bool slider color keys become editable")
        let temp=context!.lease.temporaryDirectory
        try check(temp.lastPathComponent.hasPrefix("Glimmer-ScenePreview-") && fm.fileExists(atPath:temp.path),"override storage uses private temporary selection scope")
        try await context!.overrideStore.set(.string("1 0 0"),for:"tint",itemID:context!.itemID,project:context!.project)
        try await context!.apply(["show":.bool(true),"opacity":.number(0.5),"tint":.string("1 0 0")])
        let image=try SceneWallpaperRenderer.render(inspection:context!.inspection,pixelSize:CGSize(width:12,height:12))
        let bytes=CFDataGetBytePtr(image.dataProvider!.data!)!,offset=(12-1-6)*image.bytesPerRow+6*4
        try check(abs(Int(bytes[offset])-128)<=3 && bytes[offset+1]==0,"author callback waits for real reinspection/rendered red half-opacity pixels")
        try check(try Data(contentsOf:a.appendingPathComponent("project.json"))==sourceBefore,"author edits never mutate selected project source")
        do {try await context!.apply(["combo":.string("a")]);throw SceneWallpaperFailure(message:"unsupported edit accepted")}
        catch {try check(error.localizedDescription.contains("尚未接通"),"unconnected author option cannot claim rendered success")}
        do {try await context!.apply(["opacity":.number(2)]);throw SceneWallpaperFailure(message:"invalid opacity accepted")}
        catch {try check(!context!.isUpdating,"invalid author value leaves update state usable")}
        try (sourceBefore+Data("\n".utf8)).write(to:a.appendingPathComponent("project.json"))
        do {try await context!.apply(["show":.bool(false)]);throw SceneWallpaperFailure(message:"changed source accepted")}
        catch {try check(error.localizedDescription.contains("源项目已改变"),"captured source schema mismatch is rejected before new publication")}
        try sourceBefore.write(to:a.appendingPathComponent("project.json"))
        model.select(folder:a);model.select(folder:b)
        try await wait{!model.isLoading}
        try await Task.sleep(for:.milliseconds(80))
        try check(model.context?.lease.folder==b && model.context?.inspection.layers.first?.name=="B","rapid A to B selection cannot publish stale A into B preview")
        context?.close();context=nil
        try await wait{!fm.fileExists(atPath:temp.path)}
        try check(!fm.fileExists(atPath:temp.path),"finished old selection releases temporary overrides")
        model.select(folder:root.appendingPathComponent("missing"))
        try await wait{!model.isLoading}
        try check(model.context==nil && model.error != nil,"invalid new folder clears old picture and exposes error")
        let scripted = try fixture("Scripted")
        let sceneURL = scripted.appendingPathComponent("scene.json")
        var scene = try JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as! [String: Any]
        var objects = scene["objects"] as! [[String: Any]]
        objects[0]["alpha"] = ["value": 1, "script": "export function update(value) { return value; }"]
        scene["objects"] = objects
        try json(scene).write(to: sceneURL)
        model.select(folder: scripted)
        try await wait { !model.isLoading }
        guard let scriptedContext = model.context else { throw SceneWallpaperFailure(message: model.error ?? "Script inspection missing") }
        try check(scriptedContext.inspection.isRenderableSubset && scriptedContext.inspection.scriptProgram != nil,
                  "real parser retains scripted project for explicit runtime-required UI")
        try check(scriptedContext.editableKeys.isEmpty, "static tool cannot advertise script project author controls")
        do {
            try await scriptedContext.apply([:])
            throw SceneWallpaperFailure(message: "Static tool falsely acknowledged script execution")
        } catch {
            try check(error.localizedDescription.contains("需要运行脚本"), "even empty static callback cannot falsely ACK a scripted project")
        }
        model.close()
        model.select(folder:a)
        try check(model.context==nil && !model.isLoading,"closed model cannot restart a preview")
        var lease:SceneInspectionLease?=try SceneInspectionLease(folder:b)
        let heldTemp=lease!.temporaryDirectory
        let worker=Task.detached { [held=lease!] in try? await Task.sleep(for:.milliseconds(120));return held.folder.lastPathComponent }
        lease=nil
        try check(fm.fileExists(atPath:heldTemp.path),"worker retains selection lease after owning view releases it")
        _ = await worker.value
        try await wait{!fm.fileExists(atPath:heldTemp.path)}
        try check(!fm.fileExists(atPath:heldTemp.path),"scope cleanup waits until real worker completion")
        let report:[String:Any]=["success":true,"checkCount":checks.count,"checks":checks,"scope":"CLI/offscreen model and actual CoreGraphics pixels; native folder chooser/glass/NSView CUA checks delegated to parent","productionLibraryDesktopLockScreenTouched":false]
        let output=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count>1 {try output.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
        print(String(decoding:output,as:UTF8.self))
    }
}
