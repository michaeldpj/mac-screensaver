#ifndef ShaderTypes_h
#define ShaderTypes_h
#include <simd/simd.h>

// A traveling pressure front in world (multi-display desktop) space.
typedef struct {
    simd_float2 dir;     // unit travel direction
    float head;          // distance traveled along dir (points)
    float width;         // gaussian half-width of the front (points)
    float strength;      // peak wind contribution (points/sec); 0 = inactive
    float turbBoost;     // extra curl amplitude inside the front
    float _g0, _g1;
} GustFront;

typedef struct {
    simd_float2 pos;     // points in viewport space
    simd_float2 vel;     // vx, vy (points/sec)
    simd_float2 windVel; // relaxed wind-following velocity (points/sec)
    float phase;         // per-model oscillator (flutter/gyre/wobble), advanced by flutterRate
    float rot, vrot;         // in-plane spin (z)
    float tumble, vtumble;   // axis-angle tumble: tumble = angle, vtumble = angular speed
    float pulsePhase, pulseFreq;
    float depth;         // 0.6...1.0
    float size;          // base radius (points)
    float alphaJitter;   // 0.7...1.0
    unsigned int variant;
    unsigned int seed;
    simd_float3 axis;    // unit rotation axis for 3D tumble
    unsigned int mode;       // per-model state machine (MODE_*)
    float modeTime;          // seconds remaining in the current mode
    float flutterAmp;        // per-particle peak attack angle (radians)
    float flutterRate;       // per-particle rocking rate (rad/sec)
} Particle;

// Particle.mode values (meaning depends on motion model)
#define MODE_FLUTTER 0u
#define MODE_TUMBLE  1u
#define MODE_GLIDE   2u
#define MODE_CRUISE  0u
#define MODE_PERCH   1u
#define MODE_DART    2u
#define MODE_PARKED  7u   // cross-model lifecycle state: reserve waiting for a gust to shake
                          // it loose. 7u is reserved in EVERY model's state space — new model
                          // states must stay below it.

// SimParams.motionModel
#define MODEL_GENERIC 0u
#define MODEL_LEAF    1u
#define MODEL_PETAL   2u
#define MODEL_SNOW    3u
#define MODEL_FIREFLY 4u
#define MODEL_RAIN    5u
#define MODEL_SAMARA  6u

// A curved-patch mesh vertex (object space, centered, ~unit extent).
typedef struct {
    simd_float3 pos;
    simd_float3 normal;
    simd_float2 uv;
} MeshVertex;

// Graded atmospheric backdrop (dawn-sakura etc.).
typedef struct {
    simd_float3 skyTop;     float _p0;   // upper ambient glow color (linear P3)
    simd_float3 skyBottom;  float _p1;   // deep shadow color at the base
    simd_float3 glowColor;  float glowRadius;
    simd_float2 glowCenter;
    float grain;
    float time;
    float vignette;         // 0 none .. 1 strong
    float exposure;
    float bloomIntensity;
    float saturation;
    float dofStrength;
    float maxOutput;        // >0 clamps composite output (SDR presentation); 0 = unclamped EDR
    float caStrength;       // chromatic aberration on the DOF blur, in pixels at full CoC
    float filmicWhite;      // scene value that tonemaps to 1.0 (0 disables the filmic curve)
    simd_float3 shadowTint;    float bloomMixHalf;     // split-tone: multiplied into shadows
    simd_float3 highlightTint; float bloomMixQuarter;  // split-tone: multiplied into highlights
    float bloomMixEighth;
    float _p3, _p4, _p5;
} AtmosphereParams;

// Per-species surface material (Phase E). Maps are baked from the albedo at load time.
typedef struct {
    simd_float3 sssColor;     // subsurface transmission color (linear P3)
    float sssStrength;        // backlit transmission scale
    float specStrength;       // glint specular scale
    float specPower;          // glint tightness
    float sparkle;            // hash-gated facet glints (snow), 0 disables
    float normalStrength;     // baked normal-map perturbation scale
    float aoStrength;         // baked AO influence on ambient
    float _m0, _m1, _m2;
} MaterialParams;

// Real-time lighting for the lit-mesh render path.
typedef struct {
    simd_float3 keyDir;        // normalized light direction (view space)
    float keyIntensity;
    simd_float3 keyColor;
    float ambientIntensity;
    simd_float3 ambientColor;
    float translucency;        // backlit subsurface strength (thin petals/leaves glow)
    simd_float3 rimDir;        // second light: cool top-back "track light" for black-bg separation
    float rimIntensity;
    simd_float3 rimColor;
    float specular;            // soft sheen
} LightParams;

// Image-sprite-only SDR visibility treatment. Procedural glow/streak paths do not bind this.
typedef struct {
    float exposure;
    float chroma;
    float _v0, _v1;
} VividImageParams;

typedef struct {
    float dt, time;
    simd_float2 worldViewport;  // global simulation extent in points (local viewport when not panoramic)
    simd_float2 cameraOrigin;   // this drawable's top-left crop in the y-down world
    simd_float2 cameraViewport; // this drawable's logical point extent
    float topFade, botFade; // edge-fade margins (points): 60, 80 in web
    unsigned int count;
    unsigned int flags;     // bit0 rotate, bit1 tumble, bit2 pulse, bit3 firefly-wander
    float vyMin, vyMax, vxMin, vxMax;
    float sizeMin, sizeMax;
    float rotateSpeed, tumbleSpeed, pulseFreqMin, pulseFreqMax;
    float depthMin, depthMax;
    unsigned int spriteCount;

    // Wind field, evaluated at worldPos = pos + windOrigin so every display samples the same
    // continuous deterministic field — gusts travel seamlessly across monitors with no IPC.
    simd_float2 windOrigin;    // normalized world's origin in global y-down desktop points
    float windBase;            // steady drift (points/sec, signed x)
    float turbulence;          // curl-noise amplitude (points/sec)
    float windFieldScale;      // world points → noise domain (~0.0015)
    float windEvolve;          // noise time evolution rate
    float relaxTau;            // wind-following relaxation time constant (s)
    float meanWindX;           // CPU-estimated mean horizontal wind for respawn-side bias
    unsigned int worldSeed;    // shared across panorama replicas; local views derive it from origin
    float _w0;

    // Species aerodynamics (Phase C). Orientation derives from the same state as translation.
    unsigned int motionModel;  // MODEL_*
    float flutterAmp;          // leaf/petal: season peak attack angle (radians)
    float flutterFreq;         // leaf/petal: base rocking rate (Hz)
    float tumbleChance;        // leaf: probability per mode-roll of autorotation
    float gyroRadius;          // petal: helix radius (points)
    float microTurb;           // snow: micro-turbulence amplitude (points/sec, at smallest size)
    float flashOn;             // firefly: flash duration (s)
    float flashIntervalMin;    // firefly: dark gap range (s)
    float flashIntervalMax;
    float attractorWeight;     // firefly: pull toward attractors (1/sec^2-ish)
    float _a0, _a1;
    simd_float2 attractors[3]; // firefly: viewport-space targets (CPU-animated Lissajous)

    // Choreography (Phase D): sparse calm baseline, gusts shake reserves loose, rare hero moments.
    float depthBias;           // depth = mix(min,max,pow(rnd,bias)) — many small far, few large near
    float sizeDepthCoupling;   // 0..1: how strongly size follows depth (near = large)
    unsigned int baselineCount;// particles active in calm air; the rest park until a gust
    float releaseWind;         // local wind (points/sec) that releases a parked reserve
    unsigned int heroCount;    // scripted hero slots (first N indices), 0 disables
    unsigned int heroActiveSlot; // 0xFFFFFFFF = none
    float heroT;               // 0..1 progress of the active hero crossing
    float heroDir;             // +1 left→right, -1 right→left
    float hueJitterRad;        // per-instance OKLab hue jitter, peak radians (0 disables)
    float _c0, _c1, _c2;
    GustFront gusts[4];
} SimParams;
#endif /* ShaderTypes_h */
