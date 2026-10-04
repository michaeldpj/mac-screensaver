// Wind field: curl-noise turbulence plus traveling gust fronts, evaluated in world
// (multi-display desktop) coordinates. A pure function of (worldPos, time), so independent
// renderers on different displays agree on one continuous field with no communication.
// Header-only (static inline) so any kernel translation unit can sample the field.
#ifndef Wind_h
#define Wind_h
#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

static inline float whash(float3 p) {
    p = fract(p * 0.3183099 + float3(0.1, 0.17, 0.13));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static inline float vnoise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = mix(whash(i + float3(0,0,0)), whash(i + float3(1,0,0)), u.x);
    float b = mix(whash(i + float3(0,1,0)), whash(i + float3(1,1,0)), u.x);
    float c = mix(whash(i + float3(0,0,1)), whash(i + float3(1,0,1)), u.x);
    float d = mix(whash(i + float3(0,1,1)), whash(i + float3(1,1,1)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

// Two-octave noise potential, one channel at a time (the xy curl only needs two of three).
static inline float potX(float3 p) { return vnoise3(p) + 0.5 * vnoise3(p * 2.03 + 19.1); }
static inline float potY(float3 p) {
    return vnoise3(p + float3(31.7, 7.3, 11.9)) + 0.5 * vnoise3(p * 2.03 + float3(5.2, 47.0, 23.7));
}
static inline float potZ(float3 p) {
    return vnoise3(p + float3(8.4, 23.1, 41.3)) + 0.5 * vnoise3(p * 2.03 + float3(61.0, 13.8, 3.4));
}

// Finite-difference xy-curl of the noise potential — divergence-free by construction, so the
// flow swirls and meanders like air instead of sourcing/sinking like static noise. Only the
// screen-plane components are computed (every caller drops z): 16 noise evals, not 36.
static inline float2 curlNoiseXY(float3 p) {
    const float e = 0.12;
    float dPz_dy = potZ(p + float3(0, e, 0)) - potZ(p - float3(0, e, 0));
    float dPy_dz = potY(p + float3(0, 0, e)) - potY(p - float3(0, 0, e));
    float dPx_dz = potX(p + float3(0, 0, e)) - potX(p - float3(0, 0, e));
    float dPz_dx = potZ(p + float3(e, 0, 0)) - potZ(p - float3(e, 0, 0));
    return float2(dPz_dy - dPy_dz, dPx_dz - dPz_dx) / (2.0 * e);
}

/// Gust-front contribution only (base drift + traveling fronts) — a few flops, no noise.
/// Used where the bounded curl wobble cannot change the outcome (parked-release checks,
/// firefly drift) so the full field cost is reserved for particles that show it.
static inline float2 sampleGustWind(float2 worldPos, constant SimParams& P) {
    float2 w = float2(P.windBase, 0.0);
    for (int i = 0; i < 4; i++) {
        GustFront g = P.gusts[i];
        if (g.strength == 0.0) continue;
        float d = dot(worldPos, g.dir) - g.head;
        w += g.dir * (g.strength * exp(-(d * d) / max(g.width * g.width, 1.0)));
    }
    return w;
}

/// Wind velocity (points/sec) at a world position. `depth` decorrelates parallax layers so
/// near and far particles do not move in lockstep.
static inline float2 sampleWind(float2 worldPos, float depth, float time, constant SimParams& P) {
    float2 w = float2(P.windBase, 0.0);
    float3 q = float3(worldPos * P.windFieldScale, time * P.windEvolve + depth * 1.7);
    w += P.turbulence * curlNoiseXY(q);
    // The in-gust turbulence boost is loop-invariant: accumulate the envelope-weighted boost
    // across lanes, then pay for the second curl at most once — and not at all in calm air.
    float boost = 0.0;
    for (int i = 0; i < 4; i++) {
        GustFront g = P.gusts[i];
        if (g.strength == 0.0) continue;
        float d = dot(worldPos, g.dir) - g.head;
        float env = exp(-(d * d) / max(g.width * g.width, 1.0));
        w += g.dir * (g.strength * env);
        boost += g.turbBoost * env;
    }
    if (boost > 1e-3) w += (P.turbulence * boost) * curlNoiseXY(q * 2.3 + 7.1);
    return w;
}
#endif /* Wind_h */
