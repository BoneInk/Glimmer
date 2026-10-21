import Foundation
import Darwin

/// The shader compile helper: a copy of the app's executable run with `--shader-compile-helper`
/// (`HelperRunCommand`), which translates shaders for the app that started it
/// (`HelperShaderCompiler`), so a crash or hang in glslang or SPIRV-Cross takes down the helper
/// instead of the app.
///
/// Requests come in on stdin and responses go out on the original stdout, both as
/// `ShaderCompileHelperFrame`s. The libraries' own prints are sent to stderr (the null device), so
/// they can't corrupt the stream. The helper exits when stdin closes (the app quit or died) and
/// after answering a request its compile thread hung on (`ShaderCompileThread.isStuck`).
enum ShaderCompileHelperServer {
    static let argument = "--shader-compile-helper"
    /// Exit status after a hung compile.
    static let stuckStatus: Int32 = 3
    /// The helper exits after this long without a request; the app starts a new one on demand
    /// (`HelperShaderCompiler` retires its side a little earlier, so it never sends to a helper
    /// that is about to go).
    static let idleTimeout: TimeInterval = 300

    /// Watch the parent and the idle clock; kept alive for the helper's lifetime.
    private static var watchers: [DispatchSourceProtocol] = []
    /// Uptime of the last request's end (0 while one runs); `activityLock` owns it.
    private static var lastActivity = DispatchTime.now().uptimeNanoseconds
    private static let activityLock = NSLock()

    /// Serves requests until stdin closes; returns the exit status.
    static func run() -> Int32 {
        let responses = dup(STDOUT_FILENO)
        guard responses >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            OWELog.error(.shader, "Shader compile helper: can't set up its output (errno \(errno))")
            return 1
        }
        watchParentAndIdle()
        // Compiles assert they run off the main thread (`ThreadGuards`), and glslang needs a big stack.
        var status: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            status = serve(input: FileHandle.standardInput,
                           output: FileHandle(fileDescriptor: responses, closeOnDealloc: true),
                           compiler: ShaderCompilerFactory.makeDefault())
            done.signal()
        }
        thread.name = "OWE shader compile helper"
        thread.stackSize = ShaderCompileThread.stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        done.wait()
        return status
    }

    static func serve(input: FileHandle, output: FileHandle, compiler: ShaderCompiler) -> Int32 {
        OWELog.info(.shader, "Shader compile helper started (pid \(ProcessInfo.processInfo.processIdentifier))")
        var buffer = Data()
        while true {
            do {
                guard let payload = try nextFrame(input, buffer: &buffer) else { return 0 }
                activityLock.withLock { lastActivity = 0 }
                defer { activityLock.withLock { lastActivity = DispatchTime.now().uptimeNanoseconds } }
                let request = try JSONDecoder().decode(ShaderCompileHelperMessage.Request.self, from: payload)
                var response = handle(request, compiler: compiler)
                let stuck = (compiler as? InProcessShaderCompiler)?.isStuck ?? false
                response.exiting = stuck
                try output.write(contentsOf: ShaderCompileHelperFrame.encode(response))
                if stuck {
                    OWELog.error(.shader, "Shader compile helper: a compile hung; exiting so the app starts a new helper")
                    return stuckStatus
                }
            } catch {
                OWELog.error(.shader, "Shader compile helper: broken request stream: \(error)")
                return 1
            }
        }
    }

    /// Exits when the app that started the helper goes away (as the other helper runs do), and
    /// after `idleTimeout` without a request.
    private static func watchParentAndIdle() {
        let parent = getppid()
        guard parent > 1 else { exit(0) } // Already orphaned.
        let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global(qos: .utility))
        parentWatch.setEventHandler { exit(0) }
        parentWatch.resume()
        let idle = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        idle.schedule(deadline: .now() + 30, repeating: 30)
        idle.setEventHandler {
            let last = activityLock.withLock { lastActivity }
            guard last != 0, Double(DispatchTime.now().uptimeNanoseconds - last) / 1e9 > idleTimeout else { return }
            OWELog.info(.shader, "Shader compile helper idle for \(Int(idleTimeout)) s; exiting")
            exit(0)
        }
        idle.resume()
        watchers = [parentWatch, idle]
    }

    /// Runs one request on `compiler`.
    static func handle(_ request: ShaderCompileHelperMessage.Request,
                       compiler: ShaderCompiler) -> ShaderCompileHelperMessage.Response {
        let started = DispatchTime.now().uptimeNanoseconds
        var response = ShaderCompileHelperMessage.Response(id: request.id, text: nil, reflection: nil, failure: nil,
                                                           computeNanoseconds: 0, exiting: false)
        do {
            switch request.operation {
            case .preprocess:
                response.text = try compiler.preprocess(request.source, stage: request.stage)
            case .compilePairToMSL:
                let output = try compiler.compilePairToMSL(vertex: request.source, fragment: request.fragmentSource ?? "")
                response.text = output.vertex.msl
                response.reflection = output.vertex.reflection
                response.fragmentText = output.fragment.msl
                response.fragmentReflection = output.fragment.reflection
            }
        } catch ShaderCompilerError.failed(let step, let output) {
            response.failure = .init(step: step, output: output, quarantined: false)
        } catch ShaderCompilerError.quarantined(let step) {
            response.failure = .init(step: step, output: "", quarantined: true)
        } catch {
            response.failure = .init(step: request.operation.rawValue, output: "\(error)", quarantined: false)
        }
        response.computeNanoseconds = DispatchTime.now().uptimeNanoseconds - started
        return response
    }

    /// The next request's payload, or nil once stdin closed.
    private static func nextFrame(_ input: FileHandle, buffer: inout Data) throws -> Data? {
        while true {
            if let payload = try ShaderCompileHelperFrame.take(from: &buffer) { return payload }
            // read(2), not `FileHandle.read(upToCount:)`: that one waits for the whole count (or
            // EOF) on a pipe, so a request smaller than it would never arrive.
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(input.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}
