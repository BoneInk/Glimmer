import Foundation

/// What names this build's shader caches on this Mac: the shader variant cache's generation
/// (`ShaderVariantTranslator.generation(toolchain:)`) and the pipeline archive's environment
/// (`EffectPipelineArchive.environmentKey`). Two builds with equal keys read each other's caches;
/// device and OS are the same for both, since they run on the same machine.
///
/// A new build prints its own with `--print-shader-cache-key` (`HelperRunCommand`), so the
/// running app can tell before an update installs whether its caches will have to be rebuilt.
struct ShaderCacheKey: Codable, Equatable, Sendable {
    var translatorRevision: Int
    var variantGeneration: String
    var pipelineEnvironment: String

    /// This build's key.
    static var current: ShaderCacheKey {
        let toolchain: String = InProcessShaderCompiler.libraryFingerprint
        let variantToolchain = ShaderToolchainVersions.fingerprint(compiler: InProcessShaderCompiler.fingerprint)
        return ShaderCacheKey(translatorRevision: ShaderVariantTranslator.revision,
                              variantGeneration: ShaderVariantTranslator.generation(toolchain: variantToolchain),
                              pipelineEnvironment: EffectPipelineArchive.environmentKey(
                                os: ProcessInfo.processInfo.operatingSystemVersionString, toolchain: toolchain))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// The key in a build's `--print-shader-cache-key` output: the last line that decodes, since
    /// the process may log before it.
    static func parse(_ output: Data) throws -> ShaderCacheKey {
        let lines: [Substring] = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
        var lastError: Error = ParseError.empty
        for line in lines.reversed() where line.hasPrefix("{") {
            do {
                return try JSONDecoder().decode(ShaderCacheKey.self, from: Data(line.utf8))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    enum ParseError: Error, CustomStringConvertible {
        case empty
        var description: String { "no shader cache key in the output" }
    }
}
