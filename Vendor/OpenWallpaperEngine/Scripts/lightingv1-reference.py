#!/usr/bin/env python3
"""Reference model of Wallpaper Engine's `#require LightingV1` generator, and the generator of the
test oracle.

    ./Scripts/lightingv1-reference.py LIGHTS_POINT=2 LIGHTS_TUBE=1 ...   # print one expansion
    ./Scripts/lightingv1-reference.py fixture [--out DIR]               # Tests/Fixtures/LightingV1/expansions.json

WHAT IT MODELS (docs/lighting-plan.md §2.1, from wallpaper64.exe of 2026-09)

The preprocessor's `require` handler (0x14016c0ec) calls the generator at 0x140169140. It emits
nothing unless the name is exactly "LightingV1" and the combo LIGHTING exists with atoi != 0. The
counts are the combos the engine set (0x1401a5c40): LIGHTS_POINT, LIGHTS_SPOT, LIGHTS_TUBE,
LIGHTS_DIRECTIONAL, LIGHTS_SPOT_SHADOW_COOKIE, LIGHTS_SPOT_SHADOW, LIGHTS_SPOT_COOKIE,
LIGHTS_DIRECTIONAL_SHADOW and LIGHTS_POINT_SHADOW; a missing one reads as 0 (atoi of an empty
string). Every string is verbatim from the binary. The cascade base of shadowed directionals
advances by 1 per light (0x14016a9b4 / 0x14016ae36) although each light has 3 cascades: WE's
quirk, kept. Plain Python 3, no packages.

`OpenWallpaperEngine/Scene/Shaders/LightingV1Require.swift` is the Swift port;
`LightingV1RequireTests` checks it against the fixture text for text.
"""
import json
import os
import sys


def expand(c):
    if c.get('LIGHTING', 0) == 0:
        return ''
    P  = c.get('LIGHTS_POINT', 0);  S = c.get('LIGHTS_SPOT', 0)
    T  = c.get('LIGHTS_TUBE', 0);   D = c.get('LIGHTS_DIRECTIONAL', 0)
    SSC= c.get('LIGHTS_SPOT_SHADOW_COOKIE', 0); SS = c.get('LIGHTS_SPOT_SHADOW', 0)
    SC = c.get('LIGHTS_SPOT_COOKIE', 0);        DS = c.get('LIGHTS_DIRECTIONAL_SHADOW', 0)
    PS = c.get('LIGHTS_POINT_SHADOW', 0)
    o = []
    if P:
        o.append('uniform vec4 g_LPoint_Color[%d];\n' % P)
        o.append('uniform vec4 g_LPoint_Origin[%d];\n' % P)
    if S:
        o.append('uniform vec4 g_LSpot_Color[%d];\n' % S)
        o.append('uniform vec4 g_LSpot_Origin[%d];\n' % S)
        o.append('uniform vec4 g_LSpot_Direction[%d];\n' % S)
        o.append('uniform vec4 g_LSpot_Exponent[%d];\n' % S)
    if T:
        o.append('uniform vec4 g_LTube_Color[%d];\n' % T)
        o.append('uniform vec4 g_LTube_OriginA[%d];\n' % T)
        o.append('uniform vec4 g_LTube_OriginB[%d];\n' % T)
    if D:
        o.append('uniform vec4 g_LDirectional_Color[%d];\n' % D)
        o.append('uniform vec4 g_LDirectional_Direction[%d];\n' % D)
    F = SC + 3 * DS + SS + SSC            # 0x140169a1e
    if F:
        o.append('uniform mat4 g_LFeature_ShadowProjection[%d];\n' % F)
        o.append('uniform vec4 g_LFeature_ShadowProjectionTransform[%d];\n' % F)
    if PS:
        o.append('uniform vec4 g_LFeature_ShadowPointProjection[%d];\n' % PS)
        o.append('uniform vec4 g_LFeature_ShadowPointProjectionTransform[%d];\n' % PS)
    o.append('vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)\n{\n\tvec3 light = CAST3(0.0);\n')
    I = lambda n: '\tconst uint i = %du;\n' % n
    CPBR = '\tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, '
    TAIL = ', specularTint, ambient, roughness, metallic, %s);\n'
    # --- points: first PS carry shadows (0x140169bd0), rest plain (0x140169d50)
    for i in range(P):
        o.append('{\n' + I(i))
        o.append('\tvec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;\n')
        if i < PS:
            o.append('\tvec4 projectedCoords = CalculateProjectedCoordsPoint(worldPos, g_LPoint_Origin[i].xyz, g_LFeature_ShadowPointProjection[i], g_LFeature_ShadowPointProjectionTransform[i]);\n')
            o.append('\tfloat shadowFactor = PerformPointShadowMapping(projectedCoords);\n')
            o.append(CPBR + 'g_LPoint_Color[i].rgb, g_LPoint_Color[i].w, g_LPoint_Origin[i].w' + TAIL % 'shadowFactor')
        else:
            o.append(CPBR + 'g_LPoint_Color[i].rgb, g_LPoint_Color[i].w, g_LPoint_Origin[i].w' + TAIL % '1.0')
        o.append('}\n')
    # --- spots: [SSC][SC][SS][plain]; i indexes both g_LSpot_* and g_LFeature_ShadowProjection*
    i = 0
    for _ in range(SSC):   # 0x140169e90
        o.append('{\n' + I(i) + '\tvec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n'
                 '\tvec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i]);\n'
                 '\tfloat shadowFactor = PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[i]);\n'
                 '\tvec3 colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb;\n'
                 + CPBR + 'g_LSpot_Color[i].rgb * colorCookie, g_LSpot_Color[i].w, g_LSpot_Exponent[i].x' + TAIL % 'shadowFactor' + '}\n'); i += 1
    for _ in range(SC):    # 0x14016a010
        o.append('{\n' + I(i) + '\tvec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n'
                 '\tvec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i]);\n'
                 '\tvec3 colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb;\n'
                 + CPBR + 'g_LSpot_Color[i].rgb * colorCookie, g_LSpot_Color[i].w, g_LSpot_Exponent[i].x' + TAIL % '1.0' + '}\n'); i += 1
    for _ in range(SS):    # 0x14016a170
        o.append('{\n' + I(i) + '\tvec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n'
                 '\tfloat spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz);\n'
                 '\tspotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie);\n'
                 '\tvec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i]);\n'
                 '\tfloat shadowFactor = PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[i]);\n'
                 + CPBR + 'g_LSpot_Color[i].rgb * spotCookie, g_LSpot_Color[i].w, g_LSpot_Exponent[i].x' + TAIL % 'shadowFactor' + '}\n'); i += 1
    featBase = i          # r13 at 0x14016a2e7
    while i < S:           # 0x14016a300
        o.append('{\n' + I(i) + '\tvec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n'
                 '\tfloat spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz);\n'
                 '\tspotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie);\n'
                 + CPBR + 'g_LSpot_Color[i].rgb * spotCookie, g_LSpot_Color[i].w, g_LSpot_Exponent[i].x' + TAIL % '1.0' + '}\n'); i += 1
    # --- tubes (never shadowed)
    for i in range(T):
        o.append('{\n' + I(i) + '\tvec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[i].xyz, g_LTube_OriginB[i].xyz);\n'
                 + CPBR + 'g_LTube_Color[i].rgb, g_LTube_Color[i].w, g_LTube_OriginA[i].w' + TAIL % '1.0' + '}\n')
    # --- directionals: first DS with 3 cascades. NOTE binary quirk: p-base advances by 1 per light
    p = featBase
    for i in range(D):
        o.append('{\n' + I(i))
        if i < DS:
            o.append('\tconst uint p1 = %du;\n\tconst uint p2 = %du;\n\tconst uint p3 = %du;\n' % (p, p + 1, p + 2))
            o.append('\tvec4 projectedCoords1 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p1]);\n'
                     '\tvec4 projectedCoords2 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p2]);\n'
                     '\tvec4 projectedCoords3 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p3]);\n'
                     '\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords2.xyz, projectedCoords1.w);\n'
                     '\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords3.xyz, projectedCoords2.w);\n'
                     '\tvec4 uvTransforms = mix(g_LFeature_ShadowProjectionTransform[p1], g_LFeature_ShadowProjectionTransform[p2], projectedCoords1.w);\n'
                     '\tuvTransforms = mix(uvTransforms, g_LFeature_ShadowProjectionTransform[p3], projectedCoords2.w);\n'
                     '\tfloat shadowFactor = max(projectedCoords3.w, PerformShadowMapping(projectedCoords1.xyz, uvTransforms));\n'
                     '\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, color, g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, metallic, shadowFactor);\n')
            p += 1   # binary: r13d = r13d+1 (0x14016a9b4 / 0x14016ae36), NOT +3
        else:
            o.append('\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, color, g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, metallic, 1.0);\n')
        o.append('}\n')
    o.append('\treturn light;\n}\n')
    return ''.join(o)



# The combos the fixture covers: every budget the library uses (as the engine turns them into
# combos, shadows on and off), and edge cases. Each is a LIGHTS_* combo set plus LIGHTING.
LIBRARY = {
    'no-lightconfig': {},
    'one-piece-girls': dict(LIGHTS_TUBE=4),
    'hinata': dict(LIGHTS_SPOT=1, LIGHTS_SPOT_COOKIE=1),
    'moon': dict(LIGHTS_POINT=3),
}
EDGES = {
    'one-of-each': dict(LIGHTS_POINT=1, LIGHTS_SPOT=1, LIGHTS_TUBE=1, LIGHTS_DIRECTIONAL=1),
    'all-fifteen': dict(LIGHTS_POINT=15, LIGHTS_SPOT=15, LIGHTS_TUBE=15, LIGHTS_DIRECTIONAL=15),
    'all-subsets': dict(LIGHTS_POINT=4, LIGHTS_SPOT=12, LIGHTS_TUBE=4, LIGHTS_DIRECTIONAL=4,
                        LIGHTS_SPOT_SHADOW_COOKIE=3, LIGHTS_SPOT_SHADOW=3, LIGHTS_SPOT_COOKIE=3,
                        LIGHTS_DIRECTIONAL_SHADOW=3, LIGHTS_POINT_SHADOW=3),
    'script-default': dict(LIGHTS_POINT=2, LIGHTS_POINT_SHADOW=1, LIGHTS_SPOT=4, LIGHTS_SPOT_SHADOW_COOKIE=1,
                           LIGHTS_SPOT_COOKIE=1, LIGHTS_SPOT_SHADOW=1, LIGHTS_TUBE=1, LIGHTS_DIRECTIONAL=1,
                           LIGHTS_DIRECTIONAL_SHADOW=1),
    'cascade-quirk': dict(LIGHTS_SPOT=2, LIGHTS_SPOT_SHADOW=1, LIGHTS_DIRECTIONAL=3, LIGHTS_DIRECTIONAL_SHADOW=2),
    'point-shadows-only': dict(LIGHTS_POINT=2, LIGHTS_POINT_SHADOW=2),
    'subsets-past-base': dict(LIGHTS_SPOT=1, LIGHTS_SPOT_SHADOW_COOKIE=1, LIGHTS_SPOT_COOKIE=1, LIGHTS_SPOT_SHADOW=1),
    'subsets-without-base': dict(LIGHTS_SPOT_COOKIE=2, LIGHTS_DIRECTIONAL_SHADOW=1, LIGHTS_POINT_SHADOW=1),
    'directional-shadow-only': dict(LIGHTS_DIRECTIONAL=1, LIGHTS_DIRECTIONAL_SHADOW=1),
}


def fixture_cases():
    cases = []
    for group in (LIBRARY, EDGES):
        for name, lights in group.items():
            combos = dict(LIGHTING=1, **lights)
            cases.append(dict(name=name, combos=combos, source=expand(combos)))
    for count in (0, 1, 4, 15):
        for kind in ('POINT', 'SPOT', 'TUBE', 'DIRECTIONAL'):
            combos = {'LIGHTING': 1, 'LIGHTS_' + kind: count}
            cases.append(dict(name='%s-%d' % (kind.lower(), count), combos=combos, source=expand(combos)))
    off = dict(LIGHTING=0, LIGHTS_POINT=2, LIGHTS_TUBE=1)
    cases.append(dict(name='lighting-off', combos=off, source=expand(off)))
    absent = dict(LIGHTS_POINT=2)
    cases.append(dict(name='lighting-absent', combos=absent, source=expand(absent)))
    return cases


def main(argv):
    if argv[:1] == ['fixture']:
        out = argv[argv.index('--out') + 1] if '--out' in argv else os.path.join(
            os.path.dirname(os.path.abspath(__file__)), '..', 'Tests', 'Fixtures', 'LightingV1')
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, 'expansions.json'), 'w') as f:
            json.dump(fixture_cases(), f, indent=1, sort_keys=True)
            f.write('\n')
        return
    combos = {'LIGHTING': 1}
    for a in argv:
        k, v = a.split('=')
        combos[k] = int(v)
    sys.stdout.write(expand(combos))


if __name__ == '__main__':
    main(sys.argv[1:])
