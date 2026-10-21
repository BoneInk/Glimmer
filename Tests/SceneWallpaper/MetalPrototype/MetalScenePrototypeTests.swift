import Foundation
import CoreGraphics
import ImageIO

private actor MetalCancellationStartGate {
    private var ready = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { ready = true; waiter?.resume(); waiter = nil }
    func wait() async { if !ready { await withCheckedContinuation { waiter = $0 } } }
}

/// Test-only cross-thread holder. Production access is serialized by the actual
/// compositor lease; the fixture's error state is protected independently.
private final class MetalExclusiveFixture: @unchecked Sendable {
    let gpu: MetalSceneCompositor
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var error: String?
    init(_ gpu: MetalSceneCompositor) { self.gpu = gpu }
    func hold() {
        defer { done.signal() }
        do {
            try gpu.withExclusiveRender {
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw SceneWallpaperFailure(message: "fixture release timeout") }
            }
        } catch { lock.lock(); self.error = error.localizedDescription; lock.unlock() }
    }
    func failure() -> String? { lock.lock(); defer { lock.unlock() }; return error }
    func waitForEntry() async -> Bool { await wait(entered) }
    func waitForCompletion() async -> Bool { await wait(done) }
    private func wait(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success) }
        }
    }
}

@main @MainActor enum MetalScenePrototypeTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SceneWallpaperFailure(message:message) }
        checks += 1; print("PASS \(message)")
    }
    static func reject(_ message: String, _ block: () throws -> Void) throws {
        do { try block() } catch { try check(true,message); return }
        throw SceneWallpaperFailure(message:"Unexpected success: " + message)
    }
    static func layer(_ id: Int, texture: String = "tex", parent: Int? = nil, group: Bool = false,
                      x: Double = 16, y: Double = 16, angle: Double = 0, sx: Double = 1, sy: Double = 1,
                      width: Double = 24, height: Double = 24, color: SceneVector3 = .init(x:1,y:1,z:1), alpha: Double = 1, visible: Bool = true) -> SceneImageLayer {
        .init(id:id,name:"synthetic \(id)",modelPath:"",materialPath:"",texturePath:group ? "" : texture,
              origin:.init(x:x,y:y,z:0),anglesDegrees:.init(x:0,y:0,z:angle),scale:.init(x:sx,y:sy,z:1),
              size:group ? .init(x:1,y:1) : .init(x:width,y:height),tint:group ? .init(x:1,y:1,z:1) : color,
              opacity:group ? 1 : alpha,isVisible:visible,bindings:[],parentID:parent,isTransformOnly:group)
    }
    static func asset(_ rgba: [UInt8], width: Int = 1, height: Int = 1, imageWidth: Int? = nil, imageHeight: Int? = nil, flags: UInt32 = 1) -> SceneTextureAsset {
        .init(path:"tex",format:.rgba8888,flags:flags,data:Data(rgba),storageWidth:width,storageHeight:height,imageWidth:imageWidth ?? width,imageHeight:imageHeight ?? height)
    }
    static func inspection(_ layers: [SceneImageLayer], _ texture: SceneTextureAsset, camera: SceneCamera2D = .identity) -> SceneWallpaperInspection {
        .init(canvasSize:.init(x:32,y:32),clearColor:.init(x:0.08,y:0.16,z:0.24),camera:camera,layers:layers,textures:["tex":texture],diagnostics:[])
    }
    static func compare(_ gpu: MetalSceneCompositor, _ input: SceneWallpaperInspection, width: Int = 32, height: Int = 32, label: String, tolerance: Int = 3) throws {
        let size = CGSize(width:width,height:height)
        let cpu = try SceneWallpaperRenderer.render(inspection:input,pixelSize:size)
        let actual = try gpu.render(inspection:input,pixelSize:size)
        let expected = Array(cpu.dataProvider!.data! as Data), result = Array(actual.rgba)
        var tested = 0
        // CPU edge coverage/high-quality filtering differs from Metal. Compare
        // stable 3x3 CPU interiors; dedicated full-frame RGBA tests cover alpha.
        for y in 1..<height-1 { for x in 1..<width-1 {
            let i = (y*width+x)*4
            let stable = (-1...1).allSatisfy { dy in (-1...1).allSatisfy { dx in
                let j = ((y+dy)*width+x+dx)*4
                return (0..<4).allSatisfy{expected[j+$0] == expected[i+$0]}
            } }
            if stable {
                for c in 0..<4 { guard abs(Int(expected[i+c])-Int(result[i+c])) <= tolerance else {
                    throw SceneWallpaperFailure(message:"\(label) CPU/GPU mismatch at \(x),\(y) channel\(c): \(expected[i+c]) vs \(result[i+c])")
                } }
                tested += 1
            }
        } }
        try check(tested > 80,"\(label): \(tested) CPU-reference stable interior pixels")
    }
    static func center(_ result: MetalSceneReadback) -> [UInt8] {
        let i = (result.height/2*result.width+result.width/2)*4
        return Array(result.rgba[i..<i+4])
    }
    static func near(_ actual: [UInt8], _ expected: [Int], tolerance: Int = 1) -> Bool {
        zip(actual,expected).allSatisfy { abs(Int($0)-$1) <= tolerance }
    }
    static func main() async throws {
        let gpu = try MetalSceneCompositor()
        print("ACTUAL METAL DEVICE: \(gpu.deviceName)")
        let white = asset([255,255,255,255])
        try compare(gpu,inspection([layer(1)],white),label:"opaque texture and clear")
        let quadrant = asset([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255],width:2,height:2)
        try compare(gpu,inspection([layer(1)],quadrant),label:"asymmetric four-corner UV orientation")
        try compare(gpu,inspection([layer(1,color:.init(x:0.25,y:0.5,z:0.75),alpha:0.4)],white),label:"tint and opacity")
        let transparent = asset([255,0,0,0, 0,255,0,128, 0,0,255,255, 255,255,255,32],width:2,height:2)
        try compare(gpu,inspection([layer(1,alpha:0.6)],transparent),label:"transparent colored edges and semi-alpha")
        let red = layer(1,color:.init(x:1,y:0,z:0),alpha:0.5), blue = layer(2,color:.init(x:0,y:0,z:1),alpha:0.75)
        try compare(gpu,inspection([red,blue],white),label:"source-over ordered occlusion")
        let first = try gpu.render(inspection:inspection([red,blue],white),pixelSize:.init(width:32,height:32))
        let second = try gpu.render(inspection:inspection([blue,red],white),pixelSize:.init(width:32,height:32))
        try check(center(first) != center(second),"reversing layers changes expected center color")
        let group = layer(9,group:true,x:16,y:16,angle:15,sx:1.5,sy:0.7)
        let child = layer(1,parent:9,x:0,y:0,angle:35,width:12,height:10)
        try compare(gpu,inspection([child,group],white),label:"parent nonuniform-scale shear and child rotation")
        try compare(gpu,inspection([layer(9,group:true,x:16,y:16,sx:-1,sy:1),layer(1,parent:9,x:0,y:0,width:18,height:12)],quadrant),label:"negative scale mirror")
        try compare(gpu,inspection([layer(9,group:true,visible:false),layer(1,parent:9,x:0,y:0)],white),label:"inherited visibility")
        try compare(gpu,inspection([layer(9,group:true,sx:0),layer(1,parent:9,x:0,y:0)],white),label:"singular zero scale draws nothing")
        let translatedCamera=SceneCamera2D(center:.init(x:5,y:-3,z:-1),eye:.init(x:5,y:-3,z:0),up:.init(x:0,y:1,z:0),zoom:1,nearZ:0.01,farZ:10_000,cameraFade:true)
        try compare(gpu,inspection([layer(1)],white,camera:translatedCamera),label:"orthographic camera XY translation")
        let rolledCamera=SceneCamera2D(center:.init(x:32,y:0,z:-1),eye:.init(x:32,y:0,z:0),up:.init(x:-1,y:0,z:0),zoom:1,nearZ:0.01,farZ:10_000,cameraFade:false)
        try compare(gpu,inspection([layer(1,width:18,height:8)],quadrant,camera:rolledCamera),label:"orthographic camera up-vector roll")
        let zoomCamera=SceneCamera2D(center:.init(x:0,y:0,z:-1),eye:.init(x:0,y:0,z:0),up:.init(x:0,y:1,z:0),zoom:1.5,nearZ:0.01,farZ:10_000,cameraFade:false)
        try compare(gpu,inspection([layer(1,x:10,y:10,width:8,height:8)],white,camera:zoomCamera),label:"orthographic camera zoom")
        let invalidCamera=SceneCamera2D(center:.init(x:0,y:0,z:-1),eye:.init(x:0,y:0,z:0),up:.init(x:0,y:0,z:0),zoom:1,nearZ:0.01,farZ:10_000,cameraFade:false)
        try reject("Metal adapter rejects manually constructed invalid camera before GPU submission") {
            _ = try gpu.render(inspection:inspection([layer(1)],white,camera:invalidCamera),pixelSize:.init(width:32,height:32))
        }
        let padded = asset([255,0,0,255, 0,255,0,255, 255,0,255,255, 255,0,255,255,
                            0,0,255,255, 255,255,0,255, 255,0,255,255, 255,0,255,255],width:4,height:2,imageWidth:2)
        try compare(gpu,inspection([layer(1)],padded),label:"padded texture top-left crop")
        try compare(gpu,inspection([layer(1,width:100,height:100)],white),width:64,height:32,label:"fit letterbox clips geometry to scene canvas")
        // Encode our own RGBA fixture; real ImageIO -> Metal upload, not a fake decoded probe.
        let image = try gpu.render(inspection:inspection([layer(1,width:32,height:32)],quadrant),pixelSize:.init(width:2,height:2)).makeImage()
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil) else { throw SceneWallpaperFailure(message:"PNG fixture failed") }
        CGImageDestinationAddImage(destination,image,nil); guard CGImageDestinationFinalize(destination) else { throw SceneWallpaperFailure(message:"PNG encode failed") }
        let encoded = SceneTextureAsset(path:"tex",format:.png,flags:1,data:png as Data,storageWidth:2,storageHeight:2,imageWidth:2,imageHeight:2)
        try compare(gpu,inspection([layer(1)],encoded),label:"real PNG decode/upload")
        let edgeTexture = ["edge":MetalSceneTexture(width:2,height:1,rgba:Data([255,0,0,0,0,0,255,255]))]
        let edgeDraw = MetalSceneDraw(source:"edge",transform:.init(a:1,b:0,c:0,d:1,tx:4,ty:0.5),size:.init(x:8,y:1),sampling:.linear,blend:.copy)
        let edge = try gpu.render(textures:edgeTexture,passes:[.init(target:"out",width:8,height:1,draws:[edgeDraw])])
        let expectedEdge = [0,0,32,96,159,223,255,255]
        for x in 0..<8 {
            let i = x*4
            try check(near(Array(edge.rgba[i..<i+4]),[0,0,expectedEdge[x],expectedEdge[x]]),"bilinear alpha edge texel \(x) filters premultiplied RGB without transparent-red halo")
        }
        let textures = ["red":MetalSceneTexture(width:1,height:1,rgba:Data([255,0,0,128])),"blue":MetalSceneTexture(width:1,height:1,rgba:Data([0,0,255,128]))]
        func draw(_ source: String, blend: MetalSceneBlend = .sourceOver) -> MetalSceneDraw {
            .init(source:source,transform:.init(a:1,b:0,c:0,d:1,tx:4,ty:4),size:.init(x:8,y:8),blend:blend)
        }
        func pass(_ target: String, _ draws: [MetalSceneDraw]) -> MetalScenePass { .init(target:target,width:8,height:8,draws:draws) }
        let normal = try gpu.render(textures:textures,passes:[pass("out",[draw("red"),draw("blue")])])
        try check(near(center(normal),[64,0,128,192]),"actual GPU premultiplied source-over matches independent RGBA equation")
        let additive = try gpu.render(textures:textures,passes:[pass("out",[draw("red"),draw("blue",blend:.additive)])])
        try check(near(center(additive),[128,0,128,255]),"explicit local additive clamps summed premultiplied RGBA")
        let copy = try gpu.render(textures:textures,passes:[pass("out",[draw("red"),draw("blue",blend:.copy)])])
        try check(near(center(copy),[0,0,128,128]),"copy overwrites instead of source-over")
        let ping = try gpu.render(textures:textures,passes:[pass("intermediate",[draw("red")]),pass("out",[draw("intermediate")])])
        try check(near(center(ping),[128,0,0,128]),"real second render pass samples prior target without double-premultiplication")
        let two = try gpu.render(textures:textures,passes:[pass("a",[draw("red")]),pass("b",[draw("a"),draw("blue")])])
        try check(two.rgba == normal.rgba,"multipass source-over equals independently composited direct result, every pixel")
        let three = try gpu.render(textures:textures,passes:[pass("a",[draw("red")]),pass("b",[draw("a")]),pass("c",[draw("b")])])
        try check(three.rgba == ping.rgba,"three-pass target handoff preserves every transparent pixel")
        try reject("same texture read/write feedback rejects") { _ = try gpu.render(textures:textures,passes:[pass("out",[draw("out")])]) }
        try reject("forward pass reference rejects") { _ = try gpu.render(textures:textures,passes:[pass("a",[draw("b")]),pass("b",[])]) }
        try reject("duplicate output resource rejects") { _ = try gpu.render(textures:textures,passes:[pass("a",[]),pass("a",[])]) }
        try reject("pass overwrites input rejects") { _ = try gpu.render(textures:textures,passes:[pass("red",[])]) }
        try reject("more than eight passes rejects before GPU allocation") { _ = try gpu.render(textures:[:],passes:(0..<9).map{pass("p\($0)",[])}) }
        try reject("invalid RGBA byte count rejects") { _ = try gpu.render(textures:["bad":.init(width:2,height:2,rgba:Data([1]))],passes:[pass("out",[])]) }
        try reject("unsafe texture dimensions reject") { _ = try gpu.render(textures:[:],passes:[.init(target:"out",width:8193,height:1,draws:[])]) }
        try reject("aggregate texture target budget rejects before allocation") { _ = try gpu.render(textures:[:],passes:(0..<3).map{.init(target:"large\($0)",width:8192,height:4096,draws:[])}) }
        try reject("draw count limit rejects") { _ = try gpu.render(textures:textures,passes:[pass("out",Array(repeating:draw("red"),count:2049))]) }
        var badClip = pass("out",[]);badClip.clip = .init(0,0,9,8)
        try reject("clip outside target rejects") { _ = try gpu.render(textures:[:],passes:[badClip]) }
        var bad = draw("red");bad.opacity = .nan
        try reject("nonfinite draw rejects") { _ = try gpu.render(textures:textures,passes:[pass("out",[bad])]) }
        var invalidClear = pass("out",[]);invalidClear.clear = .init(-1,0,0,1)
        try reject("invalid clear rejects") { _ = try gpu.render(textures:[:],passes:[invalidClear]) }
        for _ in 0..<32 {
            let result = try gpu.render(textures:textures,passes:[pass("out",[draw("red"),draw("blue")])])
            guard result.rgba == normal.rgba else { throw SceneWallpaperFailure(message:"Repeated frame polluted by old resource contents") }
        }
        try check(true,"32 repeated GPU submissions remain identical after validation failures; no prior output reuse")
        let newGPU = try MetalSceneCompositor()
        try check(try newGPU.render(textures:textures,passes:[pass("out",[draw("red"),draw("blue")])]).rgba == normal.rgba,"fresh compositor resource lifetime produces same pixels")
        weak var releasedGPU: MetalSceneCompositor?
        do {
            let temporary = try MetalSceneCompositor(); releasedGPU = temporary
            _ = try temporary.render(textures:textures,passes:[pass("out",[draw("red")])])
        }
        try check(releasedGPU == nil,"completed compositor deallocates; no self/queue retention cycle")
        let cancellation = Task.detached { () throws -> Bool in
            while !Task.isCancelled { await Task.yield() }
            let canceledGPU = try MetalSceneCompositor()
            do { _ = try canceledGPU.render(textures:[:],passes:[.init(target:"out",width:8,height:8,draws:[])]) }
            catch is CancellationError { return true }
            return false
        }
        cancellation.cancel()
        try check(try await cancellation.value,"pre-cancelled submission exits with CancellationError rather than stale pixels")
        // The 68-billion-fragment counterexample is rejected during preflight;
        // no large target or dangerous GPU load is allocated/submitted.
        let tiny = ["tiny": MetalSceneTexture(width:1,height:1,rgba:Data([255,255,255,255]))]
        let largeDraw = MetalSceneDraw(source:"tiny",transform:.init(a:1,b:0,c:0,d:1,tx:4096,ty:2048),size:.init(x:8192,y:4096))
        do {
            _ = try gpu.render(textures:tiny,passes:[.init(target:"huge",width:8192,height:4096,draws:Array(repeating:largeDraw,count:2048))])
            throw SceneWallpaperFailure(message:"Unsafe overdraw unexpectedly accepted")
        } catch {
            try check(error.localizedDescription.contains("workload budget"),"68-billion-fragment graph rejects as workload before allocation/submission")
        }
        let smallDraw = MetalSceneDraw(source:"tiny",transform:.init(a:1,b:0,c:0,d:1,tx:4,ty:4),size:.init(x:8,y:8),blend:.copy)
        let clipped = try gpu.render(textures:tiny,passes:[.init(target:"clip",width:8,height:8,
            clip:SIMD4(3.1,3.1,3.9,3.9),draws:Array(repeating:smallDraw,count:64))])
        let clippedBytes = Array(clipped.rgba)
        try check((0..<64).allSatisfy { index in
            let expected:UInt8 = index == 3*8+3 ? 255 : 0
            return (0..<4).allSatisfy { clippedBytes[index*4+$0] == expected }
        },"hardware scissor preserves exact fractional pixel-center clip semantics")
        let emptyClip = try gpu.render(textures:tiny,passes:[.init(target:"empty",width:8,height:8,
            clip:SIMD4(3.5,0,3.5,8),draws:[smallDraw])])
        try check(emptyClip.rgba.allSatisfy { $0 == 0 },"fractional zero-area clip skips draws and retains clear")
        let mediumBytes = Data(count:4096*2048*4)
        do {
            _ = try gpu.render(textures:["medium":.init(width:4096,height:2048,rgba:mediumBytes)],passes:[
                .init(target:"first",width:6144,height:4096,draws:[]),.init(target:"last",width:8192,height:4096,draws:[])])
            throw SceneWallpaperFailure(message:"Peak overcommit unexpectedly accepted")
        } catch {
            try check(error.localizedDescription.contains("peak memory"),"source/upload/readback/output peak rejects even when 256MiB GPU texture total fits")
        }
        // The fifth texture's invalid PNG bytes must not reach ImageIO: declared
        // decoded size alone exceeds remaining 128MiB budget before that decode.
        var manyTextures:[String:SceneTextureAsset]=[:], manyLayers:[SceneImageLayer]=[]
        for id in 1...5 {
            let name="t\(id)"
            manyTextures[name] = .init(path:name,format:id == 5 ? .png : .rgba8888,flags:1,
                data:id == 5 ? Data() : mediumBytes,storageWidth:4096,storageHeight:2048,imageWidth:4096,imageHeight:2048)
            manyLayers.append(layer(id,texture:name))
        }
        do {
            _ = try gpu.render(inspection:.init(canvasSize:.init(x:32,y:32),clearColor:.init(x:0,y:0,z:0),
                layers:manyLayers,textures:manyTextures,diagnostics:[]),pixelSize:.init(width:32,height:32))
            throw SceneWallpaperFailure(message:"Decoded overcommit unexpectedly accepted")
        } catch {
            try check(error.localizedDescription.contains("before decode"),"aggregate adapter decoded budget rejects invalid fifth image before ImageIO decode")
        }
        let exclusive = MetalExclusiveFixture(gpu)
        DispatchQueue.global().async { exclusive.hold() }
        guard await exclusive.waitForEntry() else { throw SceneWallpaperFailure(message:"Exclusive lease fixture did not start") }
        do {
            defer { exclusive.release.signal() }
            do {
                _ = try gpu.render(textures:tiny,passes:[pass("concurrent",[])])
                throw SceneWallpaperFailure(message:"Concurrent render unexpectedly accepted")
            } catch {
                try check(error.localizedDescription.contains("concurrent submission rejected"),"cross-thread render rejects while actual exclusive lease is held")
            }
            do {
                _ = try gpu.render(inspection:inspection([layer(1)],white),pixelSize:.init(width:32,height:32))
                throw SceneWallpaperFailure(message:"Concurrent adapter unexpectedly decoded")
            } catch {
                try check(error.localizedDescription.contains("concurrent submission rejected"),"inspection adapter shares the lease before decoding")
            }
        }
        guard await exclusive.waitForCompletion(), exclusive.failure() == nil else { throw SceneWallpaperFailure(message:"Exclusive lease fixture did not clean up") }
        try check(try gpu.render(textures:textures,passes:[pass("out",[draw("red"),draw("blue")])]).rgba == normal.rgba,
                  "lease releases after concurrent rejection and next actual GPU submission succeeds")
        let gate = MetalCancellationStartGate()
        let duringUpload = Task.detached { () throws -> Bool in
            let local = try MetalSceneCompositor()
            let bytes = Data(repeating:128,count:4096*2048*4)
            await gate.signal()
            do {
                _ = try local.render(textures:["large":.init(width:4096,height:2048,rgba:bytes)],passes:[.init(target:"out",width:1,height:1,draws:[])])
                return false
            } catch is CancellationError { return true }
        }
        await gate.wait(); try await Task.sleep(for:.milliseconds(15))
        let cancelledAt = Date(); duringUpload.cancel()
        let cancelledDuringUpload = try await duringUpload.value
        let cancelWait = Date().timeIntervalSince(cancelledAt)
        try check(cancelledDuringUpload && cancelWait < 1,"row-chunk cancellation during CPU upload returns without waiting for entire image")
        print("HARDENED upload-cancel wait seconds: \(cancelWait)")
        let output:[String:Any] = ["passed":checks,"device":gpu.deviceName,"backend":"Metal real render pipelines + private RGBA8Unorm targets + blit readback","workBudget":MetalSceneCompositor.maximumSampleWork,"conservativePeakByteBudget":MetalSceneCompositor.maximumPeakBytes,"uploadCancellationWaitSeconds":cancelWait,"reference":"existing CoreGraphics sRGB byte-domain renderer stable interiors; independent premultiplied RGBA equations for full-frame blend/multipass","notClaimed":["Wallpaper Engine shader/effect compatibility","Windows pixel parity","sRGB linear-light blending","CPU/GPU edge antialias or cubic/bilinear parity","runtime replacement","performance improvement"]]
        if let index = CommandLine.arguments.firstIndex(of:"--evidence"), index+1 < CommandLine.arguments.count {
            try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
        }
        print("RESULT \(checks) actual-Metal checks passed")
    }
}
