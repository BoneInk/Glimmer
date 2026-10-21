import Foundation
import CryptoKit
import IOSurface
import Metal
import OpenWallpaperEngine

@main struct SceneBackendProbe {
    static func main() {
        DispatchQueue.main.asyncAfter(deadline:.now()+180) { fputs("backend probe timed out\n",stderr); exit(2) }
        Task { do { try await run(); exit(0) } catch { fputs("backend probe failed: \(error)\n",stderr); exit(1) } }
        RunLoop.current.run()
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 || args.count == 7 else { throw NSError(domain:"Probe",code:1) }
        let project = URL(fileURLWithPath:args[1]), assets = URL(fileURLWithPath:args[2]), cache = URL(fileURLWithPath:args[3])
        let roots = SceneBackendRoots(projectRoot:project,assetsRoot:assets,cacheRoot:cache,
            projectDigest:SHA256.hash(data:try Data(contentsOf:project.appending(path:"project.json"))).map{String(format:"%02x",$0)}.joined(),
            assetsManifestDigest:args[4])
        let requestedFPS = Int(ProcessInfo.processInfo.environment["SCENE_BACKEND_PROBE_FPS"] ?? "30") ?? 30
        let aspectChangeExpected = ProcessInfo.processInfo.environment["SCENE_BACKEND_PROBE_ASPECT_CHANGE_EXPECTED"] != "NO"
        let outputWidth = Int(ProcessInfo.processInfo.environment["SCENE_BACKEND_PROBE_WIDTH"] ?? "640") ?? 640
        let outputHeight = Int(ProcessInfo.processInfo.environment["SCENE_BACKEND_PROBE_HEIGHT"] ?? "400") ?? 400
        let config = SceneBackendConfiguration(protocolVersion:1,sessionID:UUID(),generation:1,roots:roots,
            width:outputWidth,height:outputHeight,framesPerSecond:requestedFPS,properties:[:])
        let connection = NSXPCConnection(serviceName:"com.boneink.Glimmer.SceneBackend")
        let interface = NSXPCInterface(with:SceneBackendRemote.self)
        interface.setClasses(NSSet(object: IOSurface.self) as! Set<AnyHashable>,for:#selector(SceneBackendRemote.render(_:reply:)),argumentIndex:1,ofReply:true)
        connection.remoteObjectInterface = interface; connection.resume()
        defer { connection.invalidate() }
        let remote = connection.remoteObjectProxyWithErrorHandler { error in fputs("XPC error: \(error)\n",stderr); exit(1) } as! SceneBackendRemote
        func status(_ service: SceneBackendRemote) async throws -> SceneBackendProcessStatus {
            let data: Data = await withCheckedContinuation { done in service.status { done.resume(returning: $0) } }
            return try JSONDecoder().decode(SceneBackendProcessStatus.self, from: data)
        }
        let ownerStatus = try await status(remote)
        precondition(ownerStatus.ownsSession && ownerStatus.helperPID != getpid())
        if args.count == 7 {
            let expectedCode = "scene_backend_" + args[6]
            let rejected: Bool = await withCheckedContinuation { done in
                remote.prepare(try! JSONEncoder().encode(config)) { _, error in
                    done.resume(returning: error?.localizedDescription == expectedCode)
                }
            }
            precondition(rejected)
            try JSONSerialization.data(withJSONObject: ["success":true,"rejected":true,"expectedCode":expectedCode,
                "helperPID":ownerStatus.helperPID,"probePID":getpid(),"requestedFPS":requestedFPS], options:[.prettyPrinted,.sortedKeys])
                .write(to: URL(fileURLWithPath:args[5]))
            return
        }
        let secondConnection = NSXPCConnection(serviceName: "com.boneink.Glimmer.SceneBackend")
        secondConnection.remoteObjectInterface = interface; secondConnection.resume()
        defer { secondConnection.invalidate() }
        let secondRemote = secondConnection.remoteObjectProxyWithErrorHandler { error in
            fputs("second XPC error: \(error)\n", stderr); exit(1)
        } as! SceneBackendRemote
        let secondStatus = try await status(secondRemote)
        let sharedServiceInstance = ownerStatus.helperPID == secondStatus.helperPID && ownerStatus.instanceID == secondStatus.instanceID
        if sharedServiceInstance { precondition(!secondStatus.ownsSession) }
        var observerPrepareRejected = false
        if sharedServiceInstance {
            observerPrepareRejected = await withCheckedContinuation { done in
                secondRemote.prepare(try! JSONEncoder().encode(config)) { _, error in
                    done.resume(returning: error?.localizedDescription == "scene_backend_alreadyConfigured")
                }
            }
            precondition(observerPrepareRejected)
        }
        secondConnection.invalidate()
        let afterObserverExit = try await status(remote)
        precondition(afterObserverExit.helperPID == ownerStatus.helperPID && afterObserverExit.instanceID == ownerStatus.instanceID)
        let independentConnection = NSXPCConnection(serviceName: SceneBackendServiceCatalog.identifiers[1])
        independentConnection.remoteObjectInterface = interface; independentConnection.resume()
        defer { independentConnection.invalidate() }
        let independentRemote = independentConnection.remoteObjectProxyWithErrorHandler { error in
            fputs("independent XPC error: \(error)\n", stderr); exit(1)
        } as! SceneBackendRemote
        let independentStatus = try await status(independentRemote)
        precondition(independentStatus.ownsSession && independentStatus.helperPID != ownerStatus.helperPID
            && independentStatus.instanceID != ownerStatus.instanceID)
        let prepared: Data = try await withCheckedThrowingContinuation { done in
            remote.prepare(try! JSONEncoder().encode(config)) { data,error in
                if let error { done.resume(throwing:error) } else if let data { done.resume(returning:data) }
                else { done.resume(throwing:NSError(domain:"Probe",code:2)) }
            }
        }
        let readiness = try JSONDecoder().decode(SceneBackendReadiness.self,from:prepared)
        precondition(readiness.isStrictlyReady)
        let peerProject = ProcessInfo.processInfo.environment["SCENE_BACKEND_PROBE_PEER_PROJECT"].map { URL(fileURLWithPath: $0) } ?? project
        let peerRoots = SceneBackendRoots(projectRoot:peerProject,assetsRoot:assets,
            cacheRoot:cache.deletingLastPathComponent().appending(path:cache.lastPathComponent + "-peer"),
            projectDigest:SHA256.hash(data:try Data(contentsOf:peerProject.appending(path:"project.json"))).map{String(format:"%02x",$0)}.joined(),
            assetsManifestDigest:args[4])
        let peerConfig = SceneBackendConfiguration(protocolVersion:1,sessionID:UUID(),generation:1,roots:peerRoots,
            width:outputWidth,height:outputHeight,framesPerSecond:requestedFPS,properties:[:])
        let peerPrepared: Data = try await withCheckedThrowingContinuation { done in
            independentRemote.prepare(try! JSONEncoder().encode(peerConfig)) { data,error in
                if let error { done.resume(throwing:error) } else if let data { done.resume(returning:data) }
                else { done.resume(throwing:NSError(domain:"Probe",code:5)) }
            }
        }
        let peerReadiness = try JSONDecoder().decode(SceneBackendReadiness.self,from:peerPrepared)
        precondition(peerReadiness.isStrictlyReady)
        let device = MTLCreateSystemDefaultDevice()!
        func frame(_ seq:UInt64,_ time:Double, service: SceneBackendRemote? = nil,
                   session: SceneBackendConfiguration? = nil) async throws -> (SceneFrameToken,String) {
            let service = service ?? remote
            let requestConfig = session ?? config
            let input = SceneFrameInput(sessionID:requestConfig.sessionID,generation:requestConfig.generation,sequence:seq,
                elapsedSeconds:time,cursorX:320,cursorY:180,leftMouseDown:false)
            let (tokenData,surface):(Data,IOSurface) = try await withCheckedThrowingContinuation { done in
                service.render(try! JSONEncoder().encode(input)) { token,surface,error in
                    if let error { done.resume(throwing:error) }
                    else if let token,let surface { done.resume(returning:(token,surface)) }
                    else { done.resume(throwing:NSError(domain:"Probe",code:3)) }
                }
            }
            let token = try JSONDecoder().decode(SceneFrameToken.self,from:tokenData)
            precondition(token.width==outputWidth && token.height==outputHeight && surface.width==outputWidth && surface.height==outputHeight)
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:outputWidth,height:outputHeight,mipmapped:false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
            guard let texture=device.makeTexture(descriptor:descriptor,iosurface:surface,plane:0) else { throw NSError(domain:"Probe",code:4) }
            var bytes=[UInt8](repeating:0,count:outputWidth*outputHeight*4)
            texture.getBytes(&bytes,bytesPerRow:outputWidth*4,from:MTLRegionMake2D(0,0,outputWidth,outputHeight),mipmapLevel:0)
            precondition(stride(from:0,to:bytes.count,by:4).contains { bytes[$0]>2 || bytes[$0+1]>2 || bytes[$0+2]>2 })
            let hash=SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
            try await withCheckedThrowingContinuation { (done:CheckedContinuation<Void,Error>) in
                service.acknowledge(tokenData) { if let error=$0 { done.resume(throwing:error) } else { done.resume() } }
            }
            return(token,hash)
        }
        let peerFirst = try await frame(1,0,service:independentRemote,session:peerConfig)
        let first = try await frame(1,0)
        let duplicateAckRejected: Bool = await withCheckedContinuation { done in
            remote.acknowledge(try! JSONEncoder().encode(first.0)) { done.resume(returning: $0 != nil) }
        }
        let staleFrameRejected: Bool = await withCheckedContinuation { done in
            let input = SceneFrameInput(sessionID: config.sessionID, generation: config.generation,
                sequence: 1, elapsedSeconds: 0, cursorX: nil, cursorY: nil, leftMouseDown: false)
            remote.render(try! JSONEncoder().encode(input)) { _, _, error in done.resume(returning: error != nil) }
        }
        let unknownPropertyRejected: Bool = await withCheckedContinuation { done in
            remote.updateProperties(try! JSONEncoder().encode(["__unknown_probe_property": "value"]), revision: 1) {
                done.resume(returning: $0 != nil)
            }
        }
        precondition(duplicateAckRejected && staleFrameRejected && unknownPropertyRejected)
        let advanced = try await frame(2,0.25)
        let beforeUpdates = try await status(remote)
        precondition((beforeUpdates.sceneSeconds ?? 0) > 0)
        var liveFPS: [Int] = []
        for fps in [1,240,30] {
            try await withCheckedThrowingContinuation { (done:CheckedContinuation<Void,Error>) in
                remote.setFrameRateLimit(fps) { if let error=$0 { done.resume(throwing:error) } else { done.resume() } }
            }
            let state = try await status(remote)
            precondition(state.frameRateLimit == fps && state.sceneSeconds == beforeUpdates.sceneSeconds
                && state.helperPID == beforeUpdates.helperPID && state.instanceID == beforeUpdates.instanceID
                && state.sessionID == config.sessionID && state.generation == config.generation)
            liveFPS.append(state.frameRateLimit!)
        }
        for fps in [0,241] {
            let rejected: Bool = await withCheckedContinuation { done in
                remote.setFrameRateLimit(fps) { done.resume(returning: $0?.localizedDescription == "scene_backend_invalidConfiguration") }
            }
            precondition(rejected)
        }
        try await withCheckedThrowingContinuation { (done:CheckedContinuation<Void,Error>) in
            remote.setPaused(true) { if let error=$0 { done.resume(throwing:error) } else { done.resume() } }
        }
        let paused = try await frame(3,0.5); precondition(advanced.1==paused.1)
        let pausedState = try await status(remote)
        try await withCheckedThrowingContinuation { (done:CheckedContinuation<Void,Error>) in
            remote.setFrameRateLimit(240) { if let error=$0 { done.resume(throwing:error) } else { done.resume() } }
        }
        try await withCheckedThrowingContinuation { (done:CheckedContinuation<Void,Error>) in
            remote.setAspectFill(false) { if let error=$0 { done.resume(throwing:error) } else { done.resume() } }
        }
        let fitted = try await frame(4,0.5)
        let fitState = try await status(remote)
        precondition((!aspectChangeExpected || fitted.1 != paused.1) && fitState.sceneSeconds == pausedState.sceneSeconds
            && fitState.aspectFill == false && fitState.frameRateLimit == 240 && fitState.paused == true)
        try await withCheckedThrowingContinuation { (done:CheckedContinuation<Void,Error>) in
            remote.setAspectFill(true) { if let error=$0 { done.resume(throwing:error) } else { done.resume() } }
        }
        let filled = try await frame(5,0.5)
        let fillState = try await status(remote)
        precondition(filled.1 == paused.1 && fillState.sceneSeconds == pausedState.sceneSeconds && fillState.aspectFill == true
            && fillState.helperPID == beforeUpdates.helperPID && fillState.sessionID == config.sessionID)
        try await withCheckedThrowingContinuation { (done:CheckedContinuation<Void,Error>) in
            remote.setPaused(false) { if let error=$0 { done.resume(throwing:error) } else { done.resume() } }
        }
        let resumed = try await frame(6,0.75)
        let resumedState = try await status(remote)
        precondition((resumedState.sceneSeconds ?? 0) > (pausedState.sceneSeconds ?? 0))
        await withCheckedContinuation { done in independentRemote.close(peerConfig.sessionID,generation:peerConfig.generation) { done.resume() } }
        await withCheckedContinuation { done in remote.close(config.sessionID,generation:config.generation) { done.resume() } }
        let closedRejected:Bool = await withCheckedContinuation { done in
            remote.render(try! JSONEncoder().encode(SceneFrameInput(sessionID:config.sessionID,generation:1,sequence:7,
                elapsedSeconds:1,cursorX:nil,cursorY:nil,leftMouseDown:false))) { _,_,error in done.resume(returning:error != nil) }
        }
        precondition(closedRejected)
        let result:[String:Any] = ["success":true,"strictReady":true,"configuredFPS":requestedFPS,"outputWidth":outputWidth,"outputHeight":outputHeight,"separateHelperPID":connection.processIdentifier,
            "probePID":getpid(),"helperPID":ownerStatus.helperPID,"helperInstanceID":ownerStatus.instanceID.uuidString,
            "secondConnectionPID":secondStatus.helperPID,"secondConnectionInstanceID":secondStatus.instanceID.uuidString,
            "sameServiceConnectionsShareProcess":sharedServiceInstance,"secondConnectionOwnsSession":secondStatus.ownsSession,"observerPrepareRejected":observerPrepareRejected,
            "ownerSurvivedObserverInvalidation":afterObserverExit.instanceID == ownerStatus.instanceID,
            "independentServicePID":independentStatus.helperPID,"independentServiceInstanceID":independentStatus.instanceID.uuidString,
            "differentServiceIdentifiersUseSeparateProcesses":independentStatus.helperPID != ownerStatus.helperPID,
            "twoConcurrentScenesStrictReady":peerReadiness.isStrictlyReady && readiness.isStrictlyReady,
            "peerFrameSHA":peerFirst.1,"peerProjectDigest":peerRoots.projectDigest,"surfaceDecoded":true,"nonBlack":true,"duplicateAckRejected":duplicateAckRejected,
            "staleFrameRejected":staleFrameRejected,"unknownPropertyRejected":unknownPropertyRejected,"firstSHA":first.1,"pausedSHA":paused.1,
            "resumedSHA":resumed.1,"beforePauseSHA":advanced.1,"pauseHeldExactFrame":advanced.1==paused.1,
            "liveFPSUpdates":liveFPS,"liveFPSBoundsRejected":true,"configurationKeptPIDSessionClock":true,
            "clockBeforeConfiguration":beforeUpdates.sceneSeconds!,"clockWhilePaused":pausedState.sceneSeconds!,
            "clockAfterResume":resumedState.sceneSeconds!,"pausedFitSHA":fitted.1,"pausedRestoredFillSHA":filled.1,
            "pausedAspectChangeExpected":aspectChangeExpected,"pausedAspectChangedActualPixels":fitted.1 != paused.1,"pausedAspectKeptClock":fitState.sceneSeconds == pausedState.sceneSeconds,"closeRejectedFurtherFrames":closedRejected,
            "productionChanged":false,"windowsPixelEquivalenceClaim":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[5]))
    }
}
