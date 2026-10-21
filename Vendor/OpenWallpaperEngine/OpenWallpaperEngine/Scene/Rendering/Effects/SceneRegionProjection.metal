#include <metal_stdlib>
using namespace metal;

// The scene under a scene-input layer drawn through a 3D camera, as WE's `composelayer` shader
// makes it: the layer's buffer covers the whole target, and each texel reads the frame buffer at
// the projected position of the quad point with the same texture coordinate. The projected
// (x, y, w) is interpolated across the target and divided per fragment, so the region follows
// the quad's perspective exactly (a homography), not an affine approximation.

// `LayerPlacement3D` (SceneLayerPlacement.swift).
struct RegionPlacement {
    float4x4 modelViewProjection;
    float2 size;
    float2 offset;
};

struct RegionVertexOut {
    float4 position [[position]];
    // Clip x, y and w of the quad point this corner stands for (`v_ScreenCoord` in composelayer.vert).
    float3 screen;
};

vertex RegionVertexOut sceneRegionVertex3D(uint vertexID [[vertex_id]],
                                           constant RegionPlacement &placement [[buffer(1)]]) {
    constexpr float2 corners[] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    const float2 corner = corners[vertexID];
    // The texture coordinate's corner of the target (v runs down the image, as the layer is drawn).
    RegionVertexOut out;
    out.position = float4(corner.x * 2 - 1, 1 - corner.y * 2, 0, 1);
    const float2 local = float2((corner.x - 0.5) * placement.size.x, (0.5 - corner.y) * placement.size.y)
        + placement.offset;
    const float4 clip = placement.modelViewProjection * float4(local, 0, 1);
    out.screen = float3(clip.x, clip.y, clip.w);
    return out;
}

// composelayer.frag: texCoord = screen.xy / screen.z · ½ + ½, in the y-down scene target. A point
// at or behind the eye has no place on screen and reads nothing.
fragment float4 sceneRegionFragment3D(RegionVertexOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
    if (in.screen.z <= 1e-6) return float4(0);
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    const float2 ndc = in.screen.xy / in.screen.z;
    return scene.sample(linearSampler, float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5));
}
