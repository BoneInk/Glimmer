import AppKit
import Foundation
import WebKit

@main @MainActor enum AuthorPropertyServicesIntegrationTests {
    static var results: [[String: String]] = []
    static var windows: [NSWindow] = []
    static var hosts: [(WebWallpaperRuntime, UUID, UUID)] = []
    static let service = AuthorPropertyServices.shared
    static func check(_ value: Bool, _ name: String) {
        results.append(["name": name, "result": value ? "PASS" : "FAIL"])
        print("\(value ? "PASS" : "FAIL") \(name)"); fflush(stdout)
    }
    static func js(_ host: WebWallpaperRuntime, _ body: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            host.webView.callAsyncJavaScript("const value=await (async()=>{\(body)})();return String(value);", arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: (value as? String) ?? String(describing: value))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    static func wait(_ name: String, seconds: Double = 10, _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw WebProjectError.invalid("timeout: " + name) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    static func project(at root: URL, listener: Bool = true, firstFails: Bool = false) throws -> WallpaperItem {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = #"{"type":"web","file":"index.html","general":{"properties":{"picture":{"type":"file","fileType":"image","value":""},"random":{"type":"directory","mode":"ondemand","fileType":"image","value":""},"all":{"type":"directory","mode":"fetchall","fileType":"image","value":""},"caption":{"type":"textinput","value":"DEFAULT"}}}}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("project.json"))
        let callbacks = #"""
        window.seen={file:'',random:'',added:{},removed:[],caption:'',count:0};window.hold=false;window.holding=false;window.fail=false;
        window.read=async path=>{const r=await fetch('file:///'+path);if(!r.ok)throw Error('read '+r.status);return await r.text()};
        window.wallpaperPropertyListener={
          applyUserProperties:async p=>{
            window.seen.count++;if(window.firstFails){window.firstFails=false;throw Error('first callback failed')}
            if(window.hold){window.holding=true;await new Promise(r=>window.release=r);window.holding=false}
            if(window.fail)throw Error('controlled host refused');
            if(p.caption)window.seen.caption=p.caption.value;
            if(p.picture){window.seen.file=p.picture.value?await window.read(p.picture.value):'';document.getElementById('picture').src=p.picture.value?'file:///'+p.picture.value:''}
            if(p.random){window.seen.random=p.random.value?await new Promise((resolve,reject)=>window.wallpaperRequestRandomFileForProperty('random',async(k,path)=>{try{resolve(path?await window.read(path):'')}catch(e){reject(e)}})):''}
          },
          userDirectoryFilesAddedOrChanged:async(k,files)=>{for(const path of files)window.seen.added[path]=await window.read(path)},
          userDirectoryFilesRemoved:async(k,files)=>{window.seen.removed.push(...files);for(const path of files)delete window.seen.added[path]}
        };
        """#
        let html = "<html><body><img id='picture'><script>window.firstFails=\(firstFails ? "true" : "false");\(listener ? callbacks : "window.noListener=true;")</script></body></html>"
        try Data(html.utf8).write(to: root.appendingPathComponent("index.html"))
        return WallpaperItem(title: "隔离作者资源 fixture", filePath: root.appendingPathComponent("project.json").path, contentKind: .web)
    }
    static func makeHost(_ item: WallpaperItem, storage: AppStorage, failingInitial: Bool = false, expectsListener: Bool = true) async throws -> WebWallpaperRuntime {
        let config = try await AuthorPropertyServices.configuration(item: item, storage: storage)
        let runtime = try WebWallpaperRuntime(projectURL: item.fileURL, entryURL: item.fileURL.deletingLastPathComponent().appendingPathComponent("index.html"), propertiesJSON: config.payload)
        try runtime.configureResourceManifest(config.manifest)
        let token = service.register(runtime, itemID: item.id)
        hosts.append((runtime,item.id,token))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 220, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "作者资源隔离测试素材"
        window.contentView = runtime.webView; window.orderFrontRegardless(); windows.append(window)
        runtime.load()
        try await wait("document loaded") { runtime.state == .ready || runtime.state == .waitingForListener || runtime.state == .failed }
        if !failingInitial && expectsListener { try await wait("authored listener capability") { runtime.canApplyUserProperties || runtime.state == .waitingForListener } }
        return runtime
    }
    static func close(_ host: WebWallpaperRuntime) {
        if let entry = hosts.first(where: { $0.0 === host }) { service.unregister(itemID: entry.1, token: entry.2) }
        host.dispose()
        hosts.removeAll { $0.0 === host }
    }
    static func svg(_ color: String) -> Data { Data("<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'><rect width='4' height='4' fill='\(color)'/></svg>".utf8) }
    static func run(root: URL) async throws {
        let fm = FileManager.default
        let storage = AppStorage(root: root.appendingPathComponent("temporary-library"))
        let item = try Self.project(at: root.appendingPathComponent("source-project"))
        let project = try AuthorPropertyServices.project(for: item)!
        let sourceJSON = try Data(contentsOf: item.fileURL)
        let selected = root.appendingPathComponent("chosen.svg"), replacement = root.appendingPathComponent("replacement.svg")
        try svg("red").write(to: selected); try svg("blue").write(to: replacement)
        let demand = root.appendingPathComponent("ondemand"), all = root.appendingPathComponent("fetchall")
        try fm.createDirectory(at: demand, withIntermediateDirectories: true); try fm.createDirectory(at: all, withIntermediateDirectories: true)
        try svg("orange").write(to: demand.appendingPathComponent("one.svg"))
        try svg("purple").write(to: all.appendingPathComponent("one.svg"))
        let hostA = try await makeHost(item, storage: storage), hostB = try await makeHost(item, storage: storage)
        check(service.readyHosts(itemID: item.id).count == 2, "two actual WKWebView hosts registered for same item")
        check(service.editableKeys(project: project, itemID: item.id).isSuperset(of: ["picture","random","all","caption"]), "actual observed callbacks enable scalar/file/ondemand/fetchall")
        func perform(_ key: String, _ operation: AuthorPropertyResourceOperation) async throws {
            try await service.performResource(.init(itemID: item.id, project: project, definition: project.definition(for: key)!, operation: operation), storage: storage)
        }
        _ = try await js(hostB,"window.hold=true; return true")
        var completed = false
        let selection = Task { @MainActor in try await perform("picture",.select(selected)); completed=true }
        try await wait("second host callback held") { try await js(hostB,"return window.holding") == "true" }
        check(!completed, "performResource waits for second actual host ACK")
        _ = try await js(hostB,"window.hold=false;if(window.release)window.release();return true")
        try await selection.value
        check(try await js(hostA,"return window.seen.file.includes(\"fill='red'\")") == "true", "file virtual value read by actual first page")
        check(try await js(hostB,"return window.seen.file.includes(\"fill='red'\")") == "true", "file read and acknowledged by actual second page")
        do {
            try await wait("real selected SVG decodes",seconds:3) { try await js(hostA,"return document.getElementById('picture').naturalWidth===4") == "true" }
            check(true,"actual selected SVG decodes through granted resource URL")
        } catch { check(false,"actual selected SVG decodes through granted resource URL: \(try await js(hostA,"return document.getElementById('picture').src"))") }
        try await perform("random",.select(demand))
        check(try await js(hostA,"return window.seen.random.includes(\"fill='orange'\")") == "true", "ondemand callback returns real readable file")
        try await perform("all",.select(all))
        check(try await js(hostA,"return Object.values(window.seen.added).some(x=>x.includes(\"fill='purple'\"))") == "true", "fetchall added event reads actual resource bytes")
        check(try await js(hostB,"return Object.keys(window.seen.added).length") == "1", "fetchall ACK reaches both live hosts")
        let oldGrant = try await service.assets(storage: storage).grants(itemID: item.id).first { $0.propertyKey == "picture" }!
        _ = try await js(hostB,"window.fail=true;return true")
        do { try await perform("picture",.select(replacement)); check(false,"host refusal must throw") }
        catch let error as AuthorPropertyResourceFailure { check(error.persisted,"host refusal reports saved but not applied") }
        check(fm.fileExists(atPath: oldGrant.assets[0].url.path),"failed multi-host ACK retains old immutable resource version")
        check(service.editableKeys(project: project, itemID: item.id).contains("picture"),"failed host remains editable for correction")
        _ = try await js(hostB,"window.fail=false;return true")
        try await service.applySavedSettings(project: project,itemID: item.id,storage: storage)
        check(try await js(hostB,"return window.seen.file.includes(\"fill='blue'\")") == "true","applySavedSettings repairs failed host with saved grant")
        func eventCheck(_ name: String, _ condition: @MainActor () async throws -> Bool) async {
            do { try await wait(name,seconds:12,condition);check(true,name) }
            catch {
                let observed = (try? await js(hostA,"return JSON.stringify(window.seen)")) ?? "unreadable page"
                check(false,"\(name): \(error.localizedDescription); service=\(service.resourceErrors[item.id] ?? "none"); host=\(hostA.state.rawValue)/\(hostA.lastError ?? "none"); seen=\(observed)")
            }
        }
        let priorRandomRevision = try await service.assets(storage:storage).grants(itemID:item.id).first { $0.propertyKey == "random" }!.revision
        try svg("green").write(to: demand.appendingPathComponent("one.svg"),options:.atomic)
        await eventCheck("real FSEvents updates ondemand bytes available to next authored request") {
            let current = try await service.assets(storage:storage).grants(itemID:item.id).first { $0.propertyKey == "random" }
            guard current?.revision != priorRandomRevision else { return false }
            return try await js(hostA,"return await new Promise((resolve,reject)=>wallpaperRequestRandomFileForProperty('random',async(k,path)=>{try{resolve((await window.read(path)).includes(\"fill='green'\"))}catch(e){reject(e)}}))") == "true"
        }
        try svg("yellow").write(to: all.appendingPathComponent("two.svg"),options:.atomic)
        await eventCheck("real FSEvents dispatches fetchall added content to second host") { try await js(hostB,"return Object.values(window.seen.added).some(x=>x.includes(\"fill='yellow'\"))") == "true" }
        try fm.removeItem(at:all.appendingPathComponent("one.svg"))
        await eventCheck("real FSEvents dispatches fetchall removals") { try await js(hostA,"return window.seen.removed.length>0 && !Object.values(window.seen.added).some(x=>x.includes(\"fill='purple'\"))") == "true" }
        let orphan = try Self.project(at:root.appendingPathComponent("unmatched-project"))
        let orphanProject = try AuthorPropertyServices.project(for:orphan)!
        let orphanGrant = try await service.assets(storage:storage).selectFile(selected,itemID:orphan.id,propertyKey:"picture",project:orphanProject)
        var configuration = try await AuthorPropertyServices.configuration(item:orphan,storage:storage)
        check(configuration.manifest.assets.isEmpty,"native grant without persisted matching override excluded from manifest")
        try await service.store(storage:storage).set(.string("__gw_assets__/different/resource.svg"),for:"picture",itemID:orphan.id,project:orphanProject)
        configuration = try await AuthorPropertyServices.configuration(item:orphan,storage:storage)
        check(configuration.manifest.assets.isEmpty,"mismatched persisted virtual value excluded from manifest")
        try await service.store(storage:storage).set(orphanGrant.value,for:"picture",itemID:orphan.id,project:orphanProject)
        configuration = try await AuthorPropertyServices.configuration(item:orphan,storage:storage)
        check(configuration.manifest.assets.count == 1,"only explicit matching override activates native grant")
        do { try hostA.configureResourceManifest(configuration.manifest);check(false,"cross-item manifest must reject") }
        catch { check(true,"live runtime rejects other item manifest") }
        let absent = try Self.project(at:root.appendingPathComponent("no-listener"),listener:false)
        let absentHost = try await makeHost(absent,storage:storage,expectsListener:false)
        let absentProject = try AuthorPropertyServices.project(for:absent)!
        check(service.editableKeys(project:absentProject,itemID:absent.id).isEmpty,"no listener does not falsely enable controls")
        do { try await service.applySavedSettings(project:absentProject,itemID:absent.id,storage:storage);check(false,"no listener cannot ACK") }
        catch { check(true,"no listener throws rather than false success") }
        close(absentHost)
        let failedItem = try Self.project(at:root.appendingPathComponent("first-fails"),firstFails:true)
        let failedHost = try await makeHost(failedItem,storage:storage,failingInitial:true)
        try await wait("first callback failure") { failedHost.state == .failed }
        let failedProject = try AuthorPropertyServices.project(for:failedItem)!
        check(service.editableKeys(project:failedProject,itemID:failedItem.id).contains("caption"),"first authored callback failure retains observed editable capability")
        try await service.store(storage:storage).set(.string("REPAIRED"),for:"caption",itemID:failedItem.id,project:failedProject)
        try await service.applySavedSettings(project:failedProject,itemID:failedItem.id,storage:storage)
        check(try await js(failedHost,"return window.seen.caption") == "REPAIRED","new value repairs first callback failure without reload")
        close(failedHost)
        close(hostA)
        check(service.readyHosts(itemID:item.id).count == 1,"closing one host keeps shared source monitor consumer")
        close(hostB)
        let grantsBefore = try await service.assets(storage:storage).grants(itemID:item.id)
        try svg("black").write(to:demand.appendingPathComponent("one.svg"),options:.atomic)
        try await Task.sleep(for:.seconds(2))
        check(try await service.assets(storage:storage).grants(itemID:item.id) == grantsBefore,"closing last host stops automatic source refresh")
        check(service.readyHosts(itemID:item.id).isEmpty,"last host closes with no live runtime")
        check(try Data(contentsOf:item.fileURL) == sourceJSON,"source project never rewritten")
        check(!fm.fileExists(atPath:storage.root.appendingPathComponent("library.json").path),"test author settings never create production/library assignments")
    }
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("GWAuthorServices-\(UUID())")
            do { try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try await run(root:root) }
            catch { check(false,"uncaught integration failure: \(error.localizedDescription)") }
            for entry in hosts { service.unregister(itemID:entry.1,token:entry.2);entry.0.dispose() }
            hosts.removeAll();windows.forEach{$0.orderOut(nil)};windows.removeAll()
            try? FileManager.default.removeItem(at:root)
            let failures=results.filter{$0["result"] == "FAIL"}.count
            let evidence:[String:Any] = ["results":results,"passed":results.count-failures,"failed":failures,"method":"real visible WKWebView + actual temporary AuthorServices/asset store/FSEvents; no production data, network, account, desktop/lockscreen changes","cleanup":"own UUID root removed and all review hosts disposed"]
            if CommandLine.arguments.count>1,let bytes=try? JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]) { try? bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
            print("AuthorPropertyServicesIntegrationTests: \(results.count-failures) passed; \(failures) failed")
            fflush(stdout);exit(failures == 0 ? 0:1)
        }
        app.run()
    }
}
