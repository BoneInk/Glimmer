import AppKit
import Foundation
import WebKit

@main @MainActor enum WebMediaStreamingProbe {
    static func main() {
        let app = NSApplication.shared
        let delegate = WebMediaStreamingDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class WebMediaStreamingDelegate: NSObject, NSApplicationDelegate {
    var runtime: WebWallpaperRuntime!
    var window: NSWindow!
    var checks: [String] = []
    var report: [String: Any] = [:]
    let output = URL(fileURLWithPath: CommandLine.arguments[2])

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); report["success"] = true }
            catch { report["success"] = false; report["error"] = error.localizedDescription }
            if let runtime {
                report["runtimeState"] = runtime.state.rawValue
                report["runtimeError"] = runtime.lastError ?? ""
                report["media"] = try? await runtime.webView.evaluateJavaScript(Self.mediaState)
                if let image = try? await runtime.captureStaticPoster() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: output.deletingLastPathComponent().appendingPathComponent("actual-web-wallpaper.png"))
                }
                runtime.dispose()
            }
            report["checks"] = checks
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: output); print(String(decoding: bytes, as: UTF8.self))
            }
            NSApp.terminate(nil)
        }
    }
    static let mediaState = """
    JSON.stringify(Array.from(document.querySelectorAll('video')).map(v=>({src:v.currentSrc,ready:v.readyState,width:v.videoWidth,height:v.videoHeight,time:v.currentTime,duration:Number.isFinite(v.duration)?v.duration:null,paused:v.paused,error:v.error?{code:v.error.code,message:v.error.message}:null,webm:v.canPlayType('video/webm')})))
    """
    func check(_ value: Bool, _ text: String) throws {
        guard value else { throw WebWallpaperFailure(message: text) }; checks.append(text)
    }
    func wait(_ script: String, timeout: Double = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await runtime.webView.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebWallpaperFailure(message: "Timed out waiting for " + script)
    }
    func run() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,
            reason:"Validating visible Web wallpaper media loops")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let entry = try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as! [String: Any]
        let properties = Data(#"{"showclock":{"type":"bool","value":true},"hours24":{"type":"bool","value":true}}"#.utf8)
        runtime = try WebWallpaperRuntime(projectURL: project, entryURL: project.deletingLastPathComponent().appendingPathComponent(entry["file"] as! String),
            propertiesJSON: properties, mutedPlayback:true, animationFrameRateLimit:30, remoteLayerRendering:true)
        report["scope"] = "Visible receiver using native-lock-screen WebKit scheduling, output mute and explicit test-clock properties"
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.title = "Glimmer WebM 循环验证"
        window.contentView = runtime.webView; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
        runtime.load()
        try await wait("document.querySelector('video')?.readyState >= 2 && document.querySelector('video')?.videoWidth > 0")
        try check(true, "the original WebM decodes a nonzero video frame through the production scheme handler")
        let before = try await runtime.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
        try await Task.sleep(for: .milliseconds(650))
        let after = try await runtime.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
        try check(after > before + 0.1, "the original video plays and its media clock advances")
        let response = try await runtime.webView.callAsyncJavaScript("""
          const url = document.querySelector('video').currentSrc;
          const response = await fetch(url, {headers: {Range: 'bytes=0-1023'}});
          return {status: response.status, bytes: (await response.arrayBuffer()).byteLength,
                  range: response.headers.get('Content-Range'),type:response.headers.get('Content-Type')};
          """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        try check(response?["status"] as? Int == 206 && response?["bytes"] as? Int == 1024,
                  "real WebKit range fetch receives 206 and exactly the requested bytes")
        report["rangeFetch"] = response
        let seek = try await runtime.webView.evaluateJavaScript("document.querySelector('video').currentTime = 6; true")
        _ = seek
        try await wait("!document.querySelector('video').seeking && document.querySelector('video').currentTime >= 6")
        try check(true, "the original WebM seeks successfully")
        try await wait("document.getElementById('time')?.textContent !== '--:--'")
        try check(true, "the original clock script continues updating alongside the video")
        _ = try await runtime.webView.evaluateJavaScript("""
          const v=document.querySelector('video');
          window.__gwMediaLoopProbe={loops:0,frames:0};
          v.addEventListener('seeked',()=>{if(v.currentTime<0.2)window.__gwMediaLoopProbe.loops++;});
          if(v.requestVideoFrameCallback) {
            const frame=()=>{window.__gwMediaLoopProbe.frames++;v.requestVideoFrameCallback(frame);};
            v.requestVideoFrameCallback(frame);
          }
          true;
          """)
        let duration = try await runtime.webView.evaluateJavaScript("document.querySelector('video').duration") as! Double
        try check(duration.isFinite && duration > 0 && duration <= 60, "loop probe has a bounded finite clip duration")
        let deadline = Date().addingTimeInterval(duration*5+10)
        var history: [[String:Any]] = []
        while Date() < deadline {
            try await Task.sleep(for:.seconds(1))
            let value = try await runtime.webView.evaluateJavaScript("""
              ({time:document.querySelector('video').currentTime,loops:window.__gwMediaLoopProbe.loops,
                frames:window.__gwMediaLoopProbe.frames,clock:document.getElementById('time')?.textContent || '',
                paused:document.querySelector('video').paused,error:document.querySelector('video').error?.code || 0})
              """) as! [String:Any]
            history.append(value)
            if (value["loops"] as? Int ?? 0) >= 4 { break }
        }
        report["loopHistory"] = history
        let last = history.last ?? [:]
        try check((last["loops"] as? Int ?? 0) >= 4 && (last["frames"] as? Int ?? 0) > 30,
                  "four automatic loops finish and decoded frames keep presenting beyond the former second-loop stall")
        try check(last["paused"] as? Bool == false && last["error"] as? Int == 0,
                  "the original page remains playing without video errors or authored-script changes")
    }
}
