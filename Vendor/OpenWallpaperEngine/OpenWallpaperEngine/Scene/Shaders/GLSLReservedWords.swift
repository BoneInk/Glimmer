import Foundation
import ShaderToolchain

/// Names glslang rejects as identifiers in `#version 450` but WE's compiler accepts, because WE
/// compiles its dialect through HLSL: GLSL's words "reserved for future use" (`common`, `input`,
/// `filter`, `cast`, …) and GLSL-only keywords the dialect never uses as keywords (`sample`,
/// `buffer`, `patch`, the image types, …). The list is the shader toolchain's
/// (`owe_shader_glsl_reserved_words`), which renames them back in the SPIR-V.
///
/// glslang's scanner rejects these words before there is any SPIR-V, so the prelude spells each
/// one a shader uses `we_<name>` with a macro, which changes every use alike (a local, a function,
/// a uniform, a varying in both stages). The pair compile then gives the SPIR-V's names WE's
/// spelling back (`restoreReservedNames`), before SPIRV-Cross writes the MSL and the reflection:
/// material constants bind by WE's names. In the MSL, SPIRV-Cross spells a GLSL keyword its own
/// way (`_common`), and names MSL can't take (`half`, `this`, …) are renamed for Metal
/// (`renameMetalClashes`).
///
/// The keywords HLSL shares (`shared`, `volatile`, `precise`, `double`, …) can't be names in WE
/// either, so none is listed.
enum GLSLReservedWords {
    static let words: Set<String> = Set(String(cString: owe_shader_glsl_reserved_words())
        .split(separator: " ").map(String.init))

    static let prefix = "we_"

    /// The listed words `source` uses as identifiers in code, sorted. Comments and string literals
    /// (`#include "common.h"`) don't count.
    static func used(in source: String) -> [String] {
        words.intersection(codeIdentifiers(in: source)).sorted()
    }

    /// Every maximal run of ASCII identifier characters outside comments and string literals.
    static func codeIdentifiers(in source: String) -> Set<String> {
        var tokens = Set<String>()
        let bytes = Array(source.utf8)
        var index = 0
        var start: Int?
        func flush(at end: Int) {
            if let tokenStart = start {
                tokens.insert(String(decoding: bytes[tokenStart..<end], as: UTF8.self))
                start = nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == 0x2F, next == 0x2F { // `//` to the end of the line
                flush(at: index)
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                continue
            }
            if byte == 0x2F, next == 0x2A { // `/*` to `*/`
                flush(at: index)
                index += 2
                while index < bytes.count, !(bytes[index] == 0x2A && index + 1 < bytes.count && bytes[index + 1] == 0x2F) {
                    index += 1
                }
                index += 2
                continue
            }
            if byte == 0x22 { // a string literal, which only `#include` and `#line` take
                flush(at: index)
                index += 1
                while index < bytes.count, bytes[index] != 0x22, bytes[index] != 0x0A { index += 1 }
                index += 1
                continue
            }
            let isWord = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
            if isWord {
                if start == nil { start = index }
            } else {
                flush(at: index)
            }
            index += 1
        }
        flush(at: min(index, bytes.count))
        return tokens
    }
}
