import Foundation
import IOSurface
import Metal

/// Accepts the app's connection. Only the app that embeds this service can reach it. One
/// connection per process: CEF starts once, every web wallpaper's browser shares it, and the helper
/// exits when the app lets go.
final class ChromiumHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private var service: ChromiumHelperService?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard service == nil else { return false }
        let service = ChromiumHelperService(connection: connection)
        self.service = service
        connection.exportedInterface = .chromiumBrowserHelper
        connection.exportedObject = service
        connection.remoteObjectInterface = .chromiumBrowserHost
        // CEF's subprocesses watch this process and exit with it.
        connection.invalidationHandler = { exit(0) }
        connection.interruptionHandler = { exit(0) }
        connection.resume()
        return true
    }
}

/// Runs CEF on the main thread and forwards each painted frame to the app as a copy in one of a
/// few IOSurfaces it owns per browser, because CEF takes its own surface back when the paint
/// returns. Page messages, load results and `owe-wallpaper` requests go to the app too.
final class ChromiumHelperService: NSObject, ChromiumBrowserHelperProtocol {
    private weak var connection: NSXPCConnection?
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()

    /// The surfaces one browser's frames are copied into, used in turn. Main thread only.
    private struct Ring {
        var surfaces: [IOSurface] = []
        var index = 0
        var frameNumber: Int64 = 0
    }

    private var rings: [Int: Ring] = [:]

    /// Copies in flight that the app may still be reading: three frames at 60 Hz is 50 ms.
    static let ringSize = 3

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    private var host: ChromiumBrowserHostProtocol? {
        connection?.remoteObjectProxy as? ChromiumBrowserHostProtocol
    }

    /// Runs `body` on the main thread. Once CEF runs, the main queue is busy in `owe_cef_run`, so
    /// work arrives as run-loop blocks, which its nested passes serve.
    private static func onMain(_ body: @escaping () -> Void) {
        RunLoop.main.perform(body)
    }

    // MARK: Phase 1

    func start(url: String, engineBundle: String, cacheDirectory: String, width: Int, height: Int,
               frameRate: Int, debugNoSandbox: Bool, reply: @escaping (String?) -> Void) {
        guard (1...ChromiumHelperIPC.maxDimension).contains(width), (1...ChromiumHelperIPC.maxDimension).contains(height) else {
            reply("Frame size \(width)×\(height) is out of range")
            return
        }
        guard device != nil else {
            reply("No Metal device")
            return
        }
        DispatchQueue.main.async {
            var error = [CChar](repeating: 0, count: 512)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = owe_cef_start(engineBundle, cacheDirectory, url, Int32(width), Int32(height),
                                       Int32(max(1, min(frameRate, 240))), debugNoSandbox ? 1 : 0, { context, surface in
                guard let context, let surface else { return }
                Unmanaged<ChromiumHelperService>.fromOpaque(context).takeUnretainedValue().forward(surface, browserId: 0)
            }, context, &error, error.count)
            reply(status == 0 ? nil : String(cString: error))
            if status == 0 { owe_cef_run() }
        }
    }

    func stop() {
        // A run-loop block, not the main queue: the main queue is busy in `owe_cef_run`.
        RunLoop.main.perform { owe_cef_stop() }
    }

    // MARK: Browsers

    func initialize(engineBundle: String, cacheDirectory: String, debugNoSandbox: Bool,
                    remoteDebuggingPort: Int, reply: @escaping (String?) -> Void) {
        guard device != nil else {
            reply("No Metal device")
            return
        }
        Self.onMain {
            var error = [CChar](repeating: 0, count: 512)
            var callbacks = owe_cef_callbacks()
            callbacks.context = Unmanaged.passUnretained(self).toOpaque()
            callbacks.frame = { context, browserId, surface in
                guard let context, let surface else { return }
                ChromiumHelperService.service(context).forward(surface, browserId: Int(browserId))
            }
            callbacks.message = { context, browserId, name, body in
                guard let context, let name, let body else { return }
                ChromiumHelperService.service(context).host?.browser(Int(browserId), postedMessage: String(cString: name),
                                                    body: String(cString: body))
            }
            callbacks.load_end = { context, browserId, status in
                guard let context else { return }
                ChromiumHelperService.service(context).host?.browser(Int(browserId), finishedLoadingWithStatus: Int(status))
            }
            callbacks.terminated = { context, browserId, reason in
                guard let context else { return }
                ChromiumHelperService.service(context).host?.browserTerminated(Int(browserId), reason: reason.map { String(cString: $0) } ?? "")
            }
            callbacks.resource = { context, browserId, url, range, request in
                guard let context, let url, let request else { return }
                ChromiumHelperService.service(context).resource(browserId: Int(browserId), url: String(cString: url),
                                               range: range.map { String(cString: $0) }, request: request)
            }
            let status = owe_cef_initialize(engineBundle, cacheDirectory, debugNoSandbox ? 1 : 0,
                                            Int32(clamping: remoteDebuggingPort), &callbacks,
                                            &error, error.count)
            reply(status == 0 ? nil : String(cString: error))
            // Only the first successful call runs the loop; later ones return at once.
            if status == 0 { owe_cef_run() }
        }
    }

    private static func service(_ context: UnsafeMutableRawPointer) -> ChromiumHelperService {
        Unmanaged<ChromiumHelperService>.fromOpaque(context).takeUnretainedValue()
    }

    func createBrowser(_ browserId: Int, url: String, width: Int, height: Int, scale: Double, frameRate: Int,
                       startScript: String, reply: @escaping (String?) -> Void) {
        let pixels = (Double(width) * scale, Double(height) * scale)
        guard width > 0, height > 0, scale > 0, scale <= 4,
              pixels.0 <= Double(ChromiumHelperIPC.maxDimension), pixels.1 <= Double(ChromiumHelperIPC.maxDimension) else {
            reply("Browser size \(width)×\(height) at \(scale)× is out of range")
            return
        }
        Self.onMain {
            var error = [CChar](repeating: 0, count: 512)
            let status = owe_cef_create_browser(Int32(browserId), url, Int32(width), Int32(height), scale,
                                                Int32(max(1, min(frameRate, 240))), startScript, &error, error.count)
            reply(status == 0 ? nil : String(cString: error))
        }
    }

    func closeBrowser(_ browserId: Int) {
        Self.onMain {
            self.rings[browserId] = nil
            owe_cef_close_browser(Int32(browserId))
        }
    }

    func resizeBrowser(_ browserId: Int, width: Int, height: Int, scale: Double) {
        guard width > 0, height > 0, scale > 0, scale <= 4,
              Double(max(width, height)) * scale <= Double(ChromiumHelperIPC.maxDimension) else { return }
        Self.onMain { owe_cef_resize_browser(Int32(browserId), Int32(width), Int32(height), scale) }
    }

    func setBrowserHidden(_ browserId: Int, hidden: Bool) {
        Self.onMain { owe_cef_set_hidden(Int32(browserId), hidden ? 1 : 0) }
    }

    func setBrowserFrameRate(_ browserId: Int, frameRate: Int) {
        Self.onMain { owe_cef_set_frame_rate(Int32(browserId), Int32(max(1, min(frameRate, 240)))) }
    }

    func setBrowserAudioMuted(_ browserId: Int, muted: Bool) {
        Self.onMain { owe_cef_set_audio_muted(Int32(browserId), muted ? 1 : 0) }
    }

    func executeJavaScript(_ browserId: Int, script: String) {
        Self.onMain { owe_cef_execute_javascript(Int32(browserId), script) }
    }

    func sendMouseEvent(_ browserId: Int, event: ChromiumMouseEvent) {
        Self.onMain {
            owe_cef_send_mouse(Int32(browserId), Int32(event.kind.rawValue), event.x, event.y,
                               Int32(event.button.rawValue), Int32(event.clickCount), event.deltaX, event.deltaY,
                               event.modifiers)
        }
    }

    // MARK: Requests

    /// Asks the app for an `owe-wallpaper` resource (CEF's IO thread) and answers CEF when it replies.
    private func resource(browserId: Int, url: String, range: String?, request: OpaquePointer) {
        let respond = { (response: ChromiumResourceResponse) in
            let headers = response.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            // The handle closes its descriptor when it goes; CEF reads from a copy.
            let fd = response.file.map { dup($0.fileDescriptor) } ?? -1
            if let data = response.data, fd < 0 {
                data.withUnsafeBytes { bytes in
                    owe_cef_resource_respond(request, Int32(response.status), headers, bytes.baseAddress, bytes.count,
                                             -1, 0, 0)
                }
            } else {
                owe_cef_resource_respond(request, Int32(response.status), headers, nil, 0, fd, response.offset,
                                         response.length)
            }
        }
        guard let connection else {
            respond(.notFound())
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            respond(.notFound())
        } as? ChromiumBrowserHostProtocol
        guard let proxy else {
            respond(.notFound())
            return
        }
        proxy.browser(browserId, requestsResource: url, range: range, reply: respond)
    }

    // MARK: Frames

    /// Copies CEF's surface into the browser's next ring surface on the GPU and sends that one.
    private func forward(_ source: IOSurface, browserId: Int) {
        guard let device, let queue, source.pixelFormat == ChromiumHelperIPC.pixelFormat,
              let host = connection?.remoteObjectProxy as? ChromiumHostProtocol else { return }
        var ring = rings[browserId] ?? Ring()
        if ring.surfaces.first.map({ $0.width != source.width || $0.height != source.height }) ?? true {
            ring.surfaces = (0..<Self.ringSize).compactMap { _ in Self.makeSurface(width: source.width, height: source.height) }
            ring.index = 0
        }
        guard ring.surfaces.count == Self.ringSize else { return }
        let target = ring.surfaces[ring.index]
        ring.index = (ring.index + 1) % ring.surfaces.count
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: source.width,
                                                                  height: source.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let from = device.makeTexture(descriptor: descriptor, iosurface: source, plane: 0),
              let to = device.makeTexture(descriptor: descriptor, iosurface: target, plane: 0),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: from, to: to)
        blit.endEncoding()
        commands.commit()
        // The copy must finish before CEF reuses its surface, which happens when this returns.
        commands.waitUntilCompleted()
        ring.frameNumber += 1
        rings[browserId] = ring
        host.didPaint(ChromiumFrameMessage(surface: target, frameNumber: ring.frameNumber, browserId: browserId))
    }

    static func makeSurface(width: Int, height: Int) -> IOSurface? {
        IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: ChromiumHelperIPC.pixelFormat,
        ])
    }
}
