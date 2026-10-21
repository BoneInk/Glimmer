import Foundation

/// Runs a WE particle vertex stage written for engines without geometry shaders (`GS_ENABLED`
/// 0) from one record per particle, drawn instanced.
///
/// That stream has four vertices per particle that repeat the particle's data and add the quad
/// corner: `genericparticle` packs the corner into `a_TexCoordVec4.xy` (rotation z and size in
/// `.zw`) and moves rotation xy to `a_TexCoordC2`; `genericropeparticle` reads the corner from
/// `a_TexCoordC3` (thin) or `a_TexCoordC4` (thick). Here those attributes become globals the
/// stage fills on entry from the instance's record and the corner `gl_VertexID` names, so each
/// instance draws `verticesPerInstance` indices as two triangles over its four corners and no
/// vertex is stored or run twice.
enum ParticleQuadExpansion {
    /// Two triangles over the corners `(0,0) (0,1) (1,0) (1,1)`
    /// (`ParticleMaterialPlan.Stage.Geometry.indices`).
    static let verticesPerInstance = 6

    /// The sprite record's `rotationSize` slot, read whole before the corner replaces `.xy`.
    static let recordAttribute = "a_OweParticleRecord1"

    private static let entryPattern = expression(#"\bvoid\s+main\s*\(\s*(?:void)?\s*\)\s*\{"#)

    /// Rewrites the vertex stage's text (includes inlined) for `format`.
    static func rewrite(_ text: String, format: ParticleVertexFormat) -> String {
        let replaced: [String]
        let globals: String
        let entry: String
        switch format {
        case .sprite:
            replaced = ["a_TexCoordVec4", "a_TexCoordC2"]
            globals = "attribute vec4 \(recordAttribute);\nvec4 a_TexCoordVec4;\nvec2 a_TexCoordC2;\n"
            entry = "a_TexCoordVec4 = vec4(owe_quadCorner(), \(recordAttribute).zw); a_TexCoordC2 = \(recordAttribute).xy;"
        case .rope:
            replaced = ["a_TexCoordC3", "a_TexCoordC4"]
            globals = "vec2 a_TexCoordC3;\nvec2 a_TexCoordC4;\n"
            entry = "a_TexCoordC3 = owe_quadCorner(); a_TexCoordC4 = a_TexCoordC3;"
        }
        var result = text
        for name in replaced {
            let declaration = expression(#"(?m)^[ \t]*(?:attribute|in)[ \t]+(?:(?:lowp|mediump|highp)[ \t]+)?\w+[ \t]+"#
                                         + name + #"[ \t]*;[^\n]*$"#)
            result = declaration.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                          withTemplate: "// (per corner) $0")
        }
        let corner = """
        vec2 owe_quadCorner() {
        \tint corner = gl_VertexID;
        \treturn vec2(float(corner / 2), float(corner - (corner / 2) * 2));
        }

        """
        // Each `main` (a stage may keep one per `#if` branch) fills the globals first.
        for match in entryPattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.insert(contentsOf: "\n\t" + entry + "\n", at: range.upperBound)
        }
        return globals + corner + result
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("invalid particle quad pattern \(pattern): \(error)")
        }
    }
}
