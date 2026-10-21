import Foundation
import IOSurface
import Security
import OpenWallpaperEngine

/// The stable wire error keeps `scene_backend_<code>` (probe contract) and adds a bounded,
/// structured detail plus a concise Chinese message. Technical detail stays in the local report.
private func failureDetail(_ error: Error) -> SceneBackendFailureDetail {
    if let detailed = error as? SceneBackendDetailedFailure { return detailed.detail }
    if let failure = error as? SceneBackendFailure {
        let category: String
        switch failure {
        case .invalidConfiguration: category = SceneBackendFailureDetail.categoryInvalidConfiguration
        case .unsupported: category = SceneBackendFailureDetail.categoryUnsupportedCapability
        default: category = SceneBackendFailureDetail.categoryRuntimeFailure
        }
        return SceneBackendFailureDetail(code: failure.rawValue, category: category,
            userMessage: SceneBackendFailureDetail.message(for: category))
    }
    return SceneBackendFailureDetail(code: "failed",
        category: SceneBackendFailureDetail.categoryRuntimeFailure,
        userMessage: SceneBackendFailureDetail.message(for: SceneBackendFailureDetail.categoryRuntimeFailure),
        technicalDetail: String(describing: error).prefix(1_024).description)
}

private func wireError(_ error: Error, reportDirectory: URL? = nil) -> NSError {
    let detail = failureDetail(error)
    if let reportDirectory { writeFailureReport(detail, to: reportDirectory) }
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "scene_backend_" + detail.code]
    if let data = try? JSONEncoder().encode(detail) {
        userInfo[SceneBackendFailureDetail.userInfoKey] = data
    }
    userInfo[NSLocalizedRecoverySuggestionErrorKey] = detail.userMessage
    return NSError(domain: "Glimmer.SceneBackend", code: 1,
                   userInfo: userInfo)
}

private func writeFailureReport(_ detail: SceneBackendFailureDetail, to directory: URL) {
    let report: [String: Any] = [
        "code": detail.code,
        "category": detail.category,
        "message": detail.userMessage,
        "technicalDetail": detail.technicalDetail.map { String($0.prefix(8_192)) } ?? NSNull(),
        "missingResources": Array(detail.missingResources.prefix(64)),
        "timestamp": ISO8601DateFormatter().string(from: Date()),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
    try? data.write(to: directory.appendingPathComponent("backend-failure.json"), options: .atomic)
}
private let processInstanceID = UUID()
private final class Service: NSObject, SceneBackendRemote {
    private let ownsSession: Bool
    init(ownsSession: Bool) { self.ownsSession = ownsSession; super.init() }
    func status(reply: @escaping (Data) -> Void) {
        let state = lock.withLock { (engine, identity) }
        Task {
            let value = (try? await state.0?.processStatus(helperPID: getpid(), instanceID: processInstanceID, ownsSession: ownsSession))
                ?? SceneBackendProcessStatus(helperPID: getpid(), instanceID: processInstanceID,
                    sessionID: state.1?.0, generation: state.1?.1, ownsSession: ownsSession)
            reply(try! JSONEncoder().encode(value))
        }
    }
    private let lock = NSLock()
    private var engine: SceneBackendFacade?
    private var preparationClaimed = false
    private var identity: (UUID, UInt64)?
    private var cacheRoot: URL?
    private func reportError(_ error: Error) -> NSError {
        wireError(error, reportDirectory: lock.withLock { cacheRoot })
    }
    func prepare(_ configuration: Data, reply: @escaping (Data?, NSError?) -> Void) {
        guard ownsSession, configuration.count <= 1_048_576, lock.withLock({
            if preparationClaimed { return false }; preparationClaimed = true; return true
        }) else { reply(nil, reportError(SceneBackendFailure.alreadyConfigured)); return }
        Task {
            do {
                let config = try JSONDecoder().decode(SceneBackendConfiguration.self, from: configuration)
                // Remember the granted private cache first, so a failed preparation still leaves a
                // bounded local failure report beside the readiness evidence.
                lock.withLock { cacheRoot = config.roots.cacheRoot }
                let value = try await SceneBackendFacade.prepare(config)
                lock.withLock {
                    engine = value; identity = (config.sessionID, config.generation)
                }
                reply(try JSONEncoder().encode(value.readiness), nil)
            } catch { reply(nil, reportError(error)) }
        }
    }
    func render(_ input: Data, reply: @escaping (Data?, IOSurface?, NSError?) -> Void) {
        guard input.count <= 65_536, let engine = lock.withLock({ engine }) else { reply(nil,nil,reportError(SceneBackendFailure.notReady)); return }
        Task { do {
            let frame = try await engine.render(JSONDecoder().decode(SceneFrameInput.self, from: input))
            reply(try JSONEncoder().encode(frame.token), frame.surface, nil)
        } catch { reply(nil,nil,reportError(error)) } }
    }
    func acknowledge(_ frameToken: Data, reply: @escaping (NSError?) -> Void) {
        guard frameToken.count <= 65_536, let engine = lock.withLock({ engine }) else { reply(reportError(SceneBackendFailure.closed)); return }
        Task { do { try await engine.acknowledge(JSONDecoder().decode(SceneFrameToken.self, from:frameToken)); reply(nil) } catch { reply(reportError(error)) } }
    }
    func updateProperties(_ properties: Data, revision: UInt64, reply: @escaping (NSError?) -> Void) {
        guard properties.count <= 1_048_576, let engine = lock.withLock({ engine }) else { reply(reportError(SceneBackendFailure.notReady)); return }
        Task { do { try await engine.updateProperties(JSONDecoder().decode([String:String].self,from:properties), revision:revision); reply(nil) } catch { reply(reportError(error)) } }
    }
    func setFrameRateLimit(_ fps: Int, reply: @escaping (NSError?) -> Void) {
        guard let engine = lock.withLock({ engine }) else { reply(reportError(SceneBackendFailure.notReady)); return }
        Task { do { try await engine.setFrameRateLimit(fps); reply(nil) } catch { reply(reportError(error)) } }
    }
    func setAspectFill(_ fill: Bool, reply: @escaping (NSError?) -> Void) {
        guard let engine = lock.withLock({ engine }) else { reply(reportError(SceneBackendFailure.notReady)); return }
        Task { do { try await engine.setAspectFill(fill); reply(nil) } catch { reply(reportError(error)) } }
    }
    func setPaused(_ paused: Bool, reply: @escaping (NSError?) -> Void) {
        guard let engine = lock.withLock({ engine }) else { reply(reportError(SceneBackendFailure.notReady)); return }
        Task { do { try await engine.setPaused(paused); reply(nil) } catch { reply(reportError(error)) } }
    }
    func setSceneSound(_ enabled: Bool, volume: Double, reply: @escaping (NSError?) -> Void) {
        guard let engine = lock.withLock({ engine }) else { reply(reportError(SceneBackendFailure.notReady)); return }
        guard volume.isFinite, (0...1).contains(volume) else { reply(reportError(SceneBackendFailure.invalidConfiguration)); return }
        Task { do { try await engine.setSceneSound(enabled: enabled, volume: Float(volume)); reply(nil) } catch { reply(reportError(error)) } }
    }
    func close(_ sessionID: UUID, generation: UInt64, reply: @escaping () -> Void) {
        let value = lock.withLock { () -> SceneBackendFacade? in
            guard identity?.0 == sessionID, identity?.1 == generation else { return nil }
            defer { engine = nil; identity = nil }; return engine
        }
        if value != nil { DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) } }
        Task {
            await value?.close(); reply()
            if value != nil { DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { exit(0) } }
        }
    }
    func invalidate() {
        guard ownsSession else { return }
        let value = lock.withLock { engine }
        // One connection owns this process. Even a stuck GPU/close queue cannot orphan it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
        Task { await value?.close(); exit(0) }
    }
}

private func signingInformation(_ code: SecCode) -> [String:Any]? {
    var info: CFDictionary?
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue:kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
    return info as? [String:Any]
}
private final class Listener: NSObject, NSXPCListenerDelegate {
    private var accepted = false
    private let lock = NSLock()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var caller: SecCode?, own: SecCode?
        let attrs = [kSecGuestAttributePid as String: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil,attrs,[],&caller) == errSecSuccess, let caller,
              SecCodeCheckValidity(caller,[],nil) == errSecSuccess,
              SecCodeCopySelf([], &own) == errSecSuccess, let own,
              let callerInfo = signingInformation(caller), let ownInfo = signingInformation(own),
              let callerID = callerInfo[kSecCodeInfoIdentifier as String] as? String,
              let allowed = Bundle.main.object(forInfoDictionaryKey:"SceneBackendAllowedClients") as? [String], allowed.contains(callerID)
        else { return false }
        let callerTeam = callerInfo[kSecCodeInfoTeamIdentifier as String] as? String
        let ownTeam = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String
        let productionSignature = ownTeam?.isEmpty == false && callerTeam == ownTeam
        guard productionSignature else { return false }
        let ownsSession = lock.withLock { if accepted { return false }; accepted = true; return true }
        let service = Service(ownsSession: ownsSession)
        let interface = NSXPCInterface(with: SceneBackendRemote.self)
        interface.setClasses(NSSet(object: IOSurface.self) as! Set<AnyHashable>, for: #selector(SceneBackendRemote.render(_:reply:)), argumentIndex:1, ofReply:true)
        connection.exportedInterface = interface; connection.exportedObject = service
        connection.invalidationHandler = { service.invalidate() }
        connection.interruptionHandler = { service.invalidate() }
        connection.resume()
        return true
    }
}
// The service owns no windows, desktop assignment, Steam session or app lifecycle services.
let listener = NSXPCListener.service()
private let owner = Listener()
listener.delegate = owner
listener.resume()
RunLoop.current.run()
