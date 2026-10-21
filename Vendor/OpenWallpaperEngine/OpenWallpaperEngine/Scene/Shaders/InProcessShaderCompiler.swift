import Foundation
import CryptoKit
import ShaderToolchain

/// glslang and SPIRV-Cross linked into the app (`Vendor/ShaderToolchain`). Calls are serialized
/// inside the library (glslang's global state is not thread-safe).
///
/// Every call runs on the compiler's `ShaderCompileThread`, under a watchdog. A call that overruns
/// it fails (its variant is logged as failed), its shader is quarantined with the crash guard, and
/// the library's lock stays held by a thread that can't be stopped: every later call this session
/// fails at once. The next launch compiles again, skipping the quarantined shader.
struct InProcessShaderCompiler: ShaderCompiler {
    /// Marks compiles in flight, so a crash inside the library is pinned on its shader on the next
    /// launch, and skips the shaders that crashed or hung before.
    let crashGuard: InProcessCompileCrashGuard?
    private let thread: ShaderCompileThread

    init(crashGuard: InProcessCompileCrashGuard? = nil, timeout: TimeInterval = ShaderCompileThread.defaultTimeout) {
        self.crashGuard = crashGuard
        thread = ShaderCompileThread(timeout: timeout)
    }

    static var libraryFingerprint: String { String(cString: owe_shader_toolchain_fingerprint()) }

    /// The libraries' output doesn't depend on which process runs them, so the compile helper
    /// (`HelperShaderCompiler`) shares this fingerprint and the caches it names.
    static var fingerprint: String { "in-process|\(libraryFingerprint)" }

    var cacheFingerprint: String { Self.fingerprint }

    /// Whether a call overran the watchdog this session (later calls fail at once).
    var isStuck: Bool { thread.isStuck }

    /// Identifies one library call's shader: the step, the stage and the whole input, which holds
    /// the variant's combos as defines.
    static func shaderKey(step: String, stage: ShaderStage, source: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(step)\u{0}\(stage.rawValue)\u{0}".utf8))
        hasher.update(data: Data(source.utf8))
        return Digest.hex(hasher.finalize())
    }

    func preprocess(_ source: String, stage: ShaderStage) throws -> String {
        ThreadGuards.assertBackground("shader preprocess")
        return try dispatch(step: "preprocess", key: Self.shaderKey(step: "preprocess", stage: stage, source: source)) {
            var output: UnsafeMutablePointer<CChar>?
            var log: UnsafeMutablePointer<CChar>?
            defer { owe_shader_free(output); owe_shader_free(log) }
            guard owe_shader_preprocess(source, stage.library, &output, &log) != 0, let output else {
                throw ShaderCompilerError.failed(step: "preprocess", output: Self.errors(log))
            }
            return String(cString: output)
        }
    }

    func compilePairToMSL(vertex: String, fragment: String) throws -> CompiledShaderPair {
        ThreadGuards.assertBackground("shader translation")
        let key = Self.shaderKey(step: "compile-pair", stage: .vertex, source: vertex + "\u{0}" + fragment)
        return try dispatch(step: "glslang", key: key) {
            var vertexMSL: UnsafeMutablePointer<CChar>?
            var vertexReflection: UnsafeMutablePointer<CChar>?
            var fragmentMSL: UnsafeMutablePointer<CChar>?
            var fragmentReflection: UnsafeMutablePointer<CChar>?
            var log: UnsafeMutablePointer<CChar>?
            var step: UnsafePointer<CChar>?
            var stage: Int32 = -1
            defer {
                owe_shader_free(vertexMSL); owe_shader_free(vertexReflection)
                owe_shader_free(fragmentMSL); owe_shader_free(fragmentReflection)
                owe_shader_free(log)
            }
            guard owe_shader_compile_pair_msl(vertex, fragment, &vertexMSL, &vertexReflection, &fragmentMSL,
                                              &fragmentReflection, &log, &step, &stage) != 0,
                  let vertexMSL, let vertexReflection, let fragmentMSL, let fragmentReflection else {
                throw ShaderCompilerError.failed(step: step.map { String(cString: $0) } ?? "glslang",
                                                 output: Self.errors(log))
            }
            return CompiledShaderPair(
                vertex: (String(cString: vertexMSL), Data(String(cString: vertexReflection).utf8)),
                fragment: (String(cString: fragmentMSL), Data(String(cString: fragmentReflection).utf8)))
        }
    }

    /// Runs `body` (a library call on the shader `key`) on the compile thread, unless that shader
    /// is quarantined or the thread is stuck.
    func dispatch<T>(step: String, key: String, _ body: @escaping () throws -> T) throws -> T {
        if let crashGuard, crashGuard.isQuarantined(key) { throw ShaderCompilerError.quarantined(step: step) }
        let crashGuard = crashGuard
        do {
            return try thread.run {
                crashGuard?.begin(key)
                defer { crashGuard?.end() }
                return try body()
            }
        } catch ShaderCompileThread.Failure.timedOut(let seconds) {
            OWELog.error(.shader, "In-process shader \(step) hung for \(Int(seconds.rounded())) s; "
                         + "shaders can't compile again until the app restarts")
            crashGuard?.recordHang(key)
            throw ShaderCompilerError.failed(step: step, output: "timed out after \(Int(seconds.rounded())) s")
        } catch ShaderCompileThread.Failure.stuck {
            throw ShaderCompilerError.failed(step: step, output: "\(ShaderCompileThread.Failure.stuck); "
                                             + "shaders compile again after the app restarts")
        }
    }

    /// The error lines of an info log.
    private static func errors(_ log: UnsafeMutablePointer<CChar>?) -> String {
        let text = log.map { String(cString: $0) } ?? ""
        let lines = text.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("error") }.prefix(8)
        return lines.isEmpty ? (text.isEmpty ? "failed" : String(text.prefix(800))) : lines.joined(separator: "\n")
    }
}

private extension ShaderStage {
    var library: owe_shader_stage {
        switch self {
        case .vertex: return OWE_SHADER_STAGE_VERTEX
        case .fragment: return OWE_SHADER_STAGE_FRAGMENT
        }
    }
}
