import CryptoKit
import Darwin
import Foundation

@main struct SteamLibraryScannerTests {
    static func main() async throws {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { precondition(value,"FAIL: "+name);checks.append(name) }
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("GWSteamScan-\(UUID())")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        func directory(_ path: String) throws -> URL {
            let url=root.appendingPathComponent(path);try fm.createDirectory(at:url,withIntermediateDirectories:true);return url
        }
        @discardableResult func item(_ content: URL, _ id: String, type: String="video", file: String="clip.mp4", title: String?=nil, createEntry: Bool=true) throws -> URL {
            let url=content.appendingPathComponent(id);try fm.createDirectory(at:url,withIntermediateDirectories:true)
            let object:[String:Any] = ["type":type,"file":file,"title":title ?? "Fixture \(id)"]
            try JSONSerialization.data(withJSONObject:object).write(to:url.appendingPathComponent("project.json"))
            if createEntry { let entry=url.appendingPathComponent(file);try fm.createDirectory(at:entry.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("not media-validated; scan only".utf8).write(to:entry) }
            return url
        }
        func snapshot() throws -> String {
            var records:[String]=[]
            let iterator=fm.enumerator(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey],options:[])!
            while let url=iterator.nextObject() as? URL {
                let relative=String(url.path.dropFirst(root.path.count))
                var info=stat();guard lstat(url.path,&info)==0 else { throw CocoaError(.fileReadUnknown) }
                let kind=info.st_mode & mode_t(S_IFMT)
                if kind==mode_t(S_IFLNK) { iterator.skipDescendants();records.append(relative+" link:"+(try fm.destinationOfSymbolicLink(atPath:url.path))) }
                else if kind==mode_t(S_IFREG) { records.append(relative+" file:"+SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()) }
                else { records.append(relative+" type:\(kind) mode:\(info.st_mode)") }
            }
            return SHA256.hash(data:Data(records.sorted().joined(separator:"\n").utf8)).map{String(format:"%02x",$0)}.joined()
        }
        let libraryA=try directory("LibraryA"),libraryB=try directory("LibraryB")
        let contentA=try directory("LibraryA/steamapps/workshop/content/431960")
        let contentB=try directory("LibraryB/workshop/content/431960")
        try item(contentA,"10",title:"视频标题")
        try item(contentA,"2",type:"web",file:"pages/index.html")
        try item(contentA,"3",type:"scene",file:"scene.pkg")
        try item(contentA,"4",type:"application",file:"app.exe")
        try item(contentA,"5",type:"noveltype",file:"asset.bin")
        try item(contentA,"6",createEntry:false)
        let broken=try item(contentA,"7");try Data("bad json".utf8).write(to:broken.appendingPathComponent("project.json"))
        let symlinkDir=contentA.appendingPathComponent("8");try fm.createSymbolicLink(at:symlinkDir,withDestinationURL:contentB)
        let symlinkJSON=try item(contentA,"9");try fm.removeItem(at:symlinkJSON.appendingPathComponent("project.json"));try fm.createSymbolicLink(at:symlinkJSON.appendingPathComponent("project.json"),withDestinationURL:contentA.appendingPathComponent("10/project.json"))
        let symlinkEntry=try item(contentA,"11");try fm.removeItem(at:symlinkEntry.appendingPathComponent("clip.mp4"));try fm.createSymbolicLink(at:symlinkEntry.appendingPathComponent("clip.mp4"),withDestinationURL:contentA.appendingPathComponent("10/clip.mp4"))
        try item(contentA,"12",file:"../outside.mp4",createEntry:false)
        try item(contentA,"13",file:"/etc/passwd",createEntry:false)
        try item(contentA,"14",file:"C:\\outside.mp4",createEntry:false)
        try item(contentA,"15",file:"missing/clip.mp4",createEntry:false)
        let nestedLink=try item(contentA,"16",file:"linked/clip.mp4",createEntry:false);try fm.createSymbolicLink(at:nestedLink.appendingPathComponent("linked"),withDestinationURL:contentA.appendingPathComponent("10"))
        let missingProject=contentA.appendingPathComponent("17");try fm.createDirectory(at:missingProject,withIntermediateDirectories:false)
        let huge=try item(contentA,"18");try Data(repeating:32,count:2*1024*1024+1).write(to:huge.appendingPathComponent("project.json"))
        let fifo=try item(contentA,"19");try fm.removeItem(at:fifo.appendingPathComponent("project.json"));check(mkfifo(fifo.appendingPathComponent("project.json").path,0o600)==0,"fixture FIFO created without scanner opening it")
        let fifoEntry=try item(contentA,"20");try fm.removeItem(at:fifoEntry.appendingPathComponent("clip.mp4"));check(mkfifo(fifoEntry.appendingPathComponent("clip.mp4").path,0o600)==0,"fixture special entry created")
        try item(contentA,"21",title:String(repeating:"长",count:2000))
        try item(contentA,"00123")
        try item(contentB,"10",title:"另一库相同 ID")
        try item(contentA,"not-a-numeric-ID")
        try Data("numeric plain file".utf8).write(to:contentA.appendingPathComponent("22"))
        let linkedRoot=root.appendingPathComponent("LinkedLibrary");try fm.createSymbolicLink(at:linkedRoot,withDestinationURL:libraryA)
        let linkedCandidate=try directory("CandidateLink/steamapps/workshop/content")
        try fm.createSymbolicLink(at:linkedCandidate.appendingPathComponent("431960"),withDestinationURL:contentA)
        let fifoParent=try directory("CandidateFIFO/steamapps")
        check(mkfifo(fifoParent.appendingPathComponent("workshop").path,0o600)==0,"fixture non-directory candidate created")
        let before=try snapshot()
        let scanner=SteamLibraryScanner()
        let a=try await scanner.scan(selectedRoot:libraryA)
        func found(_ id:String)->SteamLibraryScannedItem { a.items.first{$0.workshopID==id}! }
        check(a.contentRoots.count==1 && a.items.count==22,"standard Steam library scans numeric entries only")
        check(found("10").title=="视频标题" && found("10").kind == .video,"bounded project type/title classified")
        check(found("10").isImportCandidate && found("10").availability == .readyForValidation,"video is candidate only, not claimed playable")
        check(found("2").kind == .web && found("2").entryURL?.lastPathComponent=="index.html" && found("2").isImportCandidate,"nested local Web entry recognized")
        check(found("3").kind == .scene && found("3").isImportCandidate && found("3").availability == .readyForValidation && found("3").diagnostics.contains { $0.code == .validationRequired },"Scene discovered as candidate with mandatory subset validation")
        check(found("4").kind == .application && !found("4").isImportCandidate,"application classified unsupported")
        check(found("5").kind == .unknown && !found("5").isImportCandidate,"unknown type retained unsupported")
        check(found("6").availability == .missingEntry,"missing media reported")
        check(found("7").availability == .invalidProject,"corrupt JSON reported")
        check(found("8").availability == .rejectedSymlink,"numeric symlink directory not followed")
        check(found("9").availability == .rejectedSymlink,"symlink project not read")
        check(found("11").availability == .rejectedSymlink,"symlink entry rejected even within source library")
        for id in ["12","13","14"] { check(found(id).diagnostics.contains{$0.code == .invalidEntry} && !found(id).isImportCandidate,"entry escape rejected \(id)") }
        check(found("15").availability == .missingEntry,"missing entry subdirectory reported")
        check(found("16").availability == .rejectedSymlink,"intermediate entry directory symlink rejected")
        check(found("17").diagnostics.contains{$0.code == .missingProject},"absent project clear diagnostic")
        check(found("18").availability == .limitExceeded,"oversized JSON bounded before reading")
        check(found("19").availability == .invalidProject,"FIFO project rejected without blocking")
        check(!found("20").isImportCandidate,"special media entry rejected")
        check(found("21").title.count==1024 && found("21").diagnostics.contains{$0.code == .limitExceeded},"title display bound reported")
        check(found("123").itemRoot.lastPathComponent=="00123","numeric ID normalized while exact source path retained")
        check(found("22").diagnostics.contains{$0.code == .unreadable},"numeric plain file is not traversed as directory")
        check(a.diagnostics.contains{$0.code == .ignoredEntries},"nonnumeric entries aggregate diagnostic")
        check(a.items.first?.workshopID=="2","numeric rather than lexical stable ordering")
        let b=try await scanner.scan(selectedRoot:libraryB)
        check(b.items.count==1 && b.items[0].workshopID=="10","alternate workshop/content root supported")
        check(b.items[0].id != found("10").id,"same Workshop ID across libraries remains distinct source")
        let direct=try await scanner.scan(selectedRoot:contentB)
        check(direct.items.map(\.id)==b.items.map(\.id),"direct 431960 selection supported")
        let notSelected=try await scanner.scan(selectedRoot:root)
        check(notSelected.items.isEmpty && notSelected.diagnostics.contains{$0.code == .contentNotFound},"scanner does not recursively discover arbitrary unselected libraries")
        let link=try await scanner.scan(selectedRoot:linkedRoot)
        check(link.items.isEmpty && link.diagnostics.contains{$0.code == .rejectedSymlink},"selected symlink root rejected")
        let parentLink=try await scanner.scan(selectedRoot:linkedRoot.appendingPathComponent("steamapps"))
        check(parentLink.items.isEmpty && parentLink.diagnostics.contains{$0.code == .rejectedSymlink},"selected root ancestor symlink rejected")
        let candidateLink=try await scanner.scan(selectedRoot:root.appendingPathComponent("CandidateLink"))
        check(candidateLink.items.isEmpty && candidateLink.diagnostics.contains{$0.code == .rejectedSymlink},"content candidate symlink not expanded")
        let candidateFIFO=try await scanner.scan(selectedRoot:root.appendingPathComponent("CandidateFIFO"))
        check(candidateFIFO.items.isEmpty && candidateFIFO.diagnostics.contains{$0.code == .unreadable},"non-directory candidate cannot block traversal")
        let missing=try await scanner.scan(selectedRoot:root.appendingPathComponent("missing"))
        check(missing.items.isEmpty && missing.diagnostics.contains{$0.code == .invalidSelectedRoot},"missing selection reported")
        let remote=try await scanner.scan(selectedRoot:URL(string:"https://example.invalid/Steam")!)
        check(remote.items.isEmpty,"remote URLs never opened")
        let small=SteamLibraryScanner(limits:.init(maximumItems:2))
        let limited=try await small.scan(selectedRoot:libraryA)
        check(limited.items.count==2 && limited.wasTruncated && limited.diagnostics.contains{$0.code == .limitExceeded},"item limit explicit partial report")
        let directoryLimited=try await SteamLibraryScanner(limits:.init(maximumDirectoryEntries:1)).scan(selectedRoot:libraryA)
        check(directoryLimited.items.count<=1 && directoryLimited.wasTruncated,"directory enumeration bounded before reading all entries")
        let bytesLimited=try await SteamLibraryScanner(limits:.init(maximumProjectBytes:1)).scan(selectedRoot:contentB)
        check(bytesLimited.items.first?.availability == .limitExceeded,"custom JSON byte cap honored")
        let cancelled=Task { try await scanner.scan(selectedRoot:libraryA) };cancelled.cancel()
        do { _=try await cancelled.value;check(false,"cancelled scan must stop") } catch is CancellationError { check(true,"cancellation checked without modifying source") }
        let after=try snapshot()
        check(before==after,"entire self-owned source tree SHA256 unchanged across all scans")
        let evidence:[String:Any] = ["passed":checks.count,"failed":0,"checks":checks,"sourceTreeSHA256Before":before,"sourceTreeSHA256After":after,"boundary":"Synthetic temp Steam libraries only; no login/network/Steam edits/copy/import; candidate is not runtime validation"]
        if CommandLine.arguments.count>1 { try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        print("PASS \(checks.count) Steam library read-only scanner checks; source tree SHA256 unchanged")
    }
}
