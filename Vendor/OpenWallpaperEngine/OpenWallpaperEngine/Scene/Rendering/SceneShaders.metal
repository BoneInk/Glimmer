#include <metal_stdlib>
using namespace metal;

struct LayerUniform {
    float2 position;
    float2 size;
    float2 sceneSize;
    float opacity;
    float particleShape;
    float rotation;
    float4 color;
    float2 uvOrigin;
    float2 uvAxisX;
    float2 uvAxisY;
    float4 effects;
    float blur;
    float4 colorEffects;
    float4 transform;
    float transformScaleY;
    float4 bloomTint;
    float2 quadAxisX;
    float2 quadAxisY;
};

struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
    float2 sceneCoordinate;
    // Particles are drawn as one instanced call per system; the fragment stage indexes the same
    // uniform array, so the index must not be interpolated.
    uint instance [[flat]];
};

struct DXTDecodeUniform {
    uint width;
    uint height;
    uint blockColumns;
    uint format;
};

ushort3 color565(ushort value) {
    return ushort3((value >> 11) * 255 / 31, ((value >> 5) & 63) * 255 / 63, (value & 31) * 255 / 31);
}

kernel void decodeDXT(device const uchar *input [[buffer(0)]],
                      texture2d<float, access::write> output [[texture(0)]],
                      constant DXTDecodeUniform &info [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= info.width || gid.y >= info.height) return;
    const uint blockIndex = (gid.y / 4) * info.blockColumns + gid.x / 4;
    const uint pixelIndex = (gid.y % 4) * 4 + gid.x % 4;
    const uint offset = blockIndex * (info.format == 7 ? 8 : 16);
    uint alpha = 255;
    uint colorOffset = offset;

    if (info.format == 6) {
        alpha = ((input[offset + pixelIndex / 2] >> ((pixelIndex % 2) * 4)) & 15) * 17;
        colorOffset += 8;
    } else if (info.format == 4) {
        const uint alpha0 = input[offset];
        const uint alpha1 = input[offset + 1];
        ulong alphaBits = 0;
        for (uint index = 0; index < 6; ++index) alphaBits |= ulong(input[offset + 2 + index]) << (index * 8);
        const uint alphaIndex = (alphaBits >> (pixelIndex * 3)) & 7;
        if (alphaIndex == 0) alpha = alpha0;
        else if (alphaIndex == 1) alpha = alpha1;
        else if (alpha0 > alpha1) alpha = ((8 - alphaIndex) * alpha0 + (alphaIndex - 1) * alpha1) / 7;
        else if (alphaIndex < 6) alpha = ((6 - alphaIndex) * alpha0 + (alphaIndex - 1) * alpha1) / 5;
        else alpha = alphaIndex == 6 ? 0 : 255;
        colorOffset += 8;
    }

    const ushort color0 = ushort(input[colorOffset]) | (ushort(input[colorOffset + 1]) << 8);
    const ushort color1 = ushort(input[colorOffset + 2]) | (ushort(input[colorOffset + 3]) << 8);
    const ushort3 first = color565(color0);
    const ushort3 second = color565(color1);
    uint colorBits = uint(input[colorOffset + 4]) | (uint(input[colorOffset + 5]) << 8)
        | (uint(input[colorOffset + 6]) << 16) | (uint(input[colorOffset + 7]) << 24);
    const uint colorIndex = (colorBits >> (pixelIndex * 2)) & 3;
    ushort3 color;
    if (colorIndex == 0) color = first;
    else if (colorIndex == 1) color = second;
    else if (colorIndex == 2) color = (info.format == 7 && color0 <= color1) ? (first + second) / 2 : (2 * first + second) / 3;
    else if (info.format == 7 && color0 <= color1) { color = ushort3(0); alpha = 0; }
    else color = (first + 2 * second) / 3;
    output.write(float4(float(color.x) / 255.0, float(color.y) / 255.0,
                        float(color.z) / 255.0, float(alpha) / 255.0), gid);
}

float4 gaussianBlur5(texture2d<float> texture, sampler samplerState, float2 coordinate, float radius) {
    const float centerWeight = 0.064230;
    const float axisWeight = 0.089465;
    const float diagonalWeight = 0.124604;
    const float farAxisWeight = 0.019880;

    float4 result = texture.sample(samplerState, coordinate) * centerWeight;

    result += texture.sample(samplerState, coordinate + float2(radius, 0)) * axisWeight;
    result += texture.sample(samplerState, coordinate - float2(radius, 0)) * axisWeight;
    result += texture.sample(samplerState, coordinate + float2(0, radius)) * axisWeight;
    result += texture.sample(samplerState, coordinate - float2(0, radius)) * axisWeight;

    result += texture.sample(samplerState, coordinate + float2(radius, radius)) * diagonalWeight;
    result += texture.sample(samplerState, coordinate - float2(radius, radius)) * diagonalWeight;
    result += texture.sample(samplerState, coordinate + float2(radius, -radius)) * diagonalWeight;
    result += texture.sample(samplerState, coordinate + float2(-radius, radius)) * diagonalWeight;

    result += texture.sample(samplerState, coordinate + float2(radius * 2.0, 0)) * farAxisWeight;
    result += texture.sample(samplerState, coordinate - float2(radius * 2.0, 0)) * farAxisWeight;
    result += texture.sample(samplerState, coordinate + float2(0, radius * 2.0)) * farAxisWeight;
    result += texture.sample(samplerState, coordinate - float2(0, radius * 2.0)) * farAxisWeight;

    return result;
}

vertex VertexOut sceneVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                             constant LayerUniform *layers [[buffer(0)]]) {
    // `instance_id` already counts from the draw's base instance.
    const LayerUniform layer = layers[instanceID];
    constexpr float2 corners[] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    const float2 corner = corners[vertexID] - 0.5;
    float2 offset;
    if (any(layer.quadAxisX != 0.0) || any(layer.quadAxisY != 0.0)) {
        // Axes are y-up and the corner's y runs down the texture: flip both into this y-down space.
        const float2 up = corner.x * layer.quadAxisX - corner.y * layer.quadAxisY;
        offset = float2(up.x, -up.y);
    } else {
        const float2 local = corner * layer.size;
        offset = float2(local.x * cos(layer.rotation) - local.y * sin(layer.rotation),
                        local.x * sin(layer.rotation) + local.y * cos(layer.rotation));
    }
    const float2 point = float2(layer.position.x, layer.sceneSize.y - layer.position.y) + offset;
    VertexOut out;
    out.position = float4(point.x / layer.sceneSize.x * 2 - 1, 1 - point.y / layer.sceneSize.y * 2, 0, 1);
    out.textureCoordinate = layer.uvOrigin + corners[vertexID].x * layer.uvAxisX + corners[vertexID].y * layer.uvAxisY;
    out.sceneCoordinate = point / layer.sceneSize;
    out.instance = instanceID;
    return out;
}

/// A layer quad drawn through a 3D camera (`SceneLayerPlacement`, `LayerPlacement3D` in Swift).
struct LayerPlacement3D {
    float4x4 modelViewProjection;
    float2 size;
    float2 offset;
};

/// `sceneVertex` for a layer drawn through a 3D camera: the corner in object units (`size` about
/// `offset`, y up) through WE's `modelViewProjection`, whose clip space Metal shares; the depth is
/// stored as the translated shaders store theirs, (z + w) / 2 (`SceneDepthStates`).
vertex VertexOut sceneVertex3D(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                               constant LayerUniform *layers [[buffer(0)]],
                               constant LayerPlacement3D &placement [[buffer(1)]]) {
    const LayerUniform layer = layers[instanceID];
    constexpr float2 corners[] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    const float2 corner = corners[vertexID];
    const float2 local = float2((corner.x - 0.5) * placement.size.x, (0.5 - corner.y) * placement.size.y)
        + placement.offset;
    float4 clip = placement.modelViewProjection * float4(local, 0, 1);
    clip.z = (clip.z + clip.w) * 0.5;
    VertexOut out;
    out.position = clip;
    out.textureCoordinate = layer.uvOrigin + corner.x * layer.uvAxisX + corner.y * layer.uvAxisY;
    out.sceneCoordinate = float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    out.instance = instanceID;
    return out;
}

/// Plain resample through the vertex stage's UVs, for copying the scene under a layer's quad.
fragment float4 sceneCopyFragment(VertexOut input [[stage_in]], texture2d<float> texture [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    return texture.sample(linearSampler, input.textureCoordinate);
}

fragment float4 sceneFragment(VertexOut input [[stage_in]], texture2d<float> texture [[texture(0)]],
                              constant LayerUniform *layers [[buffer(0)]]) {
    const LayerUniform layer = layers[input.instance];
    constexpr sampler linearSampler(filter::linear);
    float2 coordinate = input.textureCoordinate;
    if (layer.particleShape > 0.5 && distance(coordinate, float2(0.5)) > 0.5) {
        discard_fragment();
    }
    coordinate = (coordinate - 0.5) / max(float2(layer.transform.w, layer.transformScaleY), 0.001) + 0.5;
    const float transformCos = cos(layer.transform.x);
    const float transformSin = sin(layer.transform.x);
    coordinate = float2(coordinate.x * transformCos - coordinate.y * transformSin,
                        coordinate.x * transformSin + coordinate.y * transformCos);
    coordinate += layer.transform.yz;
    // Authored effects already ran on the layer's image (WE shaders, EffectGraphRenderer);
    // what's left are the material's own adjustments.
    float4 color = texture.sample(linearSampler, coordinate);
    const float blur = max(layer.blur, 0.0) * 0.004;
    if (blur > 0.0) {
        color = gaussianBlur5(texture, linearSampler, coordinate, blur);
    }
    color.rgb *= exp2(layer.colorEffects.x);
    color.rgb = (color.rgb - 0.5) * max(layer.effects.y, 0.0) + 0.5;
    const float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, max(layer.effects.z, 0.0));
    const float angle = layer.colorEffects.z;
    if (abs(angle) > 0.0001) {
        const float y = dot(color.rgb, float3(0.299, 0.587, 0.114));
        const float i = dot(color.rgb, float3(0.596, -0.275, -0.321));
        const float q = dot(color.rgb, float3(0.212, -0.523, 0.311));
        const float rotatedI = i * cos(angle) - q * sin(angle);
        const float rotatedQ = i * sin(angle) + q * cos(angle);
        color.rgb = float3(y + 0.956 * rotatedI + 0.621 * rotatedQ,
                           y - 0.272 * rotatedI - 0.647 * rotatedQ,
                           y - 1.106 * rotatedI + 1.703 * rotatedQ);
    }
    color.rgb = pow(max(color.rgb, 0.0), float3(1.0 / max(layer.colorEffects.y, 0.001)));
    color.rgb *= max(layer.effects.x, 0.0);
    // Straight alpha, as WE's translucent and additive blends expect: opacity scales alpha only,
    // and the blend applies it to the colour once.
    return float4(color.rgb * layer.color.rgb, color.a * layer.opacity * layer.color.a);
}