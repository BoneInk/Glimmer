#include <metal_stdlib>
using namespace metal;

// The smaller copy of a layer's image that its effects run on when the scene's detail matches the
// display (`SceneEffectDetail`): each texel is the average of the source area it covers, so the
// copy is the image as it would look scaled down on screen, not a point sample of it.

struct EffectDetailVertexOut {
    float4 position [[position]];
    float2 uv;
};

// A triangle covering the target; uv (0, 0) is the first row, as the effect passes read it.
vertex EffectDetailVertexOut effectDetailVertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);
    EffectDetailVertexOut out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

struct EffectDetailDownsample {
    // The source texels one target texel covers, per axis (at least 1).
    float2 ratio;
    // Taps per axis: the ratio rounded up, at most 16.
    uint2 taps;
};

fragment float4 effectDetailDownsample(EffectDetailVertexOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       sampler linearClamp [[sampler(0)]],
                                       constant EffectDetailDownsample &params [[buffer(0)]]) {
    float2 sourceSize = float2(source.get_width(), source.get_height());
    // The target texel's footprint in source texels, sampled at the centres of an even grid over
    // it; each bilinear tap averages its 2 × 2 neighbourhood.
    float2 footprint = params.ratio / sourceSize;
    float2 origin = in.uv - footprint * 0.5;
    float4 sum = 0.0;
    for (uint y = 0; y < params.taps.y; y++) {
        for (uint x = 0; x < params.taps.x; x++) {
            float2 offset = (float2(x, y) + 0.5) / float2(params.taps);
            sum += source.sample(linearClamp, origin + offset * footprint, level(0));
        }
    }
    return sum / float(params.taps.x * params.taps.y);
}
