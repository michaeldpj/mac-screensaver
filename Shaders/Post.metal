#include <metal_stdlib>
#include "ShaderTypes.h"
#include "ShaderCommon.h"
using namespace metal;

struct PostV { float4 pos [[position]]; float2 uv; };

vertex PostV postTri(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    PostV o;
    o.pos = float4(p[vid], 0, 1);
    o.uv = float2(p[vid].x * 0.5 + 0.5, 1.0 - (p[vid].y * 0.5 + 0.5));
    return o;
}

// value noise for grain
static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float a = vhash(i), b = vhash(i + float2(1, 0)), c = vhash(i + float2(0, 1)), d = vhash(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

struct GBufP {
    float4 color [[color(0)]];
    float4 coc   [[color(1)]];
};

// Hable filmic curve: gentle toe protects the deep blacks, shoulder rolls highlights off.
static inline float3 hable(float3 x) {
    const float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

// Shared by the effects and no-effects composites so disabling bloom/DoF changes only the
// effect accumulation, never the tonemap, color grade, black gating, or SDR clamp.
static inline float3 finalGrade(float3 c, float2 uv, constant AtmosphereParams& A) {
    if (A.filmicWhite > 0.0) {
        c = hable(c * A.exposure) / hable(float3(A.filmicWhite)).x;
    } else {
        c *= A.exposure;
    }

    float l = luma(c);
    c = mix(float3(l), c, A.saturation);
    c *= mix(A.shadowTint, A.highlightTint, smoothstep(0.0, 0.65, l));

    float2 q = uv - 0.5;
    float vig = 1.0 - A.vignette * dot(q, q) * 1.8;
    c *= mix(1.0, clamp(vig, 0.0, 1.0), smoothstep(0.0, 0.08, l));
    float g = (vnoise(uv * 1100.0 + A.time * 1.3) - 0.5) * A.grain * 0.6;
    float3 outc = max(c + g * smoothstep(0.0, 0.08, l), 0.0);
    if (A.maxOutput > 0.0) outc = min(outc, float3(A.maxOutput));
    return outc;
}

// Graded backdrop: vertical gradient + warm radial glow. Linear HDR out. coc=0 (sharp).
fragment GBufP atmosphere(PostV in [[stage_in]], constant AtmosphereParams& A [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 grad = mix(A.skyBottom, A.skyTop, pow(1.0 - uv.y, 1.3));
    float2 d = (uv - A.glowCenter);
    d.x *= 1.4;  // wider glow
    float r = length(d) / A.glowRadius;
    float glow = exp(-r * r * 2.2);
    float3 col = grad + A.glowColor * glow;
    // grain gated by luminance: the void stays void
    float g = (vnoise(uv * 900.0 + A.time) - 0.5) * A.grain;
    col += g * smoothstep(0.0, 0.1, luma(col));
    GBufP o;
    o.color = float4(max(col, 0.0), 1.0);
    o.coc = float4(0, 0, 0, 1);
    return o;
}

// bright-pass for bloom (soft knee around 1.0)
fragment float4 brightPass(PostV in [[stage_in]], texture2d<float> src [[texture(0)]],
                           constant float& threshold [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = src.sample(s, in.uv).rgb;
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    float k = max(0.0, l - threshold);
    return float4(c * (k / max(l, 1e-4)), 1.0);
}

// separable gaussian (9-tap)
fragment float4 blur(PostV in [[stage_in]], texture2d<float> src [[texture(0)]],
                     constant float2& dir [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float w[5] = { 0.227027, 0.194594, 0.121622, 0.054054, 0.016216 };
    float2 texel = dir / float2(src.get_width(), src.get_height());
    float3 c = src.sample(s, in.uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        c += src.sample(s, in.uv + texel * float(i)).rgb * w[i];
        c += src.sample(s, in.uv - texel * float(i)).rgb * w[i];
    }
    return float4(c, 1.0);
}

// final composite: DOF (with chromatic aberration), multi-scale bloom, filmic tonemap,
// split-tone + saturation grade, luma-gated vignette and grain.
fragment float4 composite(PostV in [[stage_in]],
                          texture2d<float> scene [[texture(0)]],
                          texture2d<float> bloomH [[texture(1)]],
                          texture2d<float> sceneBlur [[texture(2)]],
                          texture2d<float> cocTex [[texture(3)]],
                          texture2d<float> bloomQ [[texture(4)]],
                          texture2d<float> bloomE [[texture(5)]],
                          constant AtmosphereParams& A [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // depth-of-field: blend sharp scene toward blurred by coverage-weighted CoC
    float4 cocS = cocTex.sample(s, in.uv);
    float coc = saturate((cocS.r / max(cocS.a, 1e-3)) * A.dofStrength);
    float3 sharp = scene.sample(s, in.uv).rgb;
    // chromatic micro-aberration on the blurred layer only: R/B sampled with a tiny opposed
    // radial offset that grows with CoC — sells "lens", invisible on sharp subjects
    float2 radial = (in.uv - 0.5);
    float2 caOff = radial * coc * A.caStrength / float2(scene.get_width(), scene.get_height());
    float3 soft;
    soft.r = sceneBlur.sample(s, in.uv + caOff).r;
    soft.g = sceneBlur.sample(s, in.uv).g;
    soft.b = sceneBlur.sample(s, in.uv - caOff).b;
    float3 c = mix(sharp, soft, coc);

    // multi-scale bloom: tight halation + medium glow + wide soft atmosphere
    float3 bl = bloomH.sample(s, in.uv).rgb * A.bloomMixHalf
              + bloomQ.sample(s, in.uv).rgb * A.bloomMixQuarter
              + bloomE.sample(s, in.uv).rgb * A.bloomMixEighth;
    c += bl * A.bloomIntensity;

    return float4(finalGrade(c, in.uv, A), 1.0);
}

// Ultra-Lite final composite: the effects graph is disabled, so sample only scene color while
// preserving the exact grading, tonemap, vignette, grain, and SDR clamp behavior above.
fragment float4 compositeNoEffects(PostV in [[stage_in]],
                                   texture2d<float> scene [[texture(0)]],
                                   constant AtmosphereParams& A [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(finalGrade(scene.sample(s, in.uv).rgb, in.uv, A), 1.0);
}

// Copies the graded frame to the drawable. Exists so the drawable's pixel format is free to
// differ from the internal rgba16Float chain (SDR bgra10_xr_srgb vs opt-in EDR rgba16Float).
fragment float4 present(PostV in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(src.sample(s, in.uv).rgb, 1.0);
}
