# Season config reference

Each season is a JSON file in [Resources/seasons/](../Resources/seasons/) decoded to the `Season`
struct ([Sources/Season.swift](../Sources/Season.swift)). The harness reads these straight from disk
(edit → re-run `seasons-shot`, no rebuild); the app/saver bundle them, so rebuild to see changes there.

## Fields

| field | type | meaning | web origin |
|---|---|---|---|
| `name` | string | season id (`winter`/`spring`/`summer`/`autumn`); selects the backdrop/mesh preset | — |
| `glyphType` | `"image"` \| `"glow"` | sprite-mesh render vs procedural firefly glow | `glyphType` |
| `spriteSet` | string \| null | sprite folder under `Resources/sprites/`; null for glow | `sprites` |
| `spriteCount` | int | number of sprite variants (1..N.png); 0 for glow | — |
| `count` | int | particle count | `count` (scaled up) |
| `sizeMin`/`sizeMax` | float | particle size range, points (wide range → big-near/small-far depth) | `sizeMin/Max` |
| `vyMin`/`vyMax` | float | vertical velocity; use ± for bidirectional motion (fireflies), or a same-sign nonzero range for guaranteed continuous drift | `vyMin/Max` |
| `vxMin`/`vxMax` | float | horizontal velocity; non-zero enables x translation, and a same-sign nonzero range excludes stationary particles | firefly `vx` |
| `swayAmp` | float | sinusoidal horizontal sway amplitude | `swayAmp` |
| `swayPeriodMin`/`swayPeriodMax` | float | sway period range (seconds) | `swayPeriod` |
| `rotate` / `rotateSpeed` | bool / float | in-plane spin | `rotate`/`rotateSpeed` |
| `tumble` / `tumbleSpeed` | bool / float | real 3D-axis tumble (native: a real rotation, not `scaleY`) | `tumble`/`tumbleSpeed` |
| `glow` | bool | firefly additive glow | `glow` |
| `pulse` | bool | breathing alpha pulse | `pulse` |
| `spriteOpacity` | float | per-type opacity | `spriteOpacity` |
| `color` | OKLCH `{L,C,H,alpha}` | base/tint color of particles; baked to linear P3 | `color` |
| `tint` | OKLCH `{L,C,H,alpha}` | reserved season tint | `--season-tint` |
| `depthMin`/`depthMax` | float | parallax/DOF depth range (web used 0.6–1.0) | `depth` |
| `bloomThreshold` | float | bloom bright-pass knee | — |
| `bloomIntensity` | float | (see note) | — |
| `dofStrength` | float | (see note) | — |
| `edrHeadroom` | float | firefly glow EDR push (how far past 1.0) | — |

OKLCH `{L,C,H,alpha}`: L 0–1, C chroma, H degrees, alpha straight. Converted once at load by
`oklchToLinearP3`.

**Note — grade overrides:** the cinematic mood (exposure, bloom intensity, DOF strength, saturation,
vignette, grain, backdrop colors, lighting) currently lives in `Renderer.atmosphere(for:)` and
`defaultLight()` keyed by `name`, and those override the per-season `bloomIntensity`/`dofStrength`
JSON fields. The config sheet's Bloom/DOF toggles gate them on/off via the renderer's `bloom`/`dof`
init args. To make the JSON values authoritative, remove the constants in `atmosphere(for:)`.

## Flags (derived)

`ParticleSystem.makeParams` packs booleans into `SimParams.flags`: bit0 rotate, bit1 tumble,
bit2 pulse, bit3 firefly-wander (set when `vxMin`/`vxMax` ≠ 0).

## Selection & override

`SeasonSelection` storage strings: `auto`, `off`, or a season id. Persisted via `Prefs.selection`
(config sheet), overridable per-run by `SEASONS_FORCE`. `off` → still graded backdrop. Round-trip
mapping is unit-tested in `SeasonTests`.

## wind{} block (Phase B)

Optional; absent fields derive from legacy `windMax`. The field is evaluated in world
(desktop) coordinates as a pure function of shared time, so all displays render one
continuous wind — gusts travel monitor to monitor.

| field | meaning | default |
|---|---|---|
| `base` | steady drift, signed x points/sec | `windMax * 0.35` |
| `turbulence` | curl-noise amplitude (points/sec) | `max(windMax*0.8, swayAmp*1.2)` |
| `fieldScale` | world points → noise domain | 0.0015 |
| `evolve` | noise time evolution rate | 0.12 |
| `gustEvery` | [min,max] mean seconds between gusts per lane (4 lanes) | [25, 60] |
| `gustStrength` | peak front wind (points/sec); 0 disables | `windMax * 1.6` |
| `gustWidth` | gaussian half-width of a front (points) | 900 |
| `relaxTau` | wind-following relaxation (s); smaller = lighter | by glyph: glow 0.25, streak 0.1, image 0.35 (0.8 if tumble) |

QA: `SEASONS_TIME_OFFSET` fast-forwards the deterministic schedule; `SEASONS_WORLD_ORIGIN="x,y"`
renders as if on a display at that desktop origin; shot's optional `[seqEvery]` arg writes
motion strips.
