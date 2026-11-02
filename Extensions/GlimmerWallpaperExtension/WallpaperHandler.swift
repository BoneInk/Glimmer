import AppKit
import AVFoundation
import CoreImage
import ExtensionFoundation
import Foundation
import IOSurface
import QuartzCore

private struct GWBox<T>: @unchecked Sendable { let value: T }

@MainActor
private final class GWSurfaces {
    static let shared = GWSurfaces()
    private var values: [String: any GWNativeWallpaperSurface] = [:]
    private var owners: [String: UUID] = [:]
    private let displaySleep = GWLockScreenDisplaySleepGuard()
    func key(_ id: Any?) -> String {
        if let uuid = Self.uuid(in: id) { return uuid.uuidString }
        return String(describing: id ?? "default")
    }
    private static func uuid(in value: Any?, depth: Int = 0) -> UUID? {
        guard let value, depth < 7 else { return nil }
        if let uuid = value as? UUID { return uuid }
        for child in Mirror(reflecting: value).children {
            if let uuid = uuid(in: child.value, depth: depth + 1) { return uuid }
        }
        return nil
    }
    func remove(_ key: String, owner: UUID? = nil) {
        guard owner == nil || owners[key] == owner else { return }
        owners[key] = nil
        displaySleep.remove(key)
        values.removeValue(forKey: key)?.stop()
    }
    func claim(_ key: String, owner: UUID) { owners[key] = owner }
    func release(owner: UUID) {
        let keys = owners.filter { $0.value == owner }.map(\.key)
        keys.forEach { remove($0, owner: owner) }
    }
    func removeAll() { let old = values; values.removeAll(); owners.removeAll(); displaySleep.removeAll(); old.values.forEach { $0.stop() } }
    func setSleeping(_ value: Bool) { displaySleep.setSleeping(value); values.values.forEach { $0.setSleeping(value) } }
    func update(_ key: String, request: GWRequest) {
        guard let surface = values[key] else { return }
        displaySleep.update(key, request: request)
        surface.update(request)
    }
    func get(_ key: String) -> (any GWNativeWallpaperSurface)? { values[key] }
    func set(_ surface: any GWNativeWallpaperSurface, key: String) {
        remove(key)
        // A malformed or runaway host must not allocate unbounded decoders.
        if values.count >= 12 { removeAll() }
        values[key] = surface
    }
    func install(_ surface: any GWNativeWallpaperSurface, key: String, owner: UUID,
                 request: GWRequest, completion: @escaping (Bool) -> Void) {
        set(surface, key: key)
        claim(key, owner: owner)
        // Geometry and playback intent are already initialized from request.
        // update() may start a frame timer, which makes start() reject a cold
        // active acquisition as a duplicate. Only protect display sleep here.
        displaySleep.update(key, request: request)
        surface.start { success in
            guard success, self.get(key) === surface else {
                GWLog("native wallpaper startup failed context=\(surface.context.contextId) ready=\(success) current=\(self.get(key) === surface)")
                if self.get(key) === surface { self.remove(key) }
                completion(false)
                return
            }
            completion(true)
        }
    }
}

#if GW_DIAGNOSTIC_ENTRY
@MainActor
func GWInstallDiagnosticSurface(_ surface: any GWNativeWallpaperSurface, request: GWRequest,
                                completion: @escaping (Bool) -> Void) -> () -> Void {
    let key = UUID().uuidString
    let registry = GWSurfaces.shared
    registry.install(surface, key: key, owner: UUID(), request: request, completion: completion)
    return { registry.remove(key) }
}
#endif

final class GWWallpaperHandler: NSObject, WallpaperExtensionXPCProtocol {
    let owner = UUID()
    func acquire(withId id: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        let inputs = GWBox(value: (id, request, reply))
        let owner = self.owner
        Task { @MainActor in
            let (id, request, reply) = inputs.value
            let registry = GWSurfaces.shared
            let key = registry.key(id)
            do {
                let info = GWRequest(request)
                let (config, url) = try GWConfiguration.load(displayID: info.displayID, allowPreviewFallback: info.preview)
                if let existing = registry.get(key), existing.assetID == config.assetID,
                   let response = createRemoteContextXPC(contextId: existing.context.contextId) {
                    registry.claim(key, owner: owner)
                    registry.update(key, request: info)
                    reply(response, nil)
                    return
                }
                let surface = try await GWMakeNativeWallpaperSurface(config: config, url: url, request: info)
                guard let response = createRemoteContextXPC(contextId: surface.context.contextId),
                      GWRoundTripObject(response) else {
                    surface.stop(); throw GWError(30, "Unsupported wallpaper remote-context layout")
                }
                registry.install(surface, key: key, owner: owner, request: info) { success in
                    guard success else {
                        reply(nil, GWError(31, "Wallpaper surface did not produce a frame"))
                        return
                    }
                    GWLog("acquired native wallpaper context=\(surface.context.contextId) preview=\(info.preview) mode=\(info.mode ?? "none")")
                    reply(response, nil)
                }
            } catch { GWLog("native wallpaper acquire failed: \(error.localizedDescription)"); reply(nil, error) }
        }
    }

    func update(withId id: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
        let inputs = GWBox(value: (id, request, reply))
        Task { @MainActor in
            let (id, request, reply) = inputs.value
            let info = GWRequest(request)
            GWLog("wallpaper activity mode=\(info.mode ?? "none") activity=\(info.activity ?? "none") playing=\(info.shouldPlay)")
            GWSurfaces.shared.update(GWSurfaces.shared.key(id), request: info)
            reply(nil)
        }
    }

    func invalidate(withId id: Any?, reply: @escaping (Error?) -> Void) {
        let inputs = GWBox(value: (id, reply))
        Task { @MainActor in
            GWSurfaces.shared.remove(GWSurfaces.shared.key(inputs.value.0))
            inputs.value.1(nil)
        }
    }

    func snapshot(withId id: Any?, reply: @escaping (Any?, Error?) -> Void) {
        let inputs = GWBox(value: (id, reply))
        Task { @MainActor in
            let registry = GWSurfaces.shared
            guard let surface = registry.get(registry.key(inputs.value.0)) else {
                inputs.value.1(nil, GWError(32, "Wallpaper surface is unavailable")); return
            }
            do {
                let buffer = try await surface.snapshot()
                guard let current = registry.get(registry.key(inputs.value.0)), current === surface,
                      let buffer,
                  let response = GWSnapshot(buffer) else { inputs.value.1(nil, GWError(32, "No decoded snapshot available")); return }
                inputs.value.1(response, nil)
            } catch { inputs.value.1(nil, error) }
        }
    }

    func provideSettingsViewModels(withContentTypes types: Any?, reply: @escaping (Any?, Error?) -> Void) {
        let callback = GWBox(value: reply)
        Task { @MainActor in
            guard let settings = GWSettingsResponse() else { callback.value(nil, GWError(33, "Unsupported wallpaper settings layout")); return }
            callback.value(settings, nil)
        }
    }
    func selectedChoicesDidChange(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func isChoiceDownloaded(with choiceID: Any?, reply: @escaping (NSNumber?, Error?) -> Void) { reply(NSNumber(value: (try? GWConfiguration.load(allowPreviewFallback: true)) != nil), nil) }
    func handleNotification(withNamed name: Any?, reply: @escaping (Error?) -> Void) {
        let text = String(describing: name ?? "").lowercased()
        let callback = GWBox(value: reply)
        Task { @MainActor in
            if text.contains("terminate") { GWSurfaces.shared.removeAll() }
            // Sleep is not invalidation: the host may only update the same
            // context on wake, without acquiring a replacement surface.
            else if text.contains("wake") { GWSurfaces.shared.setSleeping(false) }
            else if text.contains("sleep") { GWSurfaces.shared.setSleeping(true) }
            callback.value(nil)
        }
    }
    func addChoiceRequest(withChoiceRequest request: Any?, onBehalfOfProcess process: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, GWError(40, "Choose wallpapers in Glimmer")) }
    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping (Error?) -> Void) { reply(GWError(40, "Manage wallpapers in Glimmer")) }
    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID: Any?, reply: @escaping (Error?) -> Void) { reply(GWError(40, "No context menu actions")) }
    func download(withChoiceID choiceID: Any?, reply: @escaping (Error?) -> Void) -> Any? { reply(nil); return nil }
    func pauseDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func cancelDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func resumeDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) { reply(GWError(40, "Manage wallpaper in Glimmer")) }
    func migrateSelectedChoice(for id: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, GWError(40, "Migration unavailable")) }
    func migrate(from: Any?, to: Any?, reply: @escaping (Error?) -> Void) { reply(GWError(40, "Migration unavailable")) }
    func skipShuffledContent(withId id: Any?, reply: @escaping (Error?) -> Void) { reply(GWError(40, "Shuffle unavailable")) }
    func canSkipShuffledContent(withId id: Any?, reply: @escaping (Bool, Error?) -> Void) { reply(false, nil) }
    func handleDebugRequest(for request: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, GWError(40, "Debug request unavailable")) }
}

@MainActor
func GWSnapshot(_ buffer: CVPixelBuffer) -> AnyObject? {
    if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
        return createSnapshotXPC(surface: surface)
    }
    let context = CIContext(options: [.cacheIntermediates: false])
    let input = CIImage(cvPixelBuffer: buffer)
    let ratio = min(1, 1920 / max(input.extent.width, input.extent.height))
    let resized = input.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
    guard let image = context.createCGImage(resized, from: resized.extent) else { return nil }
    let properties: [IOSurfacePropertyKey: any Sendable] = [.width: image.width, .height: image.height, .bytesPerElement: 4, .pixelFormat: 0x42475241]
    guard let surface = IOSurface(properties: properties) else { return nil }
    surface.lock(options: [], seed: nil)
    guard let bitmap = CGContext(data: surface.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
        surface.unlock(options: [], seed: nil); return nil
    }
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    surface.unlock(options: [], seed: nil)
    return createSnapshotXPC(surface: surface)
}

struct GWExtensionConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        guard GWApplePeer(connection) else { GWLog("rejected non-Apple or cross-user XPC peer"); return false }
        let exported = NSXPCInterface(with: (any WallpaperExtensionXPCProtocol).self)
        let allowed = NSMutableSet(array: [NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self])
        for name in ["WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC", "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC", "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperExtensionChoiceRequestXPC", "WallpaperChoiceRequestAdditionResultXPC", "WallpaperDebugRequestXPC", "WallpaperDebugResponseXPC", "WallpaperMigrationVersionXPC", "WallpaperSettingsViewModelsXPC", "AuditTokenXPC"] {
            if let cls = objc_getClass(name) { allowed.add(cls) }
        }
        let classes = allowed as! Set<AnyHashable>
        let selectors: [(String, Int, Bool)] = [
            ("acquireWithId:request:reply:",0,false),("acquireWithId:request:reply:",1,false),("acquireWithId:request:reply:",0,true),
            ("updateWithId:request:reply:",0,false),("updateWithId:request:reply:",1,false),
            ("invalidateWithId:reply:",0,false),("snapshotWithId:reply:",0,false),("snapshotWithId:reply:",0,true),
            ("provideSettingsViewModelsWithContentTypes:reply:",0,false),("provideSettingsViewModelsWithContentTypes:reply:",0,true),
            ("selectedChoicesDidChangeFor:reply:",0,false),("isChoiceDownloadedWith:reply:",0,false),("isChoiceDownloadedWith:reply:",0,true),
            ("handleNotificationWithNamed:reply:",0,false),
            ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:",0,false),("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:",1,false),("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:",0,true),
            ("removeChoiceRequestWithChoiceRequest:reply:",0,false),("invokeContextMenuActionWithMenuItemID:groupItemID:reply:",0,false),("invokeContextMenuActionWithMenuItemID:groupItemID:reply:",1,false),
            ("downloadWithChoiceID:reply:",0,false),("pauseDownloadFor:reply:",0,false),("cancelDownloadFor:reply:",0,false),("resumeDownloadFor:reply:",0,false),("removeDownloadFor:reply:",0,false),
            ("migrateSelectedChoiceFor:reply:",0,false),("migrateSelectedChoiceFor:reply:",0,true),("migrateFrom:to:reply:",0,false),("migrateFrom:to:reply:",1,false),
            ("skipShuffledContentWithId:reply:",0,false),("canSkipShuffledContentWithId:reply:",0,false),("handleDebugRequestFor:reply:",0,false),("handleDebugRequestFor:reply:",0,true)
        ]
        for (name, index, reply) in selectors { exported.setClasses(classes, for: NSSelectorFromString(name), argumentIndex: index, ofReply: reply) }
        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: (any WallpaperExtensionProxyXPCProtocol).self)
        let handler = GWWallpaperHandler()
        connection.exportedObject = handler
        let owner = handler.owner
        connection.invalidationHandler = {
            Task { @MainActor in GWSurfaces.shared.release(owner: owner) }
        }
        connection.interruptionHandler = {
            Task { @MainActor in GWSurfaces.shared.release(owner: owner) }
        }
        connection.resume()
        return true
    }
}
