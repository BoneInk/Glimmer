import Foundation
import AppKit
import CoreGraphics
import ImageIO
import CryptoKit

/// Development integration probe. Synthetic engine resources are explicitly
/// labelled and never installed, registered, imported, or offered as fallback.
@main @MainActor struct SceneTargetGraphProbe {
    static func main()async throws {
        guard CommandLine.arguments.count>=4 else {fatalError("project.json output worker [verified-engine-bundle.json]")}
        let project=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true),worker=URL(fileURLWithPath:CommandLine.arguments[3])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
        let package=project.deletingLastPathComponent().appendingPathComponent("scene.pkg"),before=[hash(try Data(contentsOf:project)),hash(try Data(contentsOf:package))]
        let synthetic=CommandLine.arguments.count<5
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gw-target-graph-assets-\(UUID())")
        defer {if synthetic {try? FileManager.default.removeItem(at:temp)}}
        let bundle:SceneEngineAssetBundle
        if !synthetic {
            let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[4]))) as! [String:Any]
            bundle = .init(rootURL:URL(fileURLWithPath:raw["rootURL"] as! String),manifestIdentity:raw["manifestIdentity"] as! String,verifiedFiles:raw["verifiedFiles"] as! [String:String],archivePaths:raw["archivePaths"] as? [String] ?? [])
        } else {
            func u32(_ n:UInt32)->Data {var x=n.littleEndian;return withUnsafeBytes(of:&x){Data($0)}}
            let paths=["materials/particle/halo.tex","materials/particle/beam/beam_1.tex","materials/particle/fog/fog1.tex","materials/particle/beam/hose_2.tex","materials/particle/beam/hose_2_normal.tex","materials/util/noise.tex","materials/gradient/gradient_iridescent.tex"]
            var hashes:[String:String]=[:]
            for (kind,path) in paths.enumerated() {
                let width=64,height=kind==6 ? 2:64
                var bytes=Data()
                for y in 0..<height {for x in 0..<width {
                    let dx=(Double(x)+0.5)/Double(width)*2-1,dy=(Double(y)+0.5)/Double(height)*2-1
                    let radial=max(0,1-dx*dx-dy*dy),alpha=UInt8((radial*255).rounded())
                    let pixel:[UInt8]
                    switch kind {
                    case 4:pixel=[UInt8(max(0,min(255,128+dx*80))),UInt8(max(0,min(255,128+dy*80))),255,255]
                    case 5:let n=UInt8((x*47+y*31+x*y*7)%256);pixel=[n,n,n,255]
                    case 6:pixel=[UInt8(x*4),UInt8(255-x*4),255,255]
                    default:pixel=[255,255,255,alpha]
                    }
                    bytes.append(contentsOf:pixel)
                }}
                var tex=Data("TEXV0005\0TEXI0001\0".utf8)
                for n:UInt32 in [0,0,UInt32(width),UInt32(height),UInt32(width),UInt32(height),0] {tex+=u32(n)}
                tex+=Data("TEXB0001\0".utf8)
                for n:UInt32 in [1,1,UInt32(width),UInt32(height),UInt32(bytes.count)] {tex+=u32(n)}
                tex+=bytes
                let file=temp.appendingPathComponent(path);try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try tex.write(to:file);hashes[path]=hash(tex)
            }
            bundle = .init(rootURL:temp,manifestIdentity:"SYNTHETIC-ENGINE-TEST-ASSETS-NOT-STEAM",verifiedFiles:hashes)
        }
        let inspected=try SceneWallpaperInspector.inspect(projectURL:project,engineAssets:bundle)
        guard inspected.isRenderableSubset,inspected.layers.count==13,inspected.layers.filter({$0.particleSystem != nil}).count==7,inspected.layers.filter({$0.lightShaft != nil}).count==2,let program=inspected.scriptProgram,program.bindings.count==4 else {throw SceneWallpaperFailure(message:"Target graph failed inspection: "+inspected.diagnostics.map{$0.path+": "+$0.message}.joined(separator:"\n"))}
        if !synthetic {
            let automatic=try SceneWallpaperInspector.inspectUsingAvailableEngineAssets(projectURL:project)
            guard automatic.isRenderableSubset,automatic.layers.count==13,automatic.textures.mapValues(\.data)==inspected.textures.mapValues(\.data) else {throw SceneWallpaperFailure(message:"Registered production receipt did not resolve the same actual 13-node resource graph.")}
        }
        let rawProject=try JSONSerialization.jsonObject(with:Data(contentsOf:project)) as! [String:Any]
        let properties=(rawProject["general"] as? [String:Any])?["properties"] as? [String:Any] ?? [:]
        let payload=try JSONSerialization.data(withJSONObject:properties)
        let client=SceneScriptWorkerClient(executableURL:worker)
        var frames:[[String:Any]]=[]
        var nativeResolutionEvidence:[String:Any]=[:]
        do {
            _ = try await client.configure(program:program,userProperties:payload,environment:.init(canvasSize:inspected.canvasSize,screenResolution:nil,presentation:.wallpaper))
            for time in [0.0,0.6,2.0,10.0] {
                let cursor=SceneVector3(x:time==0 ? 1200:2400,y:1400,z:0)
                let state=try await client.step(runtime:time,frameTime:time==0 ? 0:0.1,input:.init(cursorWorldPosition:cursor))
                let current=try inspected.applyingScriptFrame(state)
                guard current.layers.first(where:{$0.id==71})?.origin==cursor else {throw SceneWallpaperFailure(message:"Original mouseglow script did not consume explicit world cursor input.")}
                let start=ContinuousClock.now,image=try SceneWallpaperRenderer.render(inspection:current,pixelSize:.init(width:960,height:540),runtime:time,cursorWorldPosition:cursor)
                let duration=start.duration(to:ContinuousClock.now),seconds=Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18
                let file=output.appendingPathComponent((synthetic ? "SYNTHETIC-engine-assets-":"actual-engine-assets-")+"all13-t\(time).png")
                guard let dest=CGImageDestinationCreateWithURL(file as CFURL,"public.png" as CFString,1,nil) else {throw SceneWallpaperFailure(message:"Target frame export failed.")};CGImageDestinationAddImage(dest,image,nil);guard CGImageDestinationFinalize(dest) else {throw SceneWallpaperFailure(message:"Target frame export failed.")}
                frames.append(["runtime":time,"sha256":hash(image.dataProvider!.data! as Data),"image":file.lastPathComponent,"renderSeconds":seconds,"cursorWorldPosition":[cursor.x,cursor.y,cursor.z],"authoredNodeCount":current.layers.count])
                if time==10 {
                    let native=try SceneWallpaperRenderer.render(inspection:current,pixelSize:.init(width:current.canvasSize.x,height:current.canvasSize.y),runtime:time,cursorWorldPosition:cursor)
                    let nativeFile=output.appendingPathComponent((synthetic ? "SYNTHETIC-engine-assets-":"actual-engine-assets-")+"all13-4k-t10.png")
                    guard let destination=CGImageDestinationCreateWithURL(nativeFile as CFURL,"public.png" as CFString,1,nil) else {throw SceneWallpaperFailure(message:"Native target frame export failed.")};CGImageDestinationAddImage(destination,native,nil);guard CGImageDestinationFinalize(destination) else {throw SceneWallpaperFailure(message:"Native target frame export failed.")}
                    nativeResolutionEvidence=["runtime":time,"width":native.width,"height":native.height,"sha256":hash(native.dataProvider!.data! as Data),"image":nativeFile.lastPathComponent,"authoredNodeCount":current.layers.count]
                }
            }
            await client.dispose()
        } catch {await client.dispose();throw error}
        guard Set(frames.compactMap{$0["sha256"] as? String}).count==4,before == [hash(try Data(contentsOf:project)),hash(try Data(contentsOf:package))] else {throw SceneWallpaperFailure(message:"Target graph frames did not change or source content changed.")}
        _ = NSApplication.shared
        var lifecycle:[String]=[]
        let runtime=try SceneWallpaperRuntime(projectURL:project,workerExecutableURL:worker,engineAssets:synthetic ? bundle:nil)
        runtime.setPaused(true)
        try await runtime.load(propertiesJSON:Data("{}".utf8))
        guard runtime.state == .paused,runtime.isAnimated,runtime.inspection?.layers.count==13,let initial=runtime.posterImage else {throw SceneWallpaperFailure(message:"Full target native runtime did not reach paused animated readiness.")}
        let initialHash=hash(initial.dataProvider!.data! as Data)
        lifecycle.append("original 13-node project loads into actual native Metal runtime with 4 original SceneScript bindings")
        runtime.setPaused(false)
        let deadline=ContinuousClock.now + .seconds(10)
        while runtime.frameCount<3 && ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(30))}
        guard runtime.state == .ready,runtime.frameCount>=3,runtime.activeRuntime>0 else {throw SceneWallpaperFailure(message:"Full target native frame loop did not publish actual animation: \(runtime.lastError ?? "unknown")")}
        lifecycle.append("native frame loop serializes full target script/particle/lightshaft/bloom frames")
        runtime.setPaused(true);try await Task.sleep(for:.milliseconds(100))
        let pausedFrames=runtime.frameCount,pausedTime=runtime.activeRuntime
        try await Task.sleep(for:.milliseconds(200))
        guard runtime.state == .paused,runtime.frameCount==pausedFrames,runtime.activeRuntime==pausedTime else {throw SceneWallpaperFailure(message:"Full target pause did not stop frames and active time.")}
        lifecycle.append("pause stops native full-target frames and active runtime")
        runtime.dispose()
        let reopened=try SceneWallpaperRuntime(projectURL:project,workerExecutableURL:worker,engineAssets:synthetic ? bundle:nil)
        reopened.setPaused(true);try await reopened.load(propertiesJSON:Data("{}".utf8))
        guard reopened.state == .paused,reopened.frameCount==1,hash(reopened.posterImage!.dataProvider!.data! as Data)==initialHash else {throw SceneWallpaperFailure(message:"Reopening full target did not reset actual initial pixels.")}
        lifecycle.append("dispose/reopen resets full-target simulation and original script initial pixels")
        reopened.dispose()
        let report:[String:Any] = ["success":true,"syntheticEngineTestAssets":synthetic,"actualSteamEngineAssets":!synthetic,"productionFallbackInstalled":!synthetic,"productionReceiptResolutionVerified":!synthetic,"sourceProjectAndPackageUnchanged":true,"project":project.path,"manifestIdentity":bundle.manifestIdentity,"verifiedEngineResourceDigests":bundle.verifiedFiles,"layerCount":inspected.layers.count,"particleNodes":7,"proceduralLightshaftNodes":2,"authoredInlineBindings":program.bindings.count,"decodedTextureCount":inspected.textures.count,"textureCodecs":inspected.textures.mapValues{["flags":Int($0.flags),"channelCount":$0.channelCount,"atlasFrameCount":$0.animation?.frames.count ?? 0,"digestPinnedStorageVariant":$0.verifiedStorageVariant]},"globalBloomExecuted":inspected.bloom != nil,"originalMouseScriptConsumesWorldCursor":true,"fidelityNotes":Array(Set(inspected.fidelityNotes)).sorted(),"nativeLifecycleChecks":lifecycle,"foregroundWindowCreated":false,"desktopOrLockScreenApplied":false,"frames":frames,"nativeResolutionAt10Seconds":nativeResolutionEvidence]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:output.appendingPathComponent("report.json"));print(String(decoding:data,as:UTF8.self))
    }
}
