# Seasons — native macOS ambient screensaver

A Metal screensaver that ports the seasonal particle effect from mdpj.me to native and
elevates it: real 3D lit tumbling particles, bloom, depth-of-field, and a cinematic graded
backdrop, per season. Auto-selects by month (winter→snow, spring→petals, summer→fireflies,
autumn→leaves).

**Status:** the visual engine is complete for all four seasons. The **Seasons** menu-bar app is
the daily-driver delivery: it starts the renderer after a chosen idle interval and supports Launch
at Login. The classic `.saver` builds and installs, but macOS 26 (Tahoe) does
not currently load third-party `.saver` bundles into its screensaver host (an OS-side issue —
no dlopen attempt is made; see `CHANGELOG.md`/plans).

**External displays:** fullscreen Metal output on external displays has kernel-panicked an M5 Max
on macOS 26.5.1 (AppleDCP `DCPEXT0`, see `docs/CRASH-ANALYSIS.md`). Rendering is therefore limited
to the built-in display by default, and external displays stay black. The External Ultra-Lite mode
is experimental and opt-in, so follow `docs/SAFE-TESTING.md` before enabling it, and use it at your
own risk.

## Prerequisites

- Xcode 26+, and the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`
- `xcodegen` (project generation), ImageMagick 7 (`magick`) for sprite processing
- An image generator capable of high-resolution photoreal source art (optional; raw art is
  committed under `tools/raw/`)

`project.yml` is the source of truth; the `.xcodeproj` is generated (`xcodegen generate`).

## Build & run

**Menu-bar app (recommended daily driver):**
```sh
xcodegen generate
xcodebuild -project Seasons.xcodeproj -scheme SeasonsApp -configuration Release \
  -derivedDataPath build/DerivedData build
mkdir -p "$HOME/Applications"
ditto "build/DerivedData/Build/Products/Release/Seasons.app" "$HOME/Applications/Seasons.app"
codesign --force --deep --sign - "$HOME/Applications/Seasons.app"
open "$HOME/Applications/Seasons.app"
```
Use the leaf menu to choose a season, idle delay, and **Launch at Login**. On an external-only Mac,
the default remains fail-closed black. After the staged tests in `docs/SAFE-TESTING.md` pass, enable
**External Displays — Ultra-Lite 30 FPS (Experimental)**. That app-scoped choice persists across
normal launches and login; the preview and legacy saver remain fail-closed unless separately
authorized for a deliberate test.

**Preview app (development):**
```sh
xcodegen generate
xcodebuild -project Seasons.xcodeproj -target SeasonsPreview -configuration Debug build
open "build/Debug/Seasons Preview.app"            # auto season by month
```
Force a specific season (Esc / click / any key quits):
```sh
"build/Debug/Seasons Preview.app/Contents/MacOS/Seasons Preview" spring   # winter|spring|summer|autumn|off
```

**Headless render to PNG** — fastest way to iterate on the look. Reads season JSON straight
from disk, so **config-only tweaks need no rebuild** (rebuild only after Swift/shader edits):
```sh
xcodebuild -project Seasons.xcodeproj -target SeasonsShot -configuration Debug build
build/Debug/seasons-shot Resources/seasons/spring.json Resources/sprites 0 /tmp/out.png 1280 800 150
build/Debug/seasons-shot Resources/seasons/summer.json - 0 /tmp/summer.png 1280 800 200   # glow season: "- 0"
# Ultra-Lite-sized performance sample (offscreen only; does not present to an external display):
/usr/bin/time -l build/Debug/seasons-shot Resources/seasons/autumn.json Resources/sprites 0 /tmp/autumn-2880.png 2880 1620 300
# args: <seasonJSON> <spriteBaseDir|-> <deprecatedCount> <out.png> <width> <height> <frames> [seqEvery]
```

The sprite path is the shared base directory (`Resources/sprites`), not an individual set folder;
the harness resolves every species' `spriteSet` beneath it and fails if any declared PNG is missing
or undecodable. The numeric count position remains for script compatibility but is ignored—each
species' `spriteCount` in the season JSON is authoritative, so pass `0`.
The harness always exits nonzero if a frame cannot be rendered. Set `SEASONS_PERF_ENFORCE=1` to
also fail a timed run when it records no GPU samples or its p95 GPU time reaches 25 ms.

**Install the `.saver`** (ad-hoc signed; may not load under Tahoe yet):
```sh
./install.sh        # builds, signs, copies to ~/Library/Screen Savers
```

**Tests** (pure-logic units, including display safety, render-resource planning, static cadence,
and concurrent submission spacing):
```sh
xcodegen generate
xcodebuild -project Seasons.xcodeproj -scheme Seasons -destination 'platform=macOS' build test
```

Before any live display test—especially with external monitors—follow
[docs/SAFE-TESTING.md](docs/SAFE-TESTING.md). The default policy never animates an external:
the built-in panel may animate while externals stay GPU-free black; clamshell/external-only setups
stay entirely black. External animation flags remain experimental and can still trigger the
documented AppleDCP/DCPEXT0 kernel panic.

The menu-bar app's persisted **External Displays — Ultra-Lite 30 FPS (Experimental)** option and
the deliberate `SEASONS_EXT_ULTRALITE=1` development hook both select the same bounded path. It
clamps each external to at most 2880×1620 at native
render scale, uses 15% of the configured particles, disables bloom, depth-of-field, and EDR, and
starts each external at 30 FPS. It fairly staggers all
planned display commits by at least 2 ms, falls back per display to 20 FPS under repeated pressure,
and returns to 30 FPS after 15 healthy seconds. With three Ultra-Lite externals, the built-in is capped
at 60 FPS. Two or more participating externals render camera crops of one deterministic particle world,
so particles can cross monitor boundaries while every drawable, queue, buffer, and post graph remains
per-display. Ultra-Lite presents sRGB-encoded BGRA8 in Display-P3 with EDR off; image sprites receive a
conservative vivid-SDR treatment while the background stays exact black. These controls prevent
synchronized displays from starving one another; they are not a safety guarantee. Three
2880×1620 drawables at 30 FPS are about 419.9 million source pixels/s, 2.25× the former 1920×1080
envelope. The retained scene+CoC pair is about 71.2 MiB per display, or 213.6 MiB for three.

## Tuning knobs

### 1. Season data — `Resources/seasons/<season>.json`
Per-season behavior. With the harness, edits take effect on the next `seasons-shot` run (no
rebuild); the app/saver bundle the JSON, so rebuild to see changes there.

| field | meaning |
|---|---|
| `count` | particle count |
| `sizeMin`/`sizeMax` | particle size range (points) |
| `vyMin`/`vyMax` | vertical velocity (fireflies use ± for bidirectional) |
| `vxMin`/`vxMax` | horizontal wander (fireflies); 0 enables no x-drift |
| `swayAmp`, `swayPeriodMin/Max` | sinusoidal sway amplitude + period |
| `rotate`/`rotateSpeed` | in-plane spin |
| `tumble`/`tumbleSpeed` | real 3D axis tumble |
| `glow`/`pulse` | fireflies: additive glow + breathing pulse |
| `spriteOpacity` | per-type opacity |
| `color`, `tint` | OKLCH `{L,C,H,alpha}` (baked to linear Display P3 at load) |
| `depthMin`/`depthMax` | parallax/DOF depth range (0.6–1.0) |
| `bloomThreshold` | bloom bright-pass knee |
| `bloomIntensity`, `dofStrength`, `edrHeadroom` | bloom/DOF/glow strength (note: mood values below currently override some globals) |
| `glyphType` | `image` (sprite mesh) or `glow` (procedural firefly) |
| `spriteSet`, `spriteCount` | sprite folder name + variant count |

### 2. Grade / lighting / atmosphere — `Sources/Renderer.swift`
- **`defaultLight()`** — `keyDir`, `keyIntensity`, `keyColor`, `ambientIntensity`,
  `ambientColor`, `translucency` (backlit petal glow), `specular`.
- **`atmosphere(for:)`** — per-season backdrop (`skyTop`, `skyBottom`, `glowColor`,
  `glowCenter`, `glowRadius`) and the global mood grade (`exposure`, `bloomIntensity`,
  `saturation`, `dofStrength`, `grain`, `vignette`).

### 3. Mesh curvature — `Sources/Mesh.swift` → `curl(for:)`
Per-season `cup` (bowl), `fold` (leaf midrib V), `curl` (lengthwise), `grid` (tessellation).

### 4. Shader math — `Shaders/`
- `Post.metal` — `composite()` (exposure/saturation/vignette/grain/DOF mix), `atmosphere()`
  backdrop, `brightPass`/`blur` bloom.
- `Particles.metal` — sim kernels (physics), `meshVS`/`meshFS` (lit mesh), `glowVS`/`glowFS`
  (firefly glow).

## Regenerate sprites

Recipe and prompts: `tools/generate-sprites.md`. Generate high-detail photoreal source art with
one isolated, fully visible object per image. **Use single-species, single-object prompts**—mixed
"variety" prompts tend to make clusters or composites. Save straight-alpha source PNGs as a strict,
contiguous `1.png..N.png` set under `tools/raw/<set>/`, then:
```sh
./tools/process-sprites.sh <set>         # atomic 1024px straight-alpha runtime-set replacement
python3 tools/validate_sprites.py --json # validate every JSON-declared set and count
```
Output lands in `Resources/sprites/<set>/`. Every season JSON is authoritative: its nested
`spriteSet`/`spriteCount` declarations must exactly match the runtime files. The loader rejects an
entire set if any declared image is missing, undecodable, non-sRGB RGBA, or not exactly 1024×1024.
At load time it builds alpha-weighted linear-light RGB / RMS-alpha mipmaps, bakes surface maps at
every mip, and samples them with 16× anisotropy. Runtime sprites remain 1024px; do not document or
ship a 2048px runtime path.

## Layout

```
project.yml              xcodegen source of truth (Seasons.saver, SeasonsPreview, SeasonsShot, SeasonsTests)
Sources/                 SeasonsView, Renderer, ParticleSystem, Mesh, SpriteLoader, Season, SeasonCatalog, Color
Shaders/                 ShaderTypes.h + Particles/Post/Common .metal
Resources/seasons/*.json season configs   Resources/sprites/<season>/   mesh albedo art
tools/                   generate-sprites.md, process-sprites.sh, pack-sprites.sh, raw/, shot/, preview/
docs/superpowers/        design spec + implementation plan
reference/               the original web engine (design baseline)
```

MetalFX adaptive upscaling, the performance governor, Reduce Motion idling, and fail-closed
multi-display isolation are implemented. Remaining delivery work includes the Tahoe `.saver`
host-loading issue and any future configuration UI refinements.

## License

MIT, see `LICENSE`.
