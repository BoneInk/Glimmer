import Foundation

/// The versions of everything that turns a WE shader into a GPU program: glslang and SPIRV-Cross
/// (in `InProcessShaderCompiler.libraryFingerprint`) and the Metal compiler, which ships with the
/// OS and is identified by its build (`kern.osversion`, e.g. `25A354`). Part of every variant's
/// cache key, so a toolchain update starts a new cache instead of reading the old one.
enum ShaderToolchainVersions {
    /// This Mac's OS build; "unknown" when the kernel won't say (never in practice).
    static let osBuild: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }()

    /// The variant cache's toolchain: the translating compiler's fingerprint (backend, glslang and
    /// SPIRV-Cross versions, options) and the Metal compiler's OS build.
    static func fingerprint(compiler: String, osBuild: String = ShaderToolchainVersions.osBuild) -> String {
        "\(compiler)|metal \(osBuild)"
    }
}
