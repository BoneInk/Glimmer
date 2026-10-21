import AppKit
import Foundation
import CryptoKit

private actor RenderGate {
    private var suspended: [CheckedContinuation<Void, Never>] = []
    private var reached = 0
    func enter() async { reached += 1; await withCheckedContinuation { suspended.append($0) } }
    func didReach(_ count: Int) -> Bool { reached >= count }
    func release() { let all = suspended; suspended.removeAll(); all.forEach { $0.resume() } }
}

@main @MainActor struct SceneRuntimeServicesProbe {
    static var checks = [[String:Any]]()
    static func check(_ condition: Bool, _ name: String) throws {
        checks.append(["name":name,"passed":condition])
        guard condition else { throw SceneWallpaperFailure(message:"FAILED: " + name) }
    }
    static func rejects(_ name: String, _ body: () async throws -> Void) async throws {
        var failed = false
        do { try await body() } catch { failed = true }
        try check(failed,name)
    }
    static func payload(_ value:[String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:.sortedKeys) }
    static func hash(_ image:CGImage?) -> String {
        guard let image, let data=image.dataProvider?.data else {return "missing"}
        return SHA256.hash(data:data as Data).map{String(format:"%02x",$0)}.joined()
    }
    private static func waitGate(_ gate:RenderGate, count:Int = 1) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !gate.didReach(count) {
            guard ContinuousClock.now < deadline else {throw SceneWallpaperFailure(message:"Controlled gate never reached")}
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    static func run(fixture:URL,root:URL) async throws {
        let projectRoot=root.appendingPathComponent("project")
        try FileManager.default.copyItem(at:fixture,to:projectRoot)
        let projectURL=projectRoot.appendingPathComponent("project.json")
        let project=try AuthorPropertyProject.load(projectURL:projectURL,allowedRoot:projectRoot)
        let payloadProjectA=Data(#"{"type":"scene","general":{"properties":{"beta":{"type":"bool","value":true,"meta":{"first":1,"list":[2,1],"nested":{"z":"last","a":null},"nullValue":null,"text":"kept"}},"alpha":{"type":"bool","value":false}}}}"#.utf8)
        let payloadProjectB=Data(#"{"type":"scene","general":{"properties":{"alpha":{"value":false,"type":"bool"},"beta":{"meta":{"text":"kept","nullValue":null,"nested":{"a":null,"z":"last"},"list":[2,1],"first":1},"value":true,"type":"bool"}}}}"#.utf8)
        let payloadProjectC=Data(#"{"type":"scene","general":{"properties":{"beta":{"type":"bool","value":true,"meta":{"first":1,"list":[1,2],"nested":{"z":"last","a":null},"nullValue":null,"text":"kept"}},"alpha":{"type":"bool","value":false}}}}"#.utf8)
        let parsedPayloadProjectA=try AuthorPropertyProject.parse(data:payloadProjectA,projectURL:projectURL)
        let parsedPayloadProjectB=try AuthorPropertyProject.parse(data:payloadProjectB,projectURL:projectURL)
        let parsedPayloadProjectC=try AuthorPropertyProject.parse(data:payloadProjectC,projectURL:projectURL)
        let payloadValuesA:[String:GWJSONValue]=["beta":.bool(false),"alpha":.bool(true)]
        let payloadValuesB:[String:GWJSONValue]=["alpha":.bool(true),"beta":.bool(false)]
        let encodedPayloadA=try AuthorPropertyServices.payload(project:parsedPayloadProjectA,values:payloadValuesA)
        var repeatedPayloadsIdentical=true
        for _ in 0..<50 {
            guard try AuthorPropertyServices.payload(project:parsedPayloadProjectA,values:payloadValuesB)==encodedPayloadA else {
                repeatedPayloadsIdentical=false;break
            }
        }
        let encodedPayloadB=try AuthorPropertyServices.payload(project:parsedPayloadProjectB,values:payloadValuesA)
        let encodedPayloadC=try AuthorPropertyServices.payload(project:parsedPayloadProjectC,values:payloadValuesA)
        let changedPayload=try AuthorPropertyServices.payload(project:parsedPayloadProjectA,
            values:["beta":.bool(true),"alpha":.bool(true)])
        let payloadObject=try JSONSerialization.jsonObject(with:encodedPayloadA) as? [String:Any] ?? [:]
        let betaObject=payloadObject["beta"] as? [String:Any] ?? [:]
        let metadata=betaObject["meta"] as? [String:Any] ?? [:]
        let metadataList=(metadata["list"] as? [NSNumber])?.map(\.intValue) ?? []
        try check(repeatedPayloadsIdentical && encodedPayloadA==encodedPayloadB,
            "Production author payload emits identical bytes for unchanged params and nested insertion order")
        try check((betaObject["value"] as? Bool)==false && metadataList==[2,1]
            && metadata["nullValue"] is NSNull && metadata["text"] as? String=="kept",
            "Production author payload preserves value types, unknown nested values, and array order")
        try check(changedPayload != encodedPayloadA && encodedPayloadC != encodedPayloadA,
            "Production author payload preserves changed values and changed array order")
        let runtime=try SceneWallpaperRuntime(projectURL:projectURL)
        defer {runtime.dispose()}
        try check(runtime.state == .idle && runtime.posterImage == nil && runtime.inspection == nil,"Init validates config without full inspection or pixel publication")
        runtime.hostView.frame=NSRect(x:0,y:0,width:320,height:200)
        try await runtime.load(propertiesJSON:payload([:]))
        try check(runtime.state == .ready && runtime.inspection?.isRenderableSubset == true && runtime.posterImage != nil,"Load ACK follows actual off-main inspection and real renderer image publication")
        try check(runtime.editablePropertyKeys == ["showgeometry","geometryopacity","geometrycolor"],"Only real bool/color/opacity bindings editable; unbound author description stays read-only")
        let initial=hash(runtime.posterImage)
        let bitmap=runtime.hostView.bitmapImageRepForCachingDisplay(in:runtime.hostView.bounds)!
        runtime.hostView.cacheDisplay(in:runtime.hostView.bounds,to:bitmap)
        let center=bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)!.usingColorSpace(.sRGB)!
        try check(center.redComponent > 0.8 && center.greenComponent > 0.2,"Actual NSView host draws published orange geometry pixels")
        runtime.hostView.frame=NSRect(x:0,y:0,width:320,height:320)
        let fitBitmap=runtime.hostView.bitmapImageRepForCachingDisplay(in:runtime.hostView.bounds)!
        runtime.hostView.cacheDisplay(in:runtime.hostView.bounds,to:fitBitmap)
        let fitEdge=fitBitmap.colorAt(x:fitBitmap.pixelsWide/2,y:2)!.usingColorSpace(.sRGB)!
        runtime.setAspectFill(true)
        let fillBitmap=runtime.hostView.bitmapImageRepForCachingDisplay(in:runtime.hostView.bounds)!
        runtime.hostView.cacheDisplay(in:runtime.hostView.bounds,to:fillBitmap)
        let fillEdge=fillBitmap.colorAt(x:fillBitmap.pixelsWide/2,y:2)!.usingColorSpace(.sRGB)!
        try check(fitEdge.redComponent+fitEdge.greenComponent+fitEdge.blueComponent < 0.01 && fillEdge.redComponent+fillEdge.greenComponent+fillEdge.blueComponent > 0.1,"setAspectFill redraws real host cached pixels from letterbox fit to edge-filled crop")
        try check(hash(runtime.posterImage) == initial && runtime.state == .ready,"Fit/fill changes never re-inspect or replace acknowledged poster pixels")
        runtime.setAspectFill(false)
        runtime.hostView.frame=NSRect(x:0,y:0,width:320,height:200)
        let services=AuthorPropertyServices()
        let storage=AppStorage(root:root.appendingPathComponent("library")),itemID=UUID(),otherID=UUID()
        let second=try SceneWallpaperRuntime(projectURL:projectURL),other=try SceneWallpaperRuntime(projectURL:projectURL)
        defer {second.dispose();other.dispose()}
        try await second.load(propertiesJSON:payload([:]));try await other.load(propertiesJSON:payload([:]))
        var callbacks=0
        let firstToken=services.registerScene(runtime,itemID:itemID,onConfigurationChange:{callbacks+=1})
        let secondToken=services.registerScene(second,itemID:itemID)
        let otherToken=services.registerScene(other,itemID:otherID)
        defer {services.unregisterScene(itemID:itemID,token:firstToken);services.unregisterScene(itemID:itemID,token:secondToken);services.unregisterScene(itemID:otherID,token:otherToken)}
        try check(services.readySceneHosts(itemID:itemID).count == 2 && services.editableKeys(project:project,itemID:itemID) == runtime.editablePropertyKeys,"Services exposes shared real Scene host capabilities")
        try await services.store(storage:storage).set(.string("0.1 1 1"),for:"geometrycolor",itemID:itemID,project:project)
        try await services.applySavedSettings(project:project,itemID:itemID,storage:storage)
        try check(hash(runtime.posterImage) != initial && hash(runtime.posterImage) == hash(second.posterImage) && callbacks == 1,"Saved author value actually updates both matching host pixels before Services ACK")
        try check(hash(other.posterImage) == initial,"Changing one item never changes a different item sharing its project")
        runtime.setPaused(true)
        try await runtime.applyPropertiesAndWait(payload(["geometryopacity":0.25]))
        try check(runtime.state == .paused && runtime.posterImage != nil,"Static paused host accepts new settings and preserves pause intent without timers")
        let previous=hash(runtime.posterImage)
        try await rejects("Bad property value fails ACK") { try await runtime.applyPropertiesAndWait(payload(["geometryopacity":"wrong"])) }
        try check(runtime.state == .failed && runtime.lastError != nil && hash(runtime.posterImage) == previous,"Failed settings retain old image while reporting failed rather than ready")
        try check(services.editableKeys(project:project,itemID:itemID).contains("geometryopacity"),"Failed Scene host retains observed capability for repair")
        try await services.applySavedSettings(project:project,itemID:itemID,storage:storage)
        try check(runtime.state == .paused && runtime.lastError == nil && hash(runtime.posterImage) == hash(second.posterImage),"Services retries failed Scene host and returns only after repaired pixels")
        runtime.setPaused(false)
        try await rejects("Unknown payload keys cannot silently claim Scene application") {try await runtime.applyPropertiesAndWait(payload(["notAProperty":true]))}
        try await runtime.applyPropertiesAndWait(payload([:]))
        let failedFirst=try SceneWallpaperRuntime(projectURL:projectURL)
        defer {failedFirst.dispose()}
        try await rejects("First load with schema-invalid override fails") {try await failedFirst.load(propertiesJSON:payload(["geometryopacity":9]))}
        try check(failedFirst.state == .failed && failedFirst.posterImage == nil && failedFirst.editablePropertyKeys.contains("geometryopacity"),"Real default bindings remain editable after first-load override failure")
        let failedToken=services.registerScene(failedFirst,itemID:itemID)
        try await services.applySavedSettings(project:project,itemID:itemID,storage:storage)
        try check(failedFirst.state == .ready && failedFirst.posterImage != nil,"First failed host repairs from saved settings through Services")
        services.unregisterScene(itemID:itemID,token:failedToken)
        // Deterministic in-flight cancellation: only the barrier is controlled;
        // the inspection/render after its release remains the real implementation.
        let gate=RenderGate(),closing=try SceneWallpaperRuntime(projectURL:projectURL,inspectionBarrier:{await gate.enter()})
        let pending=Task {try await closing.load(propertiesJSON:payload([:]))}
        try await waitGate(gate)
        closing.dispose();await gate.release()
        try await rejects("Disposed in-flight host refuses late success") {_ = try await pending.value}
        try check(closing.state == .disposed && closing.posterImage == nil && closing.inspection == nil,"Dispose cancellation/generation guard prevents orphan image publication")
        let cancelGate=RenderGate(),cancelled=try SceneWallpaperRuntime(projectURL:projectURL,inspectionBarrier:{await cancelGate.enter()})
        defer {cancelled.dispose()}
        let cancelledLoad=Task {try await cancelled.load(propertiesJSON:payload([:]))}
        try await waitGate(cancelGate);cancelledLoad.cancel();await cancelGate.release()
        try await rejects("Caller cancellation propagates to actual preparation task") {_ = try await cancelledLoad.value}
        try check(cancelled.state == .idle && cancelled.posterImage == nil,"Cancelled initial render cannot become ready")
        // Latest-request protection with a first request held before real inspection.
        let latestGate=RenderGate()
        let latest=try SceneWallpaperRuntime(projectURL:projectURL,inspectionBarrier:{await latestGate.enter()})
        defer {latest.dispose()}
        let first=Task {try await latest.load(propertiesJSON:payload(["showgeometry":false]))}
        try await waitGate(latestGate)
        let newer=Task {try await latest.applyPropertiesAndWait(payload(["geometrycolor":"0.1 1 1"]))}
        try await waitGate(latestGate,count:2)
        await latestGate.release()
        _ = try await newer.value
        try await rejects("Superseded request returns cancellation after gate release") {_ = try await first.value}
        try check(latest.state == .ready && hash(latest.posterImage) != initial,"Newer settings publish actual pixels without older request overwriting them")
        let typedRoot=root.appendingPathComponent("typed-project")
        try FileManager.default.copyItem(at:fixture,to:typedRoot)
        let typedURL=typedRoot.appendingPathComponent("project.json"),sceneURL=typedRoot.appendingPathComponent("scene.json")
        var projectJSON=try JSONSerialization.jsonObject(with:Data(contentsOf:typedURL)) as! [String:Any]
        var general=projectJSON["general"] as! [String:Any],definitions=general["properties"] as! [String:Any]
        definitions["position"]=["type":"textinput","value":"480 300 0"]
        definitions["rotation"]=["type":"combo","value":"0 0 15","options":[["label":"15°","value":"0 0 15"],["label":"45°","value":"0 0 45"]]]
        definitions["vectorscale"]=["type":"textinput","value":"1 1 1"]
        definitions["vectorsize"]=["type":"textinput","value":"300 300"]
        general["properties"]=definitions;projectJSON["general"]=general
        try payload(projectJSON).write(to:typedURL)
        var scene=try JSONSerialization.jsonObject(with:Data(contentsOf:sceneURL)) as! [String:Any]
        var objects=scene["objects"] as! [[String:Any]]
        for (target,key,value) in [("origin","position","480 300 0"),("angles","rotation","0 0 15"),("scale","vectorscale","1 1 1"),("size","vectorsize","300 300")] {
            objects[1][target]=["user":key,"value":value]
        }
        scene["objects"]=objects;try payload(scene).write(to:sceneURL)
        let typed=try SceneWallpaperRuntime(projectURL:typedURL)
        defer {typed.dispose()}
        try await typed.load(propertiesJSON:payload([:]))
        try check(Set(["position","rotation","vectorscale","vectorsize"]).isSubset(of:typed.editablePropertyKeys),"Only actual typed direct transform/vector/combo bindings become editable")
        let typedBefore=hash(typed.posterImage)
        try await typed.applyPropertiesAndWait(payload(["position":"560 300 0","rotation":"0 0 45","vectorscale":"0.5 1 1","vectorsize":"240 240"]))
        try check(hash(typed.posterImage) != typedBefore && typed.inspection?.layers[1].origin.x == 560 && typed.inspection?.layers[1].anglesDegrees.z == 45,"Direct transform properties alter inspected geometry and actual pixels")
        try await rejects("Transform override entering unsupported 3D fails rather than approximating") {try await typed.applyPropertiesAndWait(payload(["position":"480 300 5"]))}
        try check(typed.state == .failed && typed.editablePropertyKeys.contains("position"),"Unsupported transform failure stays repairable")
        try await typed.applyPropertiesAndWait(payload([:]))
        definitions["showgeometry"]=["type":"unknown-future-toggle","value":true]
        definitions["geometrycolor"]=["type":"color","value":"1 0.45 0.12","condition":"unsupported(foo)"]
        general["properties"]=definitions;projectJSON["general"]=general;try payload(projectJSON).write(to:typedURL)
        let readonly=try SceneWallpaperRuntime(projectURL:typedURL)
        defer {readonly.dispose()}
        try await readonly.load(propertiesJSON:payload([:]))
        try check(readonly.state == .ready && !readonly.editablePropertyKeys.contains("showgeometry") && !readonly.editablePropertyKeys.contains("geometrycolor"),"Unknown author types and unsupported conditions keep static default rendering but remain read-only")
        try await rejects("Unknown type cannot accept an override that claims Scene application") {try await readonly.applyPropertiesAndWait(payload(["showgeometry":false]))}
        try await rejects("Unsupported-condition binding cannot apply a saved changed value") {try await readonly.applyPropertiesAndWait(payload(["geometrycolor":"0 1 1"]))}
        let sceneItem=WallpaperItem(title:"Isolated Scene payload",filePath:projectURL.path,contentKind:.scene)
        let scenePayload=try await AuthorPropertyServices.payload(item:sceneItem,storage:storage)
        let payloadHost=try SceneWallpaperRuntime(projectURL:projectURL)
        defer {payloadHost.dispose()}
        try await payloadHost.load(propertiesJSON:scenePayload)
        try check(payloadHost.state == .ready && hash(payloadHost.posterImage) == initial,"Static payload(item:) uses Scene project.json defaults and real bound type validation")
        let noHost=AuthorPropertyServices()
        try await rejects("Saved Scene settings without a live host cannot report applied") {try await noHost.applySavedSettings(project:project,itemID:UUID(),storage:storage)}
        // Removal success owns disposal and tombstones; failed commit keeps hosts alive.
        let removalID=UUID(),removalHost=try SceneWallpaperRuntime(projectURL:projectURL)
        try await removalHost.load(propertiesJSON:payload([:]))
        let removalToken=services.registerScene(removalHost,itemID:removalID)
        try await rejects("Failed removal does not dispose or tombstone Scene host") {
            try await services.withItemRemoval(itemIDs:[removalID],storage:storage) {throw SceneWallpaperFailure(message:"controlled commit failure")}
        }
        try check(removalHost.state == .ready && services.readySceneHosts(itemID:removalID).count == 1,"Failed removal leaves existing real host usable")
        try await services.withItemRemoval(itemIDs:[removalID],storage:storage) { () }
        try check(removalHost.state == .disposed && services.readySceneHosts(itemID:removalID).isEmpty,"Committed item removal disposes matching Scene hosts before returning")
        let late=try SceneWallpaperRuntime(projectURL:projectURL)
        _=services.registerScene(late,itemID:removalID)
        try check(late.state == .disposed,"Late Scene registration cannot resurrect deleted item")
        services.unregisterScene(itemID:removalID,token:removalToken)
        try await rejects("Deleted item cannot recreate author overrides via Services") {try await services.applySavedSettings(project:project,itemID:removalID,storage:storage)}
        services.unregisterScene(itemID:itemID,token:firstToken)
        try check(services.readySceneHosts(itemID:itemID).count == 1 && runtime.state != .disposed,"Unregister removes host token without stopping independently owned runtime")
    }
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        Task {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("gw-scene-host-services-\(UUID().uuidString)")
            do {try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try await run(fixture:URL(fileURLWithPath:CommandLine.arguments[1]),root:root)}
            catch {checks.append(["name":"uncaught: " + error.localizedDescription,"passed":false])}
            try? FileManager.default.removeItem(at:root)
            let failures=checks.filter{$0["passed"] as? Bool == false}.count
            let report:[String:Any]=["checks":checks,"passed":checks.count-failures,"failed":failures,"method":"Actual Scene Inspector+Renderer+NSView pixels, temporary override store, multiple live hosts and controlled preparation barriers; no production data, desktop, lockscreen or network"]
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(decoding:data,as:UTF8.self))}
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
