#include <metal_stdlib>
using namespace metal;

// A rect of a block-compressed texture decoded into a texture of the rect's size, texel for texel
// (`SceneSpriteFrameInputs`): a blit copies only whole blocks, and an image inside a padded DXT
// texture rarely ends on one.

struct SpriteFrameCutOut {
    float4 position [[position]];
};

// A triangle covering the target.
vertex SpriteFrameCutOut spriteFrameCutVertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);
    SpriteFrameCutOut out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// The target texel's centre, moved by the rect's origin, is the source texel's centre: the nearest
// sample is that texel exactly.
fragment float4 spriteFrameCutFragment(SpriteFrameCutOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                       constant uint2 &origin [[buffer(0)]]) {
    constexpr sampler texel(coord::pixel, filter::nearest, address::clamp_to_edge);
    return source.sample(texel, in.position.xy + float2(origin), level(0));
}
