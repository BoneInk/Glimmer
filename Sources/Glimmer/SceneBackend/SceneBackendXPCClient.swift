import Foundation
import IOSurface
import Darwin

enum UniversalSceneBackendError: LocalizedError, Equatable, Sendable {
    case unavailable, capacity, invalidProject, invalidProperties, invalidFrame, timedOut, interrupted, notReady, disposed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "通用 Scene 渲染服务不可用。"
        case .capacity: return "通用 Scene 渲染服务已达到同时运行上限。"
        case .invalidProject: return "Scene 项目路径或配置无效。"
        case .invalidProperties: return "Scene 作者设置包含不支持或无效的值。"
        case .invalidFrame: return "Scene 渲染服务返回了无效画面。"
        case .timedOut: return "Scene 渲染服务响应超时。"
        case .interrupted: return "Scene 渲染服务已中断。"
        case .notReady: return "Scene 尚未完成准备。"
        case .disposed: return "Scene 已关闭。"
        }
    }
}

/// A structured failure decoded from the helper's wire NSError: a concise Chinese user message,
/// a stable code/category, bounded technical detail and the real missing resources. The UI shows
/// the message; local reports keep the detail and never turn it into a blind re-download.
struct SceneBackendWireFailure: LocalizedError, Equatable, Sendable {
    let code: String
    let category: String
    let userMessage: String
    let technicalDetail: String?
    let missingResources: [String]
    var errorDescription: String? { userMessage }
    var detail: SceneBackendFailureDetail {
        SceneBackendFailureDetail(code: code, category: category, userMessage: userMessage,
                                  technicalDetail: technicalDetail, missingResources: missingResources)
    }

    init(error: Error) {
        let nsError = error as NSError
        let fallbackCode = (nsError.userInfo[NSLocalizedDescriptionKey] as? String)
            .flatMap { $0.hasPrefix("scene_backend_") ? String($0.dropFirst("scene_backend_".count)) : nil } ?? "failed"
        if let data = nsError.userInfo[SceneBackendFailureDetail.userInfoKey] as? Data,
           let detail = try? JSONDecoder().decode(SceneBackendFailureDetail.self, from: data) {
            code = detail.code; category = detail.category; userMessage = detail.userMessage
            technicalDetail = detail.technicalDetail; missingResources = detail.missingResources
        } else {
            let category = Self.category(for: fallbackCode)
            code = fallbackCode; self.category = category
            userMessage = SceneBackendFailureDetail.message(for: category)
            technicalDetail = nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String
            missingResources = []
        }
    }

    private static func category(for code: String) -> String {
        switch code {
        case "invalidConfiguration", "invalidRoot", "digestMismatch":
            return SceneBackendFailureDetail.categoryInvalidConfiguration
        case "unsupported":
            return SceneBackendFailureDetail.categoryUnsupportedCapability
        default:
            return SceneBackendFailureDetail.categoryRuntimeFailure
        }
    }
}

@MainActor
protocol SceneBackendSessionTransport: AnyObject {
    var invalidationHandler: (@MainActor () -> Void)? { get set }
    func status() async throws -> SceneBackendProcessStatus
    func prepare(_ configuration: SceneBackendConfiguration) async throws -> SceneBackendReadiness
    func render(_ input: SceneFrameInput) async throws -> (SceneFrameToken, IOSurface)
    func acknowledge(_ token: SceneFrameToken) async throws
    func updateProperties(_ properties: [String: String], revision: UInt64) async throws
    func setFrameRateLimit(_ fps: Int) async throws
    func setAspectFill(_ fill: Bool) async throws
    func setPaused(_ paused: Bool) async throws
    func setSceneSound(enabled: Bool, volume: Double) async throws
    func close(sessionID: UUID, generation: UInt64) async
    func invalidate()
    func invalidateAndWait() async
}

@MainActor
final class SceneBackendXPCClient: SceneBackendSessionTransport {
    var invalidationHandler: (@MainActor () -> Void)?
    private let connection: NSXPCConnection
    private var invalidated = false
    private var invalidationWaiters = [CheckedContinuation<Void, Never>]()

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
        let interface = NSXPCInterface(with: SceneBackendRemote.self)
        interface.setClasses(NSSet(object: IOSurface.self) as! Set<AnyHashable>,
                             for: #selector(SceneBackendRemote.render(_:reply:)), argumentIndex: 1, ofReply: true)
        connection.remoteObjectInterface = interface
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.didInvalidate() }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.didInvalidate() }
        }
        connection.resume()
    }

    private func didInvalidate() {
        guard !invalidated else { return }
        invalidated = true
        let waiters = invalidationWaiters; invalidationWaiters = []
        waiters.forEach { $0.resume() }
        invalidationHandler?()
    }

    private func call<Value: Sendable>(seconds: Double,
        _ invoke: @Sendable (SceneBackendRemoteBox, SceneBackendDeadlineRace<Value>) -> Void) async throws -> Value {
        guard !invalidated else { throw UniversalSceneBackendError.interrupted }
        let race = SceneBackendDeadlineRace<Value>()
        // NSXPC invokes this on its own queue. Explicit Sendable prevents Swift
        // 6 from inheriting this method's MainActor isolation for the callback.
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
            race.finish(.failure(UniversalSceneBackendError.interrupted))
        }
        guard let remote = proxy as? SceneBackendRemote else { throw UniversalSceneBackendError.unavailable }
        invoke(SceneBackendRemoteBox(remote), race)
        return try await race.wait(seconds: seconds)
    }

    func status() async throws -> SceneBackendProcessStatus {
        // An XPC job that has just crashed can take longer to relaunch than an
        // already connected service takes to answer an ordinary request.
        let data: Data = try await call(seconds: 15) { service, race in
            service.value.status { race.finish(.success($0)) }
        }
        return try JSONDecoder().decode(SceneBackendProcessStatus.self, from: data)
    }

    func prepare(_ configuration: SceneBackendConfiguration) async throws -> SceneBackendReadiness {
        let data = try JSONEncoder().encode(configuration)
        let result: Data = try await call(seconds: 120) { service, race in
            service.value.prepare(data) { value, error in
                if let error { race.finish(.failure(SceneBackendWireFailure(error: error))) }
                else if let value { race.finish(.success(value)) }
                else { race.finish(.failure(UniversalSceneBackendError.interrupted)) }
            }
        }
        return try JSONDecoder().decode(SceneBackendReadiness.self, from: result)
    }

    func render(_ input: SceneFrameInput) async throws -> (SceneFrameToken, IOSurface) {
        let data = try JSONEncoder().encode(input)
        let result: (Data, IOSurface) = try await call(seconds: 15) { service, race in
            service.value.render(data) { token, surface, error in
                if let error { race.finish(.failure(error)) }
                else if let token, let surface { race.finish(.success((token, surface))) }
                else { race.finish(.failure(UniversalSceneBackendError.invalidFrame)) }
            }
        }
        return (try JSONDecoder().decode(SceneFrameToken.self, from: result.0), result.1)
    }

    func acknowledge(_ token: SceneFrameToken) async throws {
        let data = try JSONEncoder().encode(token)
        let _: Void = try await call(seconds: 10) { service, race in
            service.value.acknowledge(data) { error in
                race.finish(error.map { .failure(SceneBackendWireFailure(error: $0)) } ?? .success(()))
            }
        }
    }

    func updateProperties(_ properties: [String: String], revision: UInt64) async throws {
        let data = try JSONEncoder().encode(properties)
        let _: Void = try await call(seconds: 60) { service, race in
            service.value.updateProperties(data, revision: revision) { error in
                race.finish(error.map { .failure(SceneBackendWireFailure(error: $0)) } ?? .success(()))
            }
        }
    }

    func setPaused(_ paused: Bool) async throws {
        let _: Void = try await call(seconds: 10) { service, race in
            service.value.setPaused(paused) { error in
                race.finish(error.map { .failure(SceneBackendWireFailure(error: $0)) } ?? .success(()))
            }
        }
    }

    func setFrameRateLimit(_ fps: Int) async throws {
        let _: Void = try await call(seconds: 10) { service, race in
            service.value.setFrameRateLimit(fps) { error in
                race.finish(error.map { .failure(SceneBackendWireFailure(error: $0)) } ?? .success(()))
            }
        }
    }

    func setAspectFill(_ fill: Bool) async throws {
        let _: Void = try await call(seconds: 10) { service, race in
            service.value.setAspectFill(fill) { error in
                race.finish(error.map { .failure(SceneBackendWireFailure(error: $0)) } ?? .success(()))
            }
        }
    }

    func setSceneSound(enabled: Bool, volume: Double) async throws {
        let _: Void = try await call(seconds: 10) { service, race in
            service.value.setSceneSound(enabled, volume: volume) { error in
                race.finish(error.map { .failure(SceneBackendWireFailure(error: $0)) } ?? .success(()))
            }
        }
    }

    func close(sessionID: UUID, generation: UInt64) async {
        let _: Void? = try? await call(seconds: 5) { service, race in
            service.value.close(sessionID, generation: generation) { race.finish(.success(())) }
        }
    }

    func invalidate() {
        guard !invalidated else { return }
        connection.invalidate()
    }

    func invalidateAndWait() async {
        if invalidated { return }
        await withCheckedContinuation { continuation in
            invalidationWaiters.append(continuation)
            connection.invalidate()
        }
    }
}

/// NSXPC's proxy is thread-safe but its generated Objective-C protocol cannot
/// express Sendable. Keep that unchecked boundary limited to the proxy object;
/// decoded values and all client state remain actor-isolated.
private final class SceneBackendRemoteBox: @unchecked Sendable {
    let value: SceneBackendRemote
    init(_ value: SceneBackendRemote) { self.value = value }
}

enum SceneBackendTimeout {
    static func run<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = SceneBackendDeadlineRace<T>()
        Task {
            do { race.finish(.success(try await operation())) }
            catch { race.finish(.failure(error)) }
        }
        return try await race.wait(seconds: seconds)
    }
}

enum SceneBackendProcessExit {
    static func wait(pid: Int32, timeout: Duration = .seconds(3)) async -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            errno = 0
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        errno = 0
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}

final class SceneBackendDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var completed = false

    func install(_ value: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending { self.pending = nil; lock.unlock(); value.resume(with: pending) }
        else { continuation = value; lock.unlock() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        if completed { lock.unlock(); return }
        completed = true
        if let continuation { self.continuation = nil; lock.unlock(); continuation.resume(with: result) }
        else if pending == nil { pending = result; lock.unlock() }
        else { lock.unlock() }
    }

    func wait(seconds: Double) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
                Task {
                    do { try await Task.sleep(for: .seconds(seconds)); self.finish(.failure(UniversalSceneBackendError.timedOut)) }
                    catch { }
                }
            }
        } onCancel: { finish(.failure(CancellationError())) }
    }
}

@MainActor
final class SceneBackendServicePool {
    static let shared = SceneBackendServicePool()
    private var leased = Set<Int>()
    private var quarantined = Set<Int>()
    private var nextIndex = 0
    private let serviceNames: [String]
    init(serviceNames: [String] = SceneBackendServiceCatalog.identifiers) { self.serviceNames = serviceNames }

    func acquire() throws -> (Int, String) {
        let count = serviceNames.count
        guard count > 0 else { throw UniversalSceneBackendError.capacity }
        let candidates = (0..<count).map { (nextIndex + $0) % count }
        guard let index = candidates.first(where: {
            !leased.contains($0) && !quarantined.contains($0)
        }) else {
            throw UniversalSceneBackendError.capacity
        }
        // Spread rapid close/open cycles across independent jobs instead of
        // immediately reconnecting to the job whose owner just terminated.
        nextIndex = (index + 1) % count
        leased.insert(index); return (index, serviceNames[index])
    }

    func release(_ index: Int, reusable: Bool = true) {
        leased.remove(index)
        if !reusable { quarantined.insert(index) }
    }
    var activeLeaseCount: Int { leased.count }
}
