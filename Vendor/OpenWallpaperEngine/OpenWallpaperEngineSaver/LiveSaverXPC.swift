import Foundation
import IOSurface

/// The live screen saver over XPC (the `com.apple.screensaver` extension's transport). The
/// extension asks the broker (`LiveSaverBrokerProtocol`, a launchd agent: an app can't publish a
/// Mach service itself) for the app's endpoint, connects to it, attaches its views
/// (`LiveSaverServiceProtocol`) and gets the rings' surfaces as XPC objects (Mach ports, never
/// global surfaces or copies, `LiveSaverFramesMessage`) and each frame's stamp
/// (`LiveSaverClientProtocol`). Shared by the app and the extension; the legacy `.saver` can't use
/// XPC (its host's sandbox denies the lookup).

/// The extension → the app.
@objc(OWELiveSaverServiceProtocol)
protocol LiveSaverServiceProtocol {
    /// A view (`viewID`, unique in its process) shows on the display `display` (its identity; nil
    /// when unknown). The reply says whether the app is drawing for the screen saver now; the
    /// rings follow through `LiveSaverClientProtocol.use(_:)` whenever they change.
    func attach(viewID: String, display: String?, isPreview: Bool, reply: @escaping (Bool) -> Void)
    /// The view still shows (about once a second), as the `.saver`'s `saverAlive` notification.
    func ping(viewID: String)
    /// The view stopped (willstop, stopAnimation or gone).
    func detach(viewID: String)
}

/// The app → the extension: the connection's exported object on the extension's side.
@objc(OWELiveSaverClientProtocol)
protocol LiveSaverClientProtocol {
    /// The current rings, or none (`message.manifest.isLive` false) when the app stopped drawing.
    func use(_ message: LiveSaverFramesMessage)
    /// A frame was drawn into a ring (`ScreenSaverLiveStamp.state`).
    func show(ring: Int, stamp: UInt64)
}

/// The broker: holds the app's endpoint for the extension.
@objc(OWELiveSaverBrokerProtocol)
protocol LiveSaverBrokerProtocol {
    /// The app's frame service; replaces an earlier one.
    func register(_ endpoint: NSXPCListenerEndpoint)
    /// The app's endpoint, or nil when no app registered one (the app isn't running).
    func endpoint(reply: @escaping (NSXPCListenerEndpoint?) -> Void)
}

/// The rings as the extension sees them: the manifest the `.saver` reads (sizes, displays and
/// crops) and the rings' surfaces themselves, in ring order, `manifest.rings[i].surfaces.count`
/// each (their ids are ignored).
@objc(OWELiveSaverFramesMessage)
final class LiveSaverFramesMessage: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let manifest: ScreenSaverLiveManifest
    let surfaces: [IOSurface]

    init(manifest: ScreenSaverLiveManifest, surfaces: [IOSurface]) {
        self.manifest = manifest
        self.surfaces = surfaces
    }

    func encode(with coder: NSCoder) {
        let data: Data
        do { data = try JSONEncoder().encode(manifest) } catch { data = Data() } // Plain values: can't fail.
        coder.encode(data as NSData, forKey: "manifest")
        coder.encode(surfaces as NSArray, forKey: "surfaces")
    }

    init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: "manifest") as Data?,
              let surfaces = coder.decodeObject(of: [NSArray.self, IOSurface.self], forKey: "surfaces") as? [IOSurface]
        else { return nil }
        do {
            manifest = try JSONDecoder().decode(ScreenSaverLiveManifest.self, from: data)
        } catch {
            return nil
        }
        self.surfaces = surfaces
        super.init()
        guard isConsistent else { return nil }
    }

    /// The surfaces match the rings' counts, and the manifest is this revision.
    var isConsistent: Bool {
        manifest.revision == ScreenSaverLiveManifest.revision
            && manifest.rings.reduce(0) { $0 + $1.surfaces.count } == surfaces.count
    }

    /// Ring `id`'s surfaces.
    func surfaces(ofRing id: Int) -> [IOSurface] {
        var start = 0
        for ring in manifest.rings {
            if ring.id == id { return Array(surfaces[start..<min(start + ring.surfaces.count, surfaces.count)]) }
            start += ring.surfaces.count
        }
        return []
    }

    /// The interfaces both sides set up: the frames message is the only custom class.
    static func serviceInterface() -> NSXPCInterface {
        NSXPCInterface(with: LiveSaverServiceProtocol.self)
    }

    static func clientInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: LiveSaverClientProtocol.self)
        let classes = NSSet(array: [LiveSaverFramesMessage.self, NSArray.self, IOSurface.self, NSData.self])
        interface.setClasses(classes as! Set<AnyHashable>, // An NSSet of classes is a Set<AnyHashable>.
                             for: #selector(LiveSaverClientProtocol.use(_:)), argumentIndex: 0, ofReply: false)
        return interface
    }

    static func brokerInterface() -> NSXPCInterface {
        NSXPCInterface(with: LiveSaverBrokerProtocol.self)
    }
}
