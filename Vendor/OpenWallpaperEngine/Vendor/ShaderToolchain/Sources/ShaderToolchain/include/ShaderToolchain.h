#ifndef OWE_SHADER_TOOLCHAIN_H
#define OWE_SHADER_TOOLCHAIN_H

// In-process glslang + SPIRV-Cross:
//   glslangValidator -E -S <stage> file                        (owe_shader_preprocess)
//   glslangValidator --relaxed-rules-vulkan, both stages linked (owe_shader_compile_pair_msl, step 1)
//               and the GLSL reserved words' names restored in the SPIR-V
//   spirv-cross spv --msl --msl-version 20300 --msl-decoration-binding
//               [--fixup-clipspace --flip-vert-y for vertex]   (step 2, each stage)
//   spirv-cross spv --reflect                                  (step 3, each stage)
//
// Every call is serialized on one internal lock: glslang keeps process-global state (symbol
// tables, the pool allocator) that is not safe to use from several threads at once.
//
// Strings returned through `char **` are heap allocated; release them with owe_shader_free.

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    OWE_SHADER_STAGE_VERTEX = 0,
    OWE_SHADER_STAGE_FRAGMENT = 1,
} owe_shader_stage;

/// Returns 1 on success with `*output` set; 0 on failure with `*log` set.
int owe_shader_preprocess(const char *source, owe_shader_stage stage, char **output, char **log);

/// Compiles a vertex/fragment pair as one linked program under glslang's relaxed Vulkan rules,
/// which gather both stages' loose uniforms into one `WEUniforms` block (binding 0). Returns 1
/// with both stages' MSL and reflection set; 0 with `*log`, `*failed_step` and `*failed_stage`
/// (the stage, or -1 for the link) set.
int owe_shader_compile_pair_msl(const char *vertex, const char *fragment, char **vertex_msl,
                                char **vertex_reflection, char **fragment_msl, char **fragment_reflection,
                                char **log, const char **failed_step, int *failed_stage);

void owe_shader_free(char *string);

/// The words GLSL reserves that WE's shaders may use as names, separated by spaces. The prelude
/// spells each one `we_<word>` for glslang; the pair compile gives the SPIR-V WE's spelling back
/// before writing MSL and reflection, and renames only the names MSL can't take.
const char *owe_shader_glsl_reserved_words(void);

/// Identifies the linked libraries and the fixed option set; changes whenever output can.
const char *owe_shader_toolchain_fingerprint(void);

#ifdef __cplusplus
}
#endif

#endif
