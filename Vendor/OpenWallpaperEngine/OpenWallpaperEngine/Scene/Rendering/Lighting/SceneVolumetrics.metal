#include <metal_stdlib>
using namespace metal;

/// A depth target as WE's volumetric shaders read it (`SceneVolumetricsPipelines.encodeClipDepth`):
/// the clip depth itself, rows in D3D's order.
///
/// Translated vertex shaders keep WE's clip z (0 at the near plane, 1 at the far one) and the
/// translator maps it to Metal's depth as (z + w) / 2, so a depth texel d holds the clip depth
/// 2d − 1. `volumetricsfront` reads its targets at `ndc.xy · (0.5, −0.5) + 0.5`, D3D's screen UV,
/// while the translator flips clip y when it draws, so the row a fragment reads is the mirror of
/// the row it was drawn in: rows are swapped.
kernel void volumetricsClipDepth(depth2d<float, access::read> depth [[texture(0)]],
                                 texture2d<float, access::write> clip [[texture(1)]],
                                 uint2 position [[thread_position_in_grid]]) {
    uint width = clip.get_width(), height = clip.get_height();
    if (position.x >= width || position.y >= height) return;
    float value = depth.read(position);
    clip.write(float4(2.0 * value - 1.0), uint2(position.x, height - 1 - position.y));
}
