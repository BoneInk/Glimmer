# ShaderToolchain

glslang and SPIRV-Cross linked into the app, so shader translation needs no external tools
(`OpenWallpaperEngine/Scene/Shaders/InProcessShaderCompiler.swift`).

| Library | Upstream | Version |
|---|---|---|
| glslang | https://github.com/KhronosGroup/glslang | tag `16.6.0` |
| SPIRV-Cross | https://github.com/KhronosGroup/SPIRV-Cross | tag `vulkan-sdk-1.4.357.0` |

Only the sources the library build needs are kept: glslang's `glslang/` (without HLSL, the C
interface and the grammar sources) and `SPIRV/`, and SPIRV-Cross's core, GLSL, MSL and
reflection backends. `glslang/glslang/build_info.h` is generated from upstream's
`build_info.h.tmpl` with the version above. The licenses are `glslang/LICENSE.txt` and
`SPIRV-Cross/LICENSE`.

`Sources/ShaderToolchain` is our C shim. It reproduces what the app used to run as processes
(`glslangValidator -E`, `glslangValidator -G`, `spirv-cross --msl … / --reflect`). The golden
corpus test (`ShaderVariantCacheTests.testTranslatedOutputMatchesItsRevision`) guards its output.
It also compiles a shader's two stages as one program under glslang's relaxed Vulkan rules
(`owe_shader_compile_pair_msl`, which gathers loose uniforms into one `WEUniforms` block). In the
SPIR-V debug names, the GLSL reserved words the prelude spelled `we_<word>` get WE's names back
(`restoreReservedNames`; the list is `owe_shader_glsl_reserved_words`), so the reflection carries
them, and names MSL reserves are renamed before SPIRV-Cross writes the MSL
(`renameMetalClashes`); the reflection reads the names before that rename.

## Refreshing

1. Clone both repositories at the new tags and copy the same directories over these ones.
2. Regenerate `build_info.h`, delete `glslang.y`/`glslang.m4` and `ExtensionHeaders/`.
3. Update the version string `OWE_SPIRV_CROSS_VERSION` in the shim and this table.
4. Run the test suite. If the output changes, bump `ShaderVariantTranslator.revision`
   (the cache fingerprint already includes the library versions).
