import Foundation

/// Translates shaders in a long-lived helper process (`ShaderCompileHelperServer`) instead of in
/// the app, so a crash or hang in glslang or SPIRV-Cross costs a helper, not the app.
///
/// The helper starts on the first request. When it dies or stops answering, the request is retried
/// once on a new helper; when that fails too, the step fails like any compile error and the
/// translator logs the variant to FailedShaders (`ShaderVariantTranslator.recordFailure`). A
/// shader that crashed the helper is pinned on it by the helper's crash guard, so the retry's
/// helper skips it as quarantined instead of crashing again.
///
/// Callers block on their own (compile) thread, never the render thread. Requests are serialized:
/// the libraries are single-threaded anyway. Waiting requests go in priority order: the caller's
/// QoS, so the visible scene's (user-initiated) ahead of prewarming (background) (`PriorityGate`).
/// `lock` owns `channel`, `lastUsed`, `nextID` and `statistics`.
///
/// One per app process: the app's single translator (`SceneContentLoader.defaultEffectTranslator`)
/// owns it, so every wallpaper instance and display shares one helper; an isolated copy is its
/// own process with its own.
final class HelperShaderCompiler: ShaderCompiler {
    typealias Launch = () throws -> ShaderCompileHelperChannel

    /// Round-trip cost next to compile time, logged every `reportInterval` requests.
    struct Statistics: Equatable {
        var requests = 0
        var roundTripNanoseconds: UInt64 = 0
        var computeNanoseconds: UInt64 = 0
        var launches = 0

        /// Mean time per request outside the compiler: encoding, the pipe, decoding.
        var overheadMilliseconds: Double {
            requests == 0 ? 0 : Double(roundTripNanoseconds &- computeNanoseconds) / Double(requests) / 1e6
        }
        var computeMilliseconds: Double {
            requests == 0 ? 0 : Double(computeNanoseconds) / Double(requests) / 1e6
        }
    }

    static let reportInterval = 64

    /// The helper's own watchdog (`ShaderCompileThread.defaultTimeout`) answers first; this only
    /// catches a helper that is wedged outside it.
    let timeout: TimeInterval
    private let launch: Launch
    private let lock = NSLock()
    private let gate = PriorityGate()
    private var channel: ShaderCompileHelperChannel?
    private var lastUsed = DispatchTime.now().uptimeNanoseconds
    private var nextID: UInt64 = 0
    private var statistics = Statistics()

    init(timeout: TimeInterval = ShaderCompileThread.defaultTimeout + 10, launch: @escaping Launch) {
        self.timeout = timeout
        self.launch = launch
    }

    /// A helper running this app's executable at `qos`: background for prewarming, user-initiated
    /// for the scene on screen.
    convenience init(executable: URL, qos: QualityOfService) {
        self.init { try ShaderCompileHelperProcess(executable: executable, qos: qos) }
    }

    deinit { channel?.close() }

    /// Same libraries, same output as in process: the caches stay shared.
    var cacheFingerprint: String { InProcessShaderCompiler.fingerprint }

    var currentStatistics: Statistics { lock.withLock { statistics } }

    func preprocess(_ source: String, stage: ShaderStage) throws -> String {
        let response = try send(.preprocess, stage: stage, source: source)
        guard let text = response.text else { throw ShaderCompilerError.failed(step: "preprocess", output: "empty response") }
        return text
    }

    func compilePairToMSL(vertex: String, fragment: String) throws -> CompiledShaderPair {
        let response = try send(.compilePairToMSL, stage: .vertex, source: vertex, fragmentSource: fragment)
        guard let vertexMSL = response.text, let vertexReflection = response.reflection,
              let fragmentMSL = response.fragmentText, let fragmentReflection = response.fragmentReflection else {
            throw ShaderCompilerError.failed(step: "glslang", output: "empty response")
        }
        return CompiledShaderPair(vertex: (vertexMSL, vertexReflection), fragment: (fragmentMSL, fragmentReflection))
    }

    private func send(_ operation: ShaderCompileHelperMessage.Operation, stage: ShaderStage,
                      source: String, fragmentSource: String? = nil) throws -> ShaderCompileHelperMessage.Response {
        ThreadGuards.assertBackground("shader translation")
        let step = operation == .preprocess ? "preprocess" : "glslang"
        gate.enter(priority: Thread.current.qualityOfService.rawValue)
        defer { gate.leave() }
        lock.lock()
        defer { lock.unlock() }
        nextID &+= 1
        let request = ShaderCompileHelperMessage.Request(id: nextID, operation: operation, stage: stage, source: source,
                                                         fragmentSource: fragmentSource)
        let frame: Data
        do {
            frame = try ShaderCompileHelperFrame.encode(request)
        } catch {
            throw ShaderCompilerError.failed(step: step, output: "can't encode the request: \(error)")
        }
        var lastError: Error = ShaderCompileHelperChannelError.exited("not started")
        for attempt in 0..<2 {
            do {
                let response = try exchange(frame, id: request.id)
                if let failure = response.failure {
                    throw failure.quarantined ? ShaderCompilerError.quarantined(step: failure.step)
                        : ShaderCompilerError.failed(step: failure.step, output: failure.output)
                }
                return response
            } catch let error as ShaderCompileHelperChannelError {
                channel?.close()
                channel = nil
                lastError = error
                OWELog.error(.shader, "Shader compile helper failed during \(step) (\(error))"
                             + (attempt == 0 ? "; retrying on a new helper" : "; giving up on this shader"))
            }
        }
        throw ShaderCompilerError.failed(step: step, output: "the shader compile helper failed twice: \(lastError)")
    }

    /// One request on the current helper, starting one if needed. Caller holds `lock`.
    private func exchange(_ frame: Data, id: UInt64) throws -> ShaderCompileHelperMessage.Response {
        let current: ShaderCompileHelperChannel
        let now = DispatchTime.now().uptimeNanoseconds
        if let idle = channel, Double(now - lastUsed) / 1e9 > ShaderCompileHelperServer.idleTimeout - 30 {
            idle.close() // about to idle out on its own
            channel = nil
        }
        lastUsed = now
        if let channel {
            current = channel
        } else {
            current = try launch()
            channel = current
            statistics.launches += 1
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let payload = try current.exchange(frame, timeout: timeout)
        let response: ShaderCompileHelperMessage.Response
        do {
            response = try JSONDecoder().decode(ShaderCompileHelperMessage.Response.self, from: payload)
        } catch {
            throw ShaderCompileHelperChannelError.malformedResponse("\(error)")
        }
        guard response.id == id else {
            throw ShaderCompileHelperChannelError.malformedResponse("answer to request \(response.id), expected \(id)")
        }
        record(roundTrip: DispatchTime.now().uptimeNanoseconds - started, compute: response.computeNanoseconds)
        if response.exiting {
            current.close()
            channel = nil
        }
        return response
    }

    /// Caller holds `lock`.
    private func record(roundTrip: UInt64, compute: UInt64) {
        statistics.requests += 1
        statistics.roundTripNanoseconds &+= roundTrip
        statistics.computeNanoseconds &+= min(compute, roundTrip)
        guard statistics.requests % Self.reportInterval == 0 else { return }
        OWELog.info(.shader, "Shader compile helper: \(statistics.requests) requests, round-trip overhead "
                     + String(format: "%.3f ms per request (compile %.3f ms; 4 requests per variant)",
                              statistics.overheadMilliseconds, statistics.computeMilliseconds)
                     + ", \(statistics.launches) helper launch(es)")
    }
}
