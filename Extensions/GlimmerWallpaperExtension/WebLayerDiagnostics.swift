#if GW_DIAGNOSTIC_ENTRY
import AppKit
import CoreVideo
import CryptoKit
import WebKit

@MainActor
final class GWWebLayerDiagnostics {
    private struct Request {
        let size: CGSize
        let scaleFactor: CGFloat
        let isPreview = false
        let presentationMode = "default"
        let activityState: String
    }
    let surface: GWWebLayerSurface
    private let size: CGSize
    private let scale: CGFloat
    private var input = Data()

    init(directory: URL, receiver: Bool) async throws {
        let (config, url) = try GWConfiguration.load(directory: directory, isolatedProbe: true)
        let recipe = try LiveWallpaperBundle.load(url)
        scale = receiver ? 2 : 1
        size = CGSize(width: CGFloat(recipe.width) / scale, height: CGFloat(recipe.height) / scale)
        surface = try GWWebLayerSurface(config: config, directory: url, recipe: recipe,
            request: GWRequest(Request(size: size, scaleFactor: scale, activityState: "active")))
    }

    func start() async throws {
        var started = false
        surface.start { started = $0 }
        try await wait { started || self.surface.lastError != nil }
        guard started else { throw GWError(90, surface.lastError ?? "Web layer startup failed") }
        try await installCounter()
    }

    private func wait(seconds: Double = 25, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard condition() else { throw GWError(91, surface.lastError ?? "Web layer transition timed out") }
    }

    private func text(_ script: String) async throws -> String {
        guard let web = surface.runtime?.webView else { throw GWError(92, "Web document is not active") }
        let race = SceneBackendDeadlineRace<String>()
        web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { value in
            switch value {
            case .success(let object): race.finish(.success(object as? String ?? ""))
            case .failure(let error): race.finish(.failure(error))
            }
        }
        return try await race.wait(seconds: 5)
    }

    private func installCounter() async throws {
        _ = try await text("""
        if (!window.__gwLayerCounter) {
          window.__gwLayerCounter={frames:0};
          const tick=()=>{window.__gwLayerCounter.frames++;requestAnimationFrame(tick);};
          requestAnimationFrame(tick);
          const v=document.querySelector('video');
          window.__gwLayerCounter.events=[];
          if(v) for(const name of ['ended','seeking','seeked','waiting','playing','pause','stalled','error'])
            v.addEventListener(name,()=>{
              const events=window.__gwLayerCounter.events;
              events.push({name,time:performance.now(),media:v.currentTime});
              if(events.length>24)events.shift();
            });
        }
        return '';
        """)
    }

    func metrics() async throws -> [String: Any] {
        let json = try await text("""
        const v=document.querySelector('video');
        return JSON.stringify({now:performance.now(),wall:Date.now(),raf:window.__gwLayerCounter?.frames || 0,
          videoWidth:v?.videoWidth || 0,videoTime:v?.currentTime || 0,videoPaused:v?.paused ?? true,
          videoFrames:v?.getVideoPlaybackQuality?.().totalVideoFrames || 0,
          duration:v?.duration,ended:v?.ended,seeking:v?.seeking,readyState:v?.readyState,
          networkState:v?.networkState,error:v?.error?.code || 0,playbackRate:v?.playbackRate,
          events:window.__gwLayerCounter?.events || [],
          clock:document.getElementById('clock')?.textContent || '', network:window.networkResult || '',dpr:devicePixelRatio,
          hasVideo:!!v, fixture:window.__gwMediaMatrix?.sample?.() || null,
          audioTracks:v?.audioTracks ? Array.from(v.audioTracks,t=>({id:t.id,enabled:t.enabled,language:t.language})) : null,
          videoTracks:v?.videoTracks ? Array.from(v.videoTracks,t=>({id:t.id,selected:t.selected})) : null,
          source:v?.currentSrc || ''});
        """)
        var result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        result["pageAudioMuted"] = ((surface.runtime?.webView.value(forKey: "_mediaMutedState") as? NSNumber)?.uintValue ?? 0) & 1 == 1
        result["contextID"] = surface.context.contextId
        result["documentCount"] = surface.documentCount
        result["runtimeState"] = surface.runtime?.state.rawValue ?? "released"
        return result
    }

    private func waitForVideo() async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            let value = try await metrics()
            if value["hasVideo"] as? Bool == false { return }
            if (value["videoWidth"] as? Int ?? 0) > 0,
               (value["videoTime"] as? Double ?? 0) > 0.1, value["videoPaused"] as? Bool == false { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let value = try await metrics()
        throw GWError(93, "Video did not resume in the live Web layer: \(value)")
    }

    func pause(sleep: Bool = false) async throws {
        if sleep { surface.setSleeping(true) }
        else { surface.update(GWRequest(Request(size: size, scaleFactor: scale, activityState: "inactive"))) }
        try await wait { self.surface.runtime == nil && !self.surface.isReconciling }
    }

    func resume(sleep: Bool = false) async throws {
        if sleep { surface.setSleeping(false) }
        else { surface.update(GWRequest(Request(size: size, scaleFactor: scale, activityState: "active"))) }
        try await wait { self.surface.isPlaying && !self.surface.isReconciling }
        try await installCounter()
        try await waitForVideo()
    }

    func benchmark() async throws -> [String: Any] {
        try await waitForVideo()
        let first = try await metrics()
        let snapshots = surface.snapshotCount
        try await Task.sleep(for: .seconds(3))
        let last = try await metrics()
        let duration = ((last["now"] as? Double ?? 0) - (first["now"] as? Double ?? 0)) / 1000
        let count = (last["raf"] as? Int ?? 0) - (first["raf"] as? Int ?? 0)
        return ["start":first,"end":last,"seconds":duration,"rafCallbacksPerSecond":Double(count)/max(duration,0.001),
                "snapshotsDuringPlayback":surface.snapshotCount-snapshots,
                "scope":"Page callback cadence; not measured lock-screen scanout FPS"]
    }

    func run() async {
        var result: [String: Any] = ["systemWallpaperModified":false,"sandboxActive":GWSandboxIsActive(),"kind":"web"]
        do {
            try await start()
            let contextID = surface.context.contextId
            let measurement = try await benchmark()
            result["measurement"] = measurement
            let first = try await surface.snapshot()!
            let firstSignature = signature(first)
            let count = surface.snapshotCount
            try await Task.sleep(for: .seconds(1))
            result["noPeriodicSnapshots"] = surface.snapshotCount == count
            let hostUnshown = surface.host?.isOrderedOnScreen == false
            let muted = ((surface.runtime?.webView.value(forKey: "_mediaMutedState") as? NSNumber)?.uintValue ?? 0) & 1 == 1
            var network = try await metrics()["network"] as? String ?? ""
            if surface.recipe.allowHTTPS && network == "pending" {
                let deadline = ContinuousClock.now + .seconds(20)
                while network == "pending", ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    network = try await metrics()["network"] as? String ?? ""
                }
            }
            result["networkResult"] = network
            try await pause()
            let held = surface.lastBuffer
            let pausedSnapshots = surface.snapshotCount
            try await Task.sleep(for: .milliseconds(300))
            let heldOnPause = held === surface.lastBuffer && surface.snapshotCount == pausedSnapshots
            try await resume()
            let resumeMeasurement = try await benchmark()
            let resumed = try await metrics()
            let latest = try await surface.snapshot()!
            result["resumedChangingFrames"] = signature(latest) != firstSignature
            let clock = resumed["clock"] as? String ?? ""
            let clockCurrent = Double(clock).map { abs($0/1000-Date().timeIntervalSince1970) < 3 } ?? true
            result["currentWallClockAfterPause"] = clockCurrent
            result["resumedMeasurement"] = resumeMeasurement
            try await pause(sleep:true)
            let sleepHeld = surface.runtime == nil && surface.lastBuffer != nil
            try await resume(sleep:true)
            result["videoPlayingAfterWake"] = try await metrics()["videoPaused"] as? Bool == false
            let response = createRemoteContextXPC(contextId: contextID)
            let snapshot = GWSnapshot(latest)
            result["contextXPCTransport"] = response.map { GWXPCObjectRoundTrip($0,3) } ?? false
            result["snapshotXPCTransport"] = snapshot.map { GWXPCObjectRoundTrip($0,3) } ?? false
            result["webRenderHostUnshown"] = hostUnshown && surface.host?.isOrderedOnScreen == false
            result["pageAudioMuted"] = muted
            result["defaultModePlayback"] = surface.isPlaying
            result["pausedFrameHeld"] = heldOnPause
            result["hiddenWebDocumentReleased"] = heldOnPause
            result["sleepFrameHeld"] = sleepHeld
            result["wakeResumedSameContext"] = contextID == surface.context.contextId && surface.isPlaying
            result["documentCount"] = surface.documentCount
            result["snapshotCount"] = surface.snapshotCount
            result["frameCount"] = surface.snapshotCount // retained diagnostic compatibility; not playback FPS
            result["ownedHelperExited"] = true
            surface.stop()
            result["releasedContextAndFrames"] = surface.context.layer == nil && surface.lastBuffer == nil && surface.host == nil
            let keys = ["noPeriodicSnapshots","resumedChangingFrames","currentWallClockAfterPause","videoPlayingAfterWake",
                        "contextXPCTransport","snapshotXPCTransport","webRenderHostUnshown","pageAudioMuted",
                        "defaultModePlayback","pausedFrameHeld","hiddenWebDocumentReleased","sleepFrameHeld",
                        "wakeResumedSameContext","releasedContextAndFrames"]
            result["success"] = keys.allSatisfy { result[$0] as? Bool == true } && GWSandboxIsActive()
            emit(result); exit(result["success"] as? Bool == true ? 0:1)
        } catch {
            surface.stop(); result["success"] = false; result["error"] = error.localizedDescription
            emit(result); exit(1)
        }
    }

    func serve() async throws {
        try await start()
        emit(["event":"context","contextID":surface.context.contextId,"pid":getpid(),
              "width":surface.recipe.width,"height":surface.recipe.height,"sandboxActive":GWSandboxIsActive(),
              "producerWindowOrdered":surface.host?.isOrderedOnScreen ?? true,"snapshotCallsForPlayback":0])
        FileHandle.standardInput.readabilityHandler = { [weak self] file in
            let data = file.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        let measurement = try await benchmark()
        emit(["event":"measurement","value":measurement,"snapshotCount":surface.snapshotCount])
    }

    private func reload() async throws {
        guard let runtime = surface.runtime else { throw GWError(94, "No active Web document") }
        runtime.reload()
        try await wait { runtime.state == .ready || runtime.state == .failed }
        guard runtime.state == .ready else { throw GWError(95, runtime.lastError ?? "Web reload failed") }
        try await installCounter()
        try await waitForVideo()
    }

    private func receive(_ data: Data) {
        if data.isEmpty { surface.stop(); exit(0) }
        input.append(data)
        while let line = input.range(of: Data([10])) {
            let command = String(data: input[..<line.lowerBound],encoding:.utf8) ?? ""
            input.removeSubrange(...line.lowerBound)
            Task { @MainActor in
                do {
                    if command == "pause" { try await self.pause(); self.emit(["event":"paused","success":true]) }
                    else if command == "resume" { try await self.resume(); self.emit(["event":"resumed","value":try await self.metrics()]) }
                    else if command == "metrics" { self.emit(["event":"metrics","value":try await self.metrics(),"snapshotCount":self.surface.snapshotCount]) }
                    else if command == "reload" { try await self.reload(); self.emit(["event":"reloaded","value":try await self.metrics()]) }
                    else if command == "sleep" { try await self.pause(sleep: true); self.emit(["event":"sleeping"]) }
                    else if command == "wake" { try await self.resume(sleep: true); self.emit(["event":"awake","value":try await self.metrics()]) }
                    else if command == "media-response" {
                        let value = try await self.text("""
                        const v=document.querySelector('video');
                        if(!v) return JSON.stringify({hasVideo:false});
                        if(!v.currentSrc.startsWith('gw-wallpaper://project/')) throw Error('Matrix probe requires local managed media');
                        const r=await fetch(v.currentSrc,{headers:{Range:'bytes=0-262143'}});
                        const b=new Uint8Array(await r.arrayBuffer());
                        if(b.byteLength>262144) throw Error('Matrix media exceeds bounded response');
                        let binary='';
                        for(let i=0;i<b.length;i+=16384)binary+=String.fromCharCode(...b.subarray(i,i+16384));
                        return JSON.stringify({hasVideo:true,status:r.status,type:r.headers.get('Content-Type'),
                          range:r.headers.get('Content-Range'),prefix:Array.from(b.subarray(0,16),x=>x.toString(16).padStart(2,'0')).join(''),
                          payload:btoa(binary)});
                        """)
                        var response = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] ?? [:]
                        if let payload = response.removeValue(forKey: "payload") as? String,
                           let data = Data(base64Encoded: payload) {
                            response["bytes"] = data.count
                            response["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        }
                        let encoded = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                        self.emit(["event":"media-response","value":String(decoding: encoded, as: UTF8.self)])
                    }
                    else if command == "stop" { self.surface.stop(); self.emit(["event":"stopped"]); exit(0) }
                } catch { self.emit(["event":"error","error":error.localizedDescription]) }
            }
        }
    }

    private func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object,options:[.sortedKeys]),
           let text = String(data:data,encoding:.utf8) { print(text); fflush(stdout) }
    }

    private func signature(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let pointer = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to:UInt8.self) else { return 0 }
        let count = CVPixelBufferGetHeight(buffer)*CVPixelBufferGetBytesPerRow(buffer)
        var value: UInt64 = 1469598103934665603
        for i in stride(from:0,to:count,by:max(1,count/4096)) { value = (value ^ UInt64(pointer[i])) &* 1099511628211 }
        return value
    }
}
#endif
