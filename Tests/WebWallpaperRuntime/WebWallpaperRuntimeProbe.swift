import AppKit
import Foundation
import WebKit
import AVFoundation
import CryptoKit

private struct ProbeResult<Value>: @unchecked Sendable { let value: Result<Value, Error> }

@MainActor
final class WebProbeDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var runtime: WebWallpaperRuntime!
    var checks: [String] = []
    var output: URL!
    let fixture: URL
    init(fixture: URL, output: URL) { self.fixture = fixture; self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); finish(success: true) }
            catch { finish(success: false, error: error.localizedDescription) }
        }
    }
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw WebWallpaperFailure(message: "FAILED: " + name + " runtime=" + String(describing: runtime?.state) + " error=" + (runtime?.lastError ?? "none")) }
        checks.append(name)
    }
    func js(_ script: String) async throws -> Any? {
        let result: ProbeResult<Any?> = await withCheckedContinuation { continuation in
            runtime.webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(returning: ProbeResult(value: .failure(error))) }
                else { continuation.resume(returning: ProbeResult(value: .success(value))) }
            }
        }
        return try result.value.get()
    }
    func wait(_ script: String, timeout: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await js(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw WebWallpaperFailure(message: "Timed out: " + script + " state=" + runtime.state.rawValue + " error=" + (runtime.lastError ?? "none"))
    }
    func waitForReady() async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if runtime.state == .ready || runtime.state == .paused { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw WebWallpaperFailure(message: "Runtime did not become ready: " + (runtime.lastError ?? runtime.state.rawValue))
    }
    func payload(text: String = "hello", slider: Double = 12, color: String = "1 0 0") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "enabled": ["type":"bool","value":true], "color":["type":"color","value":color],
            "slider":["type":"slider","value":slider], "combo":["type":"combo","value":"choice-b"],
            "text":["type":"textinput","value":text], "files":["type":"file","value":"/not-accessed"]
        ])
    }
    func resourceTests() async throws {
        let root = fixture.deletingLastPathComponent().appendingPathComponent("grants",isDirectory:true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        func asset(_ name:String,_ color:String) throws -> WebWallpaperGrantedAsset {
            let url=root.appendingPathComponent(name), bytes=Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\"><rect width=\"40\" height=\"40\" fill=\"\(color)\"/></svg>".utf8)
            try bytes.write(to:url)
            return WebWallpaperGrantedAsset(token:UUID().uuidString,url:url,name:name,contentIdentity:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
        }
        let red=try asset("red.svg","red"), green=try asset("green image.svg","lime"), id=UUID(), directoryToken=UUID().uuidString
        let movieURL=root.appendingPathComponent("granted.mp4")
        try FileManager.default.copyItem(at:fixture.appendingPathComponent("silent.mp4"),to:movieURL)
        let movie=WebWallpaperGrantedAsset(token:UUID().uuidString,url:movieURL,name:"granted.mp4",contentIdentity:SHA256.hash(data:try Data(contentsOf:movieURL)).map{String(format:"%02x",$0)}.joined())
        func manifest(_ members:[WebWallpaperGrantedAsset], revision:String="one") -> WebWallpaperResourceManifest {
            WebWallpaperResourceManifest(itemID:id,rootURL:root,assets:[red,green,movie],directories:[
                WebWallpaperGrantedDirectory(propertyKey:"all",mode:.fetchall,assets:members,revision:revision,virtualPath:"__gw_assets__/"+directoryToken),
                WebWallpaperGrantedDirectory(propertyKey:"random",mode:.ondemand,assets:members,revision:revision,virtualPath:"__gw_assets__/"+UUID().uuidString)
            ])
        }
        func filePayload(_ file:WebWallpaperGrantedAsset) throws -> Data {
            try JSONSerialization.data(withJSONObject:["picture":["type":"file","value":file.virtualPath],"all":["type":"directory","mode":"fetchall","value":"__gw_assets__/"+directoryToken]])
        }
        runtime=try WebWallpaperRuntime(projectURL:fixture.appendingPathComponent("project.json"),entryURL:fixture.appendingPathComponent("assets.html"),propertiesJSON:Data("{}".utf8))
        try runtime.configureResourceManifest(manifest([red]))
        window.contentView=runtime.webView
        runtime.load();try await waitForReady()
        try await runtime.applyPropertiesAndWait(filePayload(red))
        try await wait("document.getElementById('granted').complete && document.getElementById('granted').naturalWidth===40")
        try check((try await js("fetched.includes('fill=\"red\"') && document.getElementById('granted').src.startsWith('gw-wallpaper://project/__gw_grants__/') && getComputedStyle(document.getElementById('background')).backgroundImage.includes('gw-wallpaper://project/__gw_grants__/')")) as? Bool == true,"granted file:/// img CSS and fetch use only exact same-origin grant mapping")
        try check((try await js("added.length===1 && added[0].key==='all' && added[0].paths.length===1 && !assetCalls.some(x=>x.all)")) as? Bool == true,"fetchall initial files use directory callback rather than scalar callback")
        let previouslyReadRedURL = (try await js("document.getElementById('granted').src")) as? String ?? ""
        try await runtime.applyPropertiesAndWait(filePayload(green))
        try await wait("document.getElementById('granted').complete && document.getElementById('granted').src.includes('green')")
        try check((try await js("fetched.includes('fill=\"lime\"') && getComputedStyle(document.getElementById('background')).backgroundImage.includes('green%20image.svg')")) as? Bool == true,"file selection switches real fetched image and CSS including spaces in filename")
        try await Task.sleep(for:.milliseconds(150))
        let grantImage: ProbeResult<NSImage> = await withCheckedContinuation { continuation in
            runtime.webView.takeSnapshot(with:nil) { image,error in
                if let image {continuation.resume(returning:ProbeResult(value:.success(image)))}
                else {continuation.resume(returning:ProbeResult(value:.failure(error ?? WebWallpaperFailure(message:"Grant snapshot missing"))))}
            }
        }
        guard let tiff=try grantImage.value.get().tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let pixel=bitmap.colorAt(x:bitmap.pixelsWide/8,y:bitmap.pixelsHigh/8)?.usingColorSpace(.sRGB) else {throw WebWallpaperFailure(message:"Grant pixels missing")}
        try check(pixel.greenComponent > 0.8 && pixel.redComponent < 0.3,"real WebKit pixels reflect switched granted green image")
        let movieLiteral=String(decoding:try JSONSerialization.data(withJSONObject:"file:///"+movie.virtualPath,options:.fragmentsAllowed),as:UTF8.self)
        _ = try await js("window.grantVideo=document.createElement('video');grantVideo.muted=true;grantVideo.loop=true;grantVideo.style.cssText='width:16px;height:16px';grantVideo.src=\(movieLiteral);document.body.appendChild(grantVideo);window.grantPlay='pending';grantVideo.play().then(()=>window.grantPlay='played').catch(e=>window.grantPlay=e.name);void 0")
        try await wait("grantPlay==='played' && grantVideo.currentTime>0.1")
        try check((try await js("grantVideo.videoWidth===32 && grantVideo.src.startsWith('gw-wallpaper://project/__gw_grants__/')")) as? Bool == true,"granted file:/// H264 media is decoded by real WebKit")
        try await runtime.configureResourceManifestAndWait(manifest([green],revision:"two"))
        try check((try await js("added.length===2 && removed.length===1 && files.length===1 && files[0].includes('green image.svg')")) as? Bool == true,"fetchall update acknowledges real added and removed authored callbacks")
        _ = try await js("window.randomResult=null;wallpaperRequestRandomFileForProperty('random',(key,path)=>window.randomResult={key,path});void 0")
        try await wait("randomResult!==null")
        try check((try await js("randomResult.key==='random' && randomResult.path.includes('green image.svg')")) as? Bool == true,"ondemand callback returns only currently granted directory member")
        let revoked = WebWallpaperResourceManifest(itemID:id,rootURL:root,assets:[green,movie],directories:[])
        try await runtime.configureResourceManifestAndWait(revoked)
        let redLiteral=String(decoding:try JSONSerialization.data(withJSONObject:previouslyReadRedURL,options:.fragmentsAllowed),as:UTF8.self)
        _ = try await js("window.revokedBlocked=false;fetch(\(redLiteral)).then(r=>r.text()).then(x=>window.revokedLeak=x).catch(()=>window.revokedBlocked=true);void 0")
        try await wait("revokedBlocked")
        try check((try await js("typeof revokedLeak==='undefined'")) as? Bool == true,"revoked asset cannot be fetched from an earlier successful read or cache")
        let race=try asset("race.svg","blue")
        try runtime.configureResourceManifest(WebWallpaperResourceManifest(itemID:id,rootURL:root,assets:[green,movie,race],directories:[]))
        try FileManager.default.removeItem(at:race.url)
        try FileManager.default.createSymbolicLink(at:race.url,withDestinationURL:fixture.deletingLastPathComponent().appendingPathComponent("secret.txt"))
        let raceLiteral=String(decoding:try JSONSerialization.data(withJSONObject:"file:///"+race.virtualPath,options:.fragmentsAllowed),as:UTF8.self)
        _ = try await js("window.raceBlocked=false;fetch(\(raceLiteral)).then(r=>r.text()).then(x=>window.raceLeak=x).catch(()=>window.raceBlocked=true);void 0")
        try await wait("raceBlocked")
        try check((try await js("typeof raceLeak==='undefined'")) as? Bool == true,"post-authorization symlink replacement cannot bypass no-follow grant reads")
        _ = try await js("window.throwDirectory=true;void 0")
        do {try await runtime.configureResourceManifestAndWait(manifest([red],revision:"three"));throw WebWallpaperFailure(message:"directory throw acknowledged")}
        catch {try check(error.localizedDescription.contains("DIRECTORY_FAILURE"),"directory callback exception rejects separate resource acknowledgement")}
        _ = try await js("window.throwDirectory=false;void 0")
        try await runtime.configureResourceManifestAndWait(manifest([green],revision:"four"))
        _ = try await js("window.guessBlocked=false;fetch(document.getElementById('granted').src.replace(/__gw_assets__\\/[^/]+\\//,'__gw_assets__/AAAAAAAAAAAAAAAA/')).then(r=>r.text()).then(x=>window.guessLeak=x).catch(()=>window.guessBlocked=true);void 0")
        try await wait("guessBlocked")
        try check((try await js("typeof guessLeak==='undefined'")) as? Bool == true,"known document nonce does not grant guessed asset tokens")
        let oldURL=(try await js("document.getElementById('granted').src")) as? String ?? ""
        runtime.reload();try await waitForReady()
        let literal=String(decoding:try JSONSerialization.data(withJSONObject:oldURL,options:.fragmentsAllowed),as:UTF8.self)
        _ = try await js("window.oldGrantBlocked=false;fetch(\(literal)).then(r=>r.text()).then(x=>window.oldGrantLeak=x).catch(()=>window.oldGrantBlocked=true);void 0")
        try await wait("oldGrantBlocked")
        try check((try await js("typeof oldGrantLeak==='undefined'")) as? Bool == true,"reload rotates grant namespace and denies stale document asset URLs")
        do {try runtime.configureResourceManifest(WebWallpaperResourceManifest(itemID:UUID(),rootURL:root,assets:[red],directories:[]));throw WebWallpaperFailure(message:"cross item accepted")}
        catch {try check(error.localizedDescription.contains("different wallpaper"),"runtime rejects a different item's resource manifest")}
        let link=root.appendingPathComponent("symlink.svg");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:red.url)
        let unsafe=WebWallpaperGrantedAsset(token:UUID().uuidString,url:link,name:"symlink.svg",contentIdentity:red.contentIdentity)
        do {try runtime.configureResourceManifest(WebWallpaperResourceManifest(itemID:id,rootURL:root,assets:[unsafe],directories:[]));throw WebWallpaperFailure(message:"symlink accepted")}
        catch {try check(error.localizedDescription.contains("unsafe"),"resource manifest rejects symlink grants")}
        runtime.dispose()
        runtime=try WebWallpaperRuntime(projectURL:fixture.appendingPathComponent("project.json"),entryURL:fixture.appendingPathComponent("plain.html"),propertiesJSON:Data("{}".utf8))
        window.contentView=runtime.webView;runtime.load();try await waitForReady()
        try check(!runtime.canApplyUserProperties && !runtime.canApplyDirectoryProperties,"listener-less HTML becomes ready without falsely advertising authored property support")
        do {try await runtime.applyPropertiesAndWait(payload(),timeout:0.15);throw WebWallpaperFailure(message:"listenerless scalar ack")}
        catch {try check(error.localizedDescription.contains("timed out"),"listener-less page never falsely acknowledges property consumption")}
        runtime.dispose();runtime=nil
    }

    func actualAssetStoreTests() async throws {
        let base=fixture.deletingLastPathComponent(), source=base.appendingPathComponent("source.svg")
        let bytes=Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"57\" height=\"43\"><rect width=\"57\" height=\"43\" fill=\"lime\"/></svg>".utf8)
        try bytes.write(to:source)
        let project=try AuthorPropertyProject.parse(data:Data(#"{"type":"web","general":{"properties":{"picture":{"type":"file","value":"","fileType":"image"}}}}"#.utf8),projectURL:fixture.appendingPathComponent("project.json"))
        let assets=AuthorPropertyAssetStore(directory:base.appendingPathComponent("actual-vault")), itemID=UUID()
        let grant=try await assets.selectFile(source,itemID:itemID,propertyKey:"picture",project:project)
        let manifest=try await assets.manifest(itemID:itemID)
        try check(manifest.rootURL.path.hasPrefix("/private/tmp/") && manifest.assets.first?.url.pathExtension == "","actual actor produces POSIX private/tmp root and extensionless managed files")
        runtime=try WebWallpaperRuntime(projectURL:fixture.appendingPathComponent("project.json"),entryURL:fixture.appendingPathComponent("assets.html"),propertiesJSON:Data("{}".utf8))
        try runtime.configureResourceManifest(manifest)
        window.contentView=runtime.webView;runtime.load();try await waitForReady()
        let payload=try JSONSerialization.data(withJSONObject:["picture":["type":"file","value":grant.value.stringValue!]])
        try await runtime.applyPropertiesAndWait(payload)
        try await wait("document.getElementById('granted').complete && document.getElementById('granted').naturalWidth===57")
        try check((try await js("document.getElementById('granted').naturalHeight===43 && fetched.includes('fill=\"lime\"')")) as? Bool == true,"actual actor manifest maps extensionless SVG bytes to correct MIME and real image decode")
        runtime.dispose();runtime=nil
    }

    func waitForFailure() async throws {
        let deadline=Date().addingTimeInterval(8)
        while Date()<deadline {
            if runtime.state == .failed {return}
            try await Task.sleep(for:.milliseconds(40))
        }
        throw WebWallpaperFailure(message:"Expected authored failure was not reported")
    }
    func capabilityRecoveryTests() async throws {
        runtime=try WebWallpaperRuntime(projectURL:fixture.appendingPathComponent("project.json"),entryURL:fixture.appendingPathComponent("first-error.html"),propertiesJSON:payload(text:"THROW"))
        window.contentView=runtime.webView;runtime.load()
        try await waitForFailure()
        try check(runtime.lastError?.contains("FIRST_SCALAR_FAILURE") == true && runtime.canApplyUserProperties && !runtime.canApplyDirectoryProperties,"first scalar callback failure retains actually observed recovery capability")
        do {try await runtime.applyPropertiesAndWait(payload(text:"THROW"));throw WebWallpaperFailure(message:"first failing scalar falsely acknowledged")}
        catch {try check(error.localizedDescription.contains("FIRST_SCALAR_FAILURE"),"known callback capability never substitutes for failed consumption ACK")}
        try await runtime.applyPropertiesAndWait(payload(text:"recovered-first-scalar"));try await waitForReady()
        try check((try await js("document.getElementById('result').textContent")) as? String == "recovered-first-scalar" && runtime.lastError == nil,"editing after first scalar failure recovers actual authored DOM and readiness")
        runtime.dispose()
        let root=fixture.deletingLastPathComponent().appendingPathComponent("grants").resolvingSymlinksInPath(), file=root.appendingPathComponent("red.svg")
        let asset=WebWallpaperGrantedAsset(token:UUID().uuidString,url:file,name:"red.svg",contentIdentity:SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined())
        let manifest=WebWallpaperResourceManifest(itemID:UUID(),rootURL:root,assets:[asset],directories:[WebWallpaperGrantedDirectory(propertyKey:"gallery",mode:.fetchall,assets:[asset],revision:"initial",virtualPath:"__gw_assets__/"+UUID().uuidString)])
        runtime=try WebWallpaperRuntime(projectURL:fixture.appendingPathComponent("project.json"),entryURL:fixture.appendingPathComponent("first-directory-error.html"),propertiesJSON:Data("{}".utf8))
        try runtime.configureResourceManifest(manifest)
        window.contentView=runtime.webView;runtime.load();try await waitForFailure()
        try check(runtime.lastError?.contains("FIRST_DIRECTORY_FAILURE") == true && runtime.canApplyDirectoryProperties && !runtime.canApplyUserProperties,"first fetchall callback failure retains observed directory-only recovery capability")
        do {try await runtime.configureResourceManifestAndWait(manifest);throw WebWallpaperFailure(message:"first failing directory falsely acknowledged")}
        catch {try check(error.localizedDescription.contains("FIRST_DIRECTORY_FAILURE"),"directory recovery capability never substitutes for callback ACK")}
        _ = try await js("window.failDirectory=false;void 0")
        try await runtime.configureResourceManifestAndWait(manifest);try await waitForReady()
        try check((try await js("document.getElementById('result').textContent")) as? String == "gallery:1" && runtime.lastError == nil,"retry after first fetchall failure recovers real directory callback and readiness")
        runtime.dispose();runtime=nil
    }

    func makeSilentVideo() async throws {
        let writer = try AVAssetWriter(outputURL: fixture.appendingPathComponent("silent.mp4"), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey:32, AVVideoHeightKey:32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input, sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:32,kCVPixelBufferHeightKey as String:32])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? WebWallpaperFailure(message:"Synthetic video writer failed") }
        writer.startSession(atSourceTime:.zero)
        for index in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,32,32,kCVPixelFormatType_32BGRA,nil,&buffer)
            guard let buffer else { throw WebWallpaperFailure(message:"Synthetic video buffer failed") }
            CVPixelBufferLockBaseAddress(buffer,[])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base,127,CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer,[])
            guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(index),timescale:10)) else { throw writer.error ?? WebWallpaperFailure(message:"Synthetic video append failed") }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? WebWallpaperFailure(message:"Synthetic video completion failed") }
    }
    func run() async throws {
        try await makeSilentVideo()
        runtime = try WebWallpaperRuntime(projectURL: fixture.appendingPathComponent("project.json"), entryURL: fixture.appendingPathComponent("index.html"), propertiesJSON: payload())
        try check(runtime.state == .idle, "init is side-effect-free until explicit load")
        try check(!runtime.webView.configuration.websiteDataStore.isPersistent, "nonpersistent website data store")
        try check(runtime.unsupportedPropertyKeys == ["files"], "file property explicitly excluded from delivered capabilities")
        runtime.setPaused(true)
        try runtime.setGeneralPropertiesJSON(Data("{\"fps\":24}".utf8))
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Glimmer isolated WebKit runtime tests"
        window.contentView = runtime.webView
        window.orderFront(nil)
        runtime.load()
        try await wait("window.calls && calls.length===1 && window.pauseCalls.length>0")
        try check(runtime.state == .paused, "late global and late listener method handshake reaches paused readiness")
        try check((try await js("Object.keys(calls[0]).sort().join(',')")) as? String == "color,combo,enabled,slider,text", "first delivery is complete scalar payload exactly once")
        try check((try await js("document.getElementById('subject').textContent==='hello' && document.getElementById('toggle').hidden===false && document.body.dataset.combo==='choice-b' && getComputedStyle(document.getElementById('subject')).transform==='matrix(1, 0, 0, 1, 12, 0)'")) as? Bool == true, "text bool combo slider change actual DOM")
        try await wait("document.getElementById('asset').complete && document.getElementById('asset').naturalWidth===20")
        try check((try await js("window.generalCalls[0].fps")) as? Int == 24, "load-before-ready general settings delivered")
        try runtime.setFrameRateLimit(60)
        try await wait("window.generalCalls.length>=2 && window.generalCalls[generalCalls.length-1].fps===60")
        try check(runtime.frameRateLimit == 60, "live typed FPS update reaches the real authored general-properties listener")
        try await Task.sleep(for: .milliseconds(200))
        let imageResult: ProbeResult<NSImage> = await withCheckedContinuation { continuation in
            runtime.webView.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: ProbeResult(value: .success(image))) }
                else { continuation.resume(returning: ProbeResult(value: .failure(error ?? WebWallpaperFailure(message: "Snapshot missing")))) }
            }
        }
        let image = try imageResult.value.get()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let color = bitmap.colorAt(x: bitmap.pixelsWide/2, y: bitmap.pixelsHigh/2)?.usingColorSpace(.sRGB) else { throw WebWallpaperFailure(message: "Snapshot pixels missing") }
        try check(color.redComponent > 0.9 && color.greenComponent < 0.2 && color.blueComponent < 0.2, "real WebKit snapshot center pixels reflect authored red color (\(color.redComponent),\(color.greenComponent),\(color.blueComponent))")
        let firstTicks = (try await js("fixtureTicks")) as? Int ?? -1
        try await Task.sleep(for: .milliseconds(180))
        try check((try await js("fixtureTicks")) as? Int == firstTicks, "cooperative setPaused stops real fixture timer effects")
        runtime.setPaused(false)
        try await wait("fixtureTicks>\(firstTicks+2)")
        try check(runtime.state == .ready, "resume restarts cooperative timer effects")
        try check(runtime.webView.configuration.mediaTypesRequiringUserActionForPlayback == .audio, "native audio autoplay requires user gesture")
        _ = try await js("window.requestMediaTest=true;void 0")
        try await wait("typeof audioResult!=='undefined' && audioResult!=='pending'")
        let audioResult = (try await js("audioResult")) as? String ?? "missing"
        try check(audioResult == "NotAllowedError", "real audible audio play rejects without user gesture (\(audioResult))")
        try await wait("videoResult==='played' && silentVideo.currentTime>0.1")
        try check((try await js("silentVideo.muted && !silentVideo.paused && silentVideo.videoWidth===32")) as? Bool == true, "real muted silent H264 video advances without user gesture")

        try runtime.applyPropertiesJSON(payload(text: "changed"))
        try await wait("document.getElementById('subject').textContent==='changed'")
        try check((try await js("Object.keys(calls[calls.length-1]).join(',')")) as? String == "text", "subsequent update contains only changed property")
        let count = (try await js("calls.length")) as? Int ?? -1
        try runtime.applyPropertiesJSON(payload(text: "changed"))
        try await Task.sleep(for: .milliseconds(150))
        try check((try await js("calls.length")) as? Int == count, "identical author values are not delivered twice")
        try runtime.applyPropertiesJSON(payload(text: "SLOW"))
        try await Task.sleep(for: .milliseconds(40))
        try runtime.applyPropertiesJSON(payload(text: "latest", slider: 31))
        try await wait("document.getElementById('subject').textContent==='latest'")
        try check((try await js("getComputedStyle(document.getElementById('subject')).transform")) as? String == "matrix(1, 0, 0, 1, 31, 0)", "pending authored async callback coalesces to newest settings")
        try runtime.applyPropertiesJSON(payload(text: "THROW"))
        try await wait("window.calls.some(x=>x.text&&x.text.value==='THROW')")
        try await Task.sleep(for: .milliseconds(100))
        try check(runtime.state == .failed && runtime.lastError?.contains("AUTHORED_TEST_FAILURE") == true, "authored JavaScript exception is visible")
        try runtime.applyPropertiesJSON(payload(text: "after-error"))
        try await wait("document.getElementById('subject').textContent==='after-error'")
        try check(runtime.state == .ready, "successful later update recovers reported author error")
        runtime.reload()
        try await waitForReady()
        try await wait("window.calls && calls.length===1 && document.getElementById('subject').textContent==='after-error'")
        try check((try await js("Object.keys(calls[0]).length")) as? Int == 5, "reload receives one complete current property set")
        try await runtime.applyPropertiesAndWait(payload(text: "acknowledged"))
        try check((try await js("document.getElementById('subject').textContent")) as? String == "acknowledged", "async property API waits for actual authored consumption")
        let acknowledgedCount = (try await js("calls.length")) as? Int ?? -1
        try await runtime.applyPropertiesAndWait(payload(text: "acknowledged"))
        try check((try await js("calls.length")) as? Int == acknowledgedCount, "already-consumed canonical payload acknowledges without callback")
        let intermediate = Task { @MainActor () -> String in
            do { try await runtime.applyPropertiesAndWait(payload(text:"SLOW")); return "success" }
            catch is CancellationError { return "cancelled" }
            catch { return error.localizedDescription }
        }
        try await Task.sleep(for:.milliseconds(40))
        let returnStarted = Date()
        try await runtime.applyPropertiesAndWait(payload(text:"acknowledged"))
        try check(Date().timeIntervalSince(returnStarted) > 0.1, "cached A cannot acknowledge while intermediate async B is still consuming")
        try check(await intermediate.value == "cancelled", "return to cached payload supersedes intermediate waiter")
        try check((try await js("document.getElementById('subject').textContent")) as? String == "acknowledged", "cached A after in-flight B waits until A is actually consumed again")
        do {
            try await runtime.applyPropertiesAndWait(payload(text: "THROW"))
            throw WebWallpaperFailure(message:"throwing listener was acknowledged")
        } catch { try check(error.localizedDescription.contains("AUTHORED_TEST_FAILURE"), "async acknowledgement throws authored callback failure") }
        let superseded = Task { @MainActor () -> String in
            do { try await runtime.applyPropertiesAndWait(payload(text:"SLOW")); return "success" }
            catch is CancellationError { return "cancelled" }
            catch { return error.localizedDescription }
        }
        try await Task.sleep(for:.milliseconds(40))
        try await runtime.applyPropertiesAndWait(payload(text:"successor"))
        try check(await superseded.value == "cancelled", "successor payload cancels prior waiter rather than misacknowledging")
        try check((try await js("document.getElementById('subject').textContent")) as? String == "successor", "successor acknowledgement matches latest async callback payload")
        let oldFailure = Task { @MainActor () -> String in
            do { try await runtime.applyPropertiesAndWait(payload(text:"SLOW_THROW")); return "success" }
            catch is CancellationError { return "cancelled" }
            catch { return error.localizedDescription }
        }
        try await Task.sleep(for:.milliseconds(40))
        try await runtime.applyPropertiesAndWait(payload(text:"after-old-failure"))
        try check(await oldFailure.value == "cancelled" && runtime.lastError == nil, "superseded callback error cannot fail successor acknowledgement")
        _ = try await js("window.savedApply=wallpaperPropertyListener.applyUserProperties;wallpaperPropertyListener.applyUserProperties=null;void 0")
        do {
            try await runtime.applyPropertiesAndWait(payload(text:"timeout"),timeout:0.15)
            throw WebWallpaperFailure(message:"missing listener was acknowledged")
        } catch { try check(error.localizedDescription.contains("timed out"), "missing listener produces explicit bounded timeout") }
        let cancelledWaiter = Task { @MainActor () -> String in
            do { try await runtime.applyPropertiesAndWait(payload(text:"cancelled")); return "success" }
            catch is CancellationError { return "cancelled" }
            catch { return error.localizedDescription }
        }
        try await Task.sleep(for:.milliseconds(40))
        cancelledWaiter.cancel()
        try check(await cancelledWaiter.value == "cancelled", "caller cancellation releases pending acknowledgement")
        _ = try await js("wallpaperPropertyListener.applyUserProperties=window.savedApply;void 0")
        try await runtime.applyPropertiesAndWait(payload(text:"restored"))
        let reloadedWaiter = Task { @MainActor () -> String in
            do { try await runtime.applyPropertiesAndWait(payload(text:"SLOW")); return "success" }
            catch { return error.localizedDescription }
        }
        try await Task.sleep(for:.milliseconds(40))
        runtime.reload()
        try check(await reloadedWaiter.value == "Web wallpaper document was reloaded.", "reload explicitly fails prior-document waiter")
        try await waitForReady()
        try await runtime.applyPropertiesAndWait(payload(text:"after-error"))
        _ = try await js("window.blocked=false; fetch('outside.txt').then(r=>r.text()).then(x=>window.leaked=x).catch(()=>window.blocked=true); void 0")
        try await wait("window.blocked===true")
        try check((try await js("typeof window.leaked==='undefined'")) as? Bool == true, "symlink to outside project cannot read secret")
        _ = try await js("window.childAttempted=true; const f=document.createElement('iframe'); f.src='index.html'; document.body.appendChild(f); void 0")
        try await Task.sleep(for: .milliseconds(150))
        try check(runtime.lastError != nil, "CSP child-frame denial is visible")
        let beforeURL = runtime.webView.url
        _ = try await js("window.location.href='https://example.invalid/'")
        try await Task.sleep(for: .milliseconds(200))
        try check(runtime.webView.url == beforeURL, "external top-level navigation is blocked")
        runtime.reload(); runtime.reload(); runtime.reload()
        try await waitForReady()
        try await waitForReady()
        try await wait("window.calls && calls.length===1 && document.getElementById('subject').textContent==='after-error'")
        try check(runtime.propertyDeliveryCount == 1, "rapid reload rejects stale document acknowledgements")
        let disposedWaiter = Task { @MainActor () -> String in
            do { try await runtime.applyPropertiesAndWait(payload(text:"SLOW")); return "success" }
            catch { return error.localizedDescription }
        }
        try await Task.sleep(for:.milliseconds(40))
        runtime.dispose()
        try check(await disposedWaiter.value == "Web wallpaper runtime was disposed.", "dispose explicitly fails outstanding authored acknowledgement")
        try await Task.sleep(for: .milliseconds(120))
        try check(runtime.state == .disposed && runtime.webView.navigationDelegate == nil && runtime.webView.uiDelegate == nil, "dispose detaches delegates and prevents late callbacks")
        do { try runtime.applyPropertiesJSON(payload()); throw WebWallpaperFailure(message: "disposed update accepted") }
        catch let error as WebWallpaperFailure { try check(error.message.contains("disposed"), "disposed runtime rejects property updates") }
        do {
            _ = try WebWallpaperRuntime(projectURL: fixture.appendingPathComponent("project.json"), entryURL: fixture.deletingLastPathComponent().appendingPathComponent("secret.txt"), propertiesJSON: payload())
            throw WebWallpaperFailure(message: "outside entry accepted")
        } catch let error as WebWallpaperFailure { try check(error.message.contains("inside"), "outside-root entry is rejected before loading") }
        let location = runtime.location
        do {
            _ = try location.localURL(for: URL(string: "gw-wallpaper://project/%2E%2E/secret.txt")!)
            throw WebWallpaperFailure(message: "encoded traversal accepted")
        } catch let error as WebWallpaperFailure { try check(error.message.contains("Blocked"), "encoded parent traversal is rejected") }
        do {
            _ = try WebWallpaperPropertyPayload(Data("{\"bad\":{\"type\":\"slider\",\"value\":true}}".utf8))
            throw WebWallpaperFailure(message: "boolean slider accepted")
        } catch let error as WebWallpaperFailure { try check(error.message.contains("Invalid"), "invalid scalar values are rejected before JavaScript") }
        weak let released = runtime
        window.contentView = nil
        runtime = nil
        try await Task.sleep(for: .milliseconds(120))
        try check(released == nil, "disposed runtime releases without WebKit message-handler retain cycle")
        try await resourceTests()
        try await capabilityRecoveryTests()
        try await actualAssetStoreTests()
    }
    func finish(success: Bool, error: String? = nil) {
        runtime?.dispose(); window?.close()
        let report: [String: Any] = ["success": success, "checks": checks, "checkCount": checks.count, "error": error ?? "", "engine":"real WKWebView", "scope":"isolated GUI test app without production PlugIns"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: output); print(String(decoding:data,as:UTF8.self)) }
        exit(success ? 0 : 1)
    }
}

@main struct WebWallpaperProbeApp {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { exit(2) }
        let app = NSApplication.shared
        let delegate = WebProbeDelegate(fixture: URL(fileURLWithPath: arguments[1], isDirectory:true), output: URL(fileURLWithPath: arguments[2]))
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
