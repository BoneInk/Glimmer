import Foundation
import Darwin

@main @MainActor
struct SceneScriptWorkerProbe {
    static var checks = 0
    static var heartbeat = 0
    static var timings: [String: Double] = [:]
    static var lifecycleErrors: [String: String] = [:]
    static let worker = URL(fileURLWithPath: CommandLine.arguments[1])
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: "WorkerProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func layer(_ id: Int = 1, name: String = "first", text: String? = nil) -> SceneScriptLayerState {
        .init(id: id, name: name, origin: .init(x: 1,y: 2,z: 0), angles: .init(x: 0,y: 0,z: 0), scale: .init(x: 1,y: 1,z: 1), size: .init(x: 10,y: 20), color: .init(x: 1,y: 1,z: 1), alpha: 1, visible: true, text:text)
    }
    static func program(_ source: String, target: String = "alpha", layers: [SceneScriptLayerState]? = nil, properties: [String:GWJSONValue] = [:], mappings: [String:String] = [:], direct: [SceneScriptDirectBindingSpec] = []) -> SceneScriptProgram {
        .init(bindings: [.init(id: "test",layerID: 1,target: target,source: source,initialValue: .number(1),scriptProperties: properties,scriptPropertyBindings: mappings)], layers: layers ?? [layer()], directBindings: direct)
    }
    static func payload(_ text: String = "{}") -> Data { Data(text.utf8) }
    static func children() throws -> Set<Int32> {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo","pid=,ppid=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe; try p.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return Set(String(decoding: bytes,as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, let pid = Int32(fields[0]), Int32(fields[1]) == getpid(), fields.dropFirst(2).joined(separator: " ").hasSuffix("GlimmerSceneScriptWorker") else { return nil }
            return pid
        })
    }
    static func waitForChild() async throws -> Set<Int32> {
        for _ in 0..<100 { let found = try children(); if !found.isEmpty { return found }; try await Task.sleep(for: .milliseconds(10)) }
        throw NSError(domain:"WorkerProbe",code:2,userInfo:[NSLocalizedDescriptionKey:"No own worker child appeared"])
    }
    static func assertGone(_ ids: Set<Int32>) async throws {
        for _ in 0..<100 {
            if ids.isDisjoint(with: try children()) { try check(true,"own helper terminated"); return }
            try await Task.sleep(for:.milliseconds(10))
        }
        try check(false,"Own helper remained alive after termination: \(ids)")
    }
    static func rejected(_ name: String, _ p: SceneScriptProgram, stopsWorker: Bool = false) async throws {
        let client = SceneScriptWorkerClient(executableURL: worker)
        var failed = false
        do { _ = try await client.configure(program:p,userProperties:payload()) } catch { failed = true }
        if stopsWorker { try await assertGone(try children()) }
        await client.dispose(); try check(failed,name)
    }
    static func semanticRejected(_ name: String, _ p: SceneScriptProgram, reason: String) async throws {
        let client=SceneScriptWorkerClient(executableURL:worker)
        do {
            var message=""
            do { _ = try await client.configure(program:p,userProperties:payload()) }
            catch { message=error.localizedDescription }
            try check(message.localizedCaseInsensitiveContains(reason),name+" returns the expected semantic error, never timeout or disconnection")
            let ids=try await waitForChild()
            try check(ids.count==1,name+" retains exactly one own live helper after semantic rejection")
            var responded=false
            do { _ = try await client.step(runtime:0,frameTime:0); responded=true }
            catch { responded=error.localizedDescription.localizedCaseInsensitiveContains(reason) }
            try check(responded,name+" helper returns a subsequent correlated RPC response")
            try check(try children()==ids,name+" semantic errors do not implicitly replace or kill helper")
            await client.dispose();try await assertGone(ids)
        } catch { await client.dispose();throw error }
    }
    static func semantics() async throws {
        let font = SceneTextLayer(value:"old",fontData:Data([1,2,3]),pointSize:24,padding:.init(x:2,y:3),horizontalAlignment:"center",verticalAlignment:"center")
        let original = SceneImageLayer(id:1,name:"clock",modelPath:"m",materialPath:"p",texturePath:"",origin:.init(x:1,y:2,z:0),anglesDegrees:.init(x:0,y:0,z:0),scale:.init(x:1,y:1,z:1),size:.init(x:10,y:20),tint:.init(x:1,y:1,z:1),opacity:1,isVisible:true,bindings:[],colorKey:.init(color:.init(x:0,y:0,z:0),alpha:1,fuzziness:0.1,tolerance:0.2),parallaxDepth:.init(x:4,y:5),textLayer:font)
        let inspection = SceneWallpaperInspection(canvasSize:.init(x:100,y:100),clearColor:.init(x:0,y:0,z:0),layers:[original],textures:[:],diagnostics:[],parallax:.init(amount:1,delay:2,mouseInfluence:3))
        let scripted = try inspection.applyingScriptFrame(.init(layers:[.init(id:1,name:"clock",origin:original.origin,angles:original.anglesDegrees,scale:original.scale,size:original.size,color:original.tint,alpha:original.opacity,visible:true,text:"new")],hasUpdateHandlers:true,canApplyUserProperties:false))
        try check(scripted.layers[0].textLayer?.value == "new" && scripted.layers[0].textLayer?.fontData == font.fontData && scripted.layers[0].colorKey != nil && scripted.layers[0].parallaxDepth == original.parallaxDepth && scripted.parallax != nil,"script frame changes only text value while preserving verified font and render metadata")
        let client = SceneScriptWorkerClient(executableURL: worker)
        do {
            _ = try await client.configure(program:program("export function update(v){return .5;}"),userProperties:payload())
            try await Task.sleep(for:.milliseconds(650))
            let alive = try await client.step(runtime:1,frameTime:1.5)
            try check(alive.layers[0].alpha == 0.5,"live parent worker survives multiple owner watcher ticks")
            let ordinaryExports="""
            export default function defaultHelper(value){return value*.2;}
            export let ordinary=2;
            export function helper(value){return defaultHelper(value)+.1;}
            export function init(){return helper(ordinary);}
            """
            var exportsFrame=try await client.configure(program:program(ordinaryExports),userProperties:payload())
            try check(exportsFrame.layers[0].alpha == 0.5,"ordinary helper, let and named default exports are valid ESM")
            exportsFrame=try await client.configure(program:program("const amount=.3; export default amount; export function init(){return amount;}"),userProperties:payload())
            try check(exportsFrame.layers[0].alpha == 0.3,"default value export does not become an unsupported event")
            let ast = #"""
            const a = "export default import"; // export function nope() {} import x from 'bad'
            const r = /export\s+import/; const t = `import ${'export'}`;
            /* import('x'); export default */
            let count=0;
            function start(v) { if(a !== 'export default import' || !r.test('export import') || t !== 'import export') throw Error('literal changed'); count++; return 0.3; }
            function tick(v) { return count / 10; }
            export { start as init, tick as update };
            """#
            var f = try await client.configure(program:program(ast),userProperties:payload())
            try check(f.layers[0].alpha == 0.3 && f.hasUpdateHandlers,"AST export aliases and literals")
            f = try await client.step(runtime:1,frameTime:0.1); try check(f.layers[0].alpha == 0.1,"init called once")
            f = try await client.step(runtime:2,frameTime:0.1); try check(f.layers[0].alpha == 0.1,"step does not repeat init")
            f = try await client.configure(program:program("export function init(v){v.x=99;} export function update(v){}",target:"origin"),userProperties:payload())
            try check(f.layers[0].origin.x == 1,"undefined return preserves original vector")
            f = try await client.configure(program:program("export function init(v){thisLayer.alpha=.4;}",target:"alpha"),userProperties:payload())
            try check(f.layers[0].alpha == 0.4,"undefined preserves explicit layer write")
            f = try await client.configure(program:program("export function init(v){return new Vec3(.2).copy().add(.1).multiply(2).subtract(.1).divide(2);}",target:"color"),userProperties:payload())
            try check(abs(f.layers[0].color.x - 0.25) < 0.00001 && f.layers[0].color.x == f.layers[0].color.z,"Vec3 copy arithmetic numeric broadcast")
            f = try await client.configure(program:program("export function init(v){return new Vec2(4).copy().add(new Vec2(2,4)).multiply(2);}",target:"size"),userProperties:payload())
            try check(f.layers[0].size.x == 12 && f.layers[0].size.y == 16,"Vec2 copy arithmetic")
            f = try await client.configure(program:program("export function init(v){return .5;}",target:"color"),userProperties:payload())
            try check(f.layers[0].color.x == 0.5 && f.layers[0].color.z == 0.5,"scalar return broadcasts to Vec3 target")
            f = try await client.configure(program:program("export function init(v){return 4;}",target:"size"),userProperties:payload())
            try check(f.layers[0].size.x == 4 && f.layers[0].size.y == 4,"scalar return broadcasts to Vec2 target")
            f = try await client.configure(program:program("export function init(v){return '12:34';}",target:"text",layers:[layer(text:"00:00")]),userProperties:payload())
            try check(f.layers[0].text == "12:34","only an inspected text layer can return bounded dynamic text")
            let clockURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/SceneScriptClock/clock.js")
            let clockSource=try String(contentsOf:clockURL,encoding:.utf8)
            let authoredProperties=try JSONDecoder().decode([String:GWJSONValue].self,from:Data(contentsOf:clockURL.deletingLastPathComponent().appendingPathComponent("properties.json")))
            f = try await client.configure(program:program(clockSource,target:"text",layers:[layer(text:"00:00")],properties:authoredProperties),userProperties:payload())
            f = try await client.step(runtime:1,frameTime:0.1)
            let defaultClock=f.layers[0].text?.split(separator:":",omittingEmptySubsequences:false)
            try check(defaultClock?.count == 2 && defaultClock?.allSatisfy{$0.count==2 && Int($0) != nil} == true,"actual authored clock reads local Date with default 24-hour minutes and delimiter")
            f = try await client.configure(program:program(clockSource,target:"text",layers:[layer(text:"00:00")],properties:["use24hFormat":.bool(false),"showSeconds":.bool(true),"delimiter":.string("·")]),userProperties:payload())
            f = try await client.step(runtime:2,frameTime:0.1)
            let configuredClock=f.layers[0].text?.split(separator:"·",omittingEmptySubsequences:false)
            try check(configuredClock?.count == 3 && (Int(configuredClock![0]) ?? 0) >= 1 && (Int(configuredClock![0]) ?? 13) <= 12 && configuredClock?.allSatisfy{$0.count==2 && Int($0) != nil} == true,"actual authored clock honors 12-hour, seconds and delimiter script properties")
            f = try await client.configure(program:program("export function update(v){return engine.frametime / 2;}"),userProperties:payload())
            f = try await client.step(runtime:3,frameTime:1.5)
            try check(f.layers[0].alpha == 0.75,"slow frameTime 1.5 is valid")
            let seven = """
            export function init(v){ if(thisLayer !== thisObject) throw Error('alias'); let other=thisScene.getLayer('second'); if(other !== thisScene.getLayer(2)) throw Error('lookup'); thisLayer.origin=new Vec3(3,4,0); thisLayer.angles=new Vec3(0,0,30); thisLayer.scale=new Vec3(2,3,1); thisLayer.size=new Vec2(40,50); thisLayer.color=new Vec3(.2,.3,.4); thisLayer.alpha=.6; thisLayer.visible=false; other.alpha=.7; }
            """
            f = try await client.configure(program:program(seven,layers:[layer(),layer(2,name:"second")]),userProperties:payload())
            let s=f.layers[0]
            try check(s.origin.x == 3 && s.angles.z == 30 && s.scale.y == 3 && s.size.y == 50 && s.color.z == 0.4 && s.alpha == 0.6 && !s.visible && f.layers[1].alpha == 0.7,"seven layer fields and scene lookup")
            let callback = """
            let calls=0; export function applyUserProperties(p){ calls++; thisLayer.alpha=calls/10; thisLayer.origin=new Vec3(Object.keys(p).length,0,0); if(p.tint){thisLayer.color=p.tint.copy();} if(p.flag !== undefined && typeof p.flag !== 'boolean') throw Error('not raw'); if(p.gain !== undefined && (typeof p.gain !== 'number' || p.gain !== 2)) throw Error('not number'); }
            """
            let initial = payload(#"{"flag":{"value":true},"gain":{"value":2},"tint":{"type":"color","value":"0.1 0.2 0.3"}}"#)
            f = try await client.configure(program:program(callback),userProperties:initial)
            try check(f.canApplyUserProperties && f.layers[0].origin.x == 3 && f.layers[0].color.z == 0.3,"initial raw callbacks and color copy")
            f = try await client.applyUserProperties(payload(#"{"flag":{"value":false},"gain":{"value":2},"tint":{"type":"color","value":"0.1 0.2 0.3"}}"#),runtime:1)
            try check(f.layers[0].origin.x == 1 && f.layers[0].alpha == 0.2,"changed-only raw callback")
            f = try await client.applyUserProperties(payload(#"{"flag":{"value":false},"gain":{"value":2},"tint":{"type":"color","value":"0.1 0.2 0.3"}}"#),runtime:2)
            try check(f.layers[0].alpha == 0.2,"unchanged full snapshot skips callback")
            let props = """
            export var scriptProperties=createScriptProperties().addSlider({name:'gain',value:.1,min:0,max:1}).finish(); export function init(v){return scriptProperties.gain;} export function applyUserProperties(p){thisLayer.alpha=scriptProperties.gain;} export function update(v){thisLayer.alpha=.9;return scriptProperties.gain;}
            """
            f = try await client.configure(program:program(props,properties:["gain":.number(0.2)],mappings:["gain":"speed"],direct:[.init(layerID:1,target:"visible",propertyKey:"shown"),.init(layerID:1,target:"alpha",propertyKey:"speed")]),userProperties:payload(#"{"speed":{"value":0.4},"shown":{"value":false}}"#))
            try check(f.layers[0].alpha == 0.4 && !f.layers[0].visible,"builder mapping and direct binding configure")
            f = try await client.applyUserProperties(payload(#"{"speed":{"value":0.7},"shown":{"value":true}}"#),runtime:1)
            try check(f.layers[0].alpha == 0.7 && f.layers[0].visible,"mapped builder live object updated before callback")
            f = try await client.step(runtime:2,frameTime:0.1)
            try check(f.layers[0].alpha == 0.7,"script return overrides same-target direct write")
        } catch { await client.dispose(); throw error }
        await client.dispose()
    }
    static func failures() async throws {
        for (name,source) in [
            ("unsupported cursor event","export function cursorMove(){}"), ("static import","import x from 'x'; export function init(v){return v;}"),
            ("dynamic import","export function init(v){return import('x');}"), ("unsupported general settings event","export function applyGeneralSettings(){}"),
            ("authored throw","export function init(v){throw Error('authored');}"), ("NaN","export function init(v){return NaN;}"), ("alpha range","export function init(v){return 1.1;}"),
            ("size range","export function init(v){thisLayer.size=new Vec2(20000,1);}"), ("color range","export function init(v){thisLayer.color=new Vec3(2);}"),
            ("3D mutation","export function init(v){thisLayer.origin.z=3;}"),
            ("async handler","export async function init(v){return v;}"), ("unknown layer API","export function init(v){thisLayer.imaginary=1;}")
        ] { try await rejected(name,program(source)) }
        try await rejected("non-text layer cannot acquire text target",program("export function init(v){return 'hidden';}",target:"text"))
        try await rejected("text cannot contain controls",program("export function init(v){return 'line\\nfeed';}",target:"text",layers:[layer(text:"ok")]))
        try await rejected("text UTF-8 byte budget enforced",program("export function init(v){return '界'.repeat(1366);}",target:"text",layers:[layer(text:"ok")]))
        try await semanticRejected("duplicate IDs",program("export function init(v){return v;}",layers:[layer(),layer()]),reason:"duplicate")
        try await semanticRejected("unbounded coordinate",program("export function init(v){thisLayer.origin.x=1000001;}"),reason:"transform")
        let huge = SceneScriptProgram(bindings:[],layers:(0..<512).map { layer($0,name:String(repeating:"x",count:2000)) })
        let start=Date(); try await rejected("large output bounded",huge,stopsWorker:true); timings["largeOutput"] = Date().timeIntervalSince(start)
        try check(Date().timeIntervalSince(start) < 5,"large output fails promptly")
    }
    static func lifecycle() async throws {
        for mode in ["init","update","callback","cancel","dispose"] {
            let client=SceneScriptWorkerClient(executableURL:worker)
            let source = mode == "update" ? "export function update(v){while(true){}}" : mode == "callback" ? "export function applyUserProperties(p){if(p.go)while(true){}}" : "export function init(v){while(true){}}"
            let before=heartbeat; let started=Date(); var failed=false; var ids:Set<Int32>=[]
            if mode == "update" || mode == "callback" {
                _ = try await client.configure(program:program(source),userProperties:payload())
                ids=try await waitForChild()
                do { if mode == "update" { _ = try await client.step(runtime:1,frameTime:0.1) } else { _ = try await client.applyUserProperties(payload(#"{"go":{"value":true}}"#),runtime:1) } } catch { failed=true; lifecycleErrors[mode]=error.localizedDescription }
            } else {
                let task=Task { try await client.configure(program:program(source),userProperties:payload()) }
                ids=try await waitForChild()
                if mode == "cancel" { task.cancel() }
                if mode == "dispose" { await client.dispose() }
                do { _ = try await task.value } catch { failed=true; lifecycleErrors[mode]=error.localizedDescription }
            }
            timings[mode]=Date().timeIntervalSince(started)
            if let lowerBound=["init":2.8,"update":0.25,"callback":0.45][mode] {
                try check(Date().timeIntervalSince(started) >= lowerBound,"\(mode) reaches expected deadline rather than premature process crash")
                try check(lifecycleErrors[mode]?.contains("超时") == true,"\(mode) reports timeout rather than unrelated process death")
            }
            try await assertGone(ids)
            await client.dispose()
            try check(failed,"\(mode) fails instead of hanging")
            try check(heartbeat > before,"\(mode) keeps MainActor heartbeat")
            try check(Date().timeIntervalSince(started) < (mode == "init" ? 5 : 2),"\(mode) bounded deadline")
            let restarted = try await client.configure(program:program("export function init(v){return .5;}"),userProperties:payload())
            try check(restarted.layers[0].alpha == 0.5,"\(mode) client can explicitly reload after stop")
            await client.dispose()
            try await assertGone(try children())
        }
    }
    // Runs in an expendable intermediate parent, with no client timeout. Its
    // SIGKILL must leave cleanup to the production worker's own parent watcher.
    static func orphanParent(marker: URL) throws {
        let child=Process(); child.executableURL=worker
        child.arguments=["--probe-owner",marker.deletingLastPathComponent().lastPathComponent]
        let input=Pipe(), output=Pipe(); child.standardInput=input; child.standardOutput=output
        child.standardError=FileHandle.nullDevice; try child.run()
        func send(_ object: [String:Any]) throws {
            let bytes=try JSONSerialization.data(withJSONObject:object)
            try input.fileHandleForWriting.write(contentsOf:bytes + Data([10]))
        }
        let p=program("export function update(v){while(true){}}")
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p))
        try send(["id":"prepare","operation":"configure","program":encoded,"properties":[:],"runtime":0,"frameTime":0])
        var response=Data()
        while response.last != 10 {
            guard let byte=try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty else {
                throw NSError(domain:"WorkerProbe",code:3,userInfo:[NSLocalizedDescriptionKey:"orphan fixture configure disconnected"])
            }
            response.append(byte)
        }
        let decoded=try JSONSerialization.jsonObject(with:response) as? [String:Any]
        guard decoded?["ok"] as? Bool == true else { throw NSError(domain:"WorkerProbe",code:4) }
        try send(["id":"busy","operation":"step","runtime":1,"frameTime":0.1])
        usleep(150_000)
        let fd=output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK)
        var byte:UInt8=0
        let readCount=Darwin.read(fd,&byte,1)
        guard child.isRunning, readCount == -1, errno == EAGAIN || errno == EWOULDBLOCK else {
            throw NSError(domain:"WorkerProbe",code:5,userInfo:[NSLocalizedDescriptionKey:"worker not busy before parent death"])
        }
        let record:[String:Any]=["workerPID":child.processIdentifier,"parentPID":getpid(),"busy":true]
        try JSONSerialization.data(withJSONObject:record).write(to:marker,options:.atomic)
        while true { pause() }
    }
    static func orphanLifecycle() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("scene-worker-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:folder) }
        let marker=folder.appendingPathComponent("owner.json")
        let parent=Process(); parent.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        parent.arguments=[worker.path,"--orphan-parent",marker.path]
        parent.standardOutput=FileHandle.nullDevice; parent.standardError=FileHandle.nullDevice
        try parent.run()
        var childPID:Int32?
        defer {
            // These PIDs were created by this fixture, never discovered globally.
            if parent.isRunning { parent.terminate() }
            if let childPID, kill(childPID,0) == 0 {
                let inspect=Process(); inspect.executableURL=URL(fileURLWithPath:"/bin/ps")
                inspect.arguments=["-p",String(childPID),"-o","command="]
                let output=Pipe(); inspect.standardOutput=output; inspect.standardError=FileHandle.nullDevice
                if (try? inspect.run()) != nil {
                    let command=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
                    inspect.waitUntilExit()
                    if command.contains(worker.path), command.contains(folder.lastPathComponent) { _ = kill(childPID,SIGKILL) }
                }
            }
        }
        for _ in 0..<200 {
            if let data=try? Data(contentsOf:marker), let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] {
                childPID=(object["workerPID"] as? NSNumber)?.int32Value
                try check((object["parentPID"] as? NSNumber)?.int32Value == parent.processIdentifier && object["busy"] as? Bool == true,"fixture owns configured busy helper")
                break
            }
            guard parent.isRunning else { throw NSError(domain:"WorkerProbe",code:6,userInfo:[NSLocalizedDescriptionKey:"orphan fixture parent failed"]) }
            try await Task.sleep(for:.milliseconds(10))
        }
        guard let pid=childPID else { throw NSError(domain:"WorkerProbe",code:7,userInfo:[NSLocalizedDescriptionKey:"orphan fixture did not become busy"]) }
        try check(kill(pid,0) == 0,"busy worker exists before parent SIGKILL")
        let started=Date(), ticks=heartbeat
        try check(kill(parent.processIdentifier,SIGKILL) == 0,"sudden own parent death")
        for _ in 0..<300 {
            if kill(pid,0) == -1 && errno == ESRCH { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        timings["orphanParentDeath"]=Date().timeIntervalSince(started)
        try check(kill(pid,0) == -1 && errno == ESRCH,"busy orphan worker self-exits without client cleanup")
        childPID=nil
        try check(Date().timeIntervalSince(started) < 3,"parent watcher exit bounded")
        try check(heartbeat > ticks,"orphan watcher keeps outer MainActor responsive")
    }
    static func main() async {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[2] == "--orphan-parent" {
            do { try orphanParent(marker:URL(fileURLWithPath:CommandLine.arguments[3])) }
            catch { fputs("fixture failure: \(error)\n",stderr); exit(2) }
            return
        }
        let ticker=Task { while !Task.isCancelled { heartbeat += 1; try? await Task.sleep(for:.milliseconds(5)) } }
        do {
            try check(FileManager.default.isExecutableFile(atPath:worker.path),"real helper exists")
            try check(try children().isEmpty,"no existing probe-owned helpers")
            try await semantics(); try await failures(); try await lifecycle(); try await orphanLifecycle()
            try check(try children().isEmpty,"all own helpers reaped")
            ticker.cancel()
            let result:[String:Any] = ["passed":checks,"heartbeatTicks":heartbeat,"timingsSeconds":timings,"lifecycleErrors":lifecycleErrors,"worker":worker.path,"mode":"real child IPC + JavaScriptCore, no GUI"]
            let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]); print(String(decoding:data,as:UTF8.self))
        } catch { ticker.cancel(); fputs("FAIL: \(error.localizedDescription)\n",stderr); exit(1) }
    }
}
