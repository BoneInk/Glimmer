#include <metal_stdlib>
using namespace metal;

// WE's playlist transitions (dx11playlisttransition.vert/.geom/.frag, dx11playlistgaussian.frag).
// WE compiles one shader per effect with the macro FADEEFFECT (0…26); the function constant of the
// same name does that here, so each pipeline keeps only its own branch. Every effect returns the
// outgoing wallpaper with premultiplied alpha, laid source-over onto the incoming one.
//
// Ported as WE writes it, with HLSL's semantics where Metal's differ: smoothstep with reversed or
// equal edges (`hlslSmoothstep`), lerp with weights outside 0…1 (`hlslLerp`), and `pow(x, 2.0)`,
// which fxc turns into `x * x` and so stays defined for negative x (`square`).

constant int FADEEFFECT [[function_constant(0)]];
constant bool usesCloudTextures = FADEEFFECT == 26;

// WE's cbuffer g_bufDynamic (`WallpaperTransitionRenderer.Uniforms`).
struct TransitionUniforms {
    float progress;
    float hash;
    float hash2;
    float random;
    float aspectRatio;
    float width;
    float height;
    float padding;
    float4x4 viewProjection;
    float4x4 viewProjectionInv;
};

struct TransitionVaryings {
    float4 position [[position]];
    float2 texCoord;
};

struct ShatterVaryings {
    float4 position [[position]];
    float2 texCoord;
    float2 texCoordBase;
    float3 worldPos;
    float3 worldNormal;
};

// `WallpaperTransitionFacets.Vertex`.
struct FacetVertex {
    packed_float3 position;
    packed_float2 texCoord;
    packed_float3 center;
    packed_float3 normal;
};

// g_Texture0SamplerState (clamped) and g_Texture0SamplerStateWrap.
constexpr sampler clampSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler wrapSampler(filter::linear, address::repeat);

// MARK: - HLSL semantics

// HLSL's smoothstep: saturate((x - e0) / (e1 - e0)) for any edges. Equal edges divide by zero,
// which DX saturates to 1 above the edge (+inf) and 0 at or below it (-inf, NaN).
static float hlslSmoothstep(float e0, float e1, float x) {
    const float d = e1 - e0;
    const float t = d != 0.0 ? saturate((x - e0) / d) : (x > e0 ? 1.0 : 0.0);
    return t * t * (3.0 - 2.0 * t);
}

static float3 hlslSmoothstep(float3 e0, float3 e1, float3 x) {
    return float3(hlslSmoothstep(e0.x, e1.x, x.x), hlslSmoothstep(e0.y, e1.y, x.y), hlslSmoothstep(e0.z, e1.z, x.z));
}

static float hlslLerp(float a, float b, float t) { return a + (b - a) * t; }
static float2 hlslLerp(float2 a, float2 b, float t) { return a + (b - a) * t; }
static float3 hlslLerp(float3 a, float3 b, float t) { return a + (b - a) * t; }

static float square(float x) { return x * x; }
static float2 square(float2 x) { return x * x; }
static float3 square(float3 x) { return x * x; }

// MARK: - WE's helpers

static float nrand(float2 uv) {
    // The hash relies on sin's precision at large arguments; fast-math sin would band it.
    return fract(precise::sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
}

static float2 rotateFloat2(float2 v, float r) {
    const float2 cs = float2(cos(r), sin(r));
    return float2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
}

// rotation3d's rows, as columns: `m * v` is HLSL's `mul(v, rotation3d(…))`.
static float3x3 rotation3d(float3 axis, float angle) {
    axis = normalize(axis);
    const float s = sin(angle);
    const float c = cos(angle);
    const float oc = 1.0 - c;
    return float3x3(
        float3(oc * axis.x * axis.x + c, oc * axis.x * axis.y - axis.z * s, oc * axis.z * axis.x + axis.y * s),
        float3(oc * axis.x * axis.y + axis.z * s, oc * axis.y * axis.y + c, oc * axis.y * axis.z - axis.x * s),
        float3(oc * axis.z * axis.x - axis.y * s, oc * axis.y * axis.z + axis.x * s, oc * axis.z * axis.z + c));
}

static float2 mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float3 permute(float3 x) { return mod289(((x * 34.0) + 10.0) * x); }
static float4 permute(float4 x) { return mod289(((x * 34.0) + 10.0) * x); }
static float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

static float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    const float2 x0 = v - i + dot(i, C.xx);
    const float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    const float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    const float3 x = 2.0 * fract(p * C.www) - 1.0;
    const float3 h = abs(x) - 0.5;
    const float3 ox = floor(x + 0.5);
    const float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 127.0 * dot(m, g);
}

static float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i = floor(v + dot(v, C.yyy));
    const float3 x0 = v - i + dot(i, C.xxx);
    const float3 g = step(x0.yzx, x0.xyz);
    const float3 l = 1.0 - g;
    const float3 i1 = min(g.xyz, l.zxy);
    const float3 i2 = max(g.xyz, l.zxy);
    const float3 x1 = x0 - i1 + C.xxx;
    const float3 x2 = x0 - i2 + C.yyy;
    const float3 x3 = x0 - D.yyy;
    i = mod289(i);
    const float4 p = permute(permute(permute(i.z + float4(0.0, i1.z, i2.z, 1.0))
        + i.y + float4(0.0, i1.y, i2.y, 1.0)) + i.x + float4(0.0, i1.x, i2.x, 1.0));
    const float n_ = 0.142857142857;
    const float3 ns = n_ * D.wyz - D.xzx;
    const float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    const float4 x_ = floor(j * ns.z);
    const float4 y_ = floor(j - 7.0 * x_);
    const float4 x = x_ * ns.x + ns.yyyy;
    const float4 y = y_ * ns.x + ns.yyyy;
    const float4 h = 1.0 - abs(x) - abs(y);
    const float4 b0 = float4(x.xy, y.xy);
    const float4 b1 = float4(x.zw, y.zw);
    const float4 s0 = floor(b0) * 2.0 + 1.0;
    const float4 s1 = floor(b1) * 2.0 + 1.0;
    const float4 sh = -step(h, float4(0.0));
    const float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    const float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    const float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x;
    p1 *= norm.y;
    p2 *= norm.z;
    p3 *= norm.w;
    float4 m = max(0.5 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 105.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

static float fbm(float2 st, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * snoise(st);
        st *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

static float nrandFloorAspect(float2 uv, float scale, constant TransitionUniforms &u) {
    const float2 aspectScale = scale * float2(u.aspectRatio, 1.0);
    return nrand(floor(fract(uv + u.hash) * aspectScale) / aspectScale);
}

static float3 sampleRGB(texture2d<float> t, float2 uv) { return t.sample(clampSampler, uv, level(0)).rgb; }

static float3 blur13(texture2d<float> t, float2 u, float2 d) {
    const float2 o1 = float2(1.4091998770852122) * d;
    const float2 o2 = float2(3.2979348079914822) * d;
    const float2 o3 = float2(5.2062900776825969) * d;
    return sampleRGB(t, u) * 0.1976406528809576
        + sampleRGB(t, u + o1) * 0.2959855056006557 + sampleRGB(t, u - o1) * 0.2959855056006557
        + sampleRGB(t, u + o2) * 0.0935333619980593 + sampleRGB(t, u - o2) * 0.0935333619980593
        + sampleRGB(t, u + o3) * 0.0116608059608062 + sampleRGB(t, u - o3) * 0.0116608059608062;
}

static float drawGradient(float2 uvs, float2 start, float2 end, thread float &distFromRay) {
    float2 dir = end - start;
    const float2 delta = uvs - start;
    const float len = length(dir);
    dir /= len;
    const float distAlongRay = dot(dir, delta) / len;
    distFromRay = abs(dot(float2(dir.y, -dir.x), delta));
    return distAlongRay;
}

// The common "covered until the threshold passes r" ramp of the simple wipes.
static float wipeAlpha(float progress, float r, float smooth) {
    return 1.0 - hlslSmoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - r));
}

// MARK: - Effects

static float4 burntPaper(texture2d<float> t0, float2 texCoord, float progress, constant TransitionUniforms &u) {
    const float2 noiseUV = texCoord * float2(u.aspectRatio, 1.0);
    float r = fbm(noiseUV + u.hash, 6);
    r = hlslSmoothstep(-0.8, 1.0, r);
    float rNoise = snoise(noiseUV * 55.333 * (0.5 + u.progress) + u.hash + u.progress * 50.0);
    rNoise = hlslSmoothstep(-1.5, 1.0, rNoise);

    const float smooth = 0.00001;
    const float smoothDistort = 0.666;
    const float smoothDistortColor = 0.05;
    const float smoothDistortBurn = 0.5;
    const float smoothShadow = 0.1;
    const float rp = hlslSmoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - r));
    const float rpOffset = hlslSmoothstep(0.0, smoothDistort * progress, progress * (1.0 + smoothDistort) - r);

    const float2 offset = float2(dfdx(r), dfdy(r)) * square(rpOffset) * -30.0;
    float4 color = t0.sample(clampSampler, texCoord + offset, level(0));

    color.a = 1.0 - rp;
    const float shadow = (1.0 - step(0.01, color.a))
        * hlslSmoothstep(smoothShadow * 2.0, smoothShadow, progress * (1.0 + smoothShadow) - r);
    const float colorOrangeAmt = hlslSmoothstep(0.0, smoothDistortColor * progress,
                                                progress * (1.0 + smoothDistortColor) - r) * step(shadow, 0.0);
    const float darkenSrc = hlslSmoothstep(smoothDistortBurn * (progress * 0.5), smoothDistortBurn * (progress * 0.8),
                                           progress * (1.0 + smoothDistortBurn) - r);

    color.rgb = hlslLerp(color.rgb, color.rgb * 0.1 * float3(0.4, 0.03, 0.01), darkenSrc);
    color.rgb = hlslLerp(color.rgb, float3(1.0, 0.333, 0.0) * rNoise * 1.5, colorOrangeAmt);
    color.a *= pow(1.0 - hlslSmoothstep(0.9, 1.0, progress), 0.5);

    color.rgb = hlslLerp(color.rgb, float3(0.0), step(0.001, shadow));
    color.a = max(color.a, square(shadow) * 0.5);

    const float smoothDistortGlow = 0.05;
    float glowAmt = hlslSmoothstep(0.0, smoothDistortGlow * progress, progress * (1.0 + smoothDistortGlow) - r)
        * hlslSmoothstep(smoothDistortGlow * progress, 0.0, progress * (1.0 - smoothDistortGlow) - r);
    glowAmt *= 1.0 - progress;
    glowAmt = max(0.0, glowAmt - colorOrangeAmt);
    glowAmt = square(glowAmt);
    color.a = max(glowAmt, color.a);
    color.rgb += 2.0 * glowAmt * float3(1.0, 0.333, 0.0);
    color.rgb *= color.a;
    return color;
}

// Zipper (10) and Door (11): the halves part sideways, with a shadow on the incoming picture.
static float4 parting(texture2d<float> t0, float2 texCoord, float amount) {
    const float delta = texCoord.x - 0.5;
    const float offset = step(delta, 0.0) * 2.0 - 1.0;
    const float smooth = 0.333;
    const float side = step(0.5, texCoord.x);
    float2 uvs = texCoord;
    uvs.x += offset * amount * (0.5 + smooth);

    float4 color = t0.sample(clampSampler, uvs, level(0));
    color.a = hlslLerp(step(uvs.x, 0.5), step(0.5, uvs.x), side);
    const float shadow = 1.0 - hlslLerp(hlslSmoothstep(0.5, 0.5 + smooth, uvs.x),
                                        hlslSmoothstep(0.5, 0.5 - smooth, uvs.x), side);
    color.rgb = hlslLerp(color.rgb, float3(0.0), step(shadow, 0.9999));
    color.a = max(color.a, shadow * 0.5);
    color.rgb *= color.a;
    return color;
}

static float4 paint(float4 color, float2 texCoord, float progress, constant TransitionUniforms &u) {
    const float2 noiseUV = texCoord * float2(u.aspectRatio, 1.0);
    const float h = (u.hash - 0.5) * 0.1;

    float rayDist0;
    float grad0 = drawGradient(texCoord, float2(-1.0, -0.2 + h), float2(1.0, 0.15 + h), rayDist0);
    grad0 *= step(rayDist0, 0.4);
    float rayDist1;
    float grad1 = drawGradient(texCoord, float2(1.5, 0.1 + h), float2(0.0, 0.53 + h), rayDist1);
    grad1 *= step(rayDist1, 0.4);
    float rayDist2;
    float grad2 = drawGradient(texCoord, float2(-0.5, 0.6 + h), float2(1.2, 0.8 + h), rayDist2);
    grad2 *= step(rayDist2, 0.4);

    grad0 = saturate(grad0);
    grad1 = saturate(grad1);
    grad2 = saturate(grad2);
    const float v0 = step(0.001, grad0 * 0.25);
    const float v1 = step(0.001, grad1 * 0.25);
    const float v2 = step(0.001, grad2 * 0.25);
    const float l0 = grad0 * 0.25;
    const float l1 = 0.333 + grad1 * 0.25;
    const float l2 = 0.666 + grad2 * 0.333;

    float r = fbm(noiseUV * 10.0 + u.hash, 8);
    r = hlslSmoothstep(-1.0, 1.0, r);
    float rs = fbm(noiseUV * 10.0 + u.hash, 3);
    rs = hlslSmoothstep(-1.0, 1.0, rs);
    progress += r * 0.02;

    const float mask0 = step(rayDist0, 0.4 - r * 0.1);
    const float mask1 = step(rayDist1, 0.4 - r * 0.1);
    const float mask2 = step(rayDist2, 0.4 - r * 0.1);
    const float shadowMask0 = max(0.0, hlslSmoothstep(0.03, 0.0, max(0.0, rayDist0 - (0.4 - rs * 0.1))) - mask0);
    const float shadowMask1 = max(0.0, hlslSmoothstep(0.03, 0.0, max(0.0, rayDist1 - (0.4 - rs * 0.1))) - mask1);
    const float shadowMask2 = max(0.0, hlslSmoothstep(0.03, 0.0, max(0.0, rayDist2 - (0.4 - rs * 0.1))) - mask2);

    const float f0 = v0 * step(l0, progress) * mask0;
    const float f0S = v0 * step(l0, progress) * shadowMask0;
    const float f1 = v1 * step(l1, progress) * mask1;
    const float f1S = v1 * step(l1, progress) * shadowMask1;
    const float f2 = v2 * step(l2, progress) * mask2;
    const float f2S = v2 * step(l2, progress) * shadowMask2;

    const float v = max(f0, max(f1, f2));
    float vS = max(f0S, max(f1S, f2S));
    vS = hlslLerp(vS, 0.0, f1);
    vS = hlslLerp(vS, 0.0, f2);

    color.rgb = hlslLerp(color.rgb, color.rgb * 0.333, vS);
    color.a = 1.0 - v;
    color.rgb *= color.a;
    return color;
}

static float4 blackHole(float4 color, texture2d<float> t0, float2 texCoord, float progress,
                        constant TransitionUniforms &u) {
    const float holeSize = hlslSmoothstep(0.0, 0.8, progress) * hlslSmoothstep(1.0, 0.8, progress);
    const float noiseAmt = 0.01 * hlslSmoothstep(0.95, 0.8, progress);
    const float2 noiseOffset = float2(snoise(float2(progress * 100.0)),
                                      u.aspectRatio * snoise(float2(progress * 100.0 + u.hash)));
    const float2 center = float2(0.5) + holeSize * noiseAmt * noiseOffset;
    float2 delta = texCoord - center;

    const float dist = length(delta * float2(u.aspectRatio, 1.0));
    const float holeAmt = hlslSmoothstep(holeSize * 0.05, holeSize * 0.04, dist);

    texCoord -= float2(0.5);
    const float smoothDistort = 1.0;
    const float distortAmt = square(hlslSmoothstep(0.0, smoothDistort, max(0.0, (progress * 0.97) * smoothDistort)));
    texCoord *= (1.0 + (1.0 / length(delta)) * distortAmt);

    float angle = progress * 4.0 * square(hlslSmoothstep(holeSize * 0.2, 0.0, dist));
    angle = hlslLerp(angle, -angle, step(0.5, u.hash));
    texCoord = rotateFloat2(texCoord, angle);

    texCoord += float2(0.5);
    color.r = t0.sample(clampSampler, texCoord, level(0)).r;
    color.g = t0.sample(clampSampler, texCoord - angle * 0.04, level(0)).g;
    color.b = t0.sample(clampSampler, texCoord + angle * 0.04, level(0)).b;

    const float2 shadowDelta = texCoord - float2(0.5);
    const float shadowAngle = atan2(shadowDelta.y, -shadowDelta.x);
    const float shadowAmt = abs(dot(float2(1.0, 0.0), shadowDelta)) * sin(shadowAngle * 6.0);
    color.rgb = hlslLerp(color.rgb, float3(0.0), square(shadowAmt) * distortAmt * 4.0);

    color.a = step(0.0, texCoord.x) * step(texCoord.x, 1.0) * step(0.0, texCoord.y) * step(texCoord.y, 1.0);
    delta = texCoord - center;
    color.a *= step(dot(delta, delta), 0.5);
    color.a *= step(progress, 0.9);
    color.rgb *= color.a;

    const float holeCornea = hlslSmoothstep(holeSize * 0.03, holeSize * 0.05, dist);
    const float3 colorOuter = color.rgb;
    color.rgb = hlslLerp(color.rgb, float3(0.0), holeAmt);
    color.rgb = hlslLerp(color.rgb, square(colorOuter), holeAmt * holeCornea);
    color.a = max(color.a, holeAmt);
    return color;
}

static float4 crt(texture2d<float> t0, float2 texCoord, float progress, constant TransitionUniforms &u) {
    float4 color;
    const float2 texCoordOrig = texCoord;
    texCoord -= float2(0.5);
    texCoord.y *= (1.0 + square(hlslSmoothstep(0.2, 0.6, progress)) * u.height * 0.5);
    texCoord.x *= (1.0 - square(hlslSmoothstep(0.05, 0.25, progress)) * 0.8);
    texCoord.x *= (1.0 + square(hlslSmoothstep(0.4, 0.8, progress)) * u.width * 0.25);
    texCoord += float2(0.5);

    float scroll = hlslSmoothstep(0.0, 0.1, progress) * hlslSmoothstep(0.2, 0.1, progress) * 0.2;
    scroll -= pow(hlslSmoothstep(0.1, 0.4, progress), 1.4) * 5.0;
    const float amtGlowWhite = hlslSmoothstep(0.1, 0.4, progress);
    const float fadeBlack = hlslSmoothstep(0.7, 0.81, progress);
    const float amtOutsideBounds = saturate(step(texCoord.y, 0.0) + step(1.0, texCoord.y)
        + step(texCoord.x, 0.0) + step(1.0, texCoord.x) + fadeBlack);

    const float2 texCoordPreScroll = texCoord;
    texCoord.y = fract(texCoord.y + scroll);
    const float chroma = square(hlslSmoothstep(0.07, 0.2, progress));
    const float chromaMax = 0.04;
    const float mip = hlslSmoothstep(0.1, 0.3, progress) * 4.0;
    color.rgb = float3(t0.sample(clampSampler, texCoord, level(mip)).r,
                       t0.sample(clampSampler, texCoord + float2(0.0, chromaMax * chroma), level(mip)).g,
                       t0.sample(clampSampler, texCoord + float2(0.0, -chromaMax * chroma), level(mip)).b);
    color.a = hlslSmoothstep(1.0, 0.7, progress);

    const float smoothFade = 15.0;
    float amtOutsideGlow = amtOutsideBounds * (hlslSmoothstep(smoothFade, 1.0, texCoordPreScroll.y)
        * hlslSmoothstep(-smoothFade, 0.0, texCoordPreScroll.y));
    amtOutsideGlow *= hlslSmoothstep(smoothFade, 1.0, texCoordPreScroll.x) * hlslSmoothstep(-smoothFade, 0.0, texCoordPreScroll.x);
    amtOutsideGlow = pow(amtOutsideGlow, 4.0);

    float3 outsideColor = float3(snoise(float3(texCoordOrig * float2(u.aspectRatio, 1.0) * 100.0, progress * 10.0)));
    outsideColor = hlslSmoothstep(float3(-1.0), float3(1.0), outsideColor) * hlslSmoothstep(0.5, 0.4, progress) * 0.1
        * hlslSmoothstep(0.5, 0.0, abs(texCoordOrig.y - 0.5));

    color.rgb = hlslLerp(color.rgb, float3(0.666), amtGlowWhite);
    color.rgb = hlslLerp(color.rgb, outsideColor, amtOutsideBounds);
    color.rgb = hlslLerp(color.rgb, float3(0.25, 0.27, 0.33), amtOutsideGlow * (1.0 - fadeBlack));
    color.rgb *= color.a;
    return color;
}

static float4 bullets(float4 color, texture2d<float> t0, float2 texCoord, float progress, constant TransitionUniforms &u) {
    const float2 center = float2(0.25 + 0.5 * u.hash, 0.25 + 0.5 * u.hash2);

    const float shakeTimer = hlslSmoothstep(0.05, 0.2, progress);
    float shakeTimerOct = hlslSmoothstep(0.05, 0.5, progress);
    const float motionTimer = hlslSmoothstep(0.4, 1.0, progress);
    const float impactTimer = hlslSmoothstep(0.0, 0.1, progress);
    const float blackBlendTimer = hlslSmoothstep(0.8, 0.7, progress);
    const float alphaTimer = hlslSmoothstep(1.0, 0.9, progress);
    const float shakeTranslationBlend = hlslSmoothstep(0.05, 0.1, progress) * hlslSmoothstep(0.4, 0.05, progress)
        + hlslSmoothstep(0.6, 0.8, progress) * hlslSmoothstep(0.9, 0.8, progress);
    shakeTimerOct = pow(shakeTimerOct, 0.2);

    float2 zoomDelta = texCoord - center;
    float2 zoomDeltaReference = zoomDelta;
    zoomDelta.x *= u.aspectRatio;
    zoomDelta = rotateFloat2(zoomDelta, shakeTimerOct * 0.4 * u.hash2 * hlslLerp(1.0, -1.0, step(0.5, u.hash))
                             + shakeTimer * (1.0 - shakeTimer) * 0.3 * sin(shakeTimer * 4.0));
    zoomDelta.x /= u.aspectRatio;

    const float2 shakeNoise = float2(snoise(float2(progress * 10.0, 0.0)), snoise(float2(progress * 10.0, 10.0)))
        * 0.02 * shakeTranslationBlend;
    zoomDelta *= 1.0 - motionTimer;
    zoomDelta *= 1.0 - shakeTimerOct * 0.05;
    zoomDelta += shakeNoise;
    zoomDeltaReference *= 1.0 - motionTimer;
    zoomDeltaReference *= 1.0 - shakeTimerOct * 0.05;
    zoomDeltaReference += shakeNoise;
    const float2 centerMotion = (center - float2(0.5)) * motionTimer * (1.0 - motionTimer);
    texCoord = center + zoomDelta + centerMotion;
    const float2 texCoordUnrotated = center + zoomDeltaReference + centerMotion;

    float2 texCoordSkewed = texCoord;
    texCoordSkewed = texCoordSkewed * (fbm(texCoord * float2(u.aspectRatio, 1.0) * 7.0 + u.hash, 4) * 0.02 + 1.0);

    float2 delta = texCoordSkewed - center;
    delta.x *= u.aspectRatio;
    float distance = length(delta);
    const float distanceOriginal = distance;
    distance = pow(distance, 0.3);
    float angle = atan2(delta.x, -delta.y) + u.hash * 99.0;
    const float y = distance * 10.0;

    angle = angle * 10.0;
    const float testOffset1 = snoise(float2(floor(angle), y * 0.4));
    const float testOffset2 = snoise(float2(floor(angle) + 1.0, y * 0.4));
    const float testOffset = hlslLerp(testOffset1, testOffset2, fract(angle));

    const float blend1 = snoise(float2(floor(angle), 0.0));
    const float blend2 = snoise(float2(floor(angle) + 1.0, 0.0));
    float blend = hlslLerp(blend1, blend2, fract(angle));
    blend = hlslSmoothstep(0.5, 0.2, blend);

    const float patternDistance = pow(max(0.0, distance - 0.25), 0.1) * 3.0;
    float test = sin(patternDistance * 40.0 + testOffset * distance * 2.0);
    const float origFlow = test;
    test = abs(test);
    test = pow(test, 8.0 + 10.0 * testOffset);
    test = hlslSmoothstep(0.0, 0.2 + 0.8 * testOffset, test);

    float baseOpacity = hlslSmoothstep(0.01, 0.017, distanceOriginal) * hlslSmoothstep(0.2, 0.01, distanceOriginal);
    baseOpacity = pow(baseOpacity, 4.0) * impactTimer;

    // Fade out, then in.
    blend *= hlslSmoothstep(0.6 * impactTimer, 0.3 * impactTimer, distance - saturate(1.0 - testOffset) * 0.2);
    blend *= hlslSmoothstep(0.25, 0.3, distance);

    baseOpacity *= 1.0 - snoise(texCoordSkewed * 10.0 + u.hash) * (1.0 - abs(origFlow * 2.0 - 1.0)) * 2.0;

    const float gradx = dfdx(test + testOffset);
    const float grady = dfdy(test + testOffset);

    float r = fbm(float2(angle * 0.3, y * 0.4), 3);
    r = hlslSmoothstep(-0.5, 0.5, r);

    const float blackCenter = hlslSmoothstep(0.017, 0.01, distanceOriginal) * impactTimer;
    color.a = alphaTimer * hlslLerp(1.0, blackBlendTimer, blackCenter);

    color.rgb = t0.sample(clampSampler, texCoord + float2(gradx, -grady) * blend, level(0)).rgb;
    color.rgb = hlslLerp(color.rgb, (0.7 + r) * float3(0.8, 0.85, 1.0),
                         square(test * blend * r) + baseOpacity - blend * (abs(gradx) - abs(grady)));
    color.rgb = hlslLerp(color.rgb, float3(0.0), blackCenter);

    float2 flareDelta = texCoordUnrotated - center;
    flareDelta.x *= u.aspectRatio;
    float flareTimerFade = hlslSmoothstep(0.0, 0.1, progress);
    flareDelta.x *= pow(flareTimerFade, 0.1);
    flareTimerFade = flareTimerFade * (1.0 - flareTimerFade);
    flareDelta.y /= pow(flareTimerFade, 0.5) + 0.00001;
    float flare = 1.0 - length(flareDelta);
    flare *= flareTimerFade;
    flare = saturate(flare);
    flare = square(flare * 4.0);
    color.rgb *= float3(1.0) + flare * float3(1.0, 0.7, 0.2);
    color.rgb *= color.a;
    return color;
}

static float4 ice(texture2d<float> t0, float2 texCoord, float progress, constant TransitionUniforms &u) {
    float4 color;
    const float freezeOutTimer = square(hlslSmoothstep(1.0, 0.5, progress));
    const float freezeTimer = (hlslSmoothstep(0.0, 0.2, progress) * 0.333 + hlslSmoothstep(0.25, 0.5, progress) * 0.667)
        * freezeOutTimer;
    const float fadeTimer = hlslSmoothstep(1.0, 0.95, progress);

    float2 delta = texCoord - float2(0.5);
    delta.x *= u.aspectRatio;
    const float distance = length(delta) / max(u.aspectRatio, 1.0);

    float noise = fbm(texCoord * float2(u.aspectRatio, 1.0) * 2.0 + u.hash, 8) * 0.5 + 0.5;
    float rift = fbm(texCoord * float2(u.aspectRatio, 1.0) * 3.0 + u.hash2, 8) * 0.5 + 0.5;
    rift = hlslSmoothstep(0.4, 0.5, rift) * hlslSmoothstep(0.55, 0.5, rift);

    const float blendTransition = 0.3;
    const float blendDistance = 0.9 - distance;
    noise *= blendTransition + progress * 0.2 + hlslSmoothstep(0.3, 0.4, progress) * 0.1
        + hlslSmoothstep(0.5, 0.6, progress) * 0.1;
    noise *= 1.0 + rift * (0.5 + 0.5 * progress) * 0.05;

    const float blendNoise = noise + rift * 0.1;
    const float blend = hlslSmoothstep(blendDistance - blendNoise * 0.51, blendDistance - blendNoise * 0.5,
                                       freezeTimer * (1.0 + blendTransition));

    const float mip = blend * 3.0 + blend * rift * 3.0;
    float2 texCoordOffset = float2(dfdx(noise), dfdy(noise)) * 100.0;
    texCoordOffset = square(abs(texCoordOffset)) * sign(texCoordOffset);
    texCoord += texCoordOffset * blend;
    color.rgb = t0.sample(clampSampler, texCoord, level(mip)).rgb;
    color.rgb *= 1.0 + length(texCoordOffset) * 3.0 * blend;
    color.rgb += float3(0.6, 0.65, 1.0) * blend * noise * 4.0 * square(distance + rift * 0.1);

    texCoord += texCoordOffset * blend * 2.0;
    float flashLine = hlslSmoothstep(progress - 0.4, progress - 0.27, texCoord.x * 0.1 + 0.2 - texCoord.y * 0.005);
    flashLine = flashLine * (1.0 - flashLine) * 2.0;
    const float flashVert = abs(texCoord.y * 2.0 - 1.0);
    flashLine *= flashVert;
    color.rgb += color.rgb * flashLine * blend;

    color.a = max(blend, step(0.99, freezeOutTimer)) * fadeTimer;
    color.rgb *= color.a;
    return color;
}

static float4 boilover(texture2d<float> t0, texture2d<float> noiseTexture, texture2d<float> clouds,
                       float2 texCoord, float progress, constant TransitionUniforms &u) {
    float4 color;
    color.a = 1.0;
    const float blendRipple = hlslSmoothstep(0.0, 0.1, progress);
    const float blendUpscale = square(hlslSmoothstep(0.8, 1.0, progress));
    float light = 1.0;

    for (int i = 0; i < 25; ++i) {
        const float3 sharedNoise = noiseTexture.sample(wrapSampler, float2(i / 25.0 + u.hash, i / 25.0 + u.hash2),
                                                       level(0)).rgb;
        const float2 centerOffset = sharedNoise.rg * 2.0 - 1.0;
        const float2 center = float2(0.5) + centerOffset * 0.55;

        const float maxDist = 0.1 + clouds.sample(wrapSampler, center * 99.0, level(0)).r * 0.33 * progress
            + 0.5 * blendUpscale;
        const float timerOffset = sharedNoise.b * 0.9;
        float animTimer = hlslSmoothstep(timerOffset, timerOffset + 0.0001 + 0.5 * hlslSmoothstep(1.0, 0.9, progress), progress);
        animTimer = square(animTimer);

        float2 delta = texCoord - center;
        const float2 deltaRef = delta;
        delta.x *= u.aspectRatio;
        const float distance = length(delta);

        const float rippleTimer = hlslSmoothstep(timerOffset - 0.5, timerOffset + 0.5, progress);
        float ripplePos = distance;
        ripplePos = hlslSmoothstep(ripplePos, ripplePos + 0.1, rippleTimer)
            * hlslSmoothstep(ripplePos + 0.2, ripplePos + 0.1, rippleTimer);
        const float2 rippleOffset = normalize(deltaRef) * -0.01 * ripplePos * blendRipple;

        const float test = hlslSmoothstep(maxDist, 0.0, distance);
        const float anim = test * animTimer * 20.0;

        const float angle = atan2(deltaRef.x, -deltaRef.y);
        const float mask = clouds.sample(wrapSampler, float2(angle * 0.25, (anim + progress) * 0.1), level(0)).r;
        color.a *= step(anim, mask * 2.0);

        delta *= saturate(1.0 - anim);
        delta.x /= u.aspectRatio;
        const float2 uvOffset = delta - deltaRef + rippleOffset;
        texCoord += uvOffset;

        light += dot(normalize(float3(uvOffset, 1.0)), float3(-0.707, 0.707, 0.0)) * 10.0;
    }

    color.a *= hlslSmoothstep(1.0, 0.9, progress);
    color.rgb = sampleRGB(t0, texCoord) * light;
    color.rgb *= color.a;
    return color;
}

// PerformEffect for every effect drawn on the full-screen quad (all but Glass shatter).
static float4 performEffect(texture2d<float> t0, texture2d<float> noiseTexture, texture2d<float> clouds,
                            float2 texCoord, float progress, constant TransitionUniforms &u) {
    float4 color = float4(sampleRGB(t0, texCoord), 1.0);
    switch (FADEEFFECT) {
    case 0: // Fade
        color.a = 1.0 - progress;
        break;
    case 1: // Mosaic
        color.a = wipeAlpha(progress, nrandFloorAspect(texCoord, 50.0, u), 0.5);
        break;
    case 2: // Diffuse
        color.a = wipeAlpha(progress, nrandFloorAspect(texCoord, 1000.0, u), 0.5);
        break;
    case 3: // Horizontal slide
        texCoord.x -= progress;
        color = t0.sample(clampSampler, texCoord, level(0));
        color.a = step(0.0, texCoord.x);
        break;
    case 4: // Vertical slide
        texCoord.y -= progress;
        color = t0.sample(clampSampler, texCoord, level(0));
        color.a = step(0.0, texCoord.y);
        break;
    case 5: // Horizontal fade
        color.a = wipeAlpha(progress, texCoord.x, 0.5);
        break;
    case 6: // Vertical fade
        color.a = wipeAlpha(progress, texCoord.y, 0.5);
        break;
    case 7: { // Cloud blend
        const float r = hlslSmoothstep(-0.5, 0.5, fbm(texCoord * float2(u.aspectRatio, 1.0) + u.hash, 6));
        color.a = wipeAlpha(progress, r, 0.333);
        break;
    }
    case 8:
        return burntPaper(t0, texCoord, progress, u);
    case 9: { // Circular blend
        float2 delta = texCoord - float2(0.5);
        delta.x *= u.aspectRatio;
        color.a = wipeAlpha(progress, length(delta), 0.1);
        break;
    }
    case 10: { // Zipper
        float progressZipper = max(0.0, progress * 1.5 - texCoord.y * 0.5);
        progressZipper = hlslSmoothstep(0.0, 1.0, square(progressZipper));
        return parting(t0, texCoord, progressZipper);
    }
    case 11: // Door
        return parting(t0, texCoord, progress);
    case 12: // Lines
        color.a = wipeAlpha(progress, nrandFloorAspect(float2(0.0, texCoord.y), 100.0, u), 0.2);
        break;
    case 13: { // Zoom
        float2 delta = texCoord - float2(0.5);
        delta.x *= u.aspectRatio;
        const float distortUVAmt = hlslSmoothstep(0.0, 1.0, max(0.0, progress * 2.0 - length(delta)));
        texCoord -= float2(0.5);
        texCoord *= 1.0 - progress * 0.5 * distortUVAmt * 2.0;
        texCoord += float2(0.5);
        color.rgb = (blur13(t0, texCoord, progress * 50.0 * delta / u.height)
                     + blur13(t0, texCoord, progress * 33.0 * delta / u.height)) * 0.5;
        color.a = 1.0 - progress;
        break;
    }
    case 14: { // Drip vertical
        const float r = hlslSmoothstep(-0.5, 0.5, fbm(float2(texCoord.x * 10.0 + u.hash, 0.0), 2));
        float2 uvs = texCoord;
        uvs.y -= max(0.0, progress * 1.2 - r * 0.2);
        uvs.y -= texCoord.y * progress;
        color = t0.sample(clampSampler, uvs, level(0));
        color.a = step(0.0, uvs.y);
        const float shadow = hlslSmoothstep(-0.1333, 0.0, uvs.y);
        color.rgb = hlslLerp(color.rgb, float3(0.0), step(uvs.y, 0.0));
        color.a = max(color.a, shadow * (1.0 - progress));
        break;
    }
    case 15: { // Pixelate
        const float2 scale = floor((10.0 + u.height * (1.0 - pow(abs(progress), 0.1))) * float2(u.aspectRatio, 1.0));
        color.a = 1.0 - hlslSmoothstep(0.7, 1.0, progress);
        texCoord = floor((texCoord - float2(0.5)) * scale) / scale + float2(0.5);
        color.rgb = sampleRGB(t0, texCoord);
        break;
    }
    case 16: // Bricks: the vertex function moves the pieces.
        return color;
    case 17:
        return paint(color, texCoord, progress, u);
    case 18: // Fade to black
        color.rgb *= hlslSmoothstep(0.5, 0.0, progress);
        color.a = hlslSmoothstep(1.0, 0.5, progress);
        return color;
    case 19: { // Twister
        float2 delta = texCoord - float2(0.5);
        delta.x *= u.aspectRatio;
        const float dist = length(delta);
        color.a = wipeAlpha(progress, dist, 0.1);
        delta.x /= u.aspectRatio;
        const float twistAmt = hlslSmoothstep(0.0, 0.5, max(0.0, progress * 1.5 - dist));
        delta /= 1.0 + twistAmt;
        texCoord = float2(0.5) + rotateFloat2(delta, progress * 20.0 * twistAmt);
        color.rgb = sampleRGB(t0, texCoord);
        break;
    }
    case 20:
        return blackHole(color, t0, texCoord, progress, u);
    case 21:
        return crt(t0, texCoord, progress, u);
    case 22: { // Radial wipe
        const float2 delta = texCoord - float2(0.5);
        const float angle = (atan2(-delta.x, delta.y) + 3.141) / 6.283;
        const float smooth = 0.02;
        progress *= 1.0 + smooth;
        color.a = hlslSmoothstep(progress - smooth, progress, angle);
        break;
    }
    case 24:
        return bullets(color, t0, texCoord, progress, u);
    case 25:
        return ice(t0, texCoord, progress, u);
    case 26:
        return boilover(t0, noiseTexture, clouds, texCoord, progress, u);
    default:
        break;
    }
    color.rgb *= color.a;
    return color;
}

// MARK: - Entry points

// The geometry shader's full-screen strip: (-1, -1) samples (0, 1), (1, 1) samples (1, 0).
vertex TransitionVaryings transitionQuadVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = { float2(-1, -1), float2(-1, 1), float2(1, -1), float2(1, 1) };
    constexpr float2 texCoords[] = { float2(0, 1), float2(0, 0), float2(1, 1), float2(1, 0) };
    TransitionVaryings out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Bricks (16): the geometry shader's 4 sets of 3 + 4 bricks, one instance each, as a 4-vertex strip.
vertex TransitionVaryings transitionBricksVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                                 constant TransitionUniforms &u [[buffer(0)]]) {
    const float setHeight = 2.0 / 4.0;
    const float brickHeight = setHeight * 0.5;
    const float brickWidth = 2.0 * 0.333334;
    const float2 size = float2(brickWidth, brickHeight);
    const uint set = instanceID / 7;
    const uint brick = instanceID % 7;
    // A set is a row of three bricks, then a row of four shifted by half a brick.
    const float2 pos = brick < 3
        ? float2(-1.0 + float(brick) * brickWidth, -1.0 + float(set) * setHeight)
        : float2(-1.0 - brickWidth * 0.5 + float(brick - 3) * brickWidth, -1.0 + float(set) * setHeight + brickHeight);
    const float2 origin = pos + size * 0.5;

    // makeBrick
    const float animPosY = origin.y * 0.5 + 0.5;
    const float animPosX = origin.x * 0.5 + 0.5;
    const float fallDuration = 0.3;
    float fallOffset = hlslSmoothstep(0.0, fallDuration, u.progress * (1.0 + fallDuration * 1.5) - animPosY - animPosX * 0.2);
    fallOffset = square(fallOffset);
    float2 animOrigin = origin;
    animOrigin.y -= fallOffset * (animPosY + 0.2) * 2.6;
    animOrigin.x += fallOffset * origin.x * 0.333;
    const float angle = fallOffset * 3.0 * -origin.x;

    // makeBrickGeom: corners 00, 01, 10, 11.
    const float2 corner = float2(vertexID >= 2 ? 1.0 : -1.0, (vertexID & 1) != 0 ? 1.0 : -1.0);
    const float2 halfSize = size * 0.5 * float2(u.aspectRatio, 1.0);
    const float2 halfSizeAnimX = rotateFloat2(float2(halfSize.x, 0.0), angle) / float2(u.aspectRatio, 1.0);
    const float2 halfSizeAnimY = rotateFloat2(float2(0.0, halfSize.y), angle) / float2(u.aspectRatio, 1.0);
    float2 uv = (origin + corner * size * 0.5) * 0.5 + float2(0.5);
    uv.y = 1.0 - uv.y;

    TransitionVaryings out;
    out.position = float4(animOrigin + corner.x * halfSizeAnimX + corner.y * halfSizeAnimY, 0.0, 1.0);
    out.texCoord = uv;
    return out;
}

// Glass shatter (23): the transition vertex shader on the Voronoi facet mesh.
vertex ShatterVaryings transitionShatterVertex(uint vertexID [[vertex_id]], constant TransitionUniforms &u [[buffer(0)]],
                                               const device FacetVertex *vertices [[buffer(1)]]) {
    const FacetVertex vertexIn = vertices[vertexID];
    const float3 aPosition = float3(vertexIn.position);
    const float2 aTexCoord = float2(vertexIn.texCoord);
    const float3 aCenter = float3(vertexIn.center);
    const float3 aNormal = float3(vertexIn.normal);
    const float progress = u.progress;

    float3 axis = float3(nrand(aCenter.xy * 247.0), nrand(aCenter.xy * 115.0), nrand(aCenter.xy * 531.0));
    axis -= float3(0.5);
    axis = normalize(axis);

    const float centerDistance = saturate(length(aCenter));
    float animProgress = centerDistance * 0.05;
    animProgress = pow(hlslSmoothstep(0.4, 0.8, progress - animProgress), 0.5);

    float3 center = aCenter;
    float3 position = aPosition - center;
    // Move the pieces out of the center, then up and down.
    center = center * (1.0 + saturate((progress - 0.4) * (1.0 / 0.6)) * 4.0);
    center.y += pow(saturate((progress - 0.4) * 2.5), 0.5) * 2.0 + saturate(progress - 0.4) * -5.0;

    // The creak: the front faces shrink a little before they break off.
    const float creakTimer = hlslSmoothstep(0.0, 0.06, progress) * 0.05 + hlslSmoothstep(0.1, 0.14, progress) * 0.08
        + hlslSmoothstep(0.3, 0.36, progress) * 0.15;
    float creakAmt = max(abs(aTexCoord.x - 0.5), abs(aTexCoord.y - 0.5)) * 0.5;
    creakAmt = hlslSmoothstep(creakAmt, creakAmt + 0.1, creakTimer);
    const float creakRand = nrand(position.xy * 100.0);
    const float2 creakOffset = float2(0.02 / u.aspectRatio, 0.02) * (0.5 + creakRand * 1.0);
    position.xy *= hlslLerp(float2(1.0), max(float2(step(aPosition.z, -0.0001)), 1.0 - creakOffset), creakAmt);

    const float3x3 anim = rotation3d(axis, animProgress * progress * 10.0);
    const float3x3 animLight = rotation3d(axis, animProgress * progress * 10.0 + creakAmt * 0.25);
    position = anim * position;
    position += center;

    const float3 worldSpaceNormal = animLight * aNormal;
    float4 screenSpaceNormal = u.viewProjection * float4(worldSpaceNormal, 0.0);
    screenSpaceNormal.xyz = normalize(screenSpaceNormal.xyz);

    ShatterVaryings out;
    out.texCoord = aTexCoord - screenSpaceNormal.xy * 0.1;
    out.texCoordBase = hlslLerp(out.texCoord, aTexCoord, 0.1);
    out.position = u.viewProjection * float4(position, 1.0);
    out.worldPos = position;
    out.worldNormal = worldSpaceNormal;
    return out;
}

fragment float4 transitionFragment(TransitionVaryings in [[stage_in]],
                                   constant TransitionUniforms &u [[buffer(0)]],
                                   texture2d<float> outgoing [[texture(0)]],
                                   texture2d<float> noiseTexture [[texture(1), function_constant(usesCloudTextures)]],
                                   texture2d<float> clouds [[texture(2), function_constant(usesCloudTextures)]]) {
    return performEffect(outgoing, noiseTexture, clouds, in.texCoord, u.progress, u);
}

fragment float4 transitionShatterFragment(ShatterVaryings in [[stage_in]],
                                          constant TransitionUniforms &u [[buffer(0)]],
                                          texture2d<float> outgoing [[texture(0)]]) {
    const float2 texCoord = in.texCoord;
    float4 color;
    color.r = outgoing.sample(clampSampler, fract(texCoord), level(0)).r;
    color.g = outgoing.sample(clampSampler, fract(in.texCoordBase), level(0)).g;
    color.b = outgoing.sample(clampSampler, fract(texCoord - (in.texCoordBase - texCoord)), level(0)).b;

    const float3 lightDir = float3(0.707, -0.707, 0.0);
    const float3 worldNormal = normalize(in.worldNormal);
    const float3 eyeVector = float3(0.0) - in.worldPos;
    float specular = max(0.0, dot(normalize(eyeVector + lightDir), worldNormal));
    specular = pow(specular, 4.0);
    const float light = dot(lightDir, worldNormal) + 1.0;
    color.rgb *= light;
    color.rgb += float3(specular) * 2.0;

    color.a = hlslSmoothstep(1.0, 0.9, u.progress);
    color.rgb *= color.a;
    return color;
}

// dx11playlistgaussian.frag: one level of the blurred mip chain CRT and Ice sample, drawn at half
// the size of `source`, the level above.
fragment float4 transitionGaussianFragment(TransitionVaryings in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr float weight[3][3] = { { 21.0 / 256.0, 31.0 / 256.0, 21.0 / 256.0 },
                                     { 31.0 / 256.0, 48.0 / 256.0, 31.0 / 256.0 },
                                     { 21.0 / 256.0, 31.0 / 256.0, 21.0 / 256.0 } };
    const float2 uvd = 3.333 / float2(source.get_width(), source.get_height());
    float3 color = float3(0.0);
    for (int x = 0; x < 3; ++x) {
        for (int y = 0; y < 3; ++y) {
            color += sampleRGB(source, in.texCoord + float2(x - 1, y - 1) * uvd) * weight[x][y];
        }
    }
    return float4(color, 1.0);
}
