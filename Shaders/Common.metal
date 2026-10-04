#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

inline float hash(uint x) {
    x = (x ^ 61u) ^ (x >> 16u); x *= 9u; x = x ^ (x >> 4u);
    x *= 0x27d4eb2du; x = x ^ (x >> 15u);
    return float(x) / 4294967295.0;
}
inline float rnd(thread uint& s) { s = s * 1664525u + 1013904223u; return float(s >> 8) / 16777215.0; }
inline float rndRange(thread uint& s, float a, float b) { return a + rnd(s) * (b - a); }
