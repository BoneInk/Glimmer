import Foundation

enum ShaderCompilerError: Error, CustomStringConvertible {
    case failed(step: String, output: String)
    /// This shader's compile killed or hung an earlier run (`InProcessCompileCrashGuard`); it is
    /// skipped so the rest of the scene still compiles.
    case quarantined(step: String)

    var description: String {
        switch self {
        case .failed(let step, let output): return "\(step) failed: \(output)"
        case .quarantined(let step):
            return "\(step) skipped: this shader killed or hung the app in an earlier run "
                + "(quarantined until the shader libraries change)"
        }
    }
}

/// The GLSL → SPIR-V → MSL toolchain. The app uses `HelperShaderCompiler`, which runs
/// `InProcessShaderCompiler` (glslang and SPIRV-Cross linked in) in a helper process; tests
/// substitute their own.
protocol ShaderCompiler {
    /// Identifies everything that decides the output: backend, library versions and options.
    /// Part of the variant cache key; never machine-specific (no paths or dates).
    var cacheFingerprint: String { get }
    /// Runs the GLSL preprocessor only, resolving every `#if` against the defined macros.
    func preprocess(_ source: String, stage: ShaderStage) throws -> String
    /// Compiles a preprocessed, decorated vertex/fragment pair as one linked program under
    /// glslang's relaxed Vulkan rules, which gather both stages' loose uniforms into one
    /// `WEUniforms` block, and returns each stage's MSL and reflection JSON. A failure's output
    /// names the stage's file (`shader.vert` or `shader.frag`).
    func compilePairToMSL(vertex: String, fragment: String) throws -> CompiledShaderPair
}

/// Both stages of a pair, compiled together (`ShaderCompiler.compilePairToMSL`).
struct CompiledShaderPair {
    let vertex: (msl: String, reflection: Data)
    let fragment: (msl: String, reflection: Data)
}

/// Makes the app's shader compiler: the linked libraries, guarded against shaders that crashed
/// or hung them in an earlier run.
enum ShaderCompilerFactory {
    /// The app's compiler: a compile helper process (`HelperShaderCompiler`) at `qos`. Tests are
    /// hosted in the app and translate in process (`makeDefault`), as does a build without an
    /// executable to run; `inProcessStateDirectory` is then their crash guard's.
    static func makeIsolated(qos: QualityOfService,
                             inProcessStateDirectory: URL? = defaultStateDirectory,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> ShaderCompiler {
        if SceneBackendRuntimeContext.isActive { return InProcessShaderCompiler() }
        guard environment["XCTestConfigurationFilePath"] == nil, let executable = AppRelauncher.helperExecutable else {
            return makeDefault(stateDirectory: inProcessStateDirectory)
        }
        return HelperShaderCompiler(executable: executable, qos: qos)
    }

    /// The linked libraries in this process: the helper's own compiler, and tests'.
    static var defaultStateDirectory: URL? {
        ShaderVariantTranslator.defaultCacheDirectory?
            .deletingLastPathComponent().appending(path: "shader-compiler", directoryHint: .isDirectory)
    }

    static func makeDefault(stateDirectory: URL? = defaultStateDirectory) -> ShaderCompiler {
        guard let stateDirectory else { return InProcessShaderCompiler() }
        let crashGuard = InProcessCompileCrashGuard(directory: stateDirectory,
                                                    fingerprint: InProcessShaderCompiler.libraryFingerprint)
        crashGuard.collectDeaths()
        return InProcessShaderCompiler(crashGuard: crashGuard)
    }
}
