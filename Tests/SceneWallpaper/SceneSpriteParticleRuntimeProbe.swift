import Foundation
import AppKit

@main @MainActor struct SceneSpriteParticleRuntimeProbe {
    static func main() async throws {
        _ = NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("gw-sprite-runtime-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("materials"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("particles"),withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let advanced=CommandLine.arguments.contains("--advanced")
        var checks:[String]=[]
        func check(_ value:Bool,_ text:String)throws {guard value else {throw SceneWallpaperFailure(message:"FAILED: "+text)};checks.append(text)}
        func json(_ value:Any,_ path:String)throws {try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:root.appendingPathComponent(path))}
        func u32(_ n:UInt32)->Data {var x=n.littleEndian;return withUnsafeBytes(of:&x){Data($0)}}
        try json(["type":"scene","file":"scene.json","general":["properties":[:]]],"project.json")
        try json(["general":["orthogonalprojection":["width":64,"height":64],"clearcolor":"0 0 0","bloom":false,"hdr":false,"cameraparallax":false,"camerashake":false],"objects":[["id":1,"name":"Own moving sprite","particle":"particles/own.json","origin":"32 32 0"]]],"scene.json")
        var particle:[String:Any] = ["material":"materials/own.json","maxcount":32,"starttime":advanced ? 0.5:0,"emitter":[["name":"sphererandom","rate":advanced ? 20:1]],"initializer":[["name":"lifetimerandom","min":3,"max":3],["name":"sizerandom","min":8,"max":8],["name":"velocityrandom","min":"12 0 0","max":"12 0 0"]],"operator":[["name":"movement"]],"renderer":[["name":"sprite"]]]
        if advanced {particle["operator"]=[["name":"movement"],["name":"turbulence","speedmin":4,"speedmax":8,"timescale":1,"mask":"1 1 0"]];particle["renderer"]=[["name":"rope","subdivision":3,"uvscrolling":true]]}
        try json(particle,"particles/own.json")
        try json(["passes":[["shader":"genericparticle","textures":["own"],"blending":"translucent"]]],"materials/own.json")
        var tex=Data("TEXV0005\0TEXI0001\0".utf8)
        for n:UInt32 in [0,1,2,2,2,2,0] {tex+=u32(n)}
        tex+=Data("TEXB0001\0".utf8)
        for n:UInt32 in [1,1,2,2,16] {tex+=u32(n)}
        tex+=Data(repeating:255,count:16)
        try tex.write(to:root.appendingPathComponent("materials/own.tex"))
        let runtime=try SceneWallpaperRuntime(projectURL:root.appendingPathComponent("project.json"),workerExecutableURL:root.appendingPathComponent("deliberately-missing-worker"))
        defer {runtime.dispose()}
        try await runtime.load(propertiesJSON:Data("{}".utf8))
        try check(runtime.state == .ready && runtime.isAnimated,"sprite-only project reaches ready and animated without an executable JavaScript worker")
        let initial=runtime.frameCount,initialImage=runtime.posterImage!.dataProvider!.data!
        try await Task.sleep(for:.milliseconds(300))
        try check(runtime.frameCount>initial && runtime.activeRuntime>0,"actual serialized frame loop publishes particle frames and advances runtime")
        try check(initialImage != runtime.posterImage!.dataProvider!.data!,"published native particle pixels move with authored velocity")
        runtime.setPaused(true)
        try await Task.sleep(for:.milliseconds(60))
        let pausedCount=runtime.frameCount,pausedTime=runtime.activeRuntime
        try await Task.sleep(for:.milliseconds(200))
        try check(runtime.state == .paused && runtime.frameCount==pausedCount && runtime.activeRuntime==pausedTime,"paused particle renderer stops both frames and active time")
        runtime.setPaused(false)
        try await Task.sleep(for:.milliseconds(160))
        try check(runtime.state == .ready && runtime.frameCount>pausedCount && runtime.activeRuntime>pausedTime,"resume restarts native particle frame loop")
        runtime.dispose();let disposed=runtime.frameCount
        try await Task.sleep(for:.milliseconds(100))
        try check(runtime.state == .disposed && runtime.frameCount==disposed,"dispose stops particle rendering permanently")
        if advanced {
            let reopened=try SceneWallpaperRuntime(projectURL:root.appendingPathComponent("project.json"),workerExecutableURL:root.appendingPathComponent("still-no-worker"))
            reopened.setPaused(true);try await reopened.load(propertiesJSON:Data("{}".utf8))
            try check(reopened.state == .paused && reopened.isAnimated && reopened.frameCount==1 && reopened.posterImage!.dataProvider!.data! == initialImage,"reopening advanced particle project resets deterministic initial state without an old frame loop or simulation")
            reopened.dispose()
        }
        let data=try JSONSerialization.data(withJSONObject:["success":true,"checks":checks,"checkCount":checks.count,"foregroundWindowCreated":false,"userLibraryModified":false,"advancedMetalRenderer":advanced],options:[.prettyPrinted,.sortedKeys])
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:output)
        print(String(decoding:data,as:UTF8.self))
    }
}
