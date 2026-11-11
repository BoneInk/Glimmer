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

    func deterministicFramePacerTests() async throws {
        let source = String(decoding: try JSONSerialization.data(withJSONObject: WebWallpaperFramePacer.script(fps: 30, paused: true), options: .fragmentsAllowed), as: UTF8.self)
        let results = try await js("""
        (() => { try {
          const native = new Map(), allNative = new Map(), failures = [], checks = [];
          let nativeID = 0, requests = 0;
          const nativeClock = {
            requestAnimationFrame(callback) {const id=++nativeID;requests++;native.set(id,callback);allNative.set(id,callback);return id},
            cancelAnimationFrame(id) {native.delete(id)}
          };
          const host = {...nativeClock};
          Function('window','setTimeout', \(source))(host, callback=>failures.push(callback));
          const assert = (value,name) => {if(!value)throw Error(name);checks.push(name)};
          const step = time => {const batch=Array.from(native.values());native.clear();for(const callback of batch)callback(time)};
          let ticks=0;
          const loop=()=>{ticks++;host.requestAnimationFrame(loop)};
          host.requestAnimationFrame(loop);
          assert(native.size===1 && requests===1,'initial pause schedules only the bootstrap native RAF');
          step(-1000);
          assert(ticks===1 && native.size===0 && requests===1,'initial pause runs one author batch and keeps nested RAF pending');
          ticks=0;
          host.__gwSetWallpaperPaused(false);
          for(let i=0;i<60;i++)step(i*1000/60);
          assert(ticks===30,'60 Hz display delivers 30 FPS');
          const oldCallback=allNative.get(nativeID), before=ticks, beforeRequests=requests;
          host.__gwSetWallpaperPaused(true);
          for(let i=60;i<120;i++)step(i*1000/60);
          oldCallback(2000);
          assert(ticks===before && requests===beforeRequests && native.size===0,'pause cancels native wakeups and rejects already dispatched frames');
          let cancelled=false, once=0;
          const cancelID=host.requestAnimationFrame(()=>cancelled=true);
          host.requestAnimationFrame(()=>once++);
          host.cancelAnimationFrame(cancelID);
          host.__gwSetWallpaperFrameRate(12.5);
          host.__gwSetWallpaperPaused(false);
          oldCallback(2010);
          for(let i=120;i<180;i++)step(i*1000/60);
          assert(ticks-before===12 && once===1 && !cancelled,'resume preserves pending cancellation and dynamic FPS without replay');
          host.__gwSetWallpaperPaused(true);
          // A separate scheduler leaves only our finite callback batch pending.
          const isolated={...nativeClock};
          Function('window','setTimeout', \(source))(isolated, callback=>failures.push(callback));
          const seen=[];
          isolated.requestAnimationFrame(()=>{seen.push('first');isolated.__gwSetWallpaperPaused(true);isolated.__gwSetWallpaperPaused(false);isolated.requestAnimationFrame(()=>seen.push('nested'))});
          const cancelledInBatch=isolated.requestAnimationFrame(()=>seen.push('cancelled'));
          isolated.requestAnimationFrame(()=>seen.push('last'));
          isolated.__gwSetWallpaperPaused(false);step(4000);
          assert(seen.join(',')==='first' && native.size===1,'pause resume inside a callback defers the remaining batch');
          isolated.cancelAnimationFrame(cancelledInBatch);step(4017);
          assert(seen.join(',')==='first,last,nested' && native.size===0,'deferred callbacks retain handles and run once on the next frame');
          isolated.requestAnimationFrame(()=>{throw Error('authored failure')});
          isolated.requestAnimationFrame(()=>seen.push('after-error'));step(4100);
          assert(failures.length===1 && seen.at(-1)==='after-error','throwing callback does not stall remaining callbacks');
          isolated.requestAnimationFrame(()=>seen.push('never'));
          isolated.__gwSetWallpaperPaused(true);
          assert(native.size===0,'idle pause removes the final outstanding native frame');
          const initial={...nativeClock}, initialSeen=[];
          Function('window','setTimeout', \(source))(initial, callback=>failures.push(callback));
          initial.requestAnimationFrame(()=>{
            initialSeen.push('first');initial.__gwSetWallpaperPaused(false);initial.__gwSetWallpaperPaused(true);
            initial.requestAnimationFrame(()=>initialSeen.push('nested'));
          });
          const initialCancel=initial.requestAnimationFrame(()=>initialSeen.push('cancelled'));
          initial.requestAnimationFrame(()=>initialSeen.push('last'));
          step(5000);initial.cancelAnimationFrame(initialCancel);
          assert(initialSeen.join(',')==='first' && native.size===0,'initial bootstrap honors pause resume epoch and keeps deferred handles pending');
          initial.__gwSetWallpaperPaused(false);step(5017);initial.__gwSetWallpaperPaused(true);step(5100);
          assert(initialSeen.join(',')==='first,last,nested' && native.size===0,'initial bootstrap cannot be renewed by resume pause');
          let cancelledSelfTicks=0;
          const cancelLoop=()=>{cancelledSelfTicks++;initial.cancelAnimationFrame(-1);initial.requestAnimationFrame(cancelLoop)};
          initial.__gwSetWallpaperPaused(false);initial.requestAnimationFrame(cancelLoop);
          for(let i=0;i<60;i++)step(6000+i*1000/60);
          initial.__gwSetWallpaperPaused(true);
          assert(cancelledSelfTicks===30 && native.size===0,'cancelling a nonexistent handle inside RAF cannot bypass the FPS cap');
          return checks;
        } catch(error) {return ['FAILED: '+String(error)+String(error && error.stack || '')]} })()
        """) as? [String] ?? []
        try check(results.count == 12, "deterministic RAF simulation: " + results.joined(separator:"; "))
        for result in results { try check(true, "deterministic RAF: " + result) }
    }

    func hostPauseTests() async throws {
        runtime = try WebWallpaperRuntime(projectURL:fixture.appendingPathComponent("project.json"),entryURL:fixture.appendingPathComponent("host-pause.html"),propertiesJSON:Data("{}".utf8))
        runtime.setPaused(true)
        window.contentView=runtime.webView;runtime.load();try await waitForReady()
        try await Task.sleep(for:.milliseconds(160))
        try check((try await js("rafTicks===1 && timerTicks>5 && pauseCalls.at(-1)===true")) as? Bool == true,"initial host pause runs exactly one bootstrap RAF batch then remains stable while timers and handshake continue")
        try check((try await js("document.getElementById('canvas').getContext('2d').getImageData(0,0,1,1).data[0]===255")) as? Bool == true,"one initial paused bootstrap paints the common RAF-only canvas")
        runtime.setPaused(false);try await wait("rafTicks>=4")
        try check((try await js("document.getElementById('canvas').getContext('2d').getImageData(0,0,1,1).data[0]===255")) as? Bool == true,"first resume paints the RAF-only canvas")
        let acknowledgement = Task { @MainActor in try await runtime.applyPropertiesAndWait(Data(#"{"text":{"type":"textinput","value":"SLOW"}}"#.utf8)) }
        try await wait("slowStarted && !slowDone")
        runtime.setPaused(true)
        try await Task.sleep(for:.milliseconds(40))
        let stopped=(try await js("rafTicks")) as? Int ?? -1
        _ = try await js("window.cancelledFired=false;window.onceFired=0;window.cancelID=requestAnimationFrame(()=>cancelledFired=true);requestAnimationFrame(()=>onceFired++);cancelAnimationFrame(cancelID);true")
        try runtime.setFrameRateLimit(12)
        try await Task.sleep(for:.milliseconds(130))
        try check((try await js("rafTicks===\(stopped) && !slowDone && pauseCalls.at(-1)===false && onceFired===0")) as? Bool == true,"host pause stops RAF while the earlier async property callback still blocks author pause delivery")
        try await acknowledgement.value
        try await wait("pauseCalls.at(-1)===true && lastFPS===12")
        try check((try await js("rafTicks===\(stopped) && slowDone && timerTicks>20")) as? Bool == true,"async property acknowledgement completes during pause without reactivating RAF")
        runtime.setPaused(false);try await wait("onceFired===1 && rafTicks>\(stopped)")
        _ = try await js("window.resumeBaseline=rafTicks;window.resumeStamp=performance.now();true")
        try await Task.sleep(for:.milliseconds(1050))
        let resumed=(try await js("rafTicks-resumeBaseline")) as? Int ?? -1
        let pendingPreserved=(try await js("!cancelledFired && onceFired===1 && new Set(frameStamps).size===frameStamps.length")) as? Bool == true
        try check((10...15).contains(resumed) && pendingPreserved,"resumed pending callbacks run once at updated 12 FPS with no catch-up burst (ticks=\(resumed))")
        _ = try await js("requestAnimationFrame(async()=>{window.asyncRAFStarted=true;await new Promise(resolve=>setTimeout(resolve,150));window.asyncRAFReturned=true;requestAnimationFrame(()=>window.asyncRAFChild=true)});true")
        try await wait("window.asyncRAFStarted")
        runtime.setPaused(true);try await wait("pauseCalls.at(-1)===true")
        try await wait("window.asyncRAFReturned")
        try check((try await js("!window.asyncRAFChild")) as? Bool == true,"an already executing async RAF may finish but its next RAF remains pending during pause")
        do {
            try await runtime.applyPropertiesAndWait(Data(#"{"text":{"type":"textinput","value":"WAIT_RAF"}}"#.utf8),timeout:0.15)
            throw WebWallpaperFailure(message:"RAF-dependent property callback acknowledged during pause")
        } catch { try check(error.localizedDescription.contains("timed out"),"RAF-dependent author property promise has a bounded acknowledgement timeout while paused") }
        try check((try await js("rafAckStarted && !window.rafAckDone")) as? Bool == true,"property timeout never runs a hidden author RAF")
        runtime.setPaused(false);try await wait("rafAckDone && window.asyncRAFChild")
        try await runtime.applyPropertiesAndWait(Data(#"{"text":{"type":"textinput","value":"WAIT_RAF"}}"#.utf8))
        try check((try await js("rafAckDone")) as? Bool == true,"RAF-dependent property consumption recovers after resume")
        try await deterministicFramePacerTests()
        runtime.dispose()
        runtime=nil
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
    func compatibilityTests() async throws {
        runtime?.dispose()
        let entry = fixture.appendingPathComponent("compatibility.html")
        try Data(#"""
        <!doctype html><body><script>
        window.ticks=0;setInterval(()=>ticks++,20);
        window.optionalRemoved=false;const img=new Image();img.onerror=()=>{optionalRemoved=true;img.remove()};img.src='missing-optional.png';document.body.appendChild(img);
        window.httpsCaught=false;fetch('https://example.invalid/optional').catch(()=>httpsCaught=true);
        window.audioCalls=0;window.audioValid=true;window.audioActive=0;window.audioPeak=0;
        wallpaperRegisterAudioListener(async values=>{audioCalls++;audioValid=audioValid&&values.length===128&&values.every(x=>x===0);audioActive++;audioPeak=Math.max(audioPeak,audioActive);await new Promise(r=>setTimeout(r,90));audioActive--});
        window.mediaStatus=[];window.mediaEvents=0;
        wallpaperRegisterMediaStatusListener(e=>mediaStatus.push(e.enabled));
        for(const name of ['Properties','Thumbnail','Playback','Timeline'])window['wallpaperRegisterMedia'+name+'Listener'](()=>mediaEvents++);
        </script></body>
        """#.utf8).write(to: entry)
        runtime = try WebWallpaperRuntime(projectURL: fixture.appendingPathComponent("project.json"), entryURL: entry, propertiesJSON: Data("{}".utf8))
        window.contentView=runtime.webView;runtime.load();try await waitForReady()
        try await wait("optionalRemoved&&httpsCaught&&ticks>5&&audioCalls>2&&mediaStatus.length===1")
        try check(runtime.state == .ready && runtime.lastError == nil && runtime.diagnostics.count >= 3, "optional missing image and caught denied HTTPS keep real page timers running with diagnostics")
        try check((try await js("audioValid&&audioPeak===1&&mediaStatus[0]===false&&mediaEvents===0")) as? Bool == true,"registered audio has bounded async silent samples; disabled media emits status only")
        runtime.setPaused(true);try await Task.sleep(for:.milliseconds(180))
        let pausedCount=(try await js("audioCalls")) as? Int
        try await Task.sleep(for:.milliseconds(150))
        try check((try await js("audioCalls")) as? Int == pausedCount,"pause suspends audio compatibility timer")
        runtime.setPaused(false);try await wait("audioCalls>\(pausedCount ?? 0)")
        _ = try await js("wallpaperRegisterAudioListener(null);wallpaperRegisterMediaStatusListener(null);window.stoppedAudio=audioCalls;void 0")
        try await Task.sleep(for:.milliseconds(180))
        try check((try await js("audioCalls===stoppedAudio")) as? Bool == true,"null registration cancels audio listener")
        _ = try await js("for(let i=0;i<100;i++) document.dispatchEvent(new SecurityPolicyViolationEvent('securitypolicyviolation',{blockedURI:'http://blocked.invalid/'+i,effectiveDirective:'connect-src'}));void 0")
        try await Task.sleep(for:.milliseconds(120))
        try check(runtime.diagnostics.count == 64,"resource diagnostics are bounded per document")
        runtime.reload();try await waitForReady();try await wait("audioCalls>1")
        try check(runtime.diagnostics.count < 64,"reload clears previous diagnostics and restarts listener lifecycle")
        _ = try await js("window.heldAudio=0;window.replacementAudio=0;wallpaperRegisterAudioListener(()=>{heldAudio++;return new Promise(r=>window.releaseAudio=r)});void 0")
        try await wait("heldAudio===1")
        _ = try await js("wallpaperRegisterAudioListener(()=>replacementAudio++);void 0")
        try await Task.sleep(for:.milliseconds(150))
        try check((try await js("heldAudio===1 && replacementAudio===0")) as? Bool == true,"listener replacement cannot overlap an unresolved audio callback")
        _ = try await js("releaseAudio();void 0");try await wait("replacementAudio>0")
        _ = try await js("window.audioBeforeHide=replacementAudio;window.dispatchEvent(new Event('pagehide'));void 0")
        try await Task.sleep(for:.milliseconds(120))
        try check((try await js("replacementAudio===audioBeforeHide")) as? Bool == true,"pagehide releases registered audio listener and timer")
        _ = try await js("setTimeout(()=>{throw new Error('UNCAUGHT_COMPAT_FAILURE')},0);void 0")
        try await Task.sleep(for:.milliseconds(120))
        try check(runtime.state == .failed && runtime.lastError?.contains("UNCAUGHT_COMPAT_FAILURE") == true,"true uncaught JavaScript remains fatal")
        runtime.dispose()
        try Data("<!doctype html><script src='missing-core.js'></script>".utf8).write(to:entry)
        runtime = try WebWallpaperRuntime(projectURL: fixture.appendingPathComponent("project.json"),entryURL:entry,propertiesJSON:Data("{}".utf8))
        window.contentView=runtime.webView;runtime.load()
        try await Task.sleep(for:.milliseconds(400))
        try check(runtime.state == .failed && runtime.lastError?.contains("script failed to load") == true,"missing core script remains fatal")
        runtime.dispose()
    }

    func run() async throws {
        if ProcessInfo.processInfo.environment["GW_WEB_COMPATIBILITY_ONLY"] == "1" {
            window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
            window.orderFrontRegardless()
            try await compatibilityTests()
            return
        }
        try await makeSilentVideo()
        runtime = try WebWallpaperRuntime(projectURL: fixture.appendingPathComponent("project.json"), entryURL: fixture.appendingPathComponent("index.html"), propertiesJSON: payload(), mutedPlayback: true)
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
        runtime.setPaused(false)
        try await wait("window.pauseCalls[window.pauseCalls.length-1]===false")
        _ = try await js("window.__gwRateTicks=0;function rateTick(){window.__gwRateTicks++;requestAnimationFrame(rateTick)}requestAnimationFrame(rateTick);true")
        try runtime.setGeneralPropertiesJSON(Data("{\"fps\":12.5}".utf8))
        try await wait("window.generalCalls[generalCalls.length-1].fps===12.5")
        _ = try await js("window.__gwRateTicks=0;true")
        try await Task.sleep(for: .milliseconds(1100))
        let twelve = (try await js("window.__gwRateTicks")) as? Int ?? 0
        try check((10...16).contains(twelve), "normal Web runtime enforces 12 FPS even when the author ignores the setting (ticks=\(twelve))")
        try runtime.setFrameRateLimit(24)
        try await wait("window.generalCalls[generalCalls.length-1].fps===24")
        _ = try await js("window.__gwRateTicks=0;true")
        try await Task.sleep(for: .milliseconds(1100))
        let twentyFour = (try await js("window.__gwRateTicks")) as? Int ?? 0
        try check((23...29).contains(twentyFour), "live FPS changes update the same page scheduler without a reload (ticks=\(twentyFour))")
        _ = try await js("""
        window.__gwBatch={stamps:[],cancelled:false,nested:false};
        const cancelled=requestAnimationFrame(()=>window.__gwBatch.cancelled=true);
        requestAnimationFrame(t=>{__gwBatch.stamps.push(t);requestAnimationFrame(()=>__gwBatch.nested=true)});
        requestAnimationFrame(t=>__gwBatch.stamps.push(t));
        cancelAnimationFrame(cancelled);true
        """)
        try await wait("window.__gwBatch.stamps.length===2 && window.__gwBatch.nested")
        try check((try await js("!__gwBatch.cancelled && __gwBatch.stamps[0]===__gwBatch.stamps[1]")) as? Bool == true,
                  "paced callbacks preserve cancellation, shared frame timestamps and nested scheduling")
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
        runtime.setPaused(true)
        try await wait("window.pauseCalls[window.pauseCalls.length-1]===true")
        let firstTicks = (try await js("fixtureTicks")) as? Int ?? -1
        try await Task.sleep(for: .milliseconds(180))
        try check((try await js("fixtureTicks")) as? Int == firstTicks, "cooperative setPaused stops real fixture timer effects")
        runtime.setPaused(false)
        try await wait("fixtureTicks>\(firstTicks+2)")
        try check(runtime.state == .ready, "resume restarts cooperative timer effects")
        try check(runtime.webView.configuration.mediaTypesRequiringUserActionForPlayback.isEmpty, "muted wallpaper allows authored media to start without user gesture")
        _ = try await js("window.requestMediaTest=true;void 0")
        try await wait("typeof audioResult!=='undefined' && audioResult!=='pending'")
        let audioResult = (try await js("audioResult")) as? String ?? "missing"
        try check(audioResult == "played" && runtime.webView.value(forKey: "_mediaMutedState") as? UInt == 1,
                  "real audio advances while native page output remains muted (\(audioResult))")
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
        try check(runtime.diagnostics.contains(where: { $0.contains("Blocked a wallpaper resource") }) && runtime.lastError == nil, "CSP child-frame denial is visible as a nonfatal diagnostic")
        try check((try await js("(()=>{const child=document.querySelector('iframe');try{return !child.contentDocument || child.contentDocument.URL==='about:blank'}catch{return true}})()")) as? Bool == true,"CSP denial prevents the attempted child document from loading")
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
        try await hostPauseTests()
        try await compatibilityTests()
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
