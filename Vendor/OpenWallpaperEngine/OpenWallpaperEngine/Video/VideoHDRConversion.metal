#include <metal_stdlib>
using namespace metal;

/// A HDR video frame from linear BT.2020 to linear BT.709 (extended: values may leave 0…1), the
/// primaries WE's scRGB frame and macOS's extended linear sRGB share (`VideoHDRConversion`).
kernel void videoHDRToLinear709(texture2d<half, access::read> source [[texture(0)]],
                                texture2d<half, access::write> destination [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    // ITU-R BT.2087 (BT.2020 → BT.709 RGB, both linear), by column.
    const float3x3 toBT709 = float3x3(float3(1.6605, -0.1246, -0.0182),
                                      float3(-0.5876, 1.1329, -0.1006),
                                      float3(-0.0728, -0.0083, 1.1187));
    const float4 colour = float4(source.read(gid));
    destination.write(half4(half3(toBT709 * colour.rgb), half(colour.a)), gid);
}
