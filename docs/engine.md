# Engine overview

How one frame is produced, end to end. Source of truth for the runtime; pairs with
[config-reference.md](config-reference.md), [add-a-season.md](add-a-season.md), and
[sprite-recipe.md](sprite-recipe.md).

## Host

`SeasonsView: ScreenSaverView` ([Sources/SeasonsView.swift](../Sources/SeasonsView.swift)) backs
authorized surfaces with a two-drawable, render-only `CAMetalLayer`. Presentation defaults to SDR
`bgra10_xr_srgb` in Display-P3; `SEASONS_EDR=1` opts into `rgba16Float` extended-linear Display-P3.
Internal render targets remain linear `rgba16Float`. External Ultra-Lite overrides any process EDR request
and presents through `bgra8Unorm_srgb` in Display-P3.

A `CADisplayLink` (adaptive 20–120Hz) drives `displayTick → renderFrame`. External Ultra-Lite surfaces
start at 30 FPS and independently fall back to 20 FPS after repeated drawable misses, ≥25 ms GPU frames,
or ≥10 ms fair-scheduler waits; 15 healthy seconds restores 30 FPS. Planned multi-display surfaces share
a FIFO commit coordinator with at least 2 ms between admissions, so contention delays frames instead of
dropping and starving one display. With three Ultra-Lite externals, the built-in cap is 60 FPS.
`animateOneFrame` is a
slow fallback for contexts where the display link is inactive (the System Settings preview).
`startAnimation` is idempotent; `stopAnimation`/`deinit` call `teardown()` which releases the
renderer and timer so the framework's habit of re-instantiating the view can't leak a live GPU loop.
Installed external or unknown screens fail closed before a Metal device is attached. Off and Reduce
Motion present at most one atmosphere-only frame, then keep only a 30Hz lightweight state callback
with no ongoing command-buffer submission. Standalone hosts end the session if display topology changes.

Two or more authorized Ultra-Lite externals receive projections into one desktop-layout world. Each view
retains its own renderer, command queue, particle buffer, drawable, and post targets, but replicas share a
stable topology seed and integer 30 Hz tick. Tick zero seeds identical global state; fixed 1/30-second steps
keep replicas convergent at mixed 30/20 FPS presentation cadences. Vertex shaders subtract the per-display
camera origin before projection. Catch-up is bounded to 120 steps, and any synchronization, encoding, or
command-buffer failure invalidates the group so every peer fails closed. The built-in and directly hosted
`.saver` views remain independent.

The Metal library is loaded from the screensaver's **own** bundle
(`makeDefaultLibrary(bundle:)`), not `Bundle.main` — a `.saver` is a loadable bundle hosted by
another process, so `Bundle.main` is the host. Resource lookup uses an `NSObject`-rooted class so
`Bundle(for:)` resolves correctly inside the plugin host.

Selection precedence in `buildRenderer`: `SEASONS_FORCE` env (dev/preview) → persisted `Prefs.selection`
→ month-based auto ([SeasonCatalog](../Sources/SeasonCatalog.swift) `seasonByMonth`, matching the web
engine). `.off` selects the one-static-frame-then-idle policy. A missing config never crashes —
`displaySeason` falls back to any available season.

## Frame pipeline (`Renderer.renderInto`)

[Sources/Renderer.swift](../Sources/Renderer.swift) renders into an internal-resolution target,
then upscales:

1. **Governor feedback** — last frame's measured GPU time (`gpuEndTime − gpuStartTime`, from the
   command-buffer completion handler) is fed to the [Governor](../Sources/Governor.swift), which sets
   the internal render scale.
2. **Simulation** (skipped when `animate == false`) — a compute kernel
   ([Shaders/Particles.metal](../Shaders/Particles.metal) `stepParticles`) advances every particle:
   gravity-ish fall, sinusoidal sway, in-plane rotation, 3D-axis tumble, firefly pulse, edge-fade,
   respawn. State lives in one `MTLBuffer`. A PCG-style hash decorrelates per-particle streams.
3. **Backdrop + particles → scene + CoC** (one render pass, two attachments). `atmosphere` draws the
   graded backdrop; then either the lit mesh path (`meshVS`/`meshFS`: curved tessellated mesh skinned
   with sprite art, real normals, key + ambient + backlit translucency + specular) or the firefly glow
   path (`glowVS`/`glowFS`: additive EDR orbs). Both also write a coverage-weighted circle-of-confusion.
4. **Bloom, when enabled** — bright-pass → separable gaussian. Full quality uses the half/quarter/
   eighth pyramid; lite uses the half-res pair; disabled bloom allocates and encodes none of it.
5. **Scene blur, when DoF is enabled** — half-res gaussian of the scene. Disabled DoF allocates and
   encodes no scene-blur targets or passes.
6. **Composite** — `composite` blends sharp↔blurred by CoC (DOF), adds bloom, and applies exposure /
   saturation / vignette / grain. When bloom and DoF are both off, the dedicated
   `compositeNoEffects` path samples only scene color and retains no dummy effect textures. Either path
   writes straight to the drawable at native resolution, or to `graded` when upscaling is required.
7. **MetalFX** — when the internal size is below the drawable, `MTLFXSpatialScaler` (HDR mode)
   reconstructs `graded` and blits to the drawable. Native-scale frames allocate neither `graded` nor
   `upscaled`. External Ultra-Lite deliberately clamps the drawable itself to 2880px on its long edge
   (2880×1620 for 16:9), forces scale 1.0, uses 15% particles, and disables bloom, DoF, and EDR. A
   maximum-size scene+CoC pair occupies about 71.2 MiB per display; three at 30 FPS submit about
   419.9 million source pixels/s and retain about 213.6 MiB for those pairs.

## Color

OKLCH config values are converted to linear Display-P3 at load
([Sources/Color.swift](../Sources/Color.swift) `oklchToLinearP3`, unit-tested) and baked into the
`Season` struct, so there is no runtime color math and glow colors can exceed 1.0 for EDR.
PNG sprite art is decoded from sRGB to linear sRGB, varied there, then explicitly converted to the
linear Display-P3 working space. The image-only vivid profile raises opacity, midtone exposure, and chroma
within SDR bounds; glow and streak paths retain their authored behavior. Panoramic views disable drawable-UV
grain and vignette so those effects cannot repeat or form brightness seams. Black remains exactly zero.

## Sprite loading and minification

Season JSON is authoritative for every nested `spriteSet`/`spriteCount`. `SpriteLoader` loads the exact
contiguous `1.png..N.png` declaration atomically: the whole set is rejected if any file is missing,
undecodable, not an sRGB RGBA texture, or not exactly 1024×1024. Runtime arrays are always 1024px; there
is no 2048px runtime mode.

The loader creates every albedo mip in linear light. RGB is weighted by coverage so transparent border
colors cannot bleed into silhouettes, while RMS alpha conservatively preserves fine petal edges and
snow-crystal arms. Surface normal/thinness/AO maps are then derived independently at every filtered mip
instead of averaging encoded normals. Mesh rendering uses trilinear mip sampling with 16× anisotropy.
Repository validation is likewise JSON-driven: `python3 tools/validate_sprites.py --json` checks exact
declared counts, RGBA format, dimensions, transparent padding, centering, antialiased edges, and survival
through the acceptance mip.

## Targets

- **Seasons** (`.saver`) — the screensaver bundle.
- **SeasonsPreview** — standalone fullscreen app running the same view (current working delivery;
  Tahoe does not load third-party `.saver`s — see the repo README).
- **SeasonsShot** (`seasons-shot`) — headless PNG renderer for visual QA, no GUI.
- **SeasonsTests** — pure-logic units, including display safety, static and adaptive cadence,
  render-resource planning, fair concurrent submission spacing, panoramic layout/timing, and SDR color policy.
