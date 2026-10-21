import AppKit
import Foundation
import Darwin

@main @MainActor enum SceneEnvironmentRuntimeTests {
    static var checks=0
    static func check(_ value:Bool,_ name:String)throws {guard value else{throw SceneWallpaperFailure(message:name)};checks+=1;print("PASS \(name)")}
    static func u32(_ x:UInt32)->Data {var n=x.littleEndian;return withUnsafeBytes(of:&n){Data($0)}}
    static func json(_ x:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:x,options:.sortedKeys)}
    static func source(_ root:URL,script:String)throws->URL {
        let fm=FileManager.default
        try fm.createDirectory(at:root.appendingPathComponent("models"),withIntermediateDirectories:true)
        try fm.createDirectory(at:root.appendingPathComponent("materials"),withIntermediateDirectories:true)
        try json(["type":"scene","file":"scene.json","general":["properties":["tint":["type":"color","value":"1 1 1"]]]]).write(to:root.appendingPathComponent("project.json"))
        try json(["general":["orthogonalprojection":["width":64,"height":48],"clearcolor":"0 0 0"],"objects":[["id":1,"image":"models/image.json","origin":"32 24 0","size":"64 48","alpha":["value":1,"script":script]]]]).write(to:root.appendingPathComponent("scene.json"))
        try json(["material":"materials/image.json"]).write(to:root.appendingPathComponent("models/image.json"))
        try json(["passes":[["shader":"genericimage2","textures":["image"],"blending":"translucent"]]]).write(to:root.appendingPathComponent("materials/image.json"))
        var tex=Data("TEXV0005\0TEXI0001\0".utf8)
        for n:UInt32 in [0,0,2,2,2,2,0]{tex+=u32(n)}
        tex+=Data("TEXB0001\0".utf8)
        for n:UInt32 in [1,1,2,2,16]{tex+=u32(n)}
        tex+=Data(repeating:255,count:16)
        try tex.write(to:root.appendingPathComponent("materials/image.tex"))
        return root.appendingPathComponent("project.json")
    }
    static func pixel(_ runtime:SceneWallpaperRuntime)throws->[UInt8] {
        guard let image=runtime.posterImage,let bytes=image.dataProvider?.data else{throw SceneWallpaperFailure(message:"Missing actual pixels")}
        let data=bytes as Data, i=(image.height/2*image.width+image.width/2)*4
        return Array(data[i..<i+4])
    }
    static func near(_ x:[UInt8],_ expected:[Int])->Bool {zip(x,expected).allSatisfy{abs(Int($0)-$1)<=2}}
    static func ownWorkers()throws->Int {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/ps");process.arguments=["-axo","ppid=,comm="]
        let output=Pipe();process.standardOutput=output;try process.run()
        let rows=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);process.waitUntilExit()
        return rows.split(separator:"\n").filter { row in
            let fields=row.split(whereSeparator:{$0==" " || $0=="\t"})
            return fields.count>=2 && Int32(fields[0])==getpid() && fields.dropFirst().joined(separator:" ").hasSuffix("GlimmerSceneScriptWorker")
        }.count
    }
    static func main()async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("GW-SceneEnv-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let worker=URL(fileURLWithPath:CommandLine.arguments[1])
        let code="""
        let resized=0;
        export function init(){
          if(engine.canvasSize.x!==64||engine.canvasSize.y!==48||!engine.isWallpaper()||engine.isScreensaver()||engine.isRunningInEditor())throw Error('wrong native environment');
          thisLayer.color=engine.userProperties.tint.copy();return .25;
        }
        export function resizeScreen(size){
          resized++;if(engine.screenResolution.x!==size.x||engine.canvasSize.x!==64)throw Error('stale native resize facts');
          thisLayer.alpha=engine.isPortrait()?.5:.75;
        }
        export function applyUserProperties(p){if(p.tint)thisLayer.color=engine.userProperties.tint.copy();}
        """
        let project=try source(root.appendingPathComponent("normal"),script:code)
        let runtime=try SceneWallpaperRuntime(projectURL:project,workerExecutableURL:worker,screenResolution:.init(x:1920,y:1080))
        defer{runtime.dispose()}
        runtime.setPaused(true)
        try await runtime.load(propertiesJSON:Data("{}".utf8))
        try check(runtime.state == .paused && !runtime.isAnimated,"explicit offscreen host is paused without update loop")
        try check(try near(pixel(runtime),[64,64,64,255]),"startup actual pixels prove resizeScreen was not synthesized")
        try check(runtime.screenResolution == .init(x:1920,y:1080) && runtime.posterImage?.width==64,"screen pixels remain distinct from 64px render buffer")
        let count=runtime.frameCount
        try await runtime.updateScreenResolutionAndWait(.init(x:1920,y:1080))
        try check(runtime.frameCount==count,"unchanged screen does not publish a synthetic resize frame")
        try await runtime.updateScreenResolutionAndWait(.init(x:1080,y:1920))
        try check(runtime.state == .paused && runtime.activeRuntime==0,"paused resize ACK does not resume or advance animation time")
        try check(try near(pixel(runtime),[128,128,128,255]),"portrait resize returns actual 50-percent white pixels before ACK")
        try await runtime.applyPropertiesAndWait(Data(#"{"tint":"1 0 0"}"#.utf8))
        try check(try near(pixel(runtime),[128,0,0,255]),"latest typed engine.userProperties color produces real paused red pixels")
        try await runtime.updateScreenResolutionAndWait(.init(x:2560,y:1440))
        try check(try near(pixel(runtime),[191,0,0,255]),"landscape resize preserves latest color while changing actual alpha")
        try check(runtime.state == .paused,"property and screen updates preserve paused intent")
        runtime.setPaused(false)
        try check(runtime.state == .ready,"resume after environment updates preserves ready native host")
        runtime.setPaused(true)
        // A real hidden NSWindow binds the preview view to its actual NSScreen.
        guard let screen=NSScreen.main,let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else{throw SceneWallpaperFailure(message:"A real native NSScreen is required for preview provenance")}
        guard let mode=CGDisplayCopyDisplayMode(number.uint32Value) else { throw SceneWallpaperFailure(message:"Missing actual display mode") }
        var physicalWidth=Double(mode.pixelWidth),physicalHeight=Double(mode.pixelHeight)
        if (screen.frame.width < screen.frame.height) != (physicalWidth < physicalHeight) { swap(&physicalWidth,&physicalHeight) }
        let physical=SceneVector2(x:physicalWidth,y:physicalHeight)
        let registry=DisplayRegistry(observeChanges:false)
        let actualDisplay=registry.displays.first{$0.displayID==number.uint32Value}
        try check(actualDisplay?.pixelSize == CGSize(width:mode.pixelWidth,height:mode.pixelHeight),"native DisplayRegistry uses actual mode backing pixels, consistent with engine screen provenance")
        print("NATIVE SCREEN: points=\(Int(screen.frame.width))x\(Int(screen.frame.height)) scale=\(screen.backingScaleFactor) modePixels=\(mode.pixelWidth)x\(mode.pixelHeight)")
        let native=try SceneWallpaperRuntime(projectURL:project,workerExecutableURL:worker,followsHostScreen:true)
        let window=NSWindow(contentRect:NSRect(x:screen.frame.minX+20,y:screen.frame.minY+20,width:160,height:100),styleMask:.borderless,backing:.buffered,defer:false,screen:screen)
        window.isReleasedWhenClosed=false;window.contentView=native.hostView
        defer{native.dispose();window.contentView=nil;window.close()}
        native.setPaused(true);try await native.load(propertiesJSON:Data("{}".utf8))
        try check(native.screenResolution == physical,"native preview reads owning window.screen CGDisplayMode physical backing pixels")
        try check(native.screenResolution?.x != Double(native.hostView.bounds.width),"native preview never reports view point size as screen resolution")
        try check(try near(pixel(native),[64,64,64,255]),"native window startup produces pixels without firing resize")
        let nativeCount=native.frameCount
        window.setContentSize(.init(width:300,height:200))
        NotificationCenter.default.post(name:NSWindow.didChangeScreenNotification,object:window)
        NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil)
        try await Task.sleep(for:.milliseconds(80))
        try check(native.frameCount==nativeCount && native.screenResolution==physical,"view resize and duplicate native screen notifications do not fabricate screen events")
        let badURL=try source(root.appendingPathComponent("bad"),script:"export function init(){return .25;} export function resizeScreen(s){thisLayer.alpha=1;throw Error('resize-authored-failure');}")
        let bad=try SceneWallpaperRuntime(projectURL:badURL,workerExecutableURL:worker,screenResolution:.init(x:1920,y:1080))
        defer{bad.dispose()};bad.setPaused(true);try await bad.load(propertiesJSON:Data("{}".utf8))
        let prior=bad.posterImage!.dataProvider!.data! as Data
        var failed=false
        do{try await bad.updateScreenResolutionAndWait(.init(x:1080,y:1920))}catch{failed=error.localizedDescription.contains("resize-authored-failure")}
        try check(failed && bad.state == .failed,"authored resize error returns a diagnostic and retires script worker")
        try check(bad.posterImage!.dataProvider!.data! as Data == prior && bad.inspection?.layers[0].opacity==0.25,"failed resize cannot publish partial mutated pixels or layer state")
        failed=false
        do{try await bad.updateScreenResolutionAndWait(.init(x:2560,y:1440))}catch{failed=true}
        try check(failed,"a failed host cannot falsely ACK another resize without reload")
        let startupURL=try source(root.appendingPathComponent("startup"),script:"export function init(){const end=Date.now()+250;while(Date.now()<end){};return .25;} export function resizeScreen(s){thisLayer.alpha=engine.isPortrait()?.5:.75;thisLayer.scale=new Vec3(2,2,1);}")
        let startup=try SceneWallpaperRuntime(projectURL:startupURL,workerExecutableURL:worker,screenResolution:.init(x:1920,y:1080))
        defer{startup.dispose()};startup.setPaused(true)
        let beforeStartupWorkers=try ownWorkers()
        let loading=Task{try await startup.load(propertiesJSON:Data("{}".utf8))}
        for _ in 0..<100 {if try ownWorkers()>beforeStartupWorkers{break};try await Task.sleep(for:.milliseconds(5))}
        try check(try ownWorkers()>beforeStartupWorkers && startup.state == .loading,"real worker process has captured startup environment while native host is not prepared")
        var startupResizeAcked=false
        let startupResize=Task{try await startup.updateScreenResolutionAndWait(.init(x:1080,y:1920));startupResizeAcked=true}
        try await Task.sleep(for:.milliseconds(35))
        try check(!startupResizeAcked,"resize cannot ACK merely storing metadata during in-flight startup configure")
        try await loading.value;try await startupResize.value
        try check(startup.state == .paused && startup.screenResolution == .init(x:1080,y:1920) && startup.inspection?.layers[0].scale.x==2 && (try near(pixel(startup),[128,128,128,255])),"loading-time resize waits for complete load then ACKs actual resized pixels exactly once")
        startup.dispose()
        let slowURL=try source(root.appendingPathComponent("slow"),script:"""
        let calls=0;
        function delay(){const end=Date.now()+100;while(Date.now()<end){}}
        export function init(){return .25;}
        export function resizeScreen(size){delay();calls++;thisLayer.alpha=engine.isPortrait()?.5:.75;thisLayer.scale=new Vec3(calls+1,calls+1,1);}
        export function applyUserProperties(p){if(p.tint){delay();thisLayer.color=engine.userProperties.tint.copy();}}
        """)
        let slow=try SceneWallpaperRuntime(projectURL:slowURL,workerExecutableURL:worker,screenResolution:.init(x:1920,y:1080))
        defer{slow.dispose()};slow.setPaused(true);try await slow.load(propertiesJSON:Data("{}".utf8))
        let portrait=SceneVector2(x:1080,y:1920),landscape=SceneVector2(x:1920,y:1080)
        let firstResize=Task{try await slow.updateScreenResolutionAndWait(portrait)}
        try await Task.sleep(for:.milliseconds(15))
        let bStarted=ContinuousClock.now
        try await slow.updateScreenResolutionAndWait(landscape)
        try check(bStarted.duration(to:.now) > .milliseconds(150),"return-to-original B waits for in-flight A and its own real resize ACK")
        let bPixels=slow.posterImage!.dataProvider!.data! as Data
        try await firstResize.value;try await Task.sleep(for:.milliseconds(130))
        try check(slow.screenResolution==landscape && slow.inspection?.layers[0].opacity==0.75 && slow.posterImage!.dataProvider!.data! as Data==bPixels,"B ACK cannot be overwritten by older A pixels or deferred compensation")
        try await slow.load(propertiesJSON:Data("{}".utf8))
        let a=Task{try await slow.updateScreenResolutionAndWait(portrait)}
        try await Task.sleep(for:.milliseconds(10))
        let b=Task{try await slow.updateScreenResolutionAndWait(landscape)}
        try await Task.sleep(for:.milliseconds(10))
        let c=Task{try await slow.updateScreenResolutionAndWait(portrait)}
        try await c.value;try await a.value;try await b.value
        try check(slow.screenResolution==portrait && slow.inspection?.layers[0].scale.x==4 && slow.inspection?.layers[0].opacity==0.5,"delayed A-B-A calls each apply their fixed parameters in FIFO order before final ACK")
        let properties=Task{try await slow.applyPropertiesAndWait(Data(#"{"tint":"1 0 0"}"#.utf8))}
        try await Task.sleep(for:.milliseconds(10))
        let duringProperties=Task{try await slow.updateScreenResolutionAndWait(landscape)}
        try await properties.value;try await duringProperties.value
        try check(try near(pixel(slow),[191,0,0,255]),"screen transaction queues behind submitted author properties without cancellation or lost typed color")
        let duringResize=Task{try await slow.updateScreenResolutionAndWait(portrait)}
        try await Task.sleep(for:.milliseconds(10))
        let laterProperties=Task{try await slow.applyPropertiesAndWait(Data(#"{"tint":"0 1 0"}"#.utf8))}
        try await duringResize.value;try await laterProperties.value
        try check(try near(pixel(slow),[0,128,0,255]),"author properties queue behind resize and both ACK actual latest pixels")
        let holder=Task{try await slow.updateScreenResolutionAndWait(landscape)}
        try await Task.sleep(for:.milliseconds(10))
        let cancelled=Task{try await slow.applyPropertiesAndWait(Data(#"{"tint":"0 0 1"}"#.utf8))}
        try await Task.sleep(for:.milliseconds(10));cancelled.cancel()
        var canceledCorrectly=false
        do{try await cancelled.value}catch is CancellationError{canceledCorrectly=true}
        try await holder.value;try await slow.updateScreenResolutionAndWait(portrait)
        try check(canceledCorrectly && (try near(pixel(slow),[0,128,0,255])),"cancelled queued mutation does not apply or strand the FIFO gate")
        let active=Task{try await slow.updateScreenResolutionAndWait(landscape)}
        try await Task.sleep(for:.milliseconds(10))
        let waiting=Task{try await slow.applyPropertiesAndWait(Data(#"{"tint":"1 0 0"}"#.utf8))}
        try await Task.sleep(for:.milliseconds(10))
        let disposedAt=ContinuousClock.now;slow.dispose()
        let activeResult=await active.result,waitingResult=await waiting.result
        var bothFailed=false
        if case .failure=activeResult,case .failure=waitingResult{bothFailed=true}
        try check(bothFailed && disposedAt.duration(to:.now) < .seconds(2),"dispose wakes queued mutations and terminates active worker without deadlock")
        runtime.dispose();native.dispose();bad.dispose()
        try check(runtime.state == .disposed && native.state == .disposed && bad.state == .disposed,"all runtime and native observer lifetimes dispose")
        for _ in 0..<100 {if try ownWorkers()==0{break};try await Task.sleep(for:.milliseconds(20))}
        try check(try ownWorkers()==0,"all own helper children have actually exited after runtime disposal")
        print("RESULT \(checks) real-helper/runtime/native-window pixel checks passed; physical screen \(Int(physical.x))x\(Int(physical.y))")
    }
}
