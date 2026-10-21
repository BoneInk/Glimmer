import Foundation

@main @MainActor enum SceneScriptEnvironmentProbe {
    static var checks=0
    static func check(_ value:Bool,_ name:String)throws {guard value else{throw SceneWallpaperFailure(message:name)};checks+=1;print("PASS \(name)")}
    static let worker=URL(fileURLWithPath:CommandLine.arguments[1])
    static let canvas=SceneVector2(x:320,y:180)
    static func environment(_ x:Double=3840,_ y:Double=2160)->SceneScriptEnvironment {.init(canvasSize:canvas,screenResolution:.init(x:x,y:y),presentation:.wallpaper)}
    static func layer(_ id:Int=1)->SceneScriptLayerState {.init(id:id,name:"node \(id)",origin:.init(x:160,y:90,z:0),angles:.init(x:0,y:0,z:0),scale:.init(x:1,y:1,z:1),size:.init(x:10,y:10),color:.init(x:1,y:1,z:1),alpha:1,visible:true)}
    static func program(_ source:String)->SceneScriptProgram {.init(bindings:[.init(id:"one",layerID:1,target:"alpha",source:source,initialValue:.number(1),scriptProperties:[:])],layers:[layer()])}
    static func originProgram(_ source:String)->SceneScriptProgram {.init(bindings:[.init(id:"cursor",layerID:1,target:"origin",source:source,initialValue:.string("160 90 0"),scriptProperties:[:])],layers:[layer()])}
    static func payload(_ text:String="{}")->Data {Data(text.utf8)}
    static func main()async throws {
        let client=SceneScriptWorkerClient(executableURL:worker)
        do {
            let source="""
            let calls=0;
            const topCanvas=engine.canvasSize.copy(),topScreen=engine.screenResolution.copy(),topColor=engine.userProperties.tint.copy();
            export function init(){
              if(topCanvas.x!==320||topCanvas.y!==180||topScreen.x!==3840||topScreen.y!==2160||topColor.x!==1)throw Error('wrong startup facts');
              if(!engine.isDesktopDevice()||engine.isMobileDevice()||engine.isRunningInEditor()||!engine.isWallpaper()||engine.isScreensaver()||!engine.isLandscape()||engine.isPortrait())throw Error('wrong host mode');
              let a=engine.canvasSize;a.x=9;let b=engine.screenResolution;b.y=9;let p=engine.userProperties;p.tint.x=0;p.settings.deep=9;
              if(engine.canvasSize.x!==320||engine.screenResolution.y!==2160||engine.userProperties.tint.x!==1||engine.userProperties.settings.deep!==2)throw Error('mutable host facts');
              return .2;
            }
            export function applyUserProperties(p){
              if(!engine.userProperties.tint.copy().isFinite())throw Error('lost Vec3 prototype');
              if(p.tint&&p.tint.x!==engine.userProperties.tint.x)throw Error('global not updated before callback');
              if(p.gain!==undefined)thisLayer.alpha=engine.userProperties.gain;
              if(p.tint){p.tint.x=999;if(engine.userProperties.tint.x===999)throw Error('callback aliases engine');}
            }
            export function resizeScreen(size){
              calls++;
              if(engine.screenResolution.x!==size.x||engine.screenResolution.y!==size.y)throw Error('stale screen during event');
              if(engine.canvasSize.x!==320||engine.canvasSize.y!==180)throw Error('screen overwrote canvas');
              if(engine.runtime!==7||engine.frametime!==0)throw Error('resize timing advanced');
              thisLayer.alpha=calls/10;thisLayer.visible=engine.isPortrait();
              size.x=1;if(engine.screenResolution.x===1)throw Error('resize parameter aliases engine');
              return .99;
            }
            """
            var f=try await client.configure(program:program(source),userProperties:payload(#"{"tint":{"type":"color","value":"1 0.5 0.25"},"gain":{"value":0.4},"settings":{"value":{"deep":2}}}"#),environment:environment())
            try check(f.layers[0].alpha==0.4,"configure exposes real facts at module top-level/init; no startup resize")
            f=try await client.resizeScreen(environment(2160,3840),runtime:7)
            try check(f.layers[0].alpha==0.1 && f.layers[0].visible,"portrait resize actually invokes once and ignores return value")
            f=try await client.resizeScreen(environment(2160,3840),runtime:7)
            try check(f.layers[0].alpha==0.1,"same screen resolution does not synthesize another resize")
            f=try await client.resizeScreen(environment(1920,1080),runtime:7)
            try check(f.layers[0].alpha==0.2 && !f.layers[0].visible,"second real screen change updates orientation and event count")
            f=try await client.applyUserProperties(payload(#"{"tint":{"type":"color","value":"0 1 0"},"gain":{"value":0.7}}"#),runtime:7)
            try check(f.layers[0].alpha==0.7,"live typed color/userProperties are updated before callback with copy isolation")
            f=try await client.step(runtime:8,frameTime:0.1)
            try check(f.layers[0].alpha==0.7,"non-update scripts remain stable after properties/resize")
            let square="export function init(){if(!engine.isLandscape()||engine.isPortrait())throw Error('square convention');return .3;}"
            f=try await client.configure(program:program(square),userProperties:payload(),environment:environment(1000,1000))
            try check(f.layers[0].alpha==0.3,"documented local square policy is landscape (official square case unspecified)")
            f=try await client.configure(program:program("export function init(){return engine.timeOfDay;}"),userProperties:payload(),environment:environment())
            let parts=Calendar.current.dateComponents([.hour,.minute,.second,.nanosecond],from:Date())
            let seconds=Double(parts.hour!*3600+parts.minute!*60+parts.second!)+Double(parts.nanosecond ?? 0)/1e9
            let difference=abs(f.layers[0].alpha-seconds/86400)
            try check(min(difference,1-difference)<0.0002,"engine.timeOfDay uses real Mac local 24-hour wall clock, independent from runtime")
            let mode="export function init(){return engine.isWallpaper()&&!engine.isScreensaver()&&!engine.isRunningInEditor() ? .5:0;}"
            f=try await client.configure(program:program(mode),userProperties:payload(),environment:environment())
            try check(f.layers[0].alpha==0.5,"preview and desktop share wallpaper mode, never fake editor/screensaver")
            var failed=false
            do{_ = try await client.resizeScreen(.init(canvasSize:.init(x:321,y:180),screenResolution:.init(x:300,y:200),presentation:.wallpaper),runtime:0)}catch{failed=error.localizedDescription.contains("canvas")}
            try check(failed,"resize cannot silently change project canvas")
            failed=false
            do{_ = try await client.resizeScreen(environment(.nan,100),runtime:0)}catch{failed=error.localizedDescription.contains("像素")}
            try check(failed,"nonfinite screen rejected in Swift before RPC")
            failed=false
            do{_ = try await client.resizeScreen(environment(100.5,100),runtime:0)}catch{failed=true}
            try check(failed,"fractional render-buffer-like resolution rejected")
            failed=false
            do{_ = try await client.configure(program:program("export function init(){return engine.screenResolution.x;}"),userProperties:payload())}catch{failed=error.localizedDescription.contains("unavailable")}
            try check(failed,"missing real host resolution does not fabricate project/render-buffer fallback")
            let first="export function resizeScreen(s){s.x=0;let p=engine.userProperties;p.tint.x=5;thisLayer.alpha=.3;}"
            let second="export function resizeScreen(s){if(s.x!==800||engine.userProperties.tint.x!==1)throw Error('cross-script alias');thisLayer.alpha=.6;}"
            let pair=SceneScriptProgram(bindings:[.init(id:"a",layerID:1,target:"alpha",source:first,initialValue:.number(1),scriptProperties:[:]),.init(id:"b",layerID:2,target:"alpha",source:second,initialValue:.number(1),scriptProperties:[:])],layers:[layer(),layer(2)])
            _ = try await client.configure(program:pair,userProperties:payload(#"{"tint":{"type":"color","value":"1 0 0"}}"#),environment:environment())
            f=try await client.resizeScreen(environment(800,600),runtime:0)
            try check(f.layers.map(\.alpha)==[0.3,0.6],"each resize handler gets independent Vec2 and typed properties snapshot")

            // Verbatim authored mouse-glow position script from the installed
            // read-only 栖川渡-4k原画 package.
            let mouseGlow="""
            'use strict';

            // 鼠标微光：跟随鼠标位置
            export function update(value) {
            \ttry {
            \t\tvar p = input && input.cursorWorldPosition;
            \t\tif (p) return new Vec3(p.x, p.y, 0.0);
            \t} catch (e) { }
            \treturn value;
            }
            """
            _ = try await client.configure(program:originProgram(mouseGlow),userProperties:payload(),environment:environment())
            f = try await client.step(runtime:1,frameTime:0.1,input:.init(cursorWorldPosition:.init(x:42.5,y:-7.25,z:9)))
            try check(f.layers[0].origin == .init(x:42.5,y:-7.25,z:0),"actual 栖川渡 mouse-glow script consumes typed cursor world snapshot")
            f = try await client.step(runtime:2,frameTime:0.1,input:.init())
            try check(f.layers[0].origin == .init(x:42.5,y:-7.25,z:0),"missing cursor snapshot is nil and authored fallback preserves prior origin")
            let isolated="export function update(v){let p=input.cursorWorldPosition;p.x=999;let q=input.cursorWorldPosition;if(q.x===999)throw Error('aliased cursor');return new Vec3(q.x,q.y,0);}"
            _ = try await client.configure(program:originProgram(isolated),userProperties:payload(),environment:environment())
            f = try await client.step(runtime:1,frameTime:0.1,input:.init(cursorWorldPosition:.init(x:8,y:9,z:0)))
            try check(f.layers[0].origin == .init(x:8,y:9,z:0),"input cursor is a defensive Vec3 copy on every read")
            let readonly="export function update(v){input.cursorWorldPosition=new Vec3(1,2,0);return v;}"
            _ = try await client.configure(program:originProgram(readonly),userProperties:payload(),environment:environment())
            var readonlyRejected=false
            do {_ = try await client.step(runtime:1,frameTime:0.1,input:.init(cursorWorldPosition:.init(x:8,y:9,z:0)))}
            catch {readonlyRejected=error.localizedDescription.contains("read-only")}
            try check(readonlyRejected,"script cannot replace read-only input cursor snapshot")
            _ = try await client.configure(program:originProgram(isolated),userProperties:payload(),environment:environment())
            var invalidInput=false
            do {_ = try await client.step(runtime:2,frameTime:0.1,input:.init(cursorWorldPosition:.init(x:.nan,y:0,z:0)))}
            catch {invalidInput=error.localizedDescription.contains("坐标无效")}
            try check(invalidInput,"nonfinite native cursor is rejected before bounded worker JSON transport")
            f = try await client.step(runtime:3,frameTime:0.1,input:.init(cursorWorldPosition:.init(x:10,y:11,z:0)))
            try check(f.layers[0].origin == .init(x:10,y:11,z:0),"rejected native snapshot does not poison isolated worker state")
            _ = try await client.configure(program:program("export function resizeScreen(s){while(true){}}"),userProperties:payload(),environment:environment())
            let started=ContinuousClock.now
            failed=false
            do{_ = try await client.resizeScreen(environment(800,600),runtime:0)}catch{failed=error.localizedDescription.contains("超时")}
            let elapsed=started.duration(to:.now)
            try check(failed && elapsed > .milliseconds(400) && elapsed < .seconds(2),"infinite resize is killed by real 0.5s transport deadline")
        }catch{await client.dispose();throw error}
        await client.dispose()
        print("RESULT \(checks) real-worker environment/resize checks passed")
    }
}
