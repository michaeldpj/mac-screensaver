// Bakes surface maps from sprite albedo at load time — no asset pipeline, no repo bloat.
// Output (rgba8Unorm): RG = tangent-space normal.xy (0.5 biased), B = thinness (edges
// transmit backlight), A = ambient occlusion (depth in the curl/vein structure).
#include <metal_stdlib>
#include "ShaderCommon.h"
using namespace metal;

struct SpriteMipV {
    float4 position [[position]];
    uint layer [[render_target_array_index]];
};

// One fullscreen triangle per array slice. SpriteLoader renders each destination mip in one
// layered pass, so sRGB render-target writes encode the linear-light result correctly.
vertex SpriteMipV spriteMipVS(uint vertexID [[vertex_id]], uint instanceID [[instance_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SpriteMipV out;
    out.position = float4(positions[vertexID], 0, 1);
    out.layer = instanceID;
    return out;
}

// Straight-alpha downsample in linear light. RGB is coverage-weighted to prevent transparent
// border colors from bleeding into silhouettes; RMS alpha is deliberately more conservative than
// an arithmetic mean so fine petal edges and snow-crystal arms survive minification.
fragment float4 spriteMipFS(SpriteMipV in [[stage_in]],
                            texture2d_array<float> source [[texture(0)]],
                            constant uint& sourceLevel [[buffer(0)]]) {
    uint2 sourceSize(source.get_width(sourceLevel), source.get_height(sourceLevel));
    uint2 maxCoord = max(sourceSize, uint2(1)) - 1;
    uint2 origin = uint2(in.position.xy) * 2;
    float4 samples[4] = {
        source.read(min(origin, maxCoord), in.layer, sourceLevel),
        source.read(min(origin + uint2(1, 0), maxCoord), in.layer, sourceLevel),
        source.read(min(origin + uint2(0, 1), maxCoord), in.layer, sourceLevel),
        source.read(min(origin + uint2(1, 1), maxCoord), in.layer, sourceLevel),
    };

    float alphaSum = 0.0;
    float alphaSquares = 0.0;
    float3 weightedRGB = 0.0;
    for (uint i = 0; i < 4; ++i) {
        float alpha = saturate(samples[i].a);
        alphaSum += alpha;
        alphaSquares += alpha * alpha;
        weightedRGB += samples[i].rgb * alpha;
    }
    float3 rgb = alphaSum > 1e-6 ? weightedRGB / alphaSum : float3(0.0);
    float alpha = sqrt(alphaSquares * 0.25);
    return float4(max(rgb, 0.0), alpha);
}

static inline float bakeHeight(texture2d<float, access::read> albedo, int2 p, int2 dim) {
    p = clamp(p, int2(0), dim - 1);
    float4 t = albedo.read(uint2(p));
    return luma(t.rgb) * smoothstep(0.0, 0.4, t.a);   // alpha-eroded so the rim slopes down
}

kernel void bakeSurfaceMaps(texture2d<float, access::read> albedo [[texture(0)]],
                            texture2d<float, access::write> maps [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 dim = int2(albedo.get_width(), albedo.get_height());
    if (int(gid.x) >= dim.x || int(gid.y) >= dim.y) return;
    int2 p = int2(gid);

    // Sobel of the height field → tangent-space normal
    float hl = bakeHeight(albedo, p + int2(-2, 0), dim), hr = bakeHeight(albedo, p + int2(2, 0), dim);
    float hu = bakeHeight(albedo, p + int2(0, -2), dim), hd = bakeHeight(albedo, p + int2(0, 2), dim);
    float2 grad = float2(hr - hl, hd - hu);
    float3 normal = normalize(float3(grad * -2.2, 1.0));
    float2 n = normal.xy;

    // Thinness: blurred alpha says how deep inside the silhouette we are; edges are thin
    // and transmit backlight (petal rims, leaf margins, crystal arms).
    float acc = 0.0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            int2 q = clamp(p + int2(dx, dy) * 9, int2(0), dim - 1);
            acc += albedo.read(uint2(q)).a;
        }
    float thin = 1.0 - saturate(acc / 9.0) * 0.8;

    // AO: valleys (height below the local average) get occluded
    float h = bakeHeight(albedo, p, dim);
    float hAvg = 0.25 * (bakeHeight(albedo, p + int2(-5, 0), dim) + bakeHeight(albedo, p + int2(5, 0), dim)
                       + bakeHeight(albedo, p + int2(0, -5), dim) + bakeHeight(albedo, p + int2(0, 5), dim));
    float ao = 1.0 - saturate((hAvg - h) * 2.4);

    maps.write(float4(n * 0.5 + 0.5, thin, ao), gid);
}
