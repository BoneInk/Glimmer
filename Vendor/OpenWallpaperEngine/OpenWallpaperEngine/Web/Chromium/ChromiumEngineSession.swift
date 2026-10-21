import Foundation
import IOSurface
import Metal

/// One frame from the helper, wrapped for Metal without a copy. `surface` keeps the memory alive
/// while the texture is in use; the helper reuses it a few frames later (`ChromiumHelperService.ringSize`).
struct ChromiumFrame {
    let texture: MTLTexture
    let surface: IOSurface
    let frameNumber: Int64
}

/// The app's end of a connection to owe-chromium-helper: starts a windowless browser and turns
/// each frame it paints into an `MTLTexture`. CEF only ever runs in the helper process.
final class ChromiumEngineSession: NSObject, ChromiumHostProtocol, @unchecked Sendable {
    // `lock` guards `onFrame` and `droppedFrames`; the rest is set once in init.
    private let connection: NSXPCConnection
    private let device: MTLDevice
    private let lock = NSLock()
    private var onFrame: ((ChromiumFrame) -> Void)?
    private var droppedFrames = 0
    private var onExit: (@Sendable (String) -> Void)?

    /// Connects to the helper embedded in the app bundle.
    /// `onExit` runs once if the helper exits or the connection fails while the session runs.
    static func embedded(device: MTLDevice, onFrame: @escaping (ChromiumFrame) -> Void,
                         onExit: (@Sendable (String) -> Void)? = nil) -> ChromiumEngineSession {
        ChromiumEngineSession(connection: NSXPCConnection(serviceName: ChromiumHelperIPC.serviceName),
                              device: device, onFrame: onFrame, onExit: onExit)
    }

    /// `connection` is not resumed yet; tests pass one to an anonymous listener (a fake helper).
    init(connection: NSXPCConnection, device: MTLDevice, onFrame: @escaping (ChromiumFrame) -> Void,
         onExit: (@Sendable (String) -> Void)? = nil) {
        self.connection = connection
        self.device = device
        self.onFrame = onFrame
        self.onExit = onExit
        super.init()
        connection.remoteObjectInterface = .chromiumHelper
        connection.exportedInterface = .chromiumHost
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            OWELog.info(.web, "Chromium helper connection closed")
            self?.exited("The Chromium helper's connection closed")
        }
        connection.interruptionHandler = { [weak self] in
            OWELog.error(.web, "Chromium helper exited unexpectedly")
            self?.exited("The Chromium helper exited unexpectedly")
        }
        connection.resume()
    }

    private func exited(_ reason: String) {
        let handler = lock.withLock { () -> (@Sendable (String) -> Void)? in
            defer { onExit = nil }
            return onExit
        }
        handler?(reason)
    }

    /// Frames that failed `ChromiumFrameMessage.isValid` or couldn't become a texture.
    var framesDropped: Int { lock.withLock { droppedFrames } }

    /// Starts the browser for `url` from the install in `install` (a version folder). Calls
    /// `completion` with nil once the browser exists, else with the reason. `debugNoSandbox` only
    /// has an effect in Debug builds of the helper.
    func start(url: URL, install: URL, profile: URL, width: Int, height: Int, frameRate: Int,
               debugNoSandbox: Bool = false, completion: @escaping @Sendable (String?) -> Void) {
        let helper = connection.remoteObjectProxyWithErrorHandler { error in
            completion(error.localizedDescription)
        } as? ChromiumHelperProtocol
        guard let helper else {
            completion("The Chromium helper isn't available")
            return
        }
        do {
            try ChromiumEngineHelpers.sync(install)
        } catch {
            completion("Can't update the Chromium engine's helpers: \(error.localizedDescription)")
            return
        }
        let bundle = install.appending(path: ChromiumHelperIPC.engineBundleName, directoryHint: .isDirectory)
        helper.start(url: url.absoluteString, engineBundle: bundle.path, cacheDirectory: profile.path,
                     width: width, height: height, frameRate: frameRate, debugNoSandbox: debugNoSandbox,
                     reply: completion)
    }

    /// Stops frames and closes the connection; the helper and CEF's processes exit.
    func stop() {
        lock.withLock {
            onFrame = nil
            onExit = nil
        }
        (connection.remoteObjectProxy as? ChromiumHelperProtocol)?.stop()
        connection.invalidate()
    }

    // MARK: ChromiumHostProtocol

    func didPaint(_ frame: ChromiumFrameMessage) {
        guard let texture = Self.texture(for: frame, device: device) else {
            lock.withLock { droppedFrames += 1 }
            return
        }
        let handler = lock.withLock { onFrame }
        handler?(ChromiumFrame(texture: texture, surface: frame.surface, frameNumber: frame.frameNumber))
    }

    /// A BGRA texture over the message's IOSurface, nil for a frame that isn't valid.
    static func texture(for frame: ChromiumFrameMessage, device: MTLDevice) -> MTLTexture? {
        guard frame.isValid else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: frame.surface.width,
                                                                  height: frame.surface.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0)
    }
}
