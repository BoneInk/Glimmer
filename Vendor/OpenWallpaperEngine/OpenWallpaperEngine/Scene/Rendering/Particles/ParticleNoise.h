#ifndef ParticleNoise_h
#define ParticleNoise_h

#include <metal_stdlib>
using namespace metal;

// WE's particle noise functions, on the GPU.

constant int kNoisePermutation[256] = {
        151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225,
        140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148,
        247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32,
        57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175,
        74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122,
        60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54,
        65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169,
        200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64,
        52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
        207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
        119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
        129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104,
        218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241,
        81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157,
        184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93,
        222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
};

static int noisePerm(int index) { return kNoisePermutation[index & 255]; }

/// Inputs are clamped to ±1e6, which keeps the integer lattice in range (and a non-finite input
/// at 0).
static float noiseBounded(float value) { return isfinite(value) ? clamp(value, -1e6f, 1e6f) : 0.0f; }

static int noiseFloor(float value) {
    const int truncated = int(value);
    return float(truncated) <= value ? truncated : truncated - 1;
}

// MARK: - Gustavson

static float noiseGradient1(int hash, float x) {
    const int h = hash & 15;
    const float g = 1 + float(h & 7);
    return (h & 8) != 0 ? -g * x : g * x;
}

static float simplex1(float x) {
    x = noiseBounded(x);
    const int i0 = noiseFloor(x);
    const float x0 = x - float(i0), x1 = x0 - 1;
    float t0 = 1 - x0 * x0;
    t0 *= t0;
    float t1 = 1 - x1 * x1;
    t1 *= t1;
    return 0.395f * (t0 * t0 * noiseGradient1(noisePerm(i0), x0) + t1 * t1 * noiseGradient1(noisePerm(i0 + 1), x1));
}

static float noiseGradient2(int hash, float x, float y) {
    const int h = hash & 7;
    const float u = h < 4 ? x : y, v = h < 4 ? y : x;
    return ((h & 1) != 0 ? -u : u) + ((h & 2) != 0 ? -2 * v : 2 * v);
}

static float noiseCorner2(float t, int hash, float x, float y) {
    if (!(t >= 0)) return 0;
    const float t2 = t * t;
    return t2 * t2 * noiseGradient2(hash, x, y);
}

static float simplex2(float x, float y) {
    x = noiseBounded(x);
    y = noiseBounded(y);
    const float f2 = 0.366025403f, g2 = 0.211324865f;
    const float s = (x + y) * f2;
    const int i = noiseFloor(x + s), j = noiseFloor(y + s);
    const float t = float(i + j) * g2;
    const float x0 = x - (float(i) - t), y0 = y - (float(j) - t);
    const int i1 = x0 > y0 ? 1 : 0, j1 = x0 > y0 ? 0 : 1;
    const float x1 = x0 - float(i1) + g2, y1 = y0 - float(j1) + g2;
    const float x2 = x0 - 1 + 2 * g2, y2 = y0 - 1 + 2 * g2;
    const float n0 = noiseCorner2(0.5f - x0 * x0 - y0 * y0, noisePerm(i + noisePerm(j)), x0, y0);
    const float n1 = noiseCorner2(0.5f - x1 * x1 - y1 * y1, noisePerm(i + i1 + noisePerm(j + j1)), x1, y1);
    const float n2 = noiseCorner2(0.5f - x2 * x2 - y2 * y2, noisePerm(i + 1 + noisePerm(j + 1)), x2, y2);
    return 45.2307f * (n0 + n1 + n2);
}

constant float3 kNoiseGradients3[12] = {
    float3(1, 1, 0), float3(-1, 1, 0), float3(1, -1, 0), float3(-1, -1, 0),
    float3(1, 0, 1), float3(-1, 0, 1), float3(1, 0, -1), float3(-1, 0, -1),
    float3(0, 1, 1), float3(0, -1, 1), float3(0, 1, -1), float3(0, -1, -1),
};

static float noiseCorner3(float3 p, int i, int j, int k, int3 offset) {
    const float t = 0.6f - dot(p, p);
    if (!(t >= 0)) return 0;
    const int index = noisePerm(i + offset.x + noisePerm(j + offset.y + noisePerm(k + offset.z))) % 12;
    const float t2 = t * t;
    return t2 * t2 * dot(kNoiseGradients3[index], p);
}

static float simplex3(float x, float y, float z) {
    x = noiseBounded(x);
    y = noiseBounded(y);
    z = noiseBounded(z);
    const float f3 = 1.0f / 3.0f, g3 = 1.0f / 6.0f;
    const float s = (x + y + z) * f3;
    const int i = noiseFloor(x + s), j = noiseFloor(y + s), k = noiseFloor(z + s);
    const float t = float(i + j + k) * g3;
    const float3 p0 = float3(x - (float(i) - t), y - (float(j) - t), z - (float(k) - t));
    int3 o1, o2;
    if (p0.x >= p0.y) {
        if (p0.y >= p0.z) { o1 = int3(1, 0, 0); o2 = int3(1, 1, 0); }
        else if (p0.x >= p0.z) { o1 = int3(1, 0, 0); o2 = int3(1, 0, 1); }
        else { o1 = int3(0, 0, 1); o2 = int3(1, 0, 1); }
    } else {
        if (p0.y < p0.z) { o1 = int3(0, 0, 1); o2 = int3(0, 1, 1); }
        else if (p0.x < p0.z) { o1 = int3(0, 1, 0); o2 = int3(0, 1, 1); }
        else { o1 = int3(0, 1, 0); o2 = int3(1, 1, 0); }
    }
    const float3 p1 = p0 - float3(o1) + g3;
    const float3 p2 = p0 - float3(o2) + 2 * g3;
    const float3 p3 = p0 - 1 + 3 * g3;
    return 32 * (noiseCorner3(p0, i, j, k, int3(0)) + noiseCorner3(p1, i, j, k, o1) + noiseCorner3(p2, i, j, k, o2)
                 + noiseCorner3(p3, i, j, k, int3(1)));
}

// MARK: - FastNoise2

constant int kPrimeX = 501125321, kPrimeY = 1136930381;

static int noiseHash(int seed, int x, int y) {
    const int h = int(uint(seed ^ x ^ y) * 0x27d4eb2du);
    return (h >> 15) ^ h;
}

static float noiseGradientDot(int hash, float x, float y) {
    const float fx = (hash & 1) != 0 ? -x : x;
    const float fy = (hash & 2) != 0 ? -y : y;
    const bool swapped = (hash & 4) != 0;
    const float a = swapped ? fy : fx, b = swapped ? fx : fy;
    return (1 + 1.41421356237309504880f) * a + b;
}

static float noiseFalloff(float x, float y) {
    const float t = max(0.5f - x * x - y * y, 0.0f);
    const float t2 = t * t;
    return t2 * t2;
}

static float seededSimplex2(int seed, float x, float y) {
    x = noiseBounded(x);
    y = noiseBounded(y);
    const float f2 = 0.366025403784438646763723170752936183f, g2 = 0.211324865405187117745425609748f;
    const float f = f2 * (x + y);
    const float fx0 = floor(x + f), fy0 = floor(y + f);
    const int i = int(uint(int(fx0)) * uint(kPrimeX)), j = int(uint(int(fy0)) * uint(kPrimeY));
    const float g = g2 * (fx0 + fy0);
    const float x0 = x - (fx0 - g), y0 = y - (fy0 - g);
    const bool firstX = x0 > y0;
    const float x1 = (firstX ? x0 - 1 : x0) + g2, y1 = (firstX ? y0 : y0 - 1) + g2;
    const float x2 = x0 + (2 * g2 - 1), y2 = y0 + (2 * g2 - 1);
    const int iX = int(uint(i) + uint(kPrimeX)), jY = int(uint(j) + uint(kPrimeY));
    const float n0 = noiseGradientDot(noiseHash(seed, i, j), x0, y0);
    const float n1 = noiseGradientDot(noiseHash(seed, firstX ? iX : i, firstX ? j : jY), x1, y1);
    const float n2 = noiseGradientDot(noiseHash(seed, iX, jY), x2, y2);
    return 38.283687591552734375f * (n0 * noiseFalloff(x0, y0) + n1 * noiseFalloff(x1, y1) + n2 * noiseFalloff(x2, y2));
}

static float fractalBounding(int octaves) {
    float total = 0, amplitude = 1;
    for (int octave = 0; octave < max(octaves, 1); ++octave) {
        total += amplitude;
        amplitude *= 0.5f;
    }
    return 1 / total;
}

static float seededFBm2(int seed, float x, float y, int octaves) {
    const int count = max(octaves, 1);
    float amplitude = fractalBounding(count);
    float sum = seededSimplex2(seed, x, y) * amplitude;
    float frequency = 1;
    int octaveSeed = seed;
    for (int octave = 1; octave < count; ++octave) {
        frequency *= 2;
        octaveSeed = int(uint(octaveSeed) + 1u);
        amplitude *= 0.5f;
        sum += seededSimplex2(octaveSeed, x * frequency, y * frequency) * amplitude;
    }
    return sum;
}

#endif
