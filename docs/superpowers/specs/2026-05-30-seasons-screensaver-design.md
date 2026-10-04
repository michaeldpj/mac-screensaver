# Seasons — native macOS screensaver — design spec

**Date:** 2026-05-30
**Status:** Approved (brainstorming complete, ready for implementation plan)
**Target:** macOS 26 Tahoe, Apple Silicon M5 Max (M5-class floor, no backward compatibility)

## Goal

Port the seasonal ambient particle effect from mdpj.me to a native macOS `.saver`
screensaver, re-architected for Metal and elevated far past what the web canvas can do,
while keeping the soul of the original: calm, restrained, dark, low-saturation, meditative.

The web baseline is `reference/seasonal.js` (a ~314-line vanilla-JS canvas engine), its
atmosphere `reference/atmosphere.css`, and the 96px sprite sets under
`reference/images/seasonal/`. The web engine's `CONFIGS` map is the behavioral source of
truth and the schema to carry forward.

## Decisions (locked during brainstorming)

1. **Visual direction: cinematic, faithful soul.** Keep the web mood — calm, never busy —
   but render at a quality the browser cannot reach: hundreds-to-low-thousands of particles
   across real depth layers, soft bloom on highlights, gentle depth-of-field, EDR sparkle.
   Density rises modestly; the feeling stays meditative. Not a maximal demo-reel, not a
   1:1 port.
2. **Build sequence: vertical slice first.** Build one season — autumn leaves, the richest
   motion — end-to-end through the entire pipeline, install it, tune the look against a real
   display, then the other three seasons fall out as config + sprite swaps.
3. **Assets: regenerate everything up front.** Mint native-resolution sprite sets for all
   seasons via the fal.ai Ideogram recipe before engine work, so the build runs against
   final-quality assets throughout.
4. **Performance: maximize, no tier-down.** M5-class is the floor. Target the Metal 4
   command API and latest MetalFX on the Tahoe SDK with no compatibility shims and no
   "fewer particles on older GPUs" branch. Must scale to multiple high-DPI displays now
   (3×4K) and future 6K/8K panels.

## Platform findings (macOS 26 Tahoe)

- `.saver` bundles + Metal still work. Subclass `ScreenSaverView`, back it with a
  `CAMetalLayer`. Confirmed on the current SDK.
- Screensavers run in a separate process (`legacyScreenSaver.appex`). The framework can
  instantiate two view copies; setup/teardown must be idempotent and release GPU state on
  `stopAnimation`.
- Known Tahoe bug: the `isPreview` flag is unreliable (sometimes `false` in the System
  Settings preview). Do not trust it alone — also treat a small backing size as preview.
- The Screen Saver settings pane is now a modal inside Wallpaper settings; `configureSheet`
  still applies.
- Toolchain present: Xcode 26.5, macOS 26.5.

## Architecture

### Rendering host & frame pacing
`SeasonsView: ScreenSaverView` with its backing layer overridden to `CAMetalLayer` (no
child `MTKView` — fewer moving parts in the sandboxed process). The render loop is driven by
`CADisplayLink` with `preferredFrameRateRange` set for adaptive 120Hz ProMotion, not
`animateOneFrame` (whose timer caps near 30fps). `animateOneFrame` is a no-op;
`startAnimation`/`stopAnimation` start and stop the display link and own GPU teardown so the
double-instantiation bug cannot leak two live renderers.

### EDR / color pipeline
Drawable pixel format `RGBA16Float`; layer `wantsExtendedDynamicRangeContent = true`;
colorspace `extendedLinearDisplayP3`. The scene renders in linear P3, unclamped — glow types
(fireflies, snow sparkle, leaf highlights) push luminance past 1.0 so they bloom on the XDR
panel. The OKLCH palette from `atmosphere.css` and `CONFIGS` is converted OKLCH → linear-P3
at build time and baked into the config as P3 components: no runtime color math, no sRGB
clamp.

### Simulation (GPU compute)
Particle state lives in an `MTLBuffer` of structs (position, velocity, phase/freq, rot/vrot,
tumble/vtumble, pulse phase/freq, depth, alphaJitter, variant index, size). A compute kernel
advances the exact `frame()` physics from `seasonal.js`:
- `y += vy · depth · dt`
- horizontal sway `sin(phase) · swayAmp · depth` (plus firefly `vx` wander)
- rotation, tumble, pulse-driven alpha
- edge-fade near top/bottom margins
- respawn from above on exit
`depth ∈ [0.6, 1]` expands into the parallax/DOF input. GPU compute per the mandate; density
sits well within headroom at this scale.

### Render & post chain
Instanced textured quads, one per particle, sprite variant indexed from a per-season
mip-mapped texture array built from the 1024px sources. `tumble` is a real billboard
Y-axis rotation, not the web's `scaleY = cos`. Fireflies are additive procedural blobs with
no texture.

Chain: HDR scene (RGBA16Float) → bright-pass + gaussian bloom (down/up-sample) → subtle DOF
weighted by particle depth → composite over the radial season-tint gradient + animated
fractal grain → MetalFX temporal upscale to display size → tonemap to the EDR drawable. All
FX tuned restrained — bloom and DOF are felt, not flashy.

### Resolution scaling & performance governor
The scene renders at an adaptive internal resolution and MetalFX temporal upscaling
reconstructs to native display size — the main lever that lets multiple displays at extreme
resolution hold frame rate without cutting particles or FX. Each renderer measures GPU frame
time and adjusts its MetalFX input scale to hold the display's max refresh. The knob is
resolution-scale only; bloom, DOF, EDR, and full particle counts always stay on. No constant
assumes 4K — particle counts, bloom kernel radius, DOF circle-of-confusion, and grain
frequency all derive from `drawableSize`.

### Season config (extensibility contract)
Each season is a bundled JSON block decoded to a Swift `Season` struct. It carries the web
schema — `count`, `sizeMin`/`sizeMax`, `vyMin`/`vyMax`, `swayAmp`/`swayPeriod`,
`rotate`/`tumble`/`glow`/`pulse`, `spriteOpacity`, `glyphType`, `sprites` — plus native
extensions: `colorP3`, `depthRange`, `bloom { threshold, intensity }`, `dofStrength`,
`edrHeadroom`, `tint` (P3), `spriteSet`. Adding "embers" or "halloween" is a JSON block plus
a sprite folder, with no engine code.

### Selection & config sheet
Month-based auto-selection (the web's `seasonByMonth`) is the default. `configureSheet`
returns an `NSWindow` hosting a SwiftUI panel via `NSHostingView`: a dropdown for Auto /
Winter / Spring / Summer / Autumn / Off plus quality toggles (bloom, DOF, EDR). Persisted via
`ScreenSaverDefaults(forModuleWithName:)`. Mirrors the web's `?effect=` override.

### Reduce Motion, multi-display, preview
- Reduce Motion: `accessibilityDisplayShouldReduceMotion` → render only the static tint
  gradient + grain, simulation disabled.
- Multi-display: each screen gets its own view, `CAMetalLayer`, sim buffer, display link, and
  governor state. Config is shared; GPU state is per-instance.
- Preview: do not trust `isPreview` alone; also treat a small backing size as preview to
  scale counts down and guarantee the thumbnail draws.

## Repository layout

```
Seasons.xcodeproj          → builds Seasons.saver
  Sources/        Swift: view, renderer, compute host, config decode, config UI
  Shaders/        .metal: sim kernel, instanced render, bloom, dof, composite
  Resources/      seasons/*.json, sprite texture arrays
  tools/          sprite-gen (fal.ai recipe), imagemagick post-process script
  docs/           engine overview, add-a-season, sprite recipe, config reference
```

## Asset pipeline

Runs first. fal.ai Ideogram v3 transparent generation per the saved prompts in
`reference/sprite-prompts.md` (4–6 variants per season) → ImageMagick trim / square-pad /
resize to 1024px / premultiply alpha → packed per-season into mip-mapped texture arrays.
Fireflies remain procedural (no sprite). The recipe is documented as a reusable template so
new seasons match the family look.

## Scope

**In scope (v1):** all four seasons matching the web look and elevated per the hardware
mandate; month-based auto-selection + manual override in the config panel; the fal.ai
sprite recipe run at least once to produce native-resolution sets; docs for extending
seasons/styles; ad-hoc codesigning so the `.saver` installs clean on the local machine.

**Out of scope (v1):** notarization and real distribution signing. Flagged: an unsigned
`.saver` may trip Gatekeeper even for local install, so v1 ad-hoc signs; full distribution
signing is a later step if Michael wants to share it.

## Open risks

- The Tahoe `isPreview` bug has no clean upstream fix; the small-backing-size heuristic is a
  mitigation, not a guarantee.
- Metal 4 command-API specifics on the shipping Tahoe SDK should be confirmed against current
  Apple docs at implementation time; the design assumes the Metal 4 encoder model but the
  render structure is unchanged if a detail has moved.
- Three displays at 8K is an extreme fill-rate case; the governor + MetalFX are the safety
  margin, validated against real frame-time measurement, not assumed.
