import AppKit
import Foundation
import CryptoKit

@main @MainActor struct SceneScriptRuntimeProbe {
    static var checks = [[String:Any]]()
    static func check(_ value:Bool,_ name:String) throws {
        checks.append(["name":name,"passed":value])
        guard value else {throw SceneWallpaperFailure(message:"FAILED: " + name)}
    }
    static func wait(_ name:String,seconds:Double = 5,_ condition:() -> Bool) async throws {
        let deadline=ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else {throw SceneWallpaperFailure(message:"Timeout: " + name)}
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    static func rejects(_ name:String,_ body:() async throws -> Void) async throws {
        var failed=false;do {try await body()} catch {failed=true};try check(failed,name)
    }
    static func payload(_ values:[String:Any]) throws -> Data {try JSONSerialization.data(withJSONObject:values,options:.sortedKeys)}
    static func hash(_ image:CGImage?) -> String {
        guard let data=image?.dataProvider?.data else {return "missing"}
        return SHA256.hash(data:data as Data).map {String(format:"%02x",$0)}.joined()
    }
    static let script = """
    let gain=1;
    export function init(value){ return value; }
    export function applyUserProperties(properties){
      if(properties.note==='explode') throw new Error('controlled authored callback failure');
      if(properties.geometrycolor!==undefined) thisLayer.color=properties.geometrycolor.copy();
      if(properties.caption!==undefined && typeof properties.caption!=='string') throw new Error('text became a vector');
      if(properties.gain!==undefined) gain=properties.gain;
    }
    export function update(value){
      thisLayer.origin=new Vec3(480+30*Math.sin(engine.runtime*4),300,0);
      return gain*(0.6+0.4*Math.sin(engine.runtime*5));
    }
    """
    static func fixture(_ source:URL,at root:URL,script:String?,mapping:Bool=false) throws -> URL {
        try FileManager.default.copyItem(at:source,to:root)
        let projectURL=root.appendingPathComponent("project.json"),sceneURL=root.appendingPathComponent("scene.json")
        var project=try JSONSerialization.jsonObject(with:Data(contentsOf:projectURL)) as! [String:Any]
        var general=project["general"] as! [String:Any],properties=general["properties"] as! [String:Any]
        properties["gain"]=["type":"slider","value":1,"min":0,"max":1,"fraction":true,"step":0.05]
        properties["note"]=["type":"textinput","value":"OK"]
        properties["caption"]=["type":"textinput","value":"1 2 3"]
        general["properties"]=properties;project["general"]=general;try payload(project).write(to:projectURL)
        if let script {
            var scene=try JSONSerialization.jsonObject(with:Data(contentsOf:sceneURL)) as! [String:Any]
            var objects=scene["objects"] as! [[String:Any]]
            var wrapper:[String:Any]=["value":1,"script":script]
            if mapping {wrapper["scriptproperties"]=["gain":["user":"gain","value":1]]}
            objects[1]["alpha"]=wrapper
            scene["objects"]=objects;try payload(scene).write(to:sceneURL)
        }
        return projectURL
    }
    static func run(source:URL,root:URL,worker:URL) async throws {
        let identity = SceneCursorMapper.worldPosition(
            hostPoint:.init(x:210,y:220),hostBounds:.init(x:10,y:20,width:400,height:400),
            imageSize:.init(width:400,height:200),aspectFill:false,
            canvasSize:.init(x:200,y:100),camera:.identity)
        try check(identity == .init(x:100,y:50,z:0),"Cursor mapper removes actual host aspect-fit viewport and preserves nonzero content origin")
        let letterbox = SceneCursorMapper.worldPosition(
            hostPoint:.init(x:210,y:50),hostBounds:.init(x:10,y:20,width:400,height:400),
            imageSize:.init(width:400,height:200),aspectFill:false,
            canvasSize:.init(x:200,y:100),camera:.identity)
        try check(letterbox == nil,"Cursor mapper reports no world position in host letterbox")
        let camera=SceneCamera2D(center:.init(x:10,y:-20,z:-1),eye:.init(x:10,y:-20,z:0),
            up:.init(x:-1,y:0,z:0),zoom:2,nearZ:0.01,farZ:10_000,cameraFade:false)
        let transformed = SceneCursorMapper.worldPosition(
            hostPoint:.init(x:20,y:10),hostBounds:.init(x:0,y:0,width:200,height:100),
            imageSize:.init(width:200,height:100),aspectFill:false,
            canvasSize:.init(x:200,y:100),camera:camera)
        try check(transformed.map { abs($0.x-5)<1e-9 && abs($0.y+10)<1e-9 && $0.z==0 } == true,
                  "Cursor mapper applies inverse translated, rolled and zoomed camera transform")
        let fill = SceneCursorMapper.worldPosition(
            hostPoint:.init(x:0,y:200),hostBounds:.init(x:0,y:0,width:400,height:400),
            imageSize:.init(width:400,height:200),aspectFill:true,
            canvasSize:.init(x:200,y:100),camera:.identity)
        try check(fill == .init(x:50,y:50,z:0),"Cursor mapper accounts for aspect-fill crop before inverse camera")
        let staticURL=try fixture(source,at:root.appendingPathComponent("static"),script:nil)
        let still=try SceneWallpaperRuntime(projectURL:staticURL,workerExecutableURL:root.appendingPathComponent("does-not-exist"))
        defer {still.dispose()}
        try await still.load(propertiesJSON:payload([:]))
        let stillCount=still.frameCount
        try await Task.sleep(for:.milliseconds(150))
        try check(still.state == .ready && !still.isAnimated && still.frameCount == stillCount && still.activeRuntime == 0,"Static Scene never starts a helper or timer, even with invalid helper URL")
        try check(still.inspection?.textures.values.allSatisfy{$0.format == .rgba8888} == true,"Load predecodes ImageIO textures into bounded cached RGBA exactly once")
        let uncached=try SceneWallpaperInspector.inspect(projectURL:staticURL)
        let reference=try SceneWallpaperRenderer.render(inspection:uncached,pixelSize:CGSize(width:960,height:600))
        let referenceBytes=Array(reference.dataProvider!.data! as Data),cachedBytes=Array(still.posterImage!.dataProvider!.data! as Data)
        let error=zip(referenceBytes,cachedBytes).map {abs(Int($0)-Int($1))}.max() ?? 0
        try check(referenceBytes.count == cachedBytes.count && error <= 3,"RGBA texture cache preserves actual asymmetric source orientation, alpha and sRGB pixels within rounding tolerance")
        let url=try fixture(source,at:root.appendingPathComponent("animated"),script:script)
        let runtime=try SceneWallpaperRuntime(projectURL:url,workerExecutableURL:worker)
        defer {runtime.dispose()}
        try await runtime.load(propertiesJSON:payload([:]))
        try check(runtime.state == .ready && runtime.isAnimated && runtime.frameCount == 1,"Real isolated helper configure/init/callback produces first acknowledged image before scheduling")
        let firstHash=hash(runtime.posterImage)
        try await wait("dynamic actual frames") {runtime.frameCount >= 5}
        try check(hash(runtime.posterImage) != firstHash && runtime.activeRuntime > 0 && runtime.inspection!.layers[1].origin.x != 480,"Real update/engine.runtime/thisLayer changes actual rendered pixels")
        let beforeCount=runtime.frameCount,measuredStart=ContinuousClock.now
        try await Task.sleep(for:.milliseconds(300))
        let interval=measuredStart.duration(to:ContinuousClock.now)
        let seconds=Double(interval.components.seconds)+Double(interval.components.attoseconds)/1e18
        try check(Double(runtime.frameCount-beforeCount) <= seconds*30+2,"Frame driver stays bounded at 30fps with no queued timer burst")
        try runtime.setFrameRateLimit(15)
        let slowCount=runtime.frameCount,slowRuntime=runtime.activeRuntime,slowStart=ContinuousClock.now
        try await Task.sleep(for:.milliseconds(700))
        let slowDuration=slowStart.duration(to:ContinuousClock.now)
        let slowWall=Double(slowDuration.components.attoseconds)/1e18+Double(slowDuration.components.seconds)
        let capped15Frames=runtime.frameCount-slowCount,slowElapsed=runtime.activeRuntime-slowRuntime
        try check(capped15Frames >= 6 && Double(capped15Frames) <= slowWall*15+2,
                  "Live 15fps cap measures a bounded single Scene loop (\(capped15Frames) frames in \(slowWall)s)")
        try check(abs(slowElapsed-slowWall)<0.18,"Scene engine runtime follows real elapsed time at 15fps")
        try runtime.setFrameRateLimit(60)
        let fastCount=runtime.frameCount,fastRuntime=runtime.activeRuntime,fastStart=ContinuousClock.now
        try await Task.sleep(for:.milliseconds(700))
        let fastDuration=fastStart.duration(to:ContinuousClock.now)
        let fastWall=Double(fastDuration.components.seconds)+Double(fastDuration.components.attoseconds)/1e18
        let fastFrames=runtime.frameCount-fastCount,fastElapsed=runtime.activeRuntime-fastRuntime
        try check(fastFrames > capped15Frames && Double(fastFrames) <= fastWall*60+2,
                  "Live 60fps cap replaces the prior loop without a timer burst (\(fastFrames) frames)")
        try check(abs(fastElapsed-fastWall)<0.18,"Scene engine runtime remains wall-clock based at 60fps")
        var rejectedInvalidFPS=false
        do { try runtime.setFrameRateLimit(0) }
        catch is SceneWallpaperFailure { rejectedInvalidFPS=true }
        try check(rejectedInvalidFPS,"Scene runtime rejects FPS outside 1...240")
        runtime.setPaused(true)
        let pausedCount=runtime.frameCount,pausedTime=runtime.activeRuntime,pausedHash=hash(runtime.posterImage),pausedInput=runtime.lastFrameInput
        try await Task.sleep(for:.milliseconds(350))
        try check(runtime.state == .paused && runtime.isAnimated && runtime.frameCount == pausedCount && runtime.activeRuntime == pausedTime && hash(runtime.posterImage) == pausedHash && runtime.lastFrameInput == pausedInput,"Pause stops native cursor polling and keeps input/runtime/time/pixels fixed")
        runtime.setPaused(false)
        try await wait("resume") {runtime.frameCount > pausedCount}
        try check(runtime.activeRuntime-pausedTime < 0.2,"Resume excludes paused wall time instead of accumulating catchup")
        if ProcessInfo.processInfo.environment["GW_SCENE_FPS_ONLY"] == "1" { return }
        let project=try AuthorPropertyProject.load(projectURL:url,allowedRoot:url.deletingLastPathComponent())
        let services=AuthorPropertyServices(),storage=AppStorage(root:root.appendingPathComponent("settings")),itemID=UUID()
        let second=try SceneWallpaperRuntime(projectURL:url,workerExecutableURL:worker)
        defer {second.dispose()}
        try await second.load(propertiesJSON:payload([:]))
        let firstToken=services.registerScene(runtime,itemID:itemID),secondToken=services.registerScene(second,itemID:itemID)
        defer {services.unregisterScene(itemID:itemID,token:firstToken);services.unregisterScene(itemID:itemID,token:secondToken)}
        try check(services.editableKeys(project:project,itemID:itemID).contains("gain"),"Observed real SceneScript callback enables scalar author property")
        try await services.store(storage:storage).set(.number(0),for:"gain",itemID:itemID,project:project)
        try await services.applySavedSettings(project:project,itemID:itemID,storage:storage)
        try check(runtime.inspection!.layers[1].opacity == 0 && second.inspection!.layers[1].opacity == 0 && hash(runtime.posterImage) == hash(second.posterImage),"Services waits for both real helper callback+render ACKs, not merely saved values")
        let acknowledged=hash(runtime.posterImage)
        try await Task.sleep(for:.milliseconds(120))
        try check(runtime.inspection!.layers[1].opacity == 0 && hash(runtime.posterImage) == acknowledged,"In-flight old frames cannot overwrite newly acknowledged author state")
        try await services.store(storage:storage).set(.number(1),for:"gain",itemID:itemID,project:project)
        try await services.store(storage:storage).set(.bool(false),for:"showgeometry",itemID:itemID,project:project)
        try await services.applySavedSettings(project:project,itemID:itemID,storage:storage)
        try check(!runtime.inspection!.layers[1].isVisible && !second.inspection!.layers[1].isVisible,"Hybrid direct user binding updates worker state and survives subsequent script frames")
        try await Task.sleep(for:.milliseconds(80))
        try check(!runtime.inspection!.layers[1].isVisible,"Script full-layer snapshots do not restore stale direct visibility")
        runtime.setPaused(true);second.setPaused(true)
        try await services.store(storage:storage).set(.bool(true),for:"showgeometry",itemID:itemID,project:project)
        try await services.applySavedSettings(project:project,itemID:itemID,storage:storage)
        try check(runtime.state == .paused && runtime.inspection!.layers[1].isVisible,"Paused script host applies author settings and publishes pixels without advancing animation")
        let unchangedTime=runtime.activeRuntime
        try await services.store(storage:storage).set(.string("explode"),for:"note",itemID:itemID,project:project)
        try await rejects("Authored callback error rejects Services ACK") {try await services.applySavedSettings(project:project,itemID:itemID,storage:storage)}
        try check(services.readySceneHosts(itemID:itemID).count < 2 && services.editableKeys(project:project,itemID:itemID).contains("note"),"Failed script host remains editable for an explicit correction")
        try await services.store(storage:storage).set(.string("OK"),for:"note",itemID:itemID,project:project)
        try await services.applySavedSettings(project:project,itemID:itemID,storage:storage)
        try check(runtime.state == .paused && runtime.posterImage != nil && runtime.activeRuntime <= unchangedTime,"Corrected saved property can configure a fresh helper and recover real pixels")
        // File removal is restricted to our own copied fixture. Dynamic step and
        // callback rendering must continue from cached layers/textures, not Inspector.
        for texture in runtime.inspection!.textures.values {
            try FileManager.default.removeItem(at:url.deletingLastPathComponent().appendingPathComponent(texture.path))
        }
        runtime.setPaused(false)
        let cacheCount=runtime.frameCount
        try await wait("cached frames after own source removal") {runtime.frameCount >= cacheCount+3 || runtime.state == .failed}
        try check(runtime.state == .ready && runtime.frameCount >= cacheCount+3,"Dynamic frames never reopen texture files or rerun Inspector")
        try await runtime.applyPropertiesAndWait(payload(["gain":0]))
        try check(runtime.inspection!.layers[1].opacity == 0,"Author updates render from the same cache without reopening removed own sources")
        let mappingURL=try fixture(source,at:root.appendingPathComponent("mapping"),script:"export var scriptProperties=createScriptProperties().addSlider({name:'gain',value:1,min:0,max:1}).finish(); export function update(value){ return scriptProperties.gain; }",mapping:true)
        let mapped=try SceneWallpaperRuntime(projectURL:mappingURL,workerExecutableURL:worker)
        defer {mapped.dispose()}
        try await mapped.load(propertiesJSON:payload([:]))
        try check(mapped.editablePropertyKeys.contains("gain") && !mapped.editablePropertyKeys.contains("note"),"Actual scriptProperties mapping enables only mapped keys when no callback exists")
        try await mapped.applyPropertiesAndWait(payload(["gain":0.25]))
        try await wait("mapped property frame") {abs(mapped.inspection!.layers[1].opacity-0.25)<0.001}
        try check(mapped.state == .ready,"Mapped user key updates the same live scriptProperties object without callback")
        let badURL=try fixture(source,at:root.appendingPathComponent("infinite"),script:"export function update(value){ if(engine.runtime>0){while(true){}} return value; }")
        let bad=try SceneWallpaperRuntime(projectURL:badURL,workerExecutableURL:worker)
        defer {bad.dispose()}
        try await bad.load(propertiesJSON:payload([:]))
        let goodPoster=hash(bad.posterImage)
        var heartbeat=0
        let pulse=Task {while !Task.isCancelled {heartbeat+=1;try? await Task.sleep(for:.milliseconds(10))}}
        try await wait("worker infinite-loop deadline",seconds:5) {bad.state == .failed}
        pulse.cancel()
        try check(heartbeat>5 && bad.lastError != nil && !bad.isAnimated && hash(bad.posterImage) == goodPoster,"Infinite JavaScript is isolated/time-bounded; app main actor stays responsive and last frame survives")
        let repairSource="let gain=1; export function applyUserProperties(p){if(p.gain!==undefined)gain=p.gain;} export function update(value){if(gain===0.25)throw new Error('repairable first-frame value');return gain;}"
        let repairURL=try fixture(source,at:root.appendingPathComponent("observed-first-failure"),script:repairSource)
        let repair=try SceneWallpaperRuntime(projectURL:repairURL,workerExecutableURL:worker)
        defer {repair.dispose()}
        try await rejects("Bad first-frame value fails after genuine callback capability was observed") {try await repair.load(propertiesJSON:payload(["gain":0.25]))}
        try check(repair.state == .failed && repair.editablePropertyKeys.contains("gain"),"Successful configure capability survives first-update failure so its actual author value remains repairable")
        let repairID=UUID(),repairProject=try AuthorPropertyProject.load(projectURL:repairURL,allowedRoot:repairURL.deletingLastPathComponent())
        let repairToken=services.registerScene(repair,itemID:repairID)
        defer {services.unregisterScene(itemID:repairID,token:repairToken)}
        try await services.store(storage:storage).set(.number(0.75),for:"gain",itemID:repairID,project:repairProject)
        try await services.applySavedSettings(project:repairProject,itemID:repairID,storage:storage)
        try check(repair.state == .ready && repair.inspection!.layers[1].opacity == 0.75,"First-frame script failure repairs through real Services configure/update/render ACK")
        let initMapSource="export var scriptProperties=createScriptProperties().addSlider({name:'gain',value:1,min:0,max:1}).finish(); export function init(value){return scriptProperties.gain;}"
        let initMapURL=try fixture(source,at:root.appendingPathComponent("init-only-mapping"),script:initMapSource,mapping:true)
        let initMap=try SceneWallpaperRuntime(projectURL:initMapURL,workerExecutableURL:worker)
        defer {initMap.dispose()}
        try await initMap.load(propertiesJSON:payload([:]))
        try check(initMap.state == .ready && !initMap.isAnimated && !initMap.editablePropertyKeys.contains("gain"),"Init-only mapped value remains read-only when no update or author callback can consume later changes")
        try await rejects("Init-only mapped edit cannot falsely ACK unchanged pixels") {try await initMap.applyPropertiesAndWait(payload(["gain":0.25]))}
        let serialSource="""
        let gain=1;
        export function applyUserProperties(p){
          if(p.gain!==undefined){
            if(p.gain===0.25){const until=Date.now()+150;while(Date.now()<until){}}
            gain=p.gain;
          }
        }
        export function update(value){return gain;}
        """
        let serialURL=try fixture(source,at:root.appendingPathComponent("queued"),script:serialSource)
        let queued=try SceneWallpaperRuntime(projectURL:serialURL,workerExecutableURL:worker)
        defer {queued.dispose()}
        queued.setPaused(true);try await queued.load(propertiesJSON:payload([:]))
        let queueStart=ContinuousClock.now
        let earlier=Task {try await queued.applyPropertiesAndWait(payload(["gain":0.25]))}
        try await wait("first authored mutation") {queued.state == .loading}
        try await Task.sleep(for:.milliseconds(30))
        let latest=Task {try await queued.applyPropertiesAndWait(payload(["gain":0.75]))}
        try await latest.value
        try await rejects("Latest author request supersedes older in-flight callback without concurrent RPC") {_ = try await earlier.value}
        let queueDuration=queueStart.duration(to:ContinuousClock.now)
        let queueSeconds=Double(queueDuration.components.seconds)+Double(queueDuration.components.attoseconds)/1e18
        try check(queueSeconds>=0.1 && queued.state == .paused && queued.inspection!.layers[1].opacity == 0.75 && queued.frameCount == 2,"Actual 150ms callback is serialized; only newest requested pixels publish and acknowledge")
        try check(queued.activeRuntime == 0,"Queued author callbacks/current-time frames never advance paused engine time")
        let beforeCancel=hash(queued.posterImage)
        let cancelled=Task {try await queued.applyPropertiesAndWait(payload(["gain":0.25]))}
        try await wait("cancellable authored mutation") {queued.state == .loading}
        try await Task.sleep(for:.milliseconds(30));cancelled.cancel()
        try await rejects("Caller cancellation interrupts real in-flight helper callback") {_ = try await cancelled.value}
        try check(queued.state == .failed && hash(queued.posterImage) == beforeCancel,"Cancelled callback does not become ready or publish partial/stale pixels")
        try await queued.applyPropertiesAndWait(payload(["gain":0.75]))
        try check(queued.state == .paused && queued.inspection!.layers[1].opacity == 0.75,"Cancelled worker can recover through explicit fresh configure and real pixel ACK")
        let closing=Task {try await queued.applyPropertiesAndWait(payload(["gain":0.25]))}
        try await wait("closing authored mutation") {queued.state == .loading}
        try await Task.sleep(for:.milliseconds(30));queued.dispose()
        try await rejects("Dispose rejects a real callback still executing in its process") {_ = try await closing.value}
        try await Task.sleep(for:.milliseconds(100))
        try check(queued.state == .disposed && queued.posterImage == nil,"Late helper callback cannot resurrect a closed runtime")
        let slowSource="export function update(value){const until=Date.now()+60;while(Date.now()<until){} return 0.5+0.25*Math.sin(engine.runtime); }"
        let slowURL=try fixture(source,at:root.appendingPathComponent("slow-frames"),script:slowSource)
        let slow=try SceneWallpaperRuntime(projectURL:slowURL,workerExecutableURL:worker)
        defer {slow.dispose()}
        try await slow.load(propertiesJSON:payload([:]))
        let slowFrames=slow.frameCount
        try await Task.sleep(for:.milliseconds(350))
        try check(slow.state == .ready && slow.frameCount>=slowFrames+2 && slow.frameCount<=slowFrames+6,"Real 60ms updates use one step/render in flight; slow frames do not create backlog or overlapping RPC failures")
        let invalidURL=try fixture(source,at:root.appendingPathComponent("invalid-first-frame"),script:"export function update(value){ while(true){} }")
        let invalid=try SceneWallpaperRuntime(projectURL:invalidURL,workerExecutableURL:worker)
        defer {invalid.dispose()}
        try await rejects("First update must finish before load can acknowledge a usable script host") {try await invalid.load(propertiesJSON:payload([:]))}
        try check(invalid.state == .failed && invalid.posterImage == nil && !invalid.isAnimated,"Infinite first frame never becomes ready or publishes unverified initial pixels")
        let stopped=runtime.frameCount
        runtime.dispose();try await Task.sleep(for:.milliseconds(150))
        try check(runtime.state == .disposed && runtime.posterImage == nil && runtime.frameCount == stopped,"Dispose cancels helper/frame work and rejects late pixel publication")
    }
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        Task {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("gw-scene-script-runtime-\(UUID().uuidString)")
            do {try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try await run(source:URL(fileURLWithPath:CommandLine.arguments[1]),root:root,worker:URL(fileURLWithPath:CommandLine.arguments[2]))}
            catch {checks.append(["name":"uncaught: " + error.localizedDescription,"passed":false])}
            try? FileManager.default.removeItem(at:root)
            let failed=checks.filter{$0["passed"] as? Bool == false}.count
            let report:[String:Any]=["checks":checks,"passed":checks.count-failed,"failed":failed,"method":"Actual isolated JavaScriptCore helper process, cached real texture/render pixels, native Services, temporary original fixtures only; no user library/account/desktop/lockscreen changes"]
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:CommandLine.arguments[3]));print(String(decoding:data,as:UTF8.self))}
            exit(failed == 0 ? 0 : 1)
        }
        app.run()
    }
}
