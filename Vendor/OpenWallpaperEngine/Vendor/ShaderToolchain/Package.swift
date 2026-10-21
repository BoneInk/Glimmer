// swift-tools-version:5.9
// glslang and SPIRV-Cross, built from pinned upstream sources, plus a small C shim the app
// imports. See README.md for the pinned versions and how to refresh them.
import PackageDescription

let package = Package(
    name: "ShaderToolchain",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ShaderToolchain", targets: ["ShaderToolchain"]),
    ],
    targets: [
        .target(
            name: "glslang",
            path: "glslang",
            exclude: ["LICENSE.txt", "README.md", "glslang/stub.cpp", "SPIRV/spirv.hpp11", "spm-public-headers/README"],
            sources: ["glslang", "SPIRV"],
            publicHeadersPath: "spm-public-headers",
            cxxSettings: [
                .headerSearchPath("."),
                // Matches the upstream CMake build without HLSL and without SPIRV-Tools (ENABLE_OPT
                // only runs the optimizer, which GLSL → SPIR-V without -O never does).
                .define("ENABLE_SPIRV", to: "1"),
                .define("ENABLE_OPT", to: "0"),
                .define("GLSLANG_OSINCLUDE_UNIX"),
                // Release semantics like the Homebrew tools: an upstream assert must not abort the app.
                .define("NDEBUG"),
                .unsafeFlags(["-w", "-O2"]),
            ]
        ),
        .target(
            name: "SPIRVCross",
            path: "SPIRV-Cross",
            exclude: ["LICENSE", "README.md", "spm-public-headers/README"],
            publicHeadersPath: "spm-public-headers",
            cxxSettings: [
                .headerSearchPath("."),
                // glslang's spirv.hpp11 also declares `spv::`; give SPIRV-Cross's copy its own
                // namespace so the two never share mangled names (upstream's documented switch).
                .define("SPIRV_CROSS_SPV_HEADER_NAMESPACE_OVERRIDE", to: "spvc_spv"),
                .define("NDEBUG"),
                .unsafeFlags(["-w", "-O2"]),
            ]
        ),
        .target(
            name: "ShaderToolchain",
            dependencies: ["glslang", "SPIRVCross"],
            path: "Sources/ShaderToolchain",
            cxxSettings: [
                .headerSearchPath("../../glslang"),
                .headerSearchPath("../../SPIRV-Cross"),
                .define("ENABLE_SPIRV", to: "1"),
                .define("SPIRV_CROSS_SPV_HEADER_NAMESPACE_OVERRIDE", to: "spvc_spv"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
