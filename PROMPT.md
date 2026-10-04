# Project: Seasons — a native macOS screensaver

## What I want

Build a native macOS screensaver (`.saver` bundle) that recreates and elevates the
seasonal ambient particle effect from my website mdpj.me. I love that effect and want it
living on my desktop as a best-in-class screensaver. This is a fresh project, but the web
implementation is the design baseline — same look, same feel, same four seasonal moods —
ported to native and pushed far past what a browser canvas can do.

The web engine and its sprites are checked into `reference/` in this repo:
- `reference/seasonal.js` — the full canvas particle engine (read it; it is the source of truth for behavior)
- `reference/atmosphere.css` — the background gradient + grain + palette (OKLCH)
- `reference/images/seasonal/{snow,petals,leaves}/*.webp` — the original sprite sets

Before writing any code, brainstorm the architecture and visual direction with me and
present a plan. Do not jump to implementation.

## Hardware mandate (read this first)

I run a MacBook Pro M5 Max, 64GB RAM, macOS Tahoe (26). High end. I do NOT want
backward-compatibility compromises that cap visual quality or motion fidelity. Target this
chip and OS to produce a top-in-class screensaver. Specifically, exploit:

- **Metal 4 + MetalFX** — GPU-instanced particle rendering. Thousands of particles, not the
  ~30 the web version uses. Simulate on the GPU (compute shaders), not the CPU.
- **EDR / HDR** — drive fireflies, snow sparkle, and highlights into the extended brightness
  range so they actually glow against the dark field on the XDR display.
- **Display P3 wide gamut** — the web palette is authored in OKLCH; map to P3, do not clamp
  to sRGB. The amber/warm tones should be richer than the browser can show.
- **ProMotion 120Hz** — adaptive frame pacing, buttery motion, no judder.
- **Post-processing** — bloom, subtle depth-of-field, optional motion blur, volumetric/parallax
  depth layers. Treat the particle field as a real 3D-ish scene with atmosphere, not flat 2D.
- **Real-time lighting** on sprites where it sells depth (leaves catching light as they tumble).

If M3-tier compatibility falls out for free without diluting the intent, great — keep it as a
graceful tier-down (fewer particles, drop post FX). It is NOT a priority. Never trade the M5
ceiling for it. Optimize for my machine.

## The baseline: how the web effect works

The web version is a single vanilla-JS IIFE driving a 2D `<canvas>`, ~314 lines, no framework
(`reference/seasonal.js`). Port the *behavior and look*, re-architected for Metal. Key mechanics
to preserve:

**Four seasonal effects, auto-selected by month:**
- winter → **snow** (drifting flakes)
- spring → **petals** (cherry-blossom, tumbling)
- summer → **fireflies** (glowing, pulsing, wandering both directions)
- autumn → **leaves** (maple/oak, fast fall, heavy tumble)

**Per-effect config drives everything.** Each season is a data object, not bespoke code. Fields
(from the web engine `CONFIGS` map, carry these forward as the schema to extend):

| field | meaning |
|---|---|
| `count` | particle count (scale WAY up on GPU) |
| `color` | OKLCH base color (map to P3, push to EDR for glow types) |
| `sizeMin/Max` | particle size range |
| `vyMin/Max` | vertical velocity (snow slow, leaves fast, fireflies bidirectional) |
| `swayAmp`, `swayPeriod` | sinusoidal horizontal drift amplitude + period range |
| `rotate`, `rotateSpeed` | spin |
| `tumble`, `tumbleSpeed` | 3D flip — web fakes it with `scaleY = cos(phase)`; do it for real in 3D |
| `glow`, `pulse` | fireflies only — additive bloom + sinusoidal alpha breathing |
| `spriteOpacity` | per-type opacity |
| `glyphType` | render mode: `image` (sprite), `glow` (blob), `text`/`path` (fallback) |
| `sprites` | sprite variant set |

**Physics per particle (preserve the feel — see `spawn()` and `frame()` in the reference):**
- Gravity-ish fall: `y += vy * depth * dt`
- Horizontal sway: `sin(phase) * swayAmp * depth`
- `depth` ∈ [0.6, 1] gives parallax — nearer particles bigger, faster, more sway. KEEP and
  expand this into real depth layers with DOF.
- Per-particle `alphaJitter`, rotation, tumble phase, pulse phase
- **Edge fade**: particles fade in/out near top and bottom margins (no hard pop) — `edgeFade()`
- Respawn from above when they exit the bottom or sides
- Fireflies get bidirectional `vy` and `vx` (wander), plus glow (shadowBlur in web → real bloom)

**Atmosphere layer (`reference/atmosphere.css`, recreate natively):**
- Dark base field — `bg: oklch(12% 0 0)`
- A per-season **radial gradient tint** behind everything (`--season-tint`):
  winter cool-blue, spring rose, summer amber, autumn orange — all at ~15% over the dark base
- A subtle **fractal-noise grain** overlay at ~3.5% opacity for texture
- On the web, site content sits ABOVE the particles for occlusion depth. No DOM here, but
  reproduce the layered depth with the parallax/DOF system.

**Respect-the-user behaviors to carry over:**
- Honor macOS Reduce Motion accessibility setting — when set, drop to the static tinted
  gradient, no motion (web guards on `prefers-reduced-motion`).
- Multi-display aware. Each screen runs its own instance — handle that cleanly.
- The screensaver gets a preview thumbnail in System Settings AND the full-screen run; both
  must work.

## Asset pipeline: the sprites

The web sprites in `reference/images/seasonal/` are photoreal, transparent-background objects,
trimmed and encoded as 96px WebP:
- snow: 4 snowflake variants
- petals: 6 cherry-blossom petal variants
- leaves: 5 autumn-leaf variants
- fireflies: no sprite — pure procedural glow blob

The originals were generated with **Ideogram v3** (transparent PNG, single centered object, soft
natural lighting), then trimmed and re-encoded. **The exact original generation prompts, the prompt
formula for new effects, and the post-processing command are saved in `reference/sprite-prompts.md`.**
For this project, set up a repeatable generation pipeline using the **fal.ai MCP** (I have it
connected — Ideogram and Nano Banana are available) so I can mint new sprite sets that match the
existing look when I add seasons or styles.

Build a documented, reusable generation prompt template. The look to match: single isolated
natural object, fully transparent background, soft diffuse lighting, slight subsurface translucency,
shot roughly top-down/flat so it reads at any rotation, no harsh shadow, no ground plane,
high resolution then downscaled. Produce 4–6 variants per type for natural variety. For native,
author higher-res source assets than 96px — I have the GPU budget; author at 256–512px and let
mip-mapping handle scale.

## Extensibility (this is the whole point)

I will add new seasons and new visual styles over time. The architecture must make that a
config-and-assets exercise, not a rewrite. Deliver:

1. **A declarative effect schema** (the config table above, extended for native: depth layers,
   bloom params, EDR headroom, color in P3). Adding "embers" or "stars" or a "halloween" mood =
   drop in a config block + a sprite set. No engine changes.
2. **A documented asset-generation recipe** (the fal.ai prompt template + post-processing steps:
   trim, alpha-premultiply, resize, pack) so new sprite sets match the family look.
3. **A season/style selector** — auto-by-month like the web version, PLUS a manual override in the
   screensaver's System Settings configuration panel (pick a fixed season, or a non-seasonal style).
   The web version exposes `?effect=snow|petals|fireflies|leaves|off`; mirror that as a settings
   dropdown.
4. **Clear docs** in the repo: how the engine works, how to add a season, how to generate sprites,
   the config field reference. Write it so a future session can extend it cold.

## Suggested architecture (challenge this in your plan)

- Swift, `ScreenSaverView` subclass hosting a `CAMetalLayer` / `MTKView`.
- Metal compute shader for particle simulation (state in GPU buffers), instanced draw for render.
- A `Season` config struct decoded from a bundled JSON/plist so seasons are data, not code.
- Post-process chain: scene → bloom (for glow/EDR) → DOF → composite over tinted-gradient + grain.
- Configuration sheet via `ScreenSaverView.configureSheet` (or modern SwiftUI hosting) for the
  season override and any quality toggles.
- `.saver` bundle, signed for local install. (Distribution/notarization is out of scope for v1 —
  I'm installing on my own machine. Flag it if you think I'll want it later.)

Validate this against the latest Tahoe / macOS 26 screensaver APIs before committing — the
`ScreenSaverView` story and Metal integration may have moved. Check current Apple docs.

## Deliverables for v1

- Working `.saver` with all four seasons matching the web look, elevated per the hardware mandate.
- Month-based auto-selection + manual override in the config panel.
- The fal.ai sprite-generation recipe, run at least once to produce native-res sprite sets.
- Docs for extending seasons/styles.

## How to start

Brainstorm with me first: confirm the native architecture, the depth/post-FX direction, and the
quality bar before any code. Ask me the open questions. Present a plan. Then we build.
