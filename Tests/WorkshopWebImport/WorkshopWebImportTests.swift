import CryptoKit
import Darwin
import Foundation

private actor ProbeCounter {
    var count=0
    func probe(_ url:URL) async throws -> VideoProbeResult { count += 1;return try await VideoProbe.probe(url:url) }
}
private actor ProbeGate {
    var entered=false
    var continuation:CheckedContinuation<Void,Never>?
    func wait() async { entered=true;await withCheckedContinuation{continuation=$0} }
    func release(){continuation?.resume();continuation=nil}
}
@main @MainActor enum WorkshopWebImportTests {
    static func main() async throws {
        var checks:[String]=[]
        func check(_ condition:Bool,_ name:String){precondition(condition,"FAIL: "+name);checks.append(name)}
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("GWWorkshopWebImport-\(UUID())")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? fm.removeItem(at:root)}
        func project(_ name:String) throws -> URL {
            let folder=root.appendingPathComponent(name);try fm.createDirectory(at:folder.appendingPathComponent("css"),withIntermediateDirectories:true)
            try fm.createDirectory(at:folder.appendingPathComponent("js"),withIntermediateDirectories:true)
            try Data(#"{"type":"web","file":"index.html","title":"作者名称","general":{"properties":{"caption":{"type":"textinput","value":"author"}}}}"#.utf8).write(to:folder.appendingPathComponent("project.json"))
            try Data("<html><link rel='stylesheet' href='css/style.css'><script src='js/main.js'></script></html>".utf8).write(to:folder.appendingPathComponent("index.html"))
            try Data("body{color:red}".utf8).write(to:folder.appendingPathComponent("css/style.css"))
            try Data("window.test='live'".utf8).write(to:folder.appendingPathComponent("js/main.js"))
            return folder
        }
        func newStore(_ name:String)->VideoLibraryStore{VideoLibraryStore(storage:AppStorage(root:root.appendingPathComponent(name)))}
        func service(_ store:VideoLibraryStore, counter:ProbeCounter?=nil)->ImportService {
            let operation: (@Sendable (URL) async throws -> VideoProbeResult)?
            if let counter { operation = { url in try await counter.probe(url) } } else { operation = nil }
            return ImportService(store:store,storage:store.storage,thumbnailCache:ThumbnailCache(storage:store.storage),probeOperation:operation)
        }
        func id(_ outcome:ImportWorkshopOutcome)->UUID?{switch outcome{case .imported(let id),.duplicated(let id,_):return id;case .failed:return nil}}
        func failed(_ outcome:ImportWorkshopOutcome)->Bool{if case .failed=outcome{return true};return false}
        func metadata(_ id:String)->ImportWorkshopMetadata{.init(publishedFileID:id,title:"工坊名称",pageURLString:"https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)",previewImageURLString:nil,authorSteamID:"123",fileByteSize:nil)}
        func managedProjects(_ store:VideoLibraryStore)->[URL]{(try? fm.contentsOfDirectory(at:store.storage.mediaDirectory.appendingPathComponent("WebProjects"),includingPropertiesForKeys:nil)) ?? []}
        func treeHash(_ folder:URL, excludingAnnotation:Bool=false)throws->String {
            let canonical=try WebProjectPaths.canonical(folder)
            let iterator=fm.enumerator(at:canonical,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey])!
            var files:[(String,URL)]=[]
            for case let file as URL in iterator {
                let relative=String((try WebProjectPaths.canonical(file)).path.dropFirst(canonical.path.count+1))
                if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true,!(excludingAnnotation && relative=="glimmer-download.json"){files.append((relative,file))}
            }
            var hash=SHA256()
            for (relative,file) in files.sorted(by:{$0.0.utf8.lexicographicallyPrecedes($1.0.utf8)}){hash.update(data:Data(relative.utf8));hash.update(data:Data([0]));hash.update(data:Data(SHA256.hash(data:try Data(contentsOf:file))))}
            return hash.finalize().map{String(format:"%02x",$0)}.joined()
        }
        let source=try project("source"),store=newStore("library"),counter=ProbeCounter()
        let importer=service(store,counter:counter)
        let sourceHash=try treeHash(source)
        let first=await importer.importWorkshopWeb(source.appendingPathComponent("project.json"),metadata:metadata("100"))
        guard let firstID=id(first),let firstItem=store.item(withID:firstID) else{fatalError("first import failed \(first)")}
        check(firstItem.isWebWallpaper && firstItem.source == .steamWorkshop && firstItem.workshopID=="100","first published Web record has atomic Steam origin")
        check(firstItem.durationSeconds==nil && firstItem.pixelWidth==nil && firstItem.videoCodec==nil,"Web metadata contains no fabricated video probe")
        check(await counter.count==0,"Web import never invokes video probe")
        check(firstItem.filePath.contains("/Media/WebProjects/") && firstItem.filePath != source.appendingPathComponent("project.json").path,"complete project owned under Media/WebProjects")
        let copied=firstItem.fileURL.deletingLastPathComponent()
        check(try Data(contentsOf:copied.appendingPathComponent("css/style.css")) == Data("body{color:red}".utf8),"nested CSS preserved")
        check(try Data(contentsOf:copied.appendingPathComponent("js/main.js")) == Data("window.test='live'".utf8),"nested JavaScript preserved")
        check(try firstItem.contentFingerprint==sourceHash && treeHash(copied)==sourceHash,"fingerprint is sorted UTF8 relative NUL raw file SHA256")
        check(try treeHash(source)==sourceHash,"source full tree unchanged by copy")
        let restart=VideoLibraryStore(storage:store.storage)
        check(restart.item(withID:firstID)?.source == .steamWorkshop && restart.item(withID:firstID)?.workshopID=="100" && restart.items.first?.isWebWallpaper==true,"first persisted record survives restart already sourced Web")
        store.rename(id:firstID,to:"用户自定义名称");store.toggleFavorite(id:firstID)
        store.assign(itemID:firstID,to:"fixture-display")
        let authorStore=AuthorPropertyOverrideStore(directory:store.storage.root.appendingPathComponent("AuthorPropertyOverrides"))
        let authorProject=try AuthorPropertyProject.load(projectURL:source.appendingPathComponent("project.json"),allowedRoot:source)
        try await authorStore.set(.string("用户设置"),for:"caption",itemID:firstID,project:authorProject)
        store.flush()
        let duplicate=await importer.importWorkshopWeb(source,metadata:metadata("100"))
        check(id(duplicate)==firstID && store.items.count==1 && managedProjects(store).count==1,"same tree and source reuses valid UUID without duplicate copy")
        check(store.item(withID:firstID)?.title=="用户自定义名称" && store.item(withID:firstID)?.isFavorite==true,"repeat import preserves rename and favorite")
        let otherOrigin=await importer.importWorkshopWeb(source,metadata:metadata("101"))
        check(id(otherOrigin) != firstID && store.items.count==2,"same content different Workshop ID remains distinct")
        let local=await importer.importLocalWebProject(source)
        let localAgain=await importer.importLocalWebProject(source)
        check(id(local) != firstID && id(local)==id(localAgain) && store.items.count==3,"local origin deduplicates locally without merging Workshop records")
        try Data("body{color:blue}".utf8).write(to:source.appendingPathComponent("css/style.css"))
        let changedHash=try treeHash(source)
        let changed=await importer.importWorkshopWeb(source,metadata:metadata("100"))
        check(id(changed) != firstID && store.items.count==4,"CSS-only change creates new version of same Workshop ID")
        check(try Data(contentsOf:copied.appendingPathComponent("css/style.css")) == Data("body{color:red}".utf8),"new version never overwrites old running project copy")
        check(try treeHash(source)==changedHash,"source CSS version unchanged by import")
        try fm.removeItem(at:copied)
        try Data("body{color:red}".utf8).write(to:source.appendingPathComponent("css/style.css"))
        let repair=await importer.importWorkshopWeb(source,metadata:metadata("100"))
        check(id(repair)==firstID && store.item(withID:firstID)?.fileExists==true,"missing project repairs original UUID")
        check(store.item(withID:firstID)?.title=="用户自定义名称" && store.item(withID:firstID)?.isFavorite==true,"repair preserves user record state")
        check(try await authorStore.load(itemID:firstID)["caption"] == .string("用户设置") && store.assignedItemID(for:"fixture-display")==firstID,"Web repair preserves per-item author settings and display assignment")
        let repairedRoot=store.item(withID:firstID)!.fileURL.deletingLastPathComponent()
        try fm.removeItem(at:repairedRoot.appendingPathComponent("css/style.css"))
        let partialRepair=await importer.importWorkshopWeb(source,metadata:metadata("100"))
        check(id(partialRepair)==firstID && fm.fileExists(atPath:store.item(withID:firstID)!.fileURL.deletingLastPathComponent().appendingPathComponent("css/style.css").path),"missing resource repairs original UUID even when project.json exists")
        let annotationSource=try project("annotated")
        try Data("managed one".utf8).write(to:annotationSource.appendingPathComponent("glimmer-download.json"))
        let annotationStore=newStore("annotation-library"),annotationImporter=service(annotationStore)
        let annotated=await annotationImporter.importWorkshopWeb(annotationSource,metadata:metadata("200"),managedDownloadRoot:annotationSource)
        let annotatedID=id(annotated)!
        check(annotationStore.item(withID:annotatedID)?.contentFingerprint==(try treeHash(annotationSource,excludingAnnotation:true)),"explicit matching managed root excludes only root annotation from hash")
        try Data("managed changed".utf8).write(to:annotationSource.appendingPathComponent("glimmer-download.json"))
        check(id(await annotationImporter.importWorkshopWeb(annotationSource,metadata:metadata("200"),managedDownloadRoot:annotationSource))==annotatedID,"managed annotation update does not create false content version")
        let external=await annotationImporter.importWorkshopWeb(annotationSource,metadata:metadata("201"))
        check(annotationStore.item(withID:id(external)!)?.contentFingerprint==(try treeHash(annotationSource)),"external Steam source annotation is not globally ignored")
        let mismatch=await annotationImporter.importWorkshopWeb(annotationSource,metadata:metadata("202"),managedDownloadRoot:source)
        check(annotationStore.item(withID:id(mismatch)!)?.contentFingerprint==(try treeHash(annotationSource)),"mismatching explicit managed root cannot suppress annotation")
        let localAnnotated=await annotationImporter.importLocalWebProject(annotationSource)
        check(annotationStore.item(withID:id(localAnnotated)!)?.contentFingerprint==(try treeHash(annotationSource)),"local same-named annotation remains author content")
        try fm.createDirectory(at:annotationSource.appendingPathComponent("nested"),withIntermediateDirectories:false)
        try Data("author nested metadata".utf8).write(to:annotationSource.appendingPathComponent("nested/glimmer-download.json"))
        let nested=await annotationImporter.importWorkshopWeb(annotationSource,metadata:metadata("200"),managedDownloadRoot:annotationSource)
        check(id(nested) != annotatedID,"managed exclusion never suppresses nested author file of same name")
        let blocked=newStore("blocked-library"),blockedImporter=service(blocked)
        let libraryBefore=try LibraryPersistence.makeEncoder().encode(LibraryDocument())
        try libraryBefore.write(to:blocked.storage.libraryFile)
        try fm.removeItem(at:blocked.storage.libraryFile);try fm.createDirectory(at:blocked.storage.libraryFile,withIntermediateDirectories:false)
        check(failed(await blockedImporter.importWorkshopWeb(source,metadata:metadata("300"))),"real library write failure returned as failed")
        check(blocked.items.isEmpty && managedProjects(blocked).isEmpty,"failed save publishes no memory record and cleans only own stage")
        try fm.removeItem(at:blocked.storage.libraryFile);try libraryBefore.write(to:blocked.storage.libraryFile)
        let repairRecordID=id(await blockedImporter.importWorkshopWeb(source,metadata:metadata("300")))!
        let missingRecord=blocked.item(withID:repairRecordID)!
        try fm.removeItem(at:missingRecord.fileURL.deletingLastPathComponent())
        let repairDisk=try Data(contentsOf:blocked.storage.libraryFile)
        try fm.removeItem(at:blocked.storage.libraryFile);try fm.createDirectory(at:blocked.storage.libraryFile,withIntermediateDirectories:false)
        check(failed(await blockedImporter.importWorkshopWeb(source,metadata:metadata("300"))) && blocked.item(withID:repairRecordID)==missingRecord,"repair save failure preserves original missing record atomically")
        check(managedProjects(blocked).isEmpty,"repair save failure cleans new replacement tree only")
        try fm.removeItem(at:blocked.storage.libraryFile);try repairDisk.write(to:blocked.storage.libraryFile)
        let originalRecord=store.item(withID:firstID)!
        let oldDisk=try Data(contentsOf:store.storage.libraryFile)
        try fm.removeItem(at:store.storage.libraryFile);try fm.createDirectory(at:store.storage.libraryFile,withIntermediateDirectories:false)
        var replacement=originalRecord;replacement.title="不可发布的修改"
        do{try store.replacePersistedItem(replacement);check(false,"replace must fail")}
        catch{check(store.item(withID:firstID)==originalRecord,"atomic replace failure leaves memory unchanged")}
        try fm.removeItem(at:store.storage.libraryFile);try oldDisk.write(to:store.storage.libraryFile)
        let unsafe=try project("symlink-source");try fm.createSymbolicLink(at:unsafe.appendingPathComponent("escape.js"),withDestinationURL:source.appendingPathComponent("js/main.js"))
        let unsafeStore=newStore("unsafe-library"),unsafeImporter=service(unsafeStore)
        check(failed(await unsafeImporter.importLocalWebProject(unsafe)) && unsafeStore.items.isEmpty && managedProjects(unsafeStore).isEmpty,"source resource symlink rejects and cleans stage")
        let fifoSource=try project("fifo-source")
        check(mkfifo(fifoSource.appendingPathComponent("resource.bin").path,0o600)==0,"FIFO fixture created")
        check(failed(await unsafeImporter.importLocalWebProject(fifoSource)) && managedProjects(unsafeStore).isEmpty,"source FIFO rejected without blocking")
        let fifoProject=try project("fifo-project");try fm.removeItem(at:fifoProject.appendingPathComponent("project.json"));_ = mkfifo(fifoProject.appendingPathComponent("project.json").path,0o600)
        check(failed(await unsafeImporter.importLocalWebProject(fifoProject)),"FIFO project rejected before descriptor reads")
        let large=try project("large-cancel")
        let largeFile=large.appendingPathComponent("000-large.bin");fm.createFile(atPath:largeFile.path,contents:nil)
        let writer=try FileHandle(forWritingTo:largeFile)
        for _ in 0..<64{try writer.write(contentsOf:Data(repeating:0x4a,count:1_048_576))};try writer.close()
        let cancelled=Task{@MainActor in await unsafeImporter.importWorkshopWeb(large,metadata:metadata("400"))}
        let cancellationDeadline=ContinuousClock.now + .seconds(3)
        while managedProjects(unsafeStore).isEmpty && ContinuousClock.now<cancellationDeadline{await Task.yield()}
        cancelled.cancel()
        check(failed(await cancelled.value) && unsafeStore.items.isEmpty && managedProjects(unsafeStore).isEmpty,"caller cancellation reaches worker and cleans full-tree stage")
        check(fm.fileExists(atPath:largeFile.path),"cancellation retains original source")
        let racing=try project("leaf-race")
        try fm.copyItem(at:largeFile,to:racing.appendingPathComponent("000-large.bin"))
        let raceLeaf=racing.appendingPathComponent("z-last.bin");try Data([1]).write(to:raceLeaf)
        let raceTask=Task{@MainActor in await unsafeImporter.importWorkshopWeb(racing,metadata:metadata("401"))}
        let raceDeadline=ContinuousClock.now + .seconds(3)
        var inventoryFinished=false
        while ContinuousClock.now<raceDeadline {
            if managedProjects(unsafeStore).contains(where:{fm.fileExists(atPath:$0.appendingPathComponent("000-large.bin").path)}){inventoryFinished=true;break}
            await Task.yield()
        }
        check(inventoryFinished,"controlled leaf replacement occurs after file inventory")
        try fm.removeItem(at:raceLeaf);_ = mkfifo(raceLeaf.path,0o600)
        check(failed(await raceTask.value) && unsafeStore.items.isEmpty && managedProjects(unsafeStore).isEmpty,"regular leaf replaced by FIFO cannot hang or publish partial project")
        let video=root.appendingPathComponent("external.mp4")
        try await SyntheticVideoWriter.write(to:video,options:.init(width:32,height:32,frameRate:10,frameCount:5))
        let videoHash=SHA256.hash(data:try Data(contentsOf:video))
        let videoStore=newStore("video-library"),videoImporter=service(videoStore)
        let importedVideo=await videoImporter.importWorkshopVideo(video,metadata:metadata("500"),copyIntoLibrary:true)
        guard let videoID=id(importedVideo),let videoItem=videoStore.item(withID:videoID) else{fatalError("copied video import \(importedVideo)")}
        check(videoItem.source == .steamWorkshop && videoItem.workshopID=="500" && videoItem.fileURL != video,"external Steam video copied with atomic origin")
        check(videoItem.durationSeconds != nil && videoItem.pixelWidth==32,"copied video uses real AVFoundation probe")
        check(try SHA256.hash(data:Data(contentsOf:videoItem.fileURL))==videoHash && SHA256.hash(data:Data(contentsOf:video))==videoHash,"video copy exact, external source unchanged")
        check(VideoLibraryStore(storage:videoStore.storage).item(withID:videoID)?.workshopID=="500","copied video commit persists source immediately")
        videoStore.rename(id:videoID,to:"用户视频名");videoStore.toggleFavorite(id:videoID)
        let videoPreferences=VideoPlaybackPreferences(isMuted:false,volume:0.4,rate:1.5,gravity:.fit)
        videoStore.mutate(id:videoID){$0.videoPlaybackPreferences=videoPreferences};videoStore.flush()
        check(id(await videoImporter.importWorkshopVideo(video,metadata:metadata("500"),copyIntoLibrary:true))==videoID && videoStore.items.count==1,"copied video same source deduplicates UUID")
        check(id(await videoImporter.importWorkshopVideo(video,metadata:metadata("500")))==videoID && videoStore.items.count==1,"old reference API recognizes complete-hash copied UUID")
        try fm.removeItem(at:videoItem.fileURL)
        check(id(await videoImporter.importWorkshopVideo(video,metadata:metadata("500"),copyIntoLibrary:true))==videoID,"missing copied video repairs original UUID")
        check(videoStore.item(withID:videoID)?.title=="用户视频名" && videoStore.item(withID:videoID)?.isFavorite==true,"video repair preserves rename/favorite")
        check(videoStore.item(withID:videoID)?.videoPlaybackPreferences==videoPreferences,"copied-video repair preserves actual per-item playback preferences")
        let failedVideoStore=newStore("failed-video-library"),failedVideoImporter=service(failedVideoStore)
        try fm.createDirectory(at:failedVideoStore.storage.libraryFile,withIntermediateDirectories:false)
        check(failed(await failedVideoImporter.importWorkshopVideo(video,metadata:metadata("502"),copyIntoLibrary:true)) && failedVideoStore.items.isEmpty,"copied video real persistence failure never publishes source stamp")
        check((try fm.contentsOfDirectory(at:failedVideoStore.storage.mediaDirectory,includingPropertiesForKeys:nil)).isEmpty,"failed copied-video commit cleans its owned video only")
        let legacyStore=newStore("legacy-video"),legacyImporter=service(legacyStore)
        let legacy=await legacyImporter.importWorkshopVideo(video,metadata:metadata("501"));let legacyID=id(legacy)!
        legacyStore.flush()
        check(legacyStore.item(withID:legacyID)?.fileURL==video,"old default video API remains reference-compatible")
        check(id(await legacyImporter.importWorkshopVideo(video,metadata:metadata("501"),copyIntoLibrary:true))==legacyID && legacyStore.item(withID:legacyID)?.fileURL != video,"explicit copy upgrades external reference preserving UUID")
        let gate=ProbeGate(),gatedStore=newStore("gate-library")
        let gated=ImportService(store:gatedStore,storage:gatedStore.storage,thumbnailCache:ThumbnailCache(storage:gatedStore.storage),probeOperation:{url in await gate.wait();try Task.checkCancellation();return try await VideoProbe.probe(url:url)})
        let active=Task{@MainActor in await gated.importWorkshopVideo(video,metadata:metadata("600"))}
        while await !gate.entered{await Task.yield()}
        let queued=Task{@MainActor in await gated.importWorkshopWeb(source,metadata:metadata("601"))}
        await Task.yield();queued.cancel();await gate.release()
        _=await active.value
        check(failed(await queued.value) && gatedStore.items.allSatisfy{$0.workshopID != "601"},"cancelled queued Web import never starts or stamps a record")
        check(await counter.count==0,"all Web regression paths remain independent of video probe")
        let evidence:[String:Any] = ["passed":checks.count,"failed":0,"checks":checks,"method":"temporary real tree copies and library writes; real AVFoundation video fixture; no account/network/user library","sourceTreeSHA256":sourceHash,"boundaries":"Web tree copy hashes all files; explicit matching managed root excludes exact root annotation only; runtime HTML execution not performed"]
        if CommandLine.arguments.count>1{try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
        print("PASS \(checks.count) Workshop Web/copied-video import checks; temporary sources only")
    }
}
