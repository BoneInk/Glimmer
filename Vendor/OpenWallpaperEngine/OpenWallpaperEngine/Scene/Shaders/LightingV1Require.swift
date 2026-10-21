import Foundation

/// WE's `#require LightingV1`: source that `wallpaper64.exe` generates for each combo set rather
/// than reads from a file (the generator at 0x140169140, called by the preprocessor's `require`
/// handler at 0x14016c0ec; docs/lighting-plan.md §2.1).
///
/// It declares the light arrays sized by the engine's `LIGHTS_*` combos
/// (`SceneEngineCombos+Lighting.swift`) and defines `PerformLighting_V1`, unrolled as one block
/// per light: points (the first `LIGHTS_POINT_SHADOW` shadowed), spots in four groups (shadow and
/// cookie, cookie, shadow, plain), tubes, then directionals (the first
/// `LIGHTS_DIRECTIONAL_SHADOW` with three cascades). Every string is verbatim from the binary.
///
/// `Scripts/lightingv1-reference.py` is the Python model; `LightingV1RequireTests` checks this
/// port against its output text for text.
enum LightingV1Require {
    /// The one `#require` name WE knows.
    static let name = "LightingV1"

    /// The generated source for `combos`, or "" unless `LIGHTING` is set and not 0. A missing
    /// count is 0, as WE's `atoi` of an empty string.
    static func source(combos: [String: Int]) -> String {
        guard let lighting = combos["LIGHTING"], lighting != 0 else { return "" }
        return Counts(combos).source
    }

    private struct Counts {
        let point, spot, tube, directional: Int
        let spotShadowCookie, spotShadow, spotCookie, directionalShadow, pointShadow: Int

        init(_ combos: [String: Int]) {
            point = combos["LIGHTS_POINT"] ?? 0
            spot = combos["LIGHTS_SPOT"] ?? 0
            tube = combos["LIGHTS_TUBE"] ?? 0
            directional = combos["LIGHTS_DIRECTIONAL"] ?? 0
            spotShadowCookie = combos["LIGHTS_SPOT_SHADOW_COOKIE"] ?? 0
            spotShadow = combos["LIGHTS_SPOT_SHADOW"] ?? 0
            spotCookie = combos["LIGHTS_SPOT_COOKIE"] ?? 0
            directionalShadow = combos["LIGHTS_DIRECTIONAL_SHADOW"] ?? 0
            pointShadow = combos["LIGHTS_POINT_SHADOW"] ?? 0
        }

        /// Shadow projections: one per shadowed or cookie spot and three per shadowed directional
        /// (0x140169a1e).
        var features: Int { spotCookie + 3 * directionalShadow + spotShadow + spotShadowCookie }

        var source: String {
            var out = declarations
            out += "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)\n{\n\tvec3 light = CAST3(0.0);\n"
            out += points
            let (spots, featureBase) = self.spots
            out += spots
            out += tubes
            out += directionals(featureBase: featureBase)
            out += "\treturn light;\n}\n"
            return out
        }

        private var declarations: String {
            var out = ""
            func declare(_ type: String, _ names: [String], _ count: Int) {
                guard count != 0 else { return }
                for name in names { out += "uniform \(type) \(name)[\(count)];\n" }
            }
            declare("vec4", ["g_LPoint_Color", "g_LPoint_Origin"], point)
            declare("vec4", ["g_LSpot_Color", "g_LSpot_Origin", "g_LSpot_Direction", "g_LSpot_Exponent"], spot)
            declare("vec4", ["g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB"], tube)
            declare("vec4", ["g_LDirectional_Color", "g_LDirectional_Direction"], directional)
            declare("mat4", ["g_LFeature_ShadowProjection"], features)
            declare("vec4", ["g_LFeature_ShadowProjectionTransform"], features)
            declare("vec4", ["g_LFeature_ShadowPointProjection", "g_LFeature_ShadowPointProjectionTransform"], pointShadow)
            return out
        }

        private static func open(_ index: Int) -> String { "{\n\tconst uint i = \(index)u;\n" }
        private static let close = "}\n"
        private static let lightShadow = "\tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, "
        private static func tail(_ shadow: String) -> String {
            ", specularTint, ambient, roughness, metallic, \(shadow));\n"
        }

        /// 0x140169bd0 (shadowed) and 0x140169d50 (plain).
        private var points: String {
            var out = ""
            for index in stride(from: 0, to: point, by: 1) {
                out += Self.open(index)
                out += "\tvec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;\n"
                let color = "g_LPoint_Color[i].rgb, g_LPoint_Color[i].w, g_LPoint_Origin[i].w"
                if index < pointShadow {
                    out += "\tvec4 projectedCoords = CalculateProjectedCoordsPoint(worldPos, g_LPoint_Origin[i].xyz, g_LFeature_ShadowPointProjection[i], g_LFeature_ShadowPointProjectionTransform[i]);\n"
                    out += "\tfloat shadowFactor = PerformPointShadowMapping(projectedCoords);\n"
                    out += Self.lightShadow + color + Self.tail("shadowFactor")
                } else {
                    out += Self.lightShadow + color + Self.tail("1.0")
                }
                out += Self.close
            }
            return out
        }

        /// The four spot groups: shadow and cookie (0x140169e90), cookie (0x14016a010), shadow
        /// (0x14016a170), then plain up to `LIGHTS_SPOT` (0x14016a300). One index runs through all
        /// of them and also picks the shadow projection. Returns where the plain spots start, which
        /// is where the directional cascades start.
        private var spots: (String, Int) {
            var out = ""
            var index = 0
            let delta = "\tvec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n"
            let projected = "\tvec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i]);\n"
            let shadow = "\tfloat shadowFactor = PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[i]);\n"
            let cookie = "\tvec3 colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb;\n"
            let cone = "\tfloat spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz);\n"
                + "\tspotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie);\n"
            let cookieColor = "g_LSpot_Color[i].rgb * colorCookie, g_LSpot_Color[i].w, g_LSpot_Exponent[i].x"
            let coneColor = "g_LSpot_Color[i].rgb * spotCookie, g_LSpot_Color[i].w, g_LSpot_Exponent[i].x"
            func emit(_ count: Int, _ body: String) {
                for _ in stride(from: 0, to: count, by: 1) {
                    out += Self.open(index) + delta + body + Self.close
                    index += 1
                }
            }
            emit(spotShadowCookie, projected + shadow + cookie + Self.lightShadow + cookieColor + Self.tail("shadowFactor"))
            emit(spotCookie, projected + cookie + Self.lightShadow + cookieColor + Self.tail("1.0"))
            emit(spotShadow, cone + projected + shadow + Self.lightShadow + coneColor + Self.tail("shadowFactor"))
            let featureBase = index
            emit(spot - index, cone + Self.lightShadow + coneColor + Self.tail("1.0"))
            return (out, featureBase)
        }

        /// Never shadowed.
        private var tubes: String {
            var out = ""
            for index in stride(from: 0, to: tube, by: 1) {
                out += Self.open(index)
                out += "\tvec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[i].xyz, g_LTube_OriginB[i].xyz);\n"
                out += Self.lightShadow + "g_LTube_Color[i].rgb, g_LTube_Color[i].w, g_LTube_OriginA[i].w" + Self.tail("1.0")
                out += Self.close
            }
            return out
        }

        /// The first `LIGHTS_DIRECTIONAL_SHADOW` blend three cascades `p1…p3` from `featureBase`.
        /// WE's quirk, kept: the base advances by 1 per light (0x14016a9b4 / 0x14016ae36), not 3.
        private func directionals(featureBase: Int) -> String {
            var out = ""
            var cascade = featureBase
            let infinite = "\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, color, g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, metallic, "
            for index in stride(from: 0, to: directional, by: 1) {
                out += Self.open(index)
                if index < directionalShadow {
                    out += "\tconst uint p1 = \(cascade)u;\n\tconst uint p2 = \(cascade + 1)u;\n\tconst uint p3 = \(cascade + 2)u;\n"
                    out += "\tvec4 projectedCoords1 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p1]);\n"
                    out += "\tvec4 projectedCoords2 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p2]);\n"
                    out += "\tvec4 projectedCoords3 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p3]);\n"
                    out += "\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords2.xyz, projectedCoords1.w);\n"
                    out += "\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords3.xyz, projectedCoords2.w);\n"
                    out += "\tvec4 uvTransforms = mix(g_LFeature_ShadowProjectionTransform[p1], g_LFeature_ShadowProjectionTransform[p2], projectedCoords1.w);\n"
                    out += "\tuvTransforms = mix(uvTransforms, g_LFeature_ShadowProjectionTransform[p3], projectedCoords2.w);\n"
                    out += "\tfloat shadowFactor = max(projectedCoords3.w, PerformShadowMapping(projectedCoords1.xyz, uvTransforms));\n"
                    out += infinite + "shadowFactor);\n"
                    cascade += 1
                } else {
                    out += infinite + "1.0);\n"
                }
                out += Self.close
            }
            return out
        }
    }
}
