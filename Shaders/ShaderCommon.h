// Shared helpers for all shader translation units (header-only, like Wind.h).
#ifndef ShaderCommon_h
#define ShaderCommon_h
#include <metal_stdlib>
using namespace metal;

// Sin-fract hash, 2D domain. Known precision banding at large inputs — if that ever needs
// fixing, fix it here, not in a copy.
static inline float vhash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Rec.709 relative luminance.
static inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

#endif /* ShaderCommon_h */
