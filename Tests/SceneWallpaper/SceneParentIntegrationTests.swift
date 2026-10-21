import AppKit
import CryptoKit
import Foundation

@main @MainActor enum SceneParentIntegrationTests {
    static let fm=FileManager.default, services=AuthorPropertyServices.shared
    static var checks=0
    static func check(_ value:Bool,_ name:String)throws {guard value else {throw SceneWallpaperFailure(message:name)};checks += 1;print("PASS \(name)");fflush(stdout)}
    static func wait(_ name:String,_ condition:@MainActor ()->Bool)async throws {for _ in 0..<500 {if condition(){return};try await Task.sleep(for:.milliseconds(20))};throw SceneWallpaperFailure(message:"Timeout: "+name)}
    static func imageHash(_ image:CGImage)->String {SHA256.hash(data:image.dataProvider!.data! as Data).map{String(format:"%02x",$0)}.joined()}
    static func digest(_ runtime:SceneWallpaperRuntime)->String {runtime.posterImage.map(imageHash) ?? ""}
    static func sourceHashes(_ root:URL)throws->[String:String] {
        let root=root.standardizedFileURL.resolvingSymlinksInPath()
        guard let files=fm.enumerator(atPath:root.path) else {throw SceneWallpaperFailure(message:"Cannot enumerate fixture")}
        var hashes:[String:String]=[:]
        for case let path as String in files {let file=root.appendingPathComponent(path);guard try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else {continue};hashes[path]=SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()};return hashes
    }
    static func children()throws->Set<Int32> {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/ps");p.arguments=["-axo","pid=,ppid=,comm="]
        let out=Pipe();p.standardOutput=out;try p.run();let bytes=out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        return Set(String(decoding:bytes,as:UTF8.self).split(separator:"\n").compactMap{line in
            let f=line.split(whereSeparator:{$0 == " " || $0 == "\t"})
            guard f.count>=3,let pid=Int32(f[0]),Int32(f[1]) == getpid(),f.dropFirst(2).joined(separator:" ").hasSuffix("GlimmerSceneScriptWorker") else{return nil};return pid
        })
    }
    static func noChildren()async throws {for _ in 0..<200 {if try children().isEmpty{return};try await Task.sleep(for:.milliseconds(10))};throw SceneWallpaperFailure(message:"Own worker remained")}
    static func node(_ host:SceneWallpaperRuntime,_ id:Int)->SceneImageLayer? {host.inspection?.layers.first{$0.id==id}}
    static func run(_ root:URL,fixture:URL)async throws {
        try check(Bundle.main.bundleURL.pathExtension == "app" && fm.isExecutableFile(atPath:Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GlimmerSceneScriptWorker").path),"temporary app uses actual default Bundle helper")
        try check(try children().isEmpty,"no pre-existing own workers")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("Original");try fm.copyItem(at:fixture,to:source)
        let original=try sourceHashes(source),storage=AppStorage(root:root.appendingPathComponent("AppData"))
        let store=VideoLibraryStore(storage:storage)
        let imports=ImportService(store:store,storage:storage,thumbnailCache:ThumbnailCache(storage:storage))
        let metadata=ImportWorkshopMetadata(publishedFileID:"998866",title:"Parent integration",pageURLString:nil,previewImageURLString:nil,authorSteamID:nil,fileByteSize:nil)
        guard case .imported(let id)=await imports.importWorkshopScene(source.appendingPathComponent("project.json"),metadata:metadata),let item=store.item(withID:id) else{throw SceneWallpaperFailure(message:"Hierarchy fixture import failed")}
        let owned=item.fileURL.deletingLastPathComponent()
        try check(item.isSceneWallpaper && item.workshopID=="998866" && item.source == .steamWorkshop && (try sourceHashes(owned)) == original,"atomic owned Scene import preserves provenance and complete module tree")
        let frame=CGRect(x:0,y:0,width:320,height:200)
        let displays=DisplayRegistry(snapshot:["A","B"].enumerated().map{index,id in .init(id:id,displayID:UInt32(index+1),localizedName:id,frame:frame,visibleFrame:frame,backingScaleFactor:1,isPrimary:index==0,pixelSize:frame.size)})
        let playback=DesktopPlaybackController(store:store,displayRegistry:displays,storage:storage,previewOnly:true,writesToLibrary:true)
        defer{playback.tearDownAll()}
        try check(await playback.applyAndWait(item:item,to:nil) == nil,"two real nested-parent hosts ready before Desktop apply commits")
        guard let a=playback.session(for:"A"),let b=playback.session(for:"B"),let ra=a.sceneRuntime,let rb=b.sceneRuntime else{throw SceneWallpaperFailure(message:"Missing hosts")}
        let hosts=[ra,rb]
        try check(a.window==nil && b.window==nil && a.player==nil && b.player==nil,"virtual previewOnly creates no desktop windows or AVPlayers")
        try check(try children().count==2 && hosts.allSatisfy{$0.isAnimated && $0.state == .ready && $0.posterImage != nil},"two genuine default-path workers publish actual dynamic parent images")
        try check(hosts.allSatisfy{node($0,2)?.parentID==11 && node($0,11)?.parentID==10 && node($0,10)?.isTransformOnly==true && node($0,11)?.isTransformOnly==true && $0.inspection?.layers.map(\.id)==[1,2,11,10]},"helper roundtrip preserves nested parent IDs, group kind and child-before-parent order")
        let startFrames=hosts.map(\.frameCount),startPixels=hosts.map(digest)
        try await wait("dynamic parent pixels"){zip(hosts,startFrames).allSatisfy{$0.0.frameCount >= $0.1+3}}
        try check(zip(hosts,startPixels).allSatisfy{digest($0.0) != $0.1},"animated ancestor produces changed pixels on both real renderers")
        let project=try AuthorPropertyServices.project(for:item)!,overrides=services.store(storage:storage)
        try check(services.editableKeys(project:project,itemID:id).isSuperset(of:["groupscale","showgeometry","motionrange","motionspeed","geometrycolor","geometryopacity"]),"live Services exposes real group and image author controls")
        playback.applyPolicyState(isBlocked:true,displayShouldPlay:{_ in true});try await Task.sleep(for:.milliseconds(100))
        let pausedFrames=hosts.map(\.frameCount),pausedTimes=hosts.map(\.activeRuntime)
        try await Task.sleep(for:.milliseconds(200))
        try check(hosts.allSatisfy{$0.state == .paused} && zip(hosts,pausedFrames).allSatisfy{$0.0.frameCount==$0.1} && zip(hosts,pausedTimes).allSatisfy{$0.0.activeRuntime==$0.1},"pause freezes frame loops and active clocks on both hosts")
        func set(_ key:String,_ value:GWJSONValue)async throws {try await overrides.set(value,for:key,itemID:id,project:project);try await services.applySavedSettings(project:project,itemID:id,storage:storage)}
        try await overrides.set(.number(0),for:"motionrange",itemID:id,project:project);try await set("motionspeed",.number(0))
        try check(hosts.allSatisfy{node($0,10)?.origin.x==480 && node($0,10)?.anglesDegrees.z==15 && node($0,2)?.origin.x==50 && node($0,2)?.anglesDegrees.z==0 && node($0,11)?.origin.x==80 && node($0,11)?.anglesDegrees.z==35},"paused callback ACK updates animated parent while preserving child local transforms")
        let background=try hosts.map{host->String in
            let i=host.inspection!,image=host.posterImage!
            let bg=SceneWallpaperInspection(canvasSize:i.canvasSize,clearColor:i.clearColor,layers:i.layers.filter{$0.id==1},textures:i.textures,diagnostics:[])
            return imageHash(try SceneWallpaperRenderer.render(inspection:bg,pixelSize:.init(width:image.width,height:image.height)))
        }
        try await set("showgeometry",.bool(false))
        try check(zip(hosts,background).allSatisfy{digest($0.0)==$0.1 && node($0.0,10)?.isVisible==false && node($0.0,2)?.isVisible==true},"hidden group ACK leaves exactly independently rendered background despite visible child")
        try await set("showgeometry",.bool(true));try await set("groupscale",.number(0.6))
        let small=hosts.map(digest)
        try check(zip(hosts,background).allSatisfy{digest($0.0) != $0.1} && hosts.allSatisfy{node($0,10)?.scale.x==0.6},"group visibility and scale author ACK restores real transformed geometry")
        try await set("groupscale",.number(1.4))
        try check(zip(hosts,small).allSatisfy{digest($0.0) != $0.1},"nonuniform ancestor scaling changes actual shape pixels on both paused hosts")
        for host in hosts {
            let w=try SceneHierarchy.worldStates(layers:host.inspection!.layers)[2]!.transform
            let c=cos(15.0 * .pi/180),s=sin(15.0 * .pi/180),u=cos(35.0 * .pi/180),v=sin(35.0 * .pi/180)
            let a=c*1.4*u-s*0.8*v,b=s*1.4*u+c*0.8*v,cc = -c*1.4*v-s*0.8*u,d = -s*1.4*v+c*0.8*u
            try check(zip([w.a,w.b,w.c,w.d,w.tx,w.ty],[a,b,cc,d,480+c*1.4*80+a*50,300+s*1.4*80+b*50]).allSatisfy{abs($0.0-$0.1)<1e-8} && abs(w.a*w.c+w.b*w.d)>0.1,"real host world matrix matches independently calculated nested shear and translation")
        }
        let beforeColor=hosts.map(digest);try await set("geometrycolor",.string("0.1 0.8 0.3"))
        try check(hosts.allSatisfy{node($0,2)?.tint == .init(x:0.1,y:0.8,z:0.3)} && zip(hosts,beforeColor).allSatisfy{digest($0.0) != $0.1},"image color ACK changes local tint and real pixels under parent shear")
        try await set("geometryopacity",.number(0))
        try check(zip(hosts,background).allSatisfy{digest($0.0)==$0.1},"image opacity zero ACK returns exact background without changing group kind")
        try await set("geometryopacity",.number(1))
        try check(hosts.allSatisfy{node($0,10)?.isTransformOnly==true && node($0,10)?.size == .init(x:1,y:1) && node($0,10)?.opacity==1 && node($0,11)?.isTransformOnly==true && $0.state == .paused} && zip(hosts,pausedTimes).allSatisfy{$0.0.activeRuntime==$0.1},"author updates preserve group dummy fields, kind, policy pause and active time")
        try await set("motionspeed",.number(1));playback.applyPolicyState(isBlocked:false,displayShouldPlay:{_ in true})
        let resumed=hosts.map(digest),resumeFrames=hosts.map(\.frameCount)
        try await wait("resumed parent animation"){zip(hosts,resumeFrames).allSatisfy{$0.0.frameCount >= $0.1+3}}
        try check(zip(hosts,resumed).allSatisfy{digest($0.0) != $0.1},"resume advances parent world geometry and real pixels")
        let assignments=store.assignments
        for mode in ["missing","cycle"] {
            let bad=root.appendingPathComponent(mode);try fm.copyItem(at:fixture,to:bad)
            let url=bad.appendingPathComponent("scene.json");var scene=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any],objects=scene["objects"] as! [[String:Any]]
            if mode=="missing" {objects[1]["parent"]=999}else{objects[3]["parent"]=2};scene["objects"]=objects;try JSONSerialization.data(withJSONObject:scene).write(to:url)
            guard case .failed=await imports.importLocalSceneProject(bad.appendingPathComponent("project.json")) else{throw SceneWallpaperFailure(message:"Invalid parent imported")}
            try check(playback.session(for:"A") === a && playback.session(for:"B") === b && store.assignments==assignments,"\(mode) parent import refuses invalid graph and preserves both old sessions")
        }
        let badRoot=root.appendingPathComponent("BadWorker");try fm.copyItem(at:fixture,to:badRoot)
        let badURL=badRoot.appendingPathComponent("scene.json");var scene=try JSONSerialization.jsonObject(with:Data(contentsOf:badURL)) as! [String:Any],objects=scene["objects"] as! [[String:Any]],angles=objects[3]["angles"] as! [String:Any]
        angles["script"]="export function init(v){throw Error('controlled parent helper failure');}";objects[3]["angles"]=angles;scene["objects"]=objects;try JSONSerialization.data(withJSONObject:scene).write(to:badURL)
        guard case .imported(let badID)=await imports.importLocalSceneProject(badRoot.appendingPathComponent("project.json")),let badItem=store.item(withID:badID) else{throw SceneWallpaperFailure(message:"Structurally valid bad worker import failed")}
        try check(await playback.applyAndWait(item:badItem,to:nil) != nil && playback.session(for:"A") === a && playback.session(for:"B") === b && store.assignments==assignments,"actual helper failure cannot replace prior parent sessions or assignments")
        try check(try children().count==2,"rejected helper replacements retire their processes while old hosts remain")
        let layout=SteamCMDLayout(root:storage.workshopDirectory.appendingPathComponent("SteamCMD")),download=SteamCMDLayout(root:storage.workshopDirectory.appendingPathComponent("SteamCMD")).downloadDirectory(for:WorkshopItemID("998866")!)
        try fm.createDirectory(at:download.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.copyItem(at:source,to:download)
        var moved:[URL:URL]=[:]
        let deletion=ManagedWallpaperDeletionService(store:store,playback:playback,storage:storage,workshopLayout:layout,trashOperation:{src in let dst=root.appendingPathComponent("Trash").appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dst.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.moveItem(at:src,to:dst);moved[src]=dst;return dst})
        try check(await deletion.delete(workshopID:"998866",itemID:id)==nil,"whole parent project and override deletion commits in isolated Trash")
        try await noChildren()
        try check(hosts.allSatisfy{$0.state == .disposed} && playback.sessions.isEmpty && store.assignments.isEmpty && services.readySceneHosts(itemID:id).isEmpty,"deletion disposes both parent runtimes, author registrations and assignments")
        guard let trashed=moved[owned] else{throw SceneWallpaperFailure(message:"Missing whole owned tree")}
        try check(fm.fileExists(atPath:trashed.appendingPathComponent("scripts/motion.js").path) && moved[download] != nil && moved[storage.root.appendingPathComponent("AuthorPropertyOverrides/\(id.uuidString).json")] != nil && !fm.fileExists(atPath:owned.path),"complete module tree, matching download and author overrides moved together")
        try check(try sourceHashes(source)==original,"all original source bytes unchanged through import, author updates, animation and deletion")
        try Data(contentsOf:source.appendingPathComponent("scene.json")).write(to:badItem.fileURL.deletingLastPathComponent().appendingPathComponent("scene.json"))
        try check(await playback.applyAndWait(item:badItem,to:nil)==nil,"repaired independent owned test project starts two genuine parent hosts")
        let finalHosts=[playback.session(for:"A")!.sceneRuntime!,playback.session(for:"B")!.sceneRuntime!]
        try await wait("active teardown"){finalHosts.allSatisfy{$0.frameCount>=2}}
        playback.tearDownAll();try await noChildren();playback.tearDownAll();try await Task.sleep(for:.milliseconds(100))
        try check(finalHosts.allSatisfy{$0.state == .disposed} && playback.sessions.isEmpty && services.readySceneHosts(itemID:badID).isEmpty && (try children()).isEmpty,"active and repeated teardown unregisters hosts and leaves no own child or late resurrection")
        print("RESULT \(checks) parent import/Services/two-default-helper/pixels/graph/delete/teardown checks passed; virtual displays previewOnly, no real desktop/lock/account changes")
    }
    static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);Task{let root=fm.temporaryDirectory.appendingPathComponent("GW-Parent-Integration-\(UUID())");do{try await run(root,fixture:URL(fileURLWithPath:CommandLine.arguments[1]))}catch{print("FAIL \(error)");try? fm.removeItem(at:root);exit(1)};try? fm.removeItem(at:root);exit(0)};app.run()}
}
