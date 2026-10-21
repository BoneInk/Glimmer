import AppKit
import CryptoKit
import Foundation

@main @MainActor enum SceneScriptDesktopIntegrationTests {
    static let fm=FileManager.default
    static let services=AuthorPropertyServices.shared
    static var checks=0
    static func check(_ value:Bool,_ name:String) throws {
        guard value else { throw SceneWallpaperFailure(message:name) }; checks += 1
        print("PASS \(name)"); fflush(stdout)
    }
    static func wait(_ name:String,_ condition:@MainActor ()->Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for:.milliseconds(20)) }
        throw SceneWallpaperFailure(message:"Timeout: " + name)
    }
    static func digest(_ runtime:SceneWallpaperRuntime) -> String {
        guard let image=runtime.posterImage, let data=image.dataProvider?.data else { return "" }
        return SHA256.hash(data:data as Data).map { String(format:"%02x",$0) }.joined()
    }
    static func geometry(_ runtime:SceneWallpaperRuntime) -> SceneImageLayer? { runtime.inspection?.layers.first { $0.id == 2 } }
    static func children() throws -> Set<Int32> {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/ps");p.arguments=["-axo","pid=,ppid=,comm="]
        let output=Pipe();p.standardOutput=output;try p.run()
        let bytes=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        return Set(String(decoding:bytes,as:UTF8.self).split(separator:"\n").compactMap { line in
            let f=line.split(whereSeparator:{$0 == " " || $0 == "\t"})
            guard f.count >= 3, let pid=Int32(f[0]), Int32(f[1]) == getpid(),f.dropFirst(2).joined(separator:" ").hasSuffix("GlimmerSceneScriptWorker") else { return nil };return pid
        })
    }
    static func waitForNoChildren() async throws {
        for _ in 0..<200 { if try children().isEmpty { return };try await Task.sleep(for:.milliseconds(10)) }
        throw SceneWallpaperFailure(message:"Own helper remained after runtime cleanup")
    }
    static func run(_ root:URL, fixture:URL) async throws {
        try check(Bundle.main.bundleURL.pathExtension == "app" && fm.isExecutableFile(atPath:Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GlimmerSceneScriptWorker").path),"temporary app resolves real helper through default Bundle path")
        try check(try children().isEmpty,"no pre-existing own helper processes")
        let original=root.appendingPathComponent("Original")
        try fm.createDirectory(at:root,withIntermediateDirectories:true);try fm.copyItem(at:fixture,to:original)
        let originalScene=try Data(contentsOf:original.appendingPathComponent("scene.json"))
        let storage=AppStorage(root:root.appendingPathComponent("AppData")), store=VideoLibraryStore(storage:AppStorage(root:root.appendingPathComponent("AppData")))
        let importer=ImportService(store:store,storage:storage,thumbnailCache:ThumbnailCache(storage:storage))
        let metadata=ImportWorkshopMetadata(publishedFileID:"998877",title:"Dynamic Scene integration",pageURLString:nil,previewImageURLString:nil,authorSteamID:nil,fileByteSize:nil)
        guard case .imported(let id)=await importer.importWorkshopScene(original.appendingPathComponent("project.json"),metadata:metadata),let item=store.item(withID:id) else { throw SceneWallpaperFailure(message:"Dynamic fixture import failed") }
        try check(item.isSceneWallpaper && item.fileURL != original.appendingPathComponent("project.json"),"dynamic Scene imported to real owned project without VideoProbe")
        let frame=CGRect(x:0,y:0,width:320,height:200)
        let displays=DisplayRegistry(snapshot:["A","B"].enumerated().map { index,id in
            .init(id:id,displayID:UInt32(index+1),localizedName:id,frame:frame,visibleFrame:frame,backingScaleFactor:1,isPrimary:index == 0,pixelSize:frame.size)
        })
        let playback=DesktopPlaybackController(store:store,displayRegistry:displays,storage:storage,previewOnly:true,writesToLibrary:true)
        defer { playback.tearDownAll() }
        try check(await playback.applyAndWait(item:item,to:nil) == nil,"real desktop controller commits two ready dynamic hosts")
        guard let a=playback.session(for:"A"),let b=playback.session(for:"B"),let ra=a.sceneRuntime,let rb=b.sceneRuntime else { throw SceneWallpaperFailure(message:"Missing two Scene desktop sessions") }
        let hosts=[ra,rb]
        try check(a.window == nil && b.window == nil && a.player == nil && b.player == nil,"previewOnly Scene hosts create neither desktop window nor AVPlayer")
        try check(store.assignments["A"] == id && store.assignments["B"] == id,"both actual ready hosts commit persisted assignments")
        try check(hosts.allSatisfy{$0.isAnimated && $0.state == .ready && $0.posterImage != nil},"both hosts publish real dynamic images before apply returns")
        try check(try children().count == 2,"two desktop sessions own two real default-path workers")
        let initialPixels=hosts.map(digest), initialFrames=hosts.map(\.frameCount)
        try await wait("both dynamic desktop frame loops") { zip(hosts,initialFrames).allSatisfy{$0.0.frameCount >= $0.1 + 3} }
        try check(zip(hosts,initialPixels).allSatisfy{digest($0.0) != $0.1},"both rendered pixel buffers change across real script frames")
        try check(hosts.allSatisfy { geometry($0)?.anglesDegrees.z != 15 },"real inspected layer state advances on both hosts")
        let project=try AuthorPropertyServices.project(for:item)!, overrides=services.store(storage:storage)
        try check(services.editableKeys(project:project,itemID:id).isSuperset(of:["motionrange","motionspeed","geometrycolor"]),"live callback and direct bindings expose actual author capabilities")
        try await overrides.set(.number(0),for:"motionrange",itemID:id,project:project)
        try await overrides.set(.number(0),for:"motionspeed",itemID:id,project:project)
        try await services.applySavedSettings(project:project,itemID:id,storage:storage)
        try check(hosts.allSatisfy { geometry($0)?.origin.x == 480 && geometry($0)?.anglesDegrees.z == 15 },"zero motion range and speed ACK updates actual geometry before returning")
        let stoppedPixels=hosts.map(digest), stoppedFrames=hosts.map(\.frameCount)
        try await wait("zero-speed frames still serviced") { zip(hosts,stoppedFrames).allSatisfy{$0.0.frameCount >= $0.1 + 3} }
        try check(zip(hosts,stoppedPixels).allSatisfy{digest($0.0) == $0.1},"zero motion settings yield stable real pixels on both running hosts")
        let persisted=try await AuthorPropertyOverrideStore(directory:storage.root.appendingPathComponent("AuthorPropertyOverrides")).load(itemID:id)
        try check(persisted["motionrange"] == .number(0) && persisted["motionspeed"] == .number(0),"motion author overrides persist independently of host state")
        playback.applyPolicyState(isBlocked:true,displayShouldPlay:{_ in true})
        try await Task.sleep(for:.milliseconds(100))
        let pausedFrames=hosts.map(\.frameCount), pausedTimes=hosts.map(\.activeRuntime)
        try await Task.sleep(for:.milliseconds(250))
        try check(hosts.allSatisfy{$0.state == .paused} && zip(hosts,pausedFrames).allSatisfy{$0.0.frameCount == $0.1} && zip(hosts,pausedTimes).allSatisfy{$0.0.activeRuntime == $0.1},"desktop policy pause freezes actual loops and active clock on both hosts")
        let resizedA=DisplayDescriptor(id:"A",displayID:1,localizedName:"A",frame:frame,visibleFrame:frame,backingScaleFactor:1,isPrimary:true,pixelSize:CGSize(width:1080,height:1920))
        let beforeScreenB=rb.frameCount
        playback.reconcileSessions(onlineDisplayIDs:["A","B"],displays:[resizedA,displays.displays[1]])
        try await wait("virtual display reconciliation serial resize ACK while policy paused") { ra.screenResolution == .init(x:1080,y:1920) && ra.state == .paused && ra.frameCount > pausedFrames[0] }
        try check(rb.screenResolution == .init(x:320,y:200) && rb.frameCount == beforeScreenB,"display A physical-pixel update leaves B screen environment/frame unchanged")
        try check(hosts.allSatisfy{$0.state == .paused} && zip(hosts,pausedTimes).allSatisfy{$0.0.activeRuntime == $0.1},"desktop screen reconciliation ACK preserves policy pause and active clocks")
        try check(digest(ra)==stoppedPixels[0],"same-time screen RPC with no resize handler preserves actual pixels")
        try await overrides.set(.number(1),for:"motionspeed",itemID:id,project:project)
        try await services.applySavedSettings(project:project,itemID:id,storage:storage)
        try check(hosts.allSatisfy{$0.state == .paused} && zip(hosts,pausedTimes).allSatisfy{$0.0.activeRuntime == $0.1},"author ACK while paused preserves policy pause and active time")
        playback.applyPolicyState(isBlocked:false,displayShouldPlay:{_ in true})
        let resumePixels=hosts.map(digest)
        try await wait("resumed dynamic frames") { zip(hosts,pausedFrames).allSatisfy{$0.0.frameCount >= $0.1 + 4} }
        try check(hosts.allSatisfy{$0.state == .ready} && zip(hosts,resumePixels).allSatisfy{digest($0.0) != $0.1},"resume advances real frames and pixels after author speed ACK")
        let brokenRoot=root.appendingPathComponent("Broken")
        try fm.copyItem(at:fixture,to:brokenRoot)
        let sceneURL=brokenRoot.appendingPathComponent("scene.json")
        var scene=try JSONSerialization.jsonObject(with:Data(contentsOf:sceneURL)) as! [String:Any]
        var objects=scene["objects"] as! [[String:Any]], angles=objects[1]["angles"] as! [String:Any]
        angles["script"]="export function init(value){throw Error('expected integration failure');}"
        objects[1]["angles"]=angles;scene["objects"]=objects
        try JSONSerialization.data(withJSONObject:scene).write(to:sceneURL)
        guard case .imported(let brokenID)=await importer.importLocalSceneProject(brokenRoot.appendingPathComponent("project.json")),let broken=store.item(withID:brokenID) else {throw SceneWallpaperFailure(message:"Broken script fixture structurally valid import failed")}
        let assignments=store.assignments, beforeFailure=hosts.map(\.frameCount)
        try check(await playback.applyAndWait(item:broken,to:nil) != nil,"throwing script cannot commit replacement desktop sessions")
        try check(playback.session(for:"A") === a && playback.session(for:"B") === b && store.assignments == assignments,"failed script preserves prior session identity and assignments on both displays")
        try await wait("old hosts continue after failed apply") { zip(hosts,beforeFailure).allSatisfy{$0.0.frameCount > $0.1} }
        try check(try children().count == 2,"failed replacement retires prepared workers while old workers remain live")
        let layout=SteamCMDLayout(root:storage.workshopDirectory.appendingPathComponent("SteamCMD")),download=SteamCMDLayout(root:storage.workshopDirectory.appendingPathComponent("SteamCMD")).downloadDirectory(for:WorkshopItemID("998877")!)
        try fm.createDirectory(at:download.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.copyItem(at:original,to:download)
        var moved:[URL:URL]=[:]
        let deletion=ManagedWallpaperDeletionService(store:store,playback:playback,storage:storage,workshopLayout:layout,trashOperation:{source in
            let target=root.appendingPathComponent("Trash").appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.moveItem(at:source,to:target);moved[source]=target;return target
        })
        try check(await deletion.delete(workshopID:"998877",itemID:id) == nil,"managed deletion commits dynamic project and author data transaction")
        try await waitForNoChildren()
        try check(hosts.allSatisfy{$0.state == .disposed} && playback.sessions.isEmpty && store.assignments.isEmpty,"deletion disposes both animated hosts and clears live sessions and assignments")
        try check(moved[item.fileURL.deletingLastPathComponent()] != nil && moved[download] != nil && moved[storage.root.appendingPathComponent("AuthorPropertyOverrides/\(id.uuidString).json")] != nil,"whole Scene project, matching download and author overrides enter isolated Trash")
        try check(try Data(contentsOf:original.appendingPathComponent("scene.json")) == originalScene && broken.fileExists,"deletion preserves original project and unrelated Scene")
        try check(await playback.applyAndWait(item:broken,to:["A"]) != nil && playback.sessions.isEmpty,"failed script after deletion cannot resurrect old desktop session")
        // Repair only the independent owned test copy, then exercise teardown
        // while both dynamic loops and children are genuinely active.
        try originalScene.write(to:broken.fileURL.deletingLastPathComponent().appendingPathComponent("scene.json"))
        try check(await playback.applyAndWait(item:broken,to:nil) == nil,"valid repaired fixture starts two new dynamic hosts for active teardown")
        let teardownHosts=[playback.session(for:"A")!.sceneRuntime!,playback.session(for:"B")!.sceneRuntime!]
        try await wait("teardown fixture dynamic frames") {teardownHosts.allSatisfy{$0.frameCount >= 2}}
        try check(try children().count == 2,"teardown begins with two live own workers")
        let keptAssignments=store.assignments
        playback.tearDownAll();try await waitForNoChildren()
        try check(teardownHosts.allSatisfy{$0.state == .disposed} && playback.sessions.isEmpty,"active teardown disposes both runtime loops and sessions")
        try check(store.assignments == keptAssignments && services.readySceneHosts(itemID:brokenID).isEmpty,"teardown retains restart intent but unregisters all live author hosts")
        playback.tearDownAll();try await Task.sleep(for:.milliseconds(150))
        try check(playback.sessions.isEmpty && teardownHosts.allSatisfy{$0.state == .disposed},"repeated teardown remains idempotent without late host resurrection")
        try check(try children().isEmpty,"delete and teardown leave no own helper children")
        print("RESULT \(checks) passed; real dynamic DesktopPlaybackController + two virtual displays + default Bundle worker + author ACK + pause/delete/failure preservation")
    }
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task {
            let root=fm.temporaryDirectory.appendingPathComponent("GW-Dynamic-Desktop-\(UUID())")
            do {try await run(root,fixture:URL(fileURLWithPath:CommandLine.arguments[1]))}
            catch {print("FAIL \(error)");try? fm.removeItem(at:root);exit(1)}
            try? fm.removeItem(at:root);exit(0)
        };app.run()
    }
}
