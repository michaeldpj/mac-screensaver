#include <metal_stdlib>
#include "ShaderTypes.h"
#include "ShaderCommon.h"
#include "Wind.h"
using namespace metal;

// PCG-style output permutation: decorrelates streams seeded from linear particle indices
// (a plain LCG leaves nearby seeds correlated, which makes particles fall in visible ranks).
static inline float rnd(thread uint& s){
    s = s * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    w = (w >> 22u) ^ w;
    return float(w) * (1.0 / 4294967296.0);
}
static inline float rr(thread uint& s, float a, float b){ return a + rnd(s)*(b-a); }

// Would the air at a (hashed) top-edge spot shake a parked reserve loose? Gusts decide the
// release; the bounded curl wobble can't, so the cheap gust-only sample suffices.
static bool gustReleases(thread Particle& p, constant SimParams& P, thread float& px) {
    uint s = p.seed;
    px = rr(s, 0.0, P.worldViewport.x);
    p.seed = s;
    float2 w = sampleGustWind(float2(px, 40.0) + P.windOrigin, P);
    return length(w) > P.releaseWind;
}

static void respawn(thread Particle& p, constant SimParams& P, bool fromTop) {
    uint s = p.seed;
    // Risers (embers: vy strictly negative) enter from BELOW the viewport, not above.
    bool riser = P.vyMax <= 0.0 && P.vyMin < 0.0;
    p.pos.x = rr(s, 0, P.worldViewport.x);
    p.pos.y = !fromTop ? rr(s, 0, P.worldViewport.y)
            : riser    ? rr(s, P.worldViewport.y, P.worldViewport.y * 1.5)
                       : rr(s, -P.worldViewport.y*0.5, 0);
    // windward-edge bias: sustained side-wind feeds particles in from the upwind edge
    // instead of slowly emptying that side of the screen
    if (fabs(P.meanWindX) > 20.0 && rnd(s) < 0.35) {
        p.pos.x = P.meanWindX > 0.0 ? rr(s, -150.0, 0.0)
                                    : rr(s, P.worldViewport.x, P.worldViewport.x + 150.0);
        p.pos.y = rr(s, 0, P.worldViewport.y);
    }
    p.windVel = float2(0.0);
    p.size  = rr(s, P.sizeMin, P.sizeMax);
    p.vel.y = rr(s, P.vyMin, P.vyMax);
    p.vel.x = (P.flags & 8u) ? rr(s, P.vxMin, P.vxMax) : 0.0;
    p.phase = rr(s, 0, 6.2831853);
    p.rot   = (P.flags & 1u) ? rr(s, 0, 6.2831853) : 0.0;
    p.vrot  = (P.flags & 1u) ? rr(s, -P.rotateSpeed, P.rotateSpeed) : 0.0;
    p.tumble = (P.flags & 2u) ? rr(s, 0, 6.2831853) : 0.0;
    p.vtumble = (P.flags & 2u) ? rr(s, -P.tumbleSpeed, P.tumbleSpeed) : 0.0;
    p.pulsePhase = (P.flags & 4u) ? rr(s, 0, 6.2831853) : 0.0;
    p.pulseFreq  = (P.flags & 4u) ? 6.2831853 / rr(s, P.pulseFreqMin, P.pulseFreqMax) : 0.0;
    // Cinematic depth distribution: pow-bias pushes most particles far (small, soft) with a
    // few near-field subjects; size optionally couples to depth so near = large.
    float dN = pow(rnd(s), max(P.depthBias, 0.2));
    p.depth = mix(P.depthMin, P.depthMax, dN);
    p.size  = mix(p.size, mix(P.sizeMin, P.sizeMax, dN), P.sizeDepthCoupling);
    p.alphaJitter = rr(s, 0.7, 1.0);
    p.variant = uint(rnd(s) * float(max(P.spriteCount, 1u)));
    p.axis = normalize(float3(rr(s,-1,1), rr(s,-1,1), rr(s,-1,1)) + float3(1e-4, 0, 0));

    // Species seeding
    p.mode = 0u;
    p.modeTime = rr(s, 1.0, 3.0);
    p.flutterAmp = P.flutterAmp * rr(s, 0.7, 1.3);
    p.flutterRate = 6.2831853 * P.flutterFreq * rr(s, 0.7, 1.3);
    if (P.motionModel == MODEL_LEAF) {
        // flat objects flip about a near-in-plane axis — paper, never a coin on a string
        p.axis.z *= 0.25;
        p.axis = normalize(p.axis + float3(1e-4, 0, 0));
    } else if (P.motionModel == MODEL_SNOW) {
        // terminal velocity stratified by size: big flakes sail, small flakes drift
        float szN = saturate((p.size - P.sizeMin) / max(P.sizeMax - P.sizeMin, 1e-3));
        p.vel.y = mix(P.vyMin, P.vyMax, szN) * rr(s, 0.85, 1.15);
    } else if (P.motionModel == MODEL_FIREFLY) {
        p.vel = float2(rr(s, P.vxMin, P.vxMax), rr(s, P.vyMin, P.vyMax));
        // flash clock: random start inside a random-length cycle
        p.pulseFreq = rr(s, P.flashIntervalMin, P.flashIntervalMax);  // cycle length (s)
        p.pulsePhase = rr(s, 0.0, p.pulseFreq);                      // position in cycle (s)
    } else if (P.motionModel == MODEL_SAMARA) {
        // helicopters always autorotate: strong constant-sign spin
        p.vrot = (rnd(s) < 0.5 ? -1.0 : 1.0) * rr(s, 5.0, 9.0);
    }
    p.seed = s;
}

kernel void seedParticles(device Particle* ps [[buffer(0)]],
                          constant SimParams& P [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    // worldSeed folds the display origin in so multiple screens never render clone fields
    Particle p; p.seed = (i * 2654435761u + 1u) ^ P.worldSeed;
    respawn(p, P, false);
    // Hero slots stay scripted/parked; reserves above the calm baseline park until a gust.
    if (i < P.heroCount || (P.baselineCount > 0u && i >= P.baselineCount)) {
        p.mode = MODE_PARKED;
        p.pos.y = -P.worldViewport.y;   // well offscreen
    }
    ps[i] = p;
}

// ---- Species aerodynamics ----
// The invariant for every model: orientation derives from the SAME state that drives
// translation — a leaf slides sideways because it is rocking, not alongside it.

// Tachikawa-style falling card: FLUTTER (rocking seesaw) / TUMBLE (autorotation + Magnus
// glide, gust-triggered) / GLIDE (settle back out).
static void stepLeaf(thread Particle& p, constant SimParams& P, float windMag) {
    p.modeTime -= P.dt;
    uint s = p.seed;
    if (p.modeTime <= 0.0) {
        if (p.mode == MODE_FLUTTER) {
            float gustBoost = saturate(windMag / 220.0);          // strong air shakes leaves into autorotation
            if (rnd(s) < P.tumbleChance + gustBoost * 0.35) {
                p.mode = MODE_TUMBLE;
                p.modeTime = rr(s, 2.0, 4.0);
                p.vtumble = (rnd(s) < 0.5 ? -1.0 : 1.0) * rr(s, 0.9, 1.6) * max(P.tumbleSpeed, 0.3);
            } else {
                p.modeTime = rr(s, 1.5, 3.5);
                p.flutterAmp = P.flutterAmp * rr(s, 0.7, 1.3);    // each bout rocks a little differently
            }
        } else if (p.mode == MODE_TUMBLE) {
            p.mode = MODE_GLIDE;
            p.modeTime = rr(s, 0.6, 1.4);
        } else {
            p.mode = MODE_FLUTTER;
            p.modeTime = rr(s, 1.5, 3.5);
            p.phase = rr(s, 0.0, 6.2831853);
        }
    }
    p.seed = s;

    if (p.mode == MODE_FLUTTER) {
        p.phase += p.flutterRate * P.dt;
        float theta = p.flutterAmp * sin(p.phase);
        // sideslip toward the lowered edge, quarter-phase ahead of the rock
        float slip = p.flutterAmp * p.flutterRate * p.size * 0.45 * cos(p.phase);
        float c = cos(theta);
        p.pos.y += p.vel.y * mix(0.6, 1.0, 1.0 - c * c) * p.depth * P.dt;  // flat leaf stalls
        p.pos.x += slip * p.depth * P.dt;
        p.tumble = theta;                                          // the rock IS the orientation
        p.rot += p.vrot * 0.3 * P.dt;
    } else if (p.mode == MODE_TUMBLE) {
        p.tumble += p.vtumble * 2.2 * P.dt;                        // continuous autorotation
        float glide = sign(p.vtumble) * p.size * 1.1;              // Magnus-like swoop
        p.pos.x += glide * p.depth * P.dt;
        p.pos.y += p.vel.y * 0.8 * p.depth * P.dt;                 // autorotation lift slows the fall
        p.rot += p.vrot * P.dt;
    } else { // GLIDE: spin settles, slip decays
        p.tumble += p.vtumble * 2.2 * exp(-3.0 * (1.4 - p.modeTime)) * P.dt;
        p.pos.y += p.vel.y * 0.9 * p.depth * P.dt;
    }
}

// Helical gyration: petals corkscrew down, descent breathing at twice the gyre rate.
static void stepPetal(thread Particle& p, constant SimParams& P) {
    p.phase += p.flutterRate * 0.6 * P.dt;
    p.pos.x += P.gyroRadius * p.flutterRate * 0.6 * cos(p.phase) * p.depth * P.dt;
    p.pos.y += p.vel.y * (1.0 + 0.18 * sin(2.0 * p.phase)) * p.depth * P.dt;
    p.tumble = p.flutterAmp * 0.7 * sin(p.phase + 1.1);            // gentle cupped seesaw, in gyre phase
    p.rot += p.vrot * 0.5 * P.dt;
}

// Size-stratified drift: terminal velocity baked at spawn; small flakes dance in fine
// turbulence, big flakes sail; slow plane-wobble winks facets for the (Phase E) glints.
static void stepSnow(thread Particle& p, constant SimParams& P) {
    p.phase += p.flutterRate * 0.25 * P.dt;
    float szN = saturate((p.size - P.sizeMin) / max(P.sizeMax - P.sizeMin, 1e-3));
    float dance = P.microTurb * mix(1.4, 0.25, szN);
    // ±dance-points/sec cosmetic wiggle: divergence-freeness is invisible at this amplitude,
    // so two plain noise reads replace a full curl (4 evals vs 16)
    float3 jq = float3((p.pos + P.windOrigin) * 0.012, P.time * 0.7 + p.depth * 3.1);
    float2 j = float2(vnoise3(jq) - 0.5, vnoise3(jq + float3(17.3, 9.1, 4.7)) - 0.5) * 2.0;
    p.pos += j * dance * P.dt;
    p.pos.y += p.vel.y * p.depth * P.dt;
    p.tumble = 0.35 * sin(p.phase);                                // slow plane wobble
    p.rot += p.vrot * 0.4 * P.dt;
}

// Steering, not noise: Ornstein–Uhlenbeck velocity wander + weak pull toward roaming
// attractors; CRUISE / PERCH (hold + keep flashing) / DART states.
static void stepFirefly(thread Particle& p, constant SimParams& P) {
    p.modeTime -= P.dt;
    uint s = p.seed;
    if (p.modeTime <= 0.0) {
        float r = rnd(s);
        if (p.mode == MODE_CRUISE && r < 0.25) { p.mode = MODE_PERCH; p.modeTime = rr(s, 2.0, 6.0); }
        else if (p.mode == MODE_CRUISE && r > 0.9) {
            p.mode = MODE_DART; p.modeTime = rr(s, 0.3, 0.7);
            p.vel = float2(rr(s, -1.0, 1.0), rr(s, -1.0, 1.0)) * 130.0;
        }
        else { p.mode = MODE_CRUISE; p.modeTime = rr(s, 1.0, 4.0); }
    }
    // flash clock: advance within the cycle; new cycle re-rolls its length
    p.pulsePhase += P.dt;
    if (p.pulsePhase >= p.pulseFreq) {
        p.pulsePhase = 0.0;
        p.pulseFreq = rr(s, P.flashIntervalMin, P.flashIntervalMax);
    }
    p.seed = s;

    if (p.mode == MODE_PERCH) {
        p.vel *= exp(-6.0 * P.dt);                                 // settle and hold
    } else {
        // OU wander
        uint s2 = p.seed;
        float2 noise = float2(rnd(s2) - 0.5, rnd(s2) - 0.5) * 2.0;
        p.seed = s2;
        p.vel += (-p.vel * 0.5 + noise * 90.0) * P.dt;
        // weak attraction to the nearest roaming attractor
        float2 best = float2(0.0); float bestD = 1e12;
        for (int a = 0; a < 3; a++) {
            float2 d = P.attractors[a] - p.pos;
            float dd = dot(d, d);
            if (dd < bestD) { bestD = dd; best = d; }
        }
        p.vel += best * (P.attractorWeight * P.dt);
        if (p.mode == MODE_DART) p.vel *= 1.0 + 1.5 * P.dt;        // brief burst
        float spd = length(p.vel);
        if (spd > 160.0) p.vel *= 160.0 / spd;
    }
    p.pos += p.vel * p.depth * P.dt;
}

// Maple samara "helicopter": fast fixed-sign autorotation, tight helical drift, steady
// descent, slight cone angle — instantly recognizable.
static void stepSamara(thread Particle& p, constant SimParams& P) {
    p.rot += p.vrot * P.dt;
    p.phase += p.flutterRate * 0.8 * P.dt;
    p.pos.x += P.gyroRadius * 0.5 * cos(p.phase) * p.depth * P.dt;
    p.pos.y += p.vel.y * p.depth * P.dt;
    p.tumble = 0.35 + 0.12 * sin(p.phase * 0.7);
}

kernel void stepParticles(device Particle* ps [[buffer(0)]],
                          constant SimParams& P [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle p = ps[i];

    // ---- Hero slots: scripted near-field showcase crossings (first heroCount indices) ----
    if (i < P.heroCount) {
        if (i == P.heroActiveSlot) {
            float T = saturate(P.heroT);
            p.depth = P.depthMax;
            p.size = P.sizeMax * 1.35;
            float x0 = P.heroDir > 0.0 ? -150.0 : P.worldViewport.x + 150.0;
            float x1 = P.heroDir > 0.0 ? P.worldViewport.x + 150.0 : -150.0;
            p.pos.x = mix(x0, x1, T + 0.04 * sin(T * 9.0));
            p.pos.y = P.worldViewport.y * (0.2 + 0.42 * T) + 28.0 * sin(T * 11.0);
            // showcase: flutter → autorotation → glide across the crossing; entry and exit
            // points sit beyond the viewport so the hero slides in and out naturally
            if (T < 0.4)       p.tumble = p.flutterAmp * 1.3 * sin(P.time * max(p.flutterRate, 2.0));
            else if (T < 0.72) p.tumble += 3.2 * P.heroDir * P.dt;
            else               p.tumble *= exp(-2.0 * P.dt);
            p.alphaJitter = 1.0;
            p.mode = 0u;
        } else {
            p.mode = MODE_PARKED;
            p.pos.y = -P.worldViewport.y;
        }
        ps[i] = p;
        return;
    }

    // ---- Reserves: parked until a passing gust front shakes them loose ----
    bool reserve = (P.baselineCount > 0u) && (i >= P.baselineCount);
    if (p.mode == MODE_PARKED) {
        float px;
        if (gustReleases(p, P, px)) {
            respawn(p, P, true);          // the gust visibly shakes more loose
            p.pos.x = px;
        } else {
            ps[i] = p;                    // calm air: stay parked
            return;
        }
    }

    // Wind coupling: drag relaxation toward the local field — light things take time to
    // catch the air (tau), which is what reads as mass. Fireflies steer themselves: their
    // OU wander swamps the curl detail, so they get the cheap gust-only field at quarter weight.
    float2 wv = P.motionModel == MODEL_FIREFLY
        ? sampleGustWind(p.pos + P.windOrigin, P)
        : sampleWind(p.pos + P.windOrigin, p.depth, P.time, P);
    float k = 1.0 - exp(-P.dt / max(P.relaxTau, 0.05));
    p.windVel += (wv - p.windVel) * k;
    p.pos += p.windVel * p.depth * P.dt * (P.motionModel == MODEL_FIREFLY ? 0.25 : 1.0);

    switch (P.motionModel) {
        case MODEL_LEAF:    stepLeaf(p, P, length(p.windVel)); break;
        case MODEL_PETAL:   stepPetal(p, P); break;
        case MODEL_SNOW:    stepSnow(p, P); break;
        case MODEL_FIREFLY: stepFirefly(p, P); break;
        case MODEL_SAMARA:  stepSamara(p, P); break;
        default: {  // GENERIC / RAIN: legacy fall + spin
            p.pos.y += p.vel.y * p.depth * P.dt;
            p.pos.x += p.vel.x * p.depth * P.dt;
            if (P.flags & 1u) p.rot += p.vrot * P.dt;
            if (P.flags & 2u) p.tumble += p.vtumble * P.dt;
            if (P.flags & 4u) p.pulsePhase += p.pulseFreq * P.dt;
        }
    }

    float margin = p.size * 2.0;
    // Risers (embers) enter from below the viewport and exit off the top, so the falling
    // bottom-exit test must not apply to them — it would recycle every fresh below-screen
    // spawn on its first frame.
    bool riser = P.vyMax <= 0.0 && P.vyMin < 0.0;
    bool out = (!riser && p.pos.y - margin > P.worldViewport.y)
            || p.pos.x < -margin - 250.0 || p.pos.x > P.worldViewport.x + margin + 250.0;
    if (P.motionModel == MODEL_FIREFLY || riser) out = out || p.pos.y < -margin * 8.0;
    if (out) {
        // a reserve that exits in calm air parks again — the field thins back after a gust
        float px;
        if (reserve && !gustReleases(p, P, px)) {
            p.mode = MODE_PARKED;
            p.pos.y = -P.worldViewport.y;
        } else {
            respawn(p, P, true);
        }
    }
    ps[i] = p;
}

// ---- Instanced lit curved-mesh render ----

struct VSOut {
    float4 pos [[position]];
    float2 uv;
    float3 normal;   // view space
    float3 tangent;  // view-space surface tangent (uv.x direction) for baked-normal perturbation
    float3 bitan;
    float  alpha;    // coverage only: edge fade and pulse — never distance
    float  fade;     // brightness: aerial perspective + per-particle jitter (distance dims, not ghosts)
    float  depthN;   // 0 far .. 1 near
    uint   variant;
    float3 hueJit;   // per-instance OKLab variation: hue angle (rad), chroma scale, lightness scale
};

// OKLab round trip in the sprite art's decoded linear-sRGB space. The result is converted to
// the renderer's linear Display-P3 working space after the per-instance variation.
static inline float3 toOKLab(float3 c) {
    float l = 0.4122214708*c.r + 0.5363325363*c.g + 0.0514459929*c.b;
    float m = 0.2119034982*c.r + 0.6806995451*c.g + 0.1073969566*c.b;
    float s = 0.0883024619*c.r + 0.2817188376*c.g + 0.6299787005*c.b;
    l = pow(max(l,0.0), 1.0/3.0); m = pow(max(m,0.0), 1.0/3.0); s = pow(max(s,0.0), 1.0/3.0);
    return float3(0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
                  1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
                  0.0259040371*l + 0.7827717662*m - 0.8086757660*s);
}
static inline float3 fromOKLab(float3 lab) {
    float l = lab.x + 0.3963377774*lab.y + 0.2158037573*lab.z;
    float m = lab.x - 0.1055613458*lab.y - 0.0638541728*lab.z;
    float s = lab.x - 0.0894841775*lab.y - 1.2914855480*lab.z;
    l = l*l*l; m = m*m*m; s = s*s*s;
    return float3( 4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
                  -1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
                  -0.0041960863*l - 0.7034186147*m + 1.7076147010*s);
}

static inline float3 linearSRGBToLinearP3(float3 c) {
    return float3(0.82246197*c.r + 0.17753803*c.g,
                  0.03319420*c.r + 0.96680580*c.g,
                  0.01708263*c.r + 0.07239744*c.g + 0.91051993*c.b);
}

static inline float3 vividImageP3(float3 c, constant VividImageParams& vivid) {
    float luma = dot(c, float3(0.22897456, 0.69173852, 0.07928691));
    float3 enhanced = (luma + (c - luma) * vivid.chroma) * vivid.exposure;
    return saturate(enhanced);
}

struct GBuf {
    float4 color [[color(0)]];
    float4 coc   [[color(1)]];   // r = (1-depthN) coverage-weighted, a = coverage
};

inline float edgeFade(float y, float h, float top, float bot) {
    float t = clamp((y + top) / top, 0.0, 1.0);
    float b = clamp((h - y) / bot, 0.0, 1.0);
    return min(t, b);
}

static inline float3x3 rotZ(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(c, s, 0), float3(-s, c, 0), float3(0, 0, 1));
}

static inline float3x3 axisAngle(float3 ax, float a) {
    ax = normalize(ax);
    float c = cos(a), s = sin(a), t = 1.0 - c;
    float x = ax.x, y = ax.y, z = ax.z;
    return float3x3(
        float3(t*x*x + c,   t*x*y + s*z, t*x*z - s*y),
        float3(t*x*y - s*z, t*y*y + c,   t*y*z + s*x),
        float3(t*x*z + s*y, t*y*z - s*x, t*z*z + c));
}

vertex VSOut meshVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                    const device MeshVertex* verts [[buffer(0)]],
                    const device Particle* ps [[buffer(1)]],
                    constant SimParams& P [[buffer(2)]]) {
    Particle p = ps[iid];
    MeshVertex mv = verts[vid];
    float3x3 R = axisAngle(p.axis, p.tumble) * rotZ(p.rot);
    float s = p.size * p.depth * 2.0;
    float3 world = R * (mv.pos * s);
    float2 screen = p.pos + world.xy - P.cameraOrigin;
    float2 ndc = float2(screen.x / P.cameraViewport.x * 2.0 - 1.0,
                        1.0 - screen.y / P.cameraViewport.y * 2.0);

    float depthN = saturate((p.depth - P.depthMin) / max(P.depthMax - P.depthMin, 1e-4));
    // On a black field semi-transparent sprites read as ghosts: distance dims LUMINANCE,
    // alpha stays coverage (edge fade + pulse) so overlapping sprites occlude properly.
    float alpha = edgeFade(p.pos.y, P.worldViewport.y, P.topFade, P.botFade);
    if (P.flags & 4u) alpha *= (0.3 + 0.5 * (0.5 + 0.5 * sin(p.pulsePhase)));  // pulse
    float jitterB = mix(0.92, 1.0, saturate((p.alphaJitter - 0.7) / 0.3));
    float fade = mix(0.78, 1.0, depthN) * jitterB;   // keep distant art vivid, not ghostly

    VSOut o;
    o.pos = float4(ndc, 0, 1);
    o.uv = mv.uv;
    o.normal = normalize(R * mv.normal);
    o.tangent = normalize(R * float3(1, 0, 0));
    o.bitan = normalize(R * float3(0, 1, 0));
    o.alpha = alpha;
    o.fade = fade;
    o.depthN = depthN;
    o.variant = p.variant;
    // per-instance color variation, stable over the particle's life (seed-derived);
    // `hueJitterRad == 0` gates the whole feature so the fragment OKLab round trip is skipped
    uint hs = p.seed * 0x9E3779B9u;
    float h1 = float((hs >> 8)  & 0xFFFFu) / 65535.0;
    float h2 = float((hs >> 16) & 0xFFFFu) / 65535.0;
    float en = step(1e-4, P.hueJitterRad);
    o.hueJit = float3((h1 - 0.5) * 2.0 * P.hueJitterRad,
                      1.0 + (h2 - 0.5) * 0.18 * en,
                      1.0 + (h1 * h2 - 0.25) * 0.1 * en);
    return o;
}

fragment GBuf meshFS(VSOut in [[stage_in]],
                     texture2d_array<float> tex [[texture(0)]],
                     texture2d_array<float> maps [[texture(1)]],
                     constant float4& colorP3 [[buffer(0)]],
                     constant float& spriteOpacity [[buffer(1)]],
                     constant LightParams& L [[buffer(2)]],
                     constant MaterialParams& M [[buffer(3)]],
                     constant VividImageParams& vivid [[buffer(4)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, max_anisotropy(16),
                          address::clamp_to_edge);
    float4 t = tex.sample(smp, in.uv, in.variant);
    if (t.a < 0.01) discard_fragment();
    float3 base = t.rgb;
    // per-instance OKLab hue/chroma/lightness jitter multiplies perceived sprite variety
    if (in.hueJit.x != 0.0 || in.hueJit.y != 1.0) {
        float3 lab = toOKLab(base);
        float ca = cos(in.hueJit.x), sa = sin(in.hueJit.x);
        float2 ab = float2(lab.y * ca - lab.z * sa, lab.y * sa + lab.z * ca) * in.hueJit.y;
        base = max(fromOKLab(float3(lab.x * in.hueJit.z, ab)), 0.0);
    }
    base = vividImageP3(linearSRGBToLinearP3(base), vivid);

    // Baked surface maps: RG = tangent normal, B = thinness (edges transmit), A = AO.
    float4 m = maps.sample(smp, in.uv, in.variant);
    float2 nxy = (m.rg * 2.0 - 1.0) * M.normalStrength;
    float thin = m.b;
    float ao = mix(1.0, m.a, M.aoStrength);

    // Two-sided, vein-perturbed normal: surface detail now responds to the lights as it tumbles.
    float3 N = normalize(in.normal + in.tangent * nxy.x + in.bitan * nxy.y);
    if (N.z < 0.0) N = -N;
    float3 Ld = normalize(L.keyDir);
    float ndl = dot(N, Ld);
    float front = max(ndl, 0.0);
    float back  = max(-ndl, 0.0);
    float3 V = float3(0, 0, 1);
    float rim = pow(1.0 - saturate(abs(dot(N, V))), 3.0);

    float3 lit = base * (L.ambientColor * (L.ambientIntensity * ao) + L.keyColor * (L.keyIntensity * front));
    // Per-species subsurface transmission: thin margins glow in the species color when backlit
    // (petal rims pink, leaf edges amber, crystal arms cool blue) — the signature shot.
    float trans = pow(back, 1.5) * thin;
    lit += base * (L.translucency * 0.35 * back) * L.keyColor;             // body glow (legacy, toned down)
    lit += M.sssColor * (M.sssStrength * trans) * L.keyColor;              // edge transmission
    lit += L.keyColor * (L.specular * rim);                                 // soft sheen on the curl

    // Second light: cool top-back rim — separates the sprite from the black field like a
    // gallery track light. Edge-weighted by the view-rim factor so it traces the silhouette.
    float rimDot = saturate(dot(N, normalize(L.rimDir)));
    lit += (base * 0.4 + 0.6) * L.rimColor * (L.rimIntensity * rimDot * rim);

    // Hash-gated facet glints (snow): sparse cells fire a tight specular only when the
    // rotating crystal aligns with the key light — they wink as flakes wobble, and the
    // bloom pyramid blooms them.
    if (M.sparkle > 0.0) {
        float2 cell = floor(in.uv * 64.0);
        float hash = vhash(cell + float(in.variant) * 7.31);
        if (hash > 0.985) {
            float3 R = reflect(-Ld, N);
            float glint = pow(saturate(R.z), M.specPower);
            lit += L.keyColor * (glint * M.sparkle * M.specStrength * 3.0);
        }
    }

    lit *= in.fade;                                // distance dims, never ghosts
    float a = t.a * in.alpha * spriteOpacity * colorP3.a;
    GBuf o;
    o.color = float4(lit * a, a);                 // premultiplied
    o.coc = float4((1.0 - in.depthN) * a, 0, 0, a);
    return o;
}

// ---- Firefly glow (procedural additive light, no sprite) ----

struct GlowOut { float4 pos [[position]]; float2 uv; float alpha; float depthN; };

constant float2 GQUAD[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                             float2(1,-1),  float2(1,1),  float2(-1,1) };

vertex GlowOut glowVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device Particle* ps [[buffer(1)]],
                      constant SimParams& P [[buffer(2)]]) {
    Particle p = ps[iid];
    float2 corner = GQUAD[vid];
    float s = p.size * p.depth * 10.0;            // glow halo radius (points)
    float2 pos = p.pos + corner * s - P.cameraOrigin;
    float2 ndc = float2(pos.x / P.cameraViewport.x * 2.0 - 1.0,
                        1.0 - pos.y / P.cameraViewport.y * 2.0);
    float depthN = saturate((p.depth - P.depthMin) / max(P.depthMax - P.depthMin, 1e-4));
    float alpha = p.alphaJitter * edgeFade(p.pos.y, P.worldViewport.y, P.topFade, P.botFade);
    alpha *= mix(0.5, 1.0, depthN);
    if (P.motionModel == MODEL_FIREFLY) {
        // Species-accurate flash train: a short sin^2 flash, then darkness for seconds, with
        // a fraction of individuals double-flashing — the signature of real fireflies.
        float tc = p.pulsePhase;                 // seconds into this cycle
        float on = max(P.flashOn, 0.05);
        float env = 0.05;                        // faint body glow between flashes
        if (tc < on) {
            float x = tc / on;
            env = sin(3.14159265 * x); env *= env;
        } else if ((as_type<uint>(p.flutterRate) >> 6 & 7u) == 0u) {
            // ~1 in 8 are double-flashers — keyed off flutterRate's bits because that field
            // is spawn-stable for fireflies (p.seed advances every frame in the OU wander,
            // which would re-roll the identity per frame and render as flicker)
            float t2 = tc - (on + 0.4);
            if (t2 >= 0.0 && t2 < on * 0.7) {
                float x = t2 / (on * 0.7);
                float e2 = sin(3.14159265 * x);
                env = e2 * e2 * 0.8;
            }
        }
        alpha *= env;
    } else if (P.flags & 4u) {
        alpha *= (0.25 + 0.75 * (0.5 + 0.5 * sin(p.pulsePhase)));  // legacy breathing pulse
    }
    GlowOut o;
    o.pos = float4(ndc, 0, 1);
    o.uv = corner;
    o.alpha = alpha;
    o.depthN = depthN;
    return o;
}

fragment GBuf glowFS(GlowOut in [[stage_in]],
                     constant float4& colorP3 [[buffer(0)]],
                     constant float& headroom [[buffer(1)]]) {
    float d2 = dot(in.uv, in.uv);
    float core = exp(-d2 * 3.5);                  // soft radial falloff
    float ca = core * in.alpha * colorP3.a;
    float3 rgb = colorP3.rgb * headroom * core;   // pushed into EDR so bloom blooms it
    GBuf o;
    o.color = float4(rgb * in.alpha * colorP3.a, ca);   // additive light
    o.coc = float4((1.0 - in.depthN) * ca, 0, 0, ca);
    return o;
}

// ---- Rain streaks (procedural, no sprite) ----
// A thin elongated quad aligned to the particle's motion (fall + wind), soft across its
// width with a bright head and faint tail — reads as a motion-blurred droplet trail.

struct StreakOut { float4 pos [[position]]; float2 uv; float alpha; float depthN; };

constant float2 SQUAD[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                             float2(1,-1),  float2(1,1),  float2(-1,1) };

vertex StreakOut streakVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device Particle* ps [[buffer(1)]],
                          constant SimParams& P [[buffer(2)]]) {
    Particle p = ps[iid];
    float2 corner = SQUAD[vid];
    float halfW = max(p.size * p.depth * 0.6, 0.5);   // thin
    float halfL = p.size * p.depth * 7.0;             // long
    // motion direction in screen space (+y is down here); the LOCAL wind tilts each streak,
    // so a passing gust visibly rakes the rain
    float2 mdir = normalize(float2(p.windVel.x * 0.6, max(p.vel.y + p.windVel.y, 50.0)));
    float2 perp = float2(mdir.y, -mdir.x);
    float2 world = perp * (corner.x * halfW) + mdir * (corner.y * halfL);
    float2 pos = p.pos + world - P.cameraOrigin;
    float2 ndc = float2(pos.x / P.cameraViewport.x * 2.0 - 1.0,
                        1.0 - pos.y / P.cameraViewport.y * 2.0);
    float depthN = saturate((p.depth - P.depthMin) / max(P.depthMax - P.depthMin, 1e-4));
    float alpha = p.alphaJitter * edgeFade(p.pos.y, P.worldViewport.y, P.topFade, P.botFade);
    alpha *= mix(0.45, 1.0, depthN);                  // far streaks fainter
    StreakOut o;
    o.pos = float4(ndc, 0, 1);
    o.uv = corner;
    o.alpha = alpha;
    o.depthN = depthN;
    return o;
}

fragment GBuf streakFS(StreakOut in [[stage_in]],
                       constant float4& colorP3 [[buffer(0)]],
                       constant float& opacity [[buffer(1)]]) {
    float across = pow(saturate(1.0 - abs(in.uv.x)), 1.5);   // soft thin line
    float along = saturate(0.5 + 0.5 * in.uv.y);             // bright head, faint tail
    float a = across * mix(0.12, 1.0, along) * in.alpha * colorP3.a * opacity;
    GBuf o;
    o.color = float4(colorP3.rgb * a, a);                    // premultiplied, no glow push
    o.coc = float4((1.0 - in.depthN) * a, 0, 0, a);
    return o;
}
