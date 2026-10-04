# Seasons Screensaver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native macOS `.saver` screensaver that ports the mdpj.me seasonal particle effect to Metal — four seasons, GPU-simulated particles, EDR/P3 color, bloom + DOF + grain, MetalFX adaptive upscaling, data-driven season configs — installed and running on an M5 Max under macOS 26 Tahoe.

**Architecture:** `ScreenSaverView` subclass backed by a `CAMetalLayer`, driven by `CADisplayLink` at adaptive 120Hz. Particles simulated in a Metal compute kernel over an `MTLBuffer`, drawn as instanced textured quads into an `RGBA16Float` linear-P3 HDR target, then bloom → DOF → composite over tint+grain → MetalFX temporal upscale → tonemap to an EDR drawable. Each season is a bundled JSON config; selection is month-based with a `configureSheet` override. A per-display performance governor flexes only the MetalFX input scale to hold frame rate.

**Tech Stack:** Swift 6, Metal 4 + MetalFX, ScreenSaverView, CoreAnimation (CAMetalLayer, CADisplayLink), SwiftUI (config sheet via NSHostingView), XCTest, fal.ai Ideogram v3 (sprite generation), ImageMagick 7 (sprite post-process).

---

## Verification modes

Each task is tagged:
- **[TDD]** — pure Swift logic. Write the failing XCTest first, watch it fail, implement, watch it pass.
- **[BUILD]** — compiles and links; verified by a successful `xcodebuild` and, where stated, by installing the `.saver` and observing it run / capturing a screenshot.

GPU and visual correctness cannot be asserted by a unit test honestly; those tasks use BUILD + observation. Do not fabricate unit tests for shader output.

## File structure

```
mac-screensaver/
  Seasons.xcodeproj
  Sources/
    SeasonsView.swift          ScreenSaverView subclass: lifecycle, CAMetalLayer, CADisplayLink, reduce-motion, preview detect
    Renderer.swift             Owns MTLDevice/queue, pipeline states, per-frame encode orchestration
    ParticleSystem.swift       Sim buffer alloc/seed, compute dispatch, SimParams
    PostChain.swift            Bloom, DOF, composite, MetalFX upscale, tonemap orchestration
    Governor.swift             [TDD] GPU-frame-time → renderScale closed loop (pure logic)
    Season.swift               [TDD] Codable Season struct + glyph/selection enums
    SeasonCatalog.swift        [TDD] load JSON configs from bundle, month→season, apply override
    Color.swift                [TDD] OKLCH → linear Display P3 conversion
    ConfigSheet.swift          SwiftUI override/quality UI hosted in an NSWindow
    Defaults.swift             ScreenSaverDefaults wrapper (selection + quality toggles)
  Shaders/
    Particles.metal            sim compute kernel + instanced vertex/fragment for sprites & glow
    Bloom.metal                bright-pass + separable gaussian
    DOF.metal                  depth-weighted blur
    Composite.metal            tint gradient + fractal grain + scene composite
    Tonemap.metal              linear-P3 → EDR drawable
    Common.metal               shared structs (Particle, SimParams) + helpers; header-shared with Swift
  Resources/
    seasons/winter.json spring.json summer.json autumn.json
    sprites/                   packed per-season textures (built by tools)
  SeasonsTests/
    ColorTests.swift SeasonTests.swift SeasonCatalogTests.swift GovernorTests.swift
  tools/
    generate-sprites.md        fal.ai recipe (documented, run via MCP)
    process-sprites.sh         ImageMagick trim/pad/resize/premultiply → 1024px PNG
    pack-sprites.sh            assemble per-season folders into Resources/sprites
  docs/
    engine.md add-a-season.md sprite-recipe.md config-reference.md
  install.sh                   ad-hoc sign + copy .saver to ~/Library/Screen Savers
```

Build order: Phase 0 assets → Phase 1 host skeleton → Phase 2 config/color logic → Phase 3 sim+render (autumn) → Phase 4 atmosphere → Phase 5 post FX → Phase 6 MetalFX + governor → Phase 7 reduce-motion/multi-display/preview → Phase 8 config sheet → Phase 9 other seasons → Phase 10 docs.

---

## Phase 0 — Sprite assets (all seasons up front)

### Task 0.1: Generate sprite sets via fal.ai — [BUILD]

**Files:**
- Create: `tools/generate-sprites.md`

- [ ] **Step 1: Record the recipe**

Write `tools/generate-sprites.md` capturing, verbatim, the three prompts and the prompt formula from `reference/sprite-prompts.md`, the fal.ai model id `fal-ai/ideogram/v3/generate-transparent`, params `aspect_ratio: "1:1"`, `rendering_speed: "QUALITY"`, and per-season `num_images` (snow 4, petals 6, leaves 5). Add a "new season" section that points at the formula.

- [ ] **Step 2: Generate snow, petals, leaves**

Using the fal.ai MCP (`mcp__fal-ai__generate`), run each season's prompt + negative_prompt at the documented params. Download the transparent PNGs to `tools/raw/<season>/`. Fireflies are procedural — no generation.

- [ ] **Step 3: Verify outputs**

Run: `for d in snow petals leaves; do echo "$d: $(ls tools/raw/$d/*.png 2>/dev/null | wc -l)"; done`
Expected: `snow: 4`, `petals: 6`, `leaves: 5` (counts may be higher if extra variants were generated; that is fine, pick the best later).

- [ ] **Step 4: Commit**

```bash
git add tools/generate-sprites.md tools/raw
git commit -m "feat: generate native sprite source art via fal.ai"
```

### Task 0.2: Post-process sprites to 1024px premultiplied PNG — [BUILD]

**Files:**
- Create: `tools/process-sprites.sh`, `tools/pack-sprites.sh`
- Create (output): `Resources/sprites/<season>/N.png`

- [ ] **Step 1: Write the post-process script**

```sh
#!/usr/bin/env bash
# tools/process-sprites.sh <season>
# Trim transparent margin, re-pad square, resize longest edge to 1024, premultiply alpha.
set -euo pipefail
season="${1:?usage: process-sprites.sh <season>}"
src="tools/raw/$season"
out="Resources/sprites/$season"
mkdir -p "$out"
i=1
for f in "$src"/*.png; do
  magick "$f" -trim +repage \
    -resize 1024x1024 -background none -gravity center -extent 1024x1024 \
    -define png:color-type=6 PNG32:"$out/$i.png"
  i=$((i+1))
done
echo "$season: wrote $((i-1)) sprites to $out"
```

Note: Metal premultiplies at sample time via blend state; storing straight-alpha PNG is correct here, so do not bake premultiplication into the PNG. The blend pipeline (Task 3.6) uses `.sourceAlpha`/`.oneMinusSourceAlpha`. Keep `-define png:color-type=6` (RGBA).

- [ ] **Step 2: Make executable and run for each season**

Run:
```bash
chmod +x tools/process-sprites.sh
for s in snow petals leaves; do ./tools/process-sprites.sh "$s"; done
```
Expected: three "wrote N sprites" lines matching 4/6/5.

- [ ] **Step 3: Write the pack note**

`tools/pack-sprites.sh` here is a thin verifier (textures are loaded individually into a `texture2d_array` at runtime from the per-season folder, so no offline atlas is required):

```sh
#!/usr/bin/env bash
# tools/pack-sprites.sh — verify each season folder has sequential 1..N PNGs at 1024px
set -euo pipefail
for season in snow petals leaves; do
  dir="Resources/sprites/$season"
  n=$(ls "$dir"/*.png 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] || { echo "FAIL: $season has no sprites"; exit 1; }
  dims=$(magick identify -format '%wx%h ' "$dir"/*.png)
  echo "$season ($n): $dims"
done
echo "OK"
```

- [ ] **Step 4: Verify**

Run: `chmod +x tools/pack-sprites.sh && ./tools/pack-sprites.sh`
Expected: each line ends with `1024x1024` dims and a final `OK`.

- [ ] **Step 5: Commit**

```bash
git add tools/process-sprites.sh tools/pack-sprites.sh Resources/sprites
git commit -m "feat: post-process sprites to 1024px native source"
```

---

## Phase 1 — Host skeleton (clears to a season tint, installs, runs)

### Task 1.1: Xcode `.saver` project that builds and installs — [BUILD]

**Files:**
- Create: `Seasons.xcodeproj` (screen-saver bundle target named `Seasons`, principal class `Seasons.SeasonsView`)
- Create: `Sources/SeasonsView.swift`
- Create: `install.sh`

- [ ] **Step 1: Create the project**

Create an Xcode project with a single target of type "Screen Saver" (bundle extension `.saver`), product name `Seasons`, Swift, deployment target macOS 26.0. In the target's Info, set `NSPrincipalClass` to `$(PRODUCT_MODULE_NAME).SeasonsView`. Add `Sources/` to the target.

- [ ] **Step 2: Minimal view that clears the layer**

```swift
// Sources/SeasonsView.swift
import ScreenSaver
import QuartzCore
import Metal

final class SeasonsView: ScreenSaverView {
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayLink: CADisplayLink?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .rgba16Float
        l.framebufferOnly = false
        l.wantsExtendedDynamicRangeContent = true
        l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        l.isOpaque = true
        return l
    }

    override func startAnimation() {
        super.startAnimation()
        let link = displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .current, forMode: .common)
        displayLink = link
    }

    override func stopAnimation() {
        super.stopAnimation()
        displayLink?.invalidate()
        displayLink = nil
    }

    override func animateOneFrame() { /* unused: CADisplayLink drives rendering */ }

    @objc private func tick() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let drawable = metalLayer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // autumn tint, linear-P3, slightly into EDR-safe range
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.03, blue: 0.02, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Seasons.xcodeproj -scheme Seasons -configuration Debug build`
Expected: `BUILD SUCCEEDED`, a `Seasons.saver` under the derived-data products dir.

- [ ] **Step 4: Write the install script**

```sh
#!/usr/bin/env bash
# install.sh — build, ad-hoc sign, install the .saver locally
set -euo pipefail
DERIVED=$(xcodebuild -project Seasons.xcodeproj -scheme Seasons -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
SAVER="$DERIVED/Seasons.saver"
xcodebuild -project Seasons.xcodeproj -scheme Seasons -configuration Debug build
codesign --force --deep --sign - "$SAVER"
DEST="$HOME/Library/Screen Savers/Seasons.saver"
rm -rf "$DEST"
cp -R "$SAVER" "$DEST"
echo "Installed to $DEST"
```

- [ ] **Step 5: Install and observe**

Run: `chmod +x install.sh && ./install.sh`
Then open System Settings → Wallpaper → Screen Saver, select Seasons, and confirm the preview shows a dark warm field (not black, not white). Capture a screenshot for the record.
Expected: install path printed; preview renders the warm-dark clear color.

- [ ] **Step 6: Commit**

```bash
git add Seasons.xcodeproj Sources/SeasonsView.swift install.sh
git commit -m "feat: scaffold Metal-backed .saver host with EDR drawable"
```

---

## Phase 2 — Config & color logic (pure Swift, real TDD)

### Task 2.1: OKLCH → linear Display P3 — [TDD]

**Files:**
- Create: `Sources/Color.swift`
- Test: `SeasonsTests/ColorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// SeasonsTests/ColorTests.swift
import XCTest
@testable import Seasons

final class ColorTests: XCTestCase {
    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 0.01) {
        XCTAssertEqual(a.x, b.x, accuracy: tol)
        XCTAssertEqual(a.y, b.y, accuracy: tol)
        XCTAssertEqual(a.z, b.z, accuracy: tol)
    }

    func testWhiteIsUnityInLinearP3() {
        // OKLCH L=1, C=0 is reference white → linear P3 (1,1,1)
        assertClose(oklchToLinearP3(L: 1.0, C: 0.0, H: 0.0), SIMD3(1, 1, 1))
    }

    func testBlackIsZero() {
        assertClose(oklchToLinearP3(L: 0.0, C: 0.0, H: 0.0), SIMD3(0, 0, 0))
    }

    func testMidGrayIsAchromatic() {
        let c = oklchToLinearP3(L: 0.5, C: 0.0, H: 0.0)
        XCTAssertEqual(c.x, c.y, accuracy: 0.001)
        XCTAssertEqual(c.y, c.z, accuracy: 0.001)
        XCTAssertGreaterThan(c.x, 0.0)
        XCTAssertLessThan(c.x, 1.0)
    }

    func testWarmAmberIsReddish() {
        // summer firefly base oklch(88% 0.16 95) → warm, R > B
        let c = oklchToLinearP3(L: 0.88, C: 0.16, H: 95)
        XCTAssertGreaterThan(c.x, c.z)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/ColorTests`
Expected: FAIL — `oklchToLinearP3` undefined.

- [ ] **Step 3: Implement the conversion**

```swift
// Sources/Color.swift
import simd

/// OKLCH (L in 0...1, C chroma, H degrees) → linear Display P3 (unclamped; values may exceed 1 for EDR).
func oklchToLinearP3(L: Float, C: Float, H: Float) -> SIMD3<Float> {
    let h = H * Float.pi / 180
    let a = C * cos(h)
    let b = C * sin(h)
    // OKLab → LMS'
    let l_ = L + 0.3963377774 * a + 0.2158037573 * b
    let m_ = L - 0.1055613458 * a - 0.0638541728 * b
    let s_ = L - 0.0894841775 * a - 1.2914855480 * b
    let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
    // LMS → linear sRGB (Björn Ottosson matrix)
    let rLin =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let gLin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let bLin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    // linear sRGB → linear Display P3 (D65, Bradford-adapted)
    let srgb = SIMD3<Float>(rLin, gLin, bLin)
    let m1 = SIMD3<Float>(0.82246197, 0.17753803, 0.0)
    let m2 = SIMD3<Float>(0.03319420, 0.96680580, 0.0)
    let m3 = SIMD3<Float>(0.01708263, 0.07239744, 0.91051993)
    return SIMD3<Float>(dot(m1, srgb), dot(m2, srgb), dot(m3, srgb))
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/ColorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Color.swift SeasonsTests/ColorTests.swift
git commit -m "feat: OKLCH to linear Display P3 conversion"
```

### Task 2.2: Season model + glyph/selection enums — [TDD]

**Files:**
- Create: `Sources/Season.swift`
- Test: `SeasonsTests/SeasonTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// SeasonsTests/SeasonTests.swift
import XCTest
@testable import Seasons

final class SeasonTests: XCTestCase {
    func testDecodeAutumnJSON() throws {
        let json = """
        {"name":"autumn","glyphType":"image","spriteSet":"leaves","spriteCount":5,
         "count":600,"sizeMin":12,"sizeMax":26,"vyMin":25,"vyMax":55,"vxMin":0,"vxMax":0,
         "swayAmp":32,"swayPeriodMin":4,"swayPeriodMax":8,
         "rotate":true,"rotateSpeed":0.7,"tumble":true,"tumbleSpeed":0.9,
         "glow":false,"pulse":false,"spriteOpacity":0.6,
         "color":{"L":0.72,"C":0.14,"H":50,"alpha":0.7},
         "tint":{"L":0.25,"C":0.04,"H":50,"alpha":0.15},
         "depthMin":0.6,"depthMax":1.0,
         "bloomThreshold":1.0,"bloomIntensity":0.4,"dofStrength":0.3,"edrHeadroom":1.0}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Season.self, from: json)
        XCTAssertEqual(s.name, "autumn")
        XCTAssertEqual(s.glyphType, .image)
        XCTAssertEqual(s.spriteSet, "leaves")
        XCTAssertEqual(s.count, 600)
        XCTAssertTrue(s.tumble)
        XCTAssertEqual(s.colorP3.w, 0.7, accuracy: 0.001)   // alpha preserved
        XCTAssertGreaterThan(s.colorP3.x, s.colorP3.z)       // warm: R>B
    }

    func testGlowSeasonHasNoSpriteSet() throws {
        let json = """
        {"name":"summer","glyphType":"glow","spriteCount":0,
         "count":400,"sizeMin":1.4,"sizeMax":2.6,"vyMin":-15,"vyMax":15,"vxMin":-15,"vxMax":15,
         "swayAmp":18,"swayPeriodMin":3,"swayPeriodMax":6,
         "rotate":false,"rotateSpeed":0,"tumble":false,"tumbleSpeed":0,
         "glow":true,"pulse":true,"spriteOpacity":1.0,
         "color":{"L":0.88,"C":0.16,"H":95,"alpha":0.65},
         "tint":{"L":0.25,"C":0.04,"H":95,"alpha":0.15},
         "depthMin":0.6,"depthMax":1.0,
         "bloomThreshold":0.8,"bloomIntensity":0.9,"dofStrength":0.2,"edrHeadroom":2.0}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Season.self, from: json)
        XCTAssertEqual(s.glyphType, .glow)
        XCTAssertNil(s.spriteSet)
        XCTAssertTrue(s.glow)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/SeasonTests`
Expected: FAIL — `Season` undefined.

- [ ] **Step 3: Implement the model**

```swift
// Sources/Season.swift
import simd

enum GlyphType: String, Codable { case image, glow }

enum SeasonID: String, CaseIterable, Codable {
    case winter, spring, summer, autumn
    var effect: String {
        switch self {
        case .winter: return "snow"
        case .spring: return "petals"
        case .summer: return "fireflies"
        case .autumn: return "leaves"
        }
    }
}

enum SeasonSelection: Equatable {
    case auto
    case fixed(SeasonID)
    case off
}

private struct OKLCHColor: Codable { let L, C, H, alpha: Float }

struct Season: Decodable {
    let name: String
    let glyphType: GlyphType
    let spriteSet: String?
    let spriteCount: Int
    let count: Int
    let sizeMin, sizeMax, vyMin, vyMax, vxMin, vxMax: Float
    let swayAmp, swayPeriodMin, swayPeriodMax: Float
    let rotate: Bool, rotateSpeed: Float
    let tumble: Bool, tumbleSpeed: Float
    let glow: Bool, pulse: Bool
    let spriteOpacity: Float
    let depthMin, depthMax: Float
    let bloomThreshold, bloomIntensity, dofStrength, edrHeadroom: Float
    let colorP3: SIMD4<Float>   // linear P3 rgb + straight alpha
    let tintP3: SIMD4<Float>

    private enum CodingKeys: String, CodingKey {
        case name, glyphType, spriteSet, spriteCount, count
        case sizeMin, sizeMax, vyMin, vyMax, vxMin, vxMax
        case swayAmp, swayPeriodMin, swayPeriodMax
        case rotate, rotateSpeed, tumble, tumbleSpeed, glow, pulse, spriteOpacity
        case depthMin, depthMax, bloomThreshold, bloomIntensity, dofStrength, edrHeadroom
        case color, tint
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        glyphType = try c.decode(GlyphType.self, forKey: .glyphType)
        spriteSet = try c.decodeIfPresent(String.self, forKey: .spriteSet)
        spriteCount = try c.decode(Int.self, forKey: .spriteCount)
        count = try c.decode(Int.self, forKey: .count)
        sizeMin = try c.decode(Float.self, forKey: .sizeMin)
        sizeMax = try c.decode(Float.self, forKey: .sizeMax)
        vyMin = try c.decode(Float.self, forKey: .vyMin)
        vyMax = try c.decode(Float.self, forKey: .vyMax)
        vxMin = try c.decode(Float.self, forKey: .vxMin)
        vxMax = try c.decode(Float.self, forKey: .vxMax)
        swayAmp = try c.decode(Float.self, forKey: .swayAmp)
        swayPeriodMin = try c.decode(Float.self, forKey: .swayPeriodMin)
        swayPeriodMax = try c.decode(Float.self, forKey: .swayPeriodMax)
        rotate = try c.decode(Bool.self, forKey: .rotate)
        rotateSpeed = try c.decode(Float.self, forKey: .rotateSpeed)
        tumble = try c.decode(Bool.self, forKey: .tumble)
        tumbleSpeed = try c.decode(Float.self, forKey: .tumbleSpeed)
        glow = try c.decode(Bool.self, forKey: .glow)
        pulse = try c.decode(Bool.self, forKey: .pulse)
        spriteOpacity = try c.decode(Float.self, forKey: .spriteOpacity)
        depthMin = try c.decode(Float.self, forKey: .depthMin)
        depthMax = try c.decode(Float.self, forKey: .depthMax)
        bloomThreshold = try c.decode(Float.self, forKey: .bloomThreshold)
        bloomIntensity = try c.decode(Float.self, forKey: .bloomIntensity)
        dofStrength = try c.decode(Float.self, forKey: .dofStrength)
        edrHeadroom = try c.decode(Float.self, forKey: .edrHeadroom)
        let col = try c.decode(OKLCHColor.self, forKey: .color)
        let tnt = try c.decode(OKLCHColor.self, forKey: .tint)
        let crgb = oklchToLinearP3(L: col.L, C: col.C, H: col.H)
        let trgb = oklchToLinearP3(L: tnt.L, C: tnt.C, H: tnt.H)
        colorP3 = SIMD4(crgb, col.alpha)
        tintP3 = SIMD4(trgb, tnt.alpha)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/SeasonTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Season.swift SeasonsTests/SeasonTests.swift
git commit -m "feat: season model decoding OKLCH config to P3"
```

### Task 2.3: Season catalog — month selection + bundle load + override — [TDD]

**Files:**
- Create: `Sources/SeasonCatalog.swift`
- Create: `Resources/seasons/autumn.json`
- Test: `SeasonsTests/SeasonCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// SeasonsTests/SeasonCatalogTests.swift
import XCTest
@testable import Seasons

final class SeasonCatalogTests: XCTestCase {
    func testSeasonByMonthMatchesWebEngine() {
        // web: Dec/Jan/Feb winter, Mar-May spring, Jun-Aug summer, else autumn (months 0-indexed)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(11), .winter)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(0), .winter)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(1), .winter)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(3), .spring)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(6), .summer)
        XCTAssertEqual(SeasonCatalog.seasonByMonth(9), .autumn)
    }

    func testResolveOverride() {
        XCTAssertEqual(SeasonCatalog.resolve(.fixed(.winter), month: 6), .winter)
        XCTAssertEqual(SeasonCatalog.resolve(.auto, month: 6), .summer)
    }

    func testResolveOffReturnsNil() {
        XCTAssertNil(SeasonCatalog.resolveActive(.off, month: 6))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/SeasonCatalogTests`
Expected: FAIL — `SeasonCatalog` undefined.

- [ ] **Step 3: Implement catalog + author autumn.json**

```swift
// Sources/SeasonCatalog.swift
import Foundation

enum SeasonCatalog {
    static func seasonByMonth(_ m: Int) -> SeasonID {
        if m == 11 || m == 0 || m == 1 { return .winter }
        if m >= 2 && m <= 4 { return .spring }
        if m >= 5 && m <= 7 { return .summer }
        return .autumn
    }

    /// The season id to display, ignoring `.off`.
    static func resolve(_ sel: SeasonSelection, month: Int) -> SeasonID {
        switch sel {
        case .auto: return seasonByMonth(month)
        case .fixed(let id): return id
        case .off: return seasonByMonth(month)
        }
    }

    /// nil when selection is `.off` (caller renders static atmosphere only).
    static func resolveActive(_ sel: SeasonSelection, month: Int) -> SeasonID? {
        if case .off = sel { return nil }
        return resolve(sel, month: month)
    }

    static func load(_ id: SeasonID, bundle: Bundle = Bundle(for: SeasonsView.self)) -> Season {
        let url = bundle.url(forResource: id.rawValue, withExtension: "json", subdirectory: "seasons")!
        return try! JSONDecoder().decode(Season.self, from: Data(contentsOf: url))
    }
}
```

Author `Resources/seasons/autumn.json` with exactly the field set the decoder expects (use the autumn values from `SeasonTests.testDecodeAutumnJSON`, `count: 600`). Add the JSON to the target's Copy Bundle Resources, preserving the `seasons/` folder reference.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/SeasonCatalogTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SeasonCatalog.swift Resources/seasons/autumn.json SeasonsTests/SeasonCatalogTests.swift
git commit -m "feat: season catalog with month selection and bundle load"
```

---

## Phase 3 — GPU simulation + instanced sprite render (autumn slice)

### Task 3.1: Shared GPU structs (Swift ↔ Metal) — [BUILD]

**Files:**
- Create: `Shaders/Common.metal` (and a bridging header `Shaders/ShaderTypes.h`)
- Modify: target build settings to set the Metal/ObjC bridging header

- [ ] **Step 1: Define shared structs in a C header**

```c
// Shaders/ShaderTypes.h
#ifndef ShaderTypes_h
#define ShaderTypes_h
#include <simd/simd.h>

typedef struct {
    simd_float2 pos;     // points in viewport space
    simd_float2 vel;     // vx, vy (points/sec)
    float phase, freq;
    float rot, vrot;
    float tumble, vtumble;
    float pulsePhase, pulseFreq;
    float depth;         // 0.6...1.0
    float size;          // base radius (points)
    float alphaJitter;   // 0.7...1.0
    uint  variant;
    uint  seed;
} Particle;

typedef struct {
    float dt, time;
    simd_float2 viewport;   // points
    float swayAmp;
    float topFade, botFade; // edge-fade margins (points): 60, 80 in web
    uint  count;
    uint  flags;            // bit0 rotate, bit1 tumble, bit2 pulse, bit3 firefly-wander
    float vyMin, vyMax, vxMin, vxMax;
    float sizeMin, sizeMax;
    float swayPeriodMin, swayPeriodMax;
    float rotateSpeed, tumbleSpeed, pulseFreqMin, pulseFreqMax;
    float depthMin, depthMax;
    uint  spriteCount;
} SimParams;
#endif
```

- [ ] **Step 2: Set bridging header & include it**

In target build settings set `SWIFT_OBJC_BRIDGING_HEADER = Shaders/ShaderTypes.h` so `Particle`/`SimParams` are visible to Swift. `Shaders/Common.metal` `#include "ShaderTypes.h"` and defines a `rand` helper:

```metal
// Shaders/Common.metal
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
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Seasons.xcodeproj -scheme Seasons -configuration Debug build`
Expected: `BUILD SUCCEEDED`; `Particle`/`SimParams` usable from Swift (verified next task).

- [ ] **Step 4: Commit**

```bash
git add Shaders/ShaderTypes.h Shaders/Common.metal
git commit -m "feat: shared GPU particle and sim-param structs"
```

### Task 3.2: ParticleSystem — buffer alloc + GPU seed/respawn + step kernel — [BUILD]

**Files:**
- Create: `Sources/ParticleSystem.swift`
- Modify: `Shaders/Particles.metal` (create)

- [ ] **Step 1: Write the sim kernel (mirrors `seasonal.js` frame())**

```metal
// Shaders/Particles.metal
#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;
// helpers from Common.metal are recompiled per file; redeclare rnd locally:
static inline float rnd(thread uint& s){ s = s*1664525u+1013904223u; return float(s>>8)/16777215.0; }
static inline float rr(thread uint& s, float a, float b){ return a + rnd(s)*(b-a); }

static void respawn(thread Particle& p, constant SimParams& P, bool fromTop) {
    uint s = p.seed;
    p.pos.x = rr(s, 0, P.viewport.x);
    p.pos.y = fromTop ? rr(s, -P.viewport.y*0.5, 0) : rr(s, 0, P.viewport.y);
    p.size  = rr(s, P.sizeMin, P.sizeMax);
    p.vel.y = rr(s, P.vyMin, P.vyMax);
    p.vel.x = (P.flags & 8u) ? rr(s, P.vxMin, P.vxMax) : 0.0;
    p.phase = rr(s, 0, 6.2831853);
    p.freq  = 6.2831853 / rr(s, P.swayPeriodMin, P.swayPeriodMax);
    p.rot   = (P.flags & 1u) ? rr(s, 0, 6.2831853) : 0.0;
    p.vrot  = (P.flags & 1u) ? rr(s, -P.rotateSpeed, P.rotateSpeed) : 0.0;
    p.tumble= (P.flags & 2u) ? rr(s, 0, 6.2831853) : 0.0;
    p.vtumble=(P.flags & 2u) ? rr(s, -P.tumbleSpeed, P.tumbleSpeed) : 0.0;
    p.pulsePhase = (P.flags & 4u) ? rr(s, 0, 6.2831853) : 0.0;
    p.pulseFreq  = (P.flags & 4u) ? 6.2831853 / rr(s, P.pulseFreqMin, P.pulseFreqMax) : 0.0;
    p.depth = rr(s, P.depthMin, P.depthMax);
    p.alphaJitter = rr(s, 0.7, 1.0);
    p.variant = uint(rnd(s) * float(max(P.spriteCount, 1u)));
    p.seed = s;
}

kernel void seedParticles(device Particle* ps [[buffer(0)]],
                           constant SimParams& P [[buffer(1)]],
                           uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle p; p.seed = i * 2654435761u + 1u;
    respawn(p, P, false);
    ps[i] = p;
}

kernel void stepParticles(device Particle* ps [[buffer(0)]],
                          constant SimParams& P [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
    if (i >= P.count) return;
    Particle p = ps[i];
    p.phase += p.freq * P.dt;
    p.pos.y += p.vel.y * p.depth * P.dt;
    float swayX = sin(p.phase) * P.swayAmp * p.depth;
    p.pos.x += (p.vel.x * p.depth * P.dt) + (swayX * P.dt * 0.4);
    if (P.flags & 1u) p.rot += p.vrot * P.dt;
    if (P.flags & 2u) p.tumble += p.vtumble * P.dt;
    if (P.flags & 4u) p.pulsePhase += p.pulseFreq * P.dt;
    float margin = p.size * 2.0;
    if (p.pos.y - margin > P.viewport.y || p.pos.x < -margin - 50.0 || p.pos.x > P.viewport.x + margin + 50.0) {
        respawn(p, P, true);
    }
    ps[i] = p;
}
```

- [ ] **Step 2: Implement ParticleSystem host**

```swift
// Sources/ParticleSystem.swift
import Metal

final class ParticleSystem {
    let buffer: MTLBuffer
    private let seedPSO: MTLComputePipelineState
    private let stepPSO: MTLComputePipelineState
    private(set) var params: SimParams
    private var seeded = false

    init(device: MTLDevice, library: MTLLibrary, season: Season, viewport: SIMD2<Float>) {
        let n = season.count
        buffer = device.makeBuffer(length: MemoryLayout<Particle>.stride * n,
                                    options: .storageModePrivate)!
        seedPSO = try! device.makeComputePipelineState(function: library.makeFunction(name: "seedParticles")!)
        stepPSO = try! device.makeComputePipelineState(function: library.makeFunction(name: "stepParticles")!)
        params = ParticleSystem.makeParams(season: season, viewport: viewport, dt: 0, time: 0)
    }

    static func makeParams(season s: Season, viewport: SIMD2<Float>, dt: Float, time: Float) -> SimParams {
        var p = SimParams()
        p.dt = dt; p.time = time; p.viewport = viewport
        p.swayAmp = s.swayAmp; p.topFade = 60; p.botFade = 80
        p.count = UInt32(s.count)
        var flags: UInt32 = 0
        if s.rotate { flags |= 1 }; if s.tumble { flags |= 2 }
        if s.pulse  { flags |= 4 }; if s.vxMin != 0 || s.vxMax != 0 { flags |= 8 }
        p.flags = flags
        p.vyMin = s.vyMin; p.vyMax = s.vyMax; p.vxMin = s.vxMin; p.vxMax = s.vxMax
        p.sizeMin = s.sizeMin; p.sizeMax = s.sizeMax
        p.swayPeriodMin = s.swayPeriodMin; p.swayPeriodMax = s.swayPeriodMax
        p.rotateSpeed = s.rotateSpeed; p.tumbleSpeed = s.tumbleSpeed
        p.pulseFreqMin = 2; p.pulseFreqMax = 4
        p.depthMin = s.depthMin; p.depthMax = s.depthMax
        p.spriteCount = UInt32(max(s.spriteCount, 1))
        return p
    }

    func step(_ enc: MTLComputeCommandEncoder, dt: Float, time: Float, viewport: SIMD2<Float>) {
        params.dt = dt; params.time = time; params.viewport = viewport
        let pso = seeded ? stepPSO : seedPSO
        seeded = true
        enc.setComputePipelineState(pso)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 1)
        let w = pso.threadExecutionWidth
        enc.dispatchThreads(MTLSize(width: Int(params.count), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Seasons.xcodeproj -scheme Seasons -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sources/ParticleSystem.swift Shaders/Particles.metal
git commit -m "feat: GPU particle simulation kernel and host"
```

### Task 3.3: Sprite texture-array loader — [BUILD]

**Files:**
- Create: `Sources/SpriteLoader.swift`

- [ ] **Step 1: Implement the loader**

```swift
// Sources/SpriteLoader.swift
import Metal
import MetalKit

enum SpriteLoader {
    /// Loads sprites/<set>/1..N.png into a mip-mapped texture2d_array. Returns nil for glow seasons.
    static func loadArray(set: String?, count: Int, device: MTLDevice,
                          bundle: Bundle = Bundle(for: SeasonsView.self)) -> MTLTexture? {
        guard let set, count > 0 else { return nil }
        let loader = MTKTextureLoader(device: device)
        var slices: [MTLTexture] = []
        for i in 1...count {
            guard let url = bundle.url(forResource: "\(i)", withExtension: "png",
                                       subdirectory: "sprites/\(set)") else { continue }
            let tex = try! loader.newTexture(URL: url, options: [
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .generateMipmaps: true, .SRGB: false])
            slices.append(tex)
        }
        guard let first = slices.first else { return nil }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = first.pixelFormat
        desc.width = first.width; desc.height = first.height
        desc.mipmapLevelCount = first.mipmapLevelCount
        desc.arrayLength = slices.count
        desc.storageMode = .private
        desc.usage = .shaderRead
        let array = device.makeTexture(descriptor: desc)!
        let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
        for (s, tex) in slices.enumerated() {
            for m in 0..<tex.mipmapLevelCount {
                blit.copy(from: tex, sourceSlice: 0, sourceLevel: m,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: max(1, tex.width >> m), height: max(1, tex.height >> m), depth: 1),
                          to: array, destinationSlice: s, destinationLevel: m,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
        }
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return array
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Seasons.xcodeproj -scheme Seasons -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sources/SpriteLoader.swift
git commit -m "feat: sprite texture-array loader with mipmaps"
```

### Task 3.4: Instanced sprite render pipeline + Renderer wiring — [BUILD]

**Files:**
- Modify: `Shaders/Particles.metal` (add vertex/fragment)
- Create: `Sources/Renderer.swift`
- Modify: `Sources/SeasonsView.swift` (delegate ticking to Renderer)

- [ ] **Step 1: Add the instanced sprite shaders**

```metal
// append to Shaders/Particles.metal
struct VSOut { float4 pos [[position]]; float2 uv; float alpha; uint variant; };

// Unit quad corners in [-0.5,0.5]
constant float2 QUAD[6] = { float2(-0.5,-0.5), float2(0.5,-0.5), float2(-0.5,0.5),
                            float2(0.5,-0.5),  float2(0.5,0.5),  float2(-0.5,0.5) };
constant float2 QUV[6]  = { float2(0,1), float2(1,1), float2(0,0),
                            float2(1,1), float2(1,0), float2(0,0) };

inline float edgeFade(float y, float h, float top, float bot) {
    float t = clamp((y + top) / top, 0.0, 1.0);
    float b = clamp((h - y) / bot, 0.0, 1.0);
    return min(t, b);
}

vertex VSOut spriteVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device Particle* ps [[buffer(0)]],
                      constant SimParams& P [[buffer(1)]]) {
    Particle p = ps[iid];
    float2 corner = QUAD[vid];
    float s = p.size * p.depth * 2.0;
    // rotate
    float cr = cos(p.rot), sr = sin(p.rot);
    float2 r = float2(corner.x*cr - corner.y*sr, corner.x*sr + corner.y*cr) * s;
    // tumble = real Y-axis foreshortening
    r.y *= cos(p.tumble);
    float2 pos = p.pos + r;
    // viewport (points) → clip space; y down → up
    float2 ndc = float2(pos.x / P.viewport.x * 2.0 - 1.0, 1.0 - pos.y / P.viewport.y * 2.0);
    VSOut o;
    o.pos = float4(ndc, 0, 1);
    o.uv = QUV[vid];
    o.alpha = p.alphaJitter * edgeFade(p.pos.y, P.viewport.y, P.topFade, P.botFade);
    o.variant = p.variant;
    return o;
}

fragment float4 spriteFS(VSOut in [[stage_in]],
                         texture2d_array<float> tex [[texture(0)]],
                         constant float4& colorP3 [[buffer(0)]],
                         constant float& spriteOpacity [[buffer(1)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float4 t = tex.sample(smp, in.uv, in.variant);
    float a = t.a * in.alpha * spriteOpacity * colorP3.a;
    return float4(t.rgb * a, a); // premultiplied output
}
```

- [ ] **Step 2: Implement Renderer (encodes sim + sprite pass to an HDR scene texture)**

```swift
// Sources/Renderer.swift
import Metal
import simd

final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let spritePSO: MTLRenderPipelineState
    private let system: ParticleSystem
    private let spriteArray: MTLTexture?
    private let season: Season
    private var scene: MTLTexture!
    private var lastTime: CFTimeInterval = CACurrentMediaTime()

    init(device: MTLDevice, season: Season, viewport: SIMD2<Float>) {
        self.device = device
        self.season = season
        queue = device.makeCommandQueue()!
        library = device.makeDefaultLibrary()!
        system = ParticleSystem(device: device, library: library, season: season, viewport: viewport)
        spriteArray = SpriteLoader.loadArray(set: season.spriteSet, count: season.spriteCount, device: device)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "spriteVS")
        desc.fragmentFunction = library.makeFunction(name: "spriteFS")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one          // premultiplied
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        spritePSO = try! device.makeRenderPipelineState(descriptor: desc)
    }

    private func ensureScene(_ size: SIMD2<Int>) {
        if let s = scene, s.width == size.x, s.height == size.y { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                    width: size.x, height: size.y, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        scene = device.makeTexture(descriptor: d)
    }

    /// Renders one frame into `drawable`. Post chain is added in later phases; for now blit scene → drawable.
    func render(to drawable: CAMetalDrawable, pixelSize: SIMD2<Int>, pointSize: SIMD2<Float>) {
        ensureScene(pixelSize)
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 0.05)); lastTime = now
        guard let cb = queue.makeCommandBuffer() else { return }

        if let ce = cb.makeComputeCommandEncoder() {
            system.step(ce, dt: dt, time: Float(now), viewport: pointSize)
            ce.endEncoding()
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let re = cb.makeRenderCommandEncoder(descriptor: pass), spriteArray != nil {
            re.setRenderPipelineState(spritePSO)
            re.setVertexBuffer(system.buffer, offset: 0, index: 0)
            var sp = system.params
            re.setVertexBytes(&sp, length: MemoryLayout<SimParams>.stride, index: 1)
            re.setFragmentTexture(spriteArray, index: 0)
            var color = season.colorP3; var op = season.spriteOpacity
            re.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            re.setFragmentBytes(&op, length: MemoryLayout<Float>.stride, index: 1)
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                              instanceCount: Int(system.params.count))
            re.endEncoding()
        }
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: scene, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x:0,y:0,z:0),
                      sourceSize: MTLSize(width: pixelSize.x, height: pixelSize.y, depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x:0,y:0,z:0))
            blit.endEncoding()
        }
        cb.present(drawable); cb.commit()
    }
}
```

- [ ] **Step 2b: Wire SeasonsView to Renderer**

Replace the `tick()` body in `SeasonsView.swift` to lazily build a `Renderer` from the resolved season (`SeasonCatalog.load(SeasonCatalog.resolve(.auto, month: Calendar.current.component(.month, from: Date()) - 1))`) and call `renderer.render(...)` with `pixelSize` from `drawableSize` and `pointSize` from `bounds.size`. Remove the placeholder clear-only encoder.

- [ ] **Step 3: Build, install, observe**

Run: `./install.sh`
Open the screensaver preview. Expected: autumn leaf sprites falling, tumbling, swaying, respawning from the top — recognizably the web effect at higher density, soft (sprites are not yet bloomed). Capture a screenshot.

- [ ] **Step 4: Commit**

```bash
git add Shaders/Particles.metal Sources/Renderer.swift Sources/SeasonsView.swift
git commit -m "feat: instanced sprite rendering of simulated particles"
```

---

## Phase 4 — Atmosphere (tint gradient + grain) under the particles

### Task 4.1: Composite pass — tint radial gradient + fractal grain — [BUILD]

**Files:**
- Create: `Shaders/Composite.metal`
- Modify: `Sources/PostChain.swift` (create), `Sources/Renderer.swift`

- [ ] **Step 1: Write the composite shader (full-screen triangle)**

```metal
// Shaders/Composite.metal
#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

struct CParams { float2 viewport; float time; float grainOpacity; float4 tintP3; float bg; };

struct FSV { float4 pos [[position]]; float2 uv; };
vertex FSV fsTri(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    FSV o; o.pos = float4(p[vid], 0, 1); o.uv = (p[vid]*0.5+0.5); o.uv.y = 1.0 - o.uv.y; return o;
}

inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float a = fract(sin(dot(i, float2(127.1,311.7)))*43758.5453);
    float b = fract(sin(dot(i+float2(1,0), float2(127.1,311.7)))*43758.5453);
    float c = fract(sin(dot(i+float2(0,1), float2(127.1,311.7)))*43758.5453);
    float d = fract(sin(dot(i+float2(1,1), float2(127.1,311.7)))*43758.5453);
    float2 u = f*f*(3.0-2.0*f);
    return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
}

// Renders atmosphere; scene particles are composited over this in a second draw (loadAction load).
fragment float4 atmosphere(FSV in [[stage_in]], constant CParams& P [[buffer(0)]]) {
    float2 uv = in.uv;
    // radial-ellipse tint at (0.5,0.2), 80% x / 50% y, fade to 0 by 70%
    float2 c = float2(0.5, 0.2);
    float2 d = (uv - c) / float2(0.8, 0.5);
    float r = length(d);
    float tintA = (1.0 - smoothstep(0.0, 0.7, r)) * P.tintP3.a;
    float3 base = float3(P.bg);
    float3 col = base + P.tintP3.rgb * tintA;
    // grain
    float g = vnoise(uv * P.viewport * 0.5 + P.time);
    col += (g - 0.5) * P.grainOpacity;
    return float4(col, 1.0);
}
```

`bg` = the dark base `oklch(12% 0 0)` → linear value; compute once on the Swift side via `oklchToLinearP3(L:0.12,C:0,H:0).x`. `grainOpacity` = 0.035.

- [ ] **Step 2: PostChain renders atmosphere into scene before particles**

Implement `PostChain.atmosphere(_ cb:, into scene:, params:)` that runs the `fsTri`/`atmosphere` pipeline with `loadAction = .clear`. Change `Renderer.render` to: (1) compute pass (sim), (2) atmosphere pass into `scene` (clear), (3) sprite pass into `scene` with `loadAction = .load` so particles composite over the tint, (4) blit to drawable. Move the sprite pass's `loadAction` to `.load`.

- [ ] **Step 3: Build, install, observe**

Run: `./install.sh`
Expected: leaves now fall over a dark field with a soft warm-orange glow at top-center and faint grain texture — matches `atmosphere.css` intent. Screenshot.

- [ ] **Step 4: Commit**

```bash
git add Shaders/Composite.metal Sources/PostChain.swift Sources/Renderer.swift
git commit -m "feat: atmosphere tint gradient and grain under particles"
```

---

## Phase 5 — Post FX (bloom, DOF)

### Task 5.1: Bloom (bright-pass + separable gaussian) — [BUILD]

**Files:**
- Create: `Shaders/Bloom.metal`
- Modify: `Sources/PostChain.swift`, `Sources/Renderer.swift`

- [ ] **Step 1: Write bloom shaders**

```metal
// Shaders/Bloom.metal
#include <metal_stdlib>
using namespace metal;
struct FSV { float4 pos [[position]]; float2 uv; };
vertex FSV bloomTri(uint vid [[vertex_id]]) {
    float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    FSV o; o.pos=float4(p[vid],0,1); o.uv=p[vid]*0.5+0.5; o.uv.y=1-o.uv.y; return o;
}
fragment float4 brightPass(FSV in [[stage_in]], texture2d<float> src [[texture(0)]],
                           constant float& threshold [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    float3 c = src.sample(s, in.uv).rgb;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    return float4(c * max(0.0, lum - threshold) / max(lum, 1e-4), 1.0);
}
fragment float4 blur(FSV in [[stage_in]], texture2d<float> src [[texture(0)]],
                     constant float2& dir [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    float w[5] = {0.227027,0.194594,0.121622,0.054054,0.016216};
    float2 texel = dir / float2(src.get_width(), src.get_height());
    float3 c = src.sample(s, in.uv).rgb * w[0];
    for (int i=1;i<5;i++){ c += src.sample(s, in.uv + texel*float(i)).rgb*w[i];
                           c += src.sample(s, in.uv - texel*float(i)).rgb*w[i]; }
    return float4(c,1.0);
}
fragment float4 bloomComposite(FSV in [[stage_in]], texture2d<float> scene [[texture(0)]],
                               texture2d<float> bloom [[texture(1)]], constant float& intensity [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    return float4(scene.sample(s,in.uv).rgb + bloom.sample(s,in.uv).rgb*intensity, 1.0);
}
```

- [ ] **Step 2: PostChain bloom orchestration**

Add `PostChain.bloom(_ cb:, scene:, threshold:, intensity:) -> MTLTexture` that allocates half-res ping-pong textures (rgba16Float), runs brightPass → horizontal blur (dir=(1,0)) → vertical blur (dir=(0,1)) → returns the blur result, then a `bloomComposite` into a full-res output. Wire into `Renderer.render` after the sprite pass, before blit, using `season.bloomThreshold` / `season.bloomIntensity`.

- [ ] **Step 3: Build, install, observe**

Run: `./install.sh`
Expected: leaf highlights and bright edges glow softly; the look is richer but still restrained. Screenshot. Confirm no runaway over-bloom (adjust `bloomIntensity` in `autumn.json` if needed).

- [ ] **Step 4: Commit**

```bash
git add Shaders/Bloom.metal Sources/PostChain.swift Sources/Renderer.swift
git commit -m "feat: bloom post pass for EDR highlights"
```

### Task 5.2: Depth-of-field (depth-weighted blur) — [BUILD]

**Files:**
- Create: `Shaders/DOF.metal`
- Modify: `Sources/PostChain.swift`, `Sources/Renderer.swift`, `Shaders/Particles.metal`

- [ ] **Step 1: Write depth to an auxiliary target**

Add a second color attachment to the sprite pass that writes per-pixel `depth` (the particle's `depth`, 0.6..1) so DOF knows near/far. In `spriteFS`, output `float4(depth)` to `[[color(1)]]`; declare a struct with two outputs. The scene render pass gains a second `rgba16Float` (or `r16Float`) attachment.

- [ ] **Step 2: Write DOF shader**

```metal
// Shaders/DOF.metal
#include <metal_stdlib>
using namespace metal;
struct FSV { float4 pos [[position]]; float2 uv; };
vertex FSV dofTri(uint vid [[vertex_id]]) {
    float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    FSV o; o.pos=float4(p[vid],0,1); o.uv=p[vid]*0.5+0.5; o.uv.y=1-o.uv.y; return o;
}
// Circle-of-confusion grows for far particles (depth→0.6). focus plane at depth=1 (nearest).
fragment float4 dof(FSV in [[stage_in]], texture2d<float> scene [[texture(0)]],
                    texture2d<float> depth [[texture(1)]], constant float& strength [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    float d = depth.sample(s, in.uv).r;
    float coc = clamp((1.0 - d) / 0.4, 0.0, 1.0) * strength;     // 0 at near, →strength at far
    float2 texel = coc * 4.0 / float2(scene.get_width(), scene.get_height());
    float3 c = scene.sample(s, in.uv).rgb * 0.4;
    c += scene.sample(s, in.uv+float2(texel.x,0)).rgb*0.15;
    c += scene.sample(s, in.uv-float2(texel.x,0)).rgb*0.15;
    c += scene.sample(s, in.uv+float2(0,texel.y)).rgb*0.15;
    c += scene.sample(s, in.uv-float2(0,texel.y)).rgb*0.15;
    return float4(c, 1.0);
}
```

- [ ] **Step 3: Wire DOF before bloom**

In `Renderer.render`, order becomes: sim → atmosphere → sprites (writes color + depth) → DOF (scene+depth → scene') → bloom(scene') → blit. Use `season.dofStrength`.

- [ ] **Step 4: Build, install, observe**

Run: `./install.sh`
Expected: far (smaller, slower) leaves are gently soft; near leaves crisp — subtle depth separation, not heavy. Screenshot.

- [ ] **Step 5: Commit**

```bash
git add Shaders/DOF.metal Shaders/Particles.metal Sources/PostChain.swift Sources/Renderer.swift
git commit -m "feat: depth-of-field weighted by particle depth"
```

---

## Phase 6 — MetalFX upscaling + performance governor

### Task 6.1: Governor logic — [TDD]

**Files:**
- Create: `Sources/Governor.swift`
- Test: `SeasonsTests/GovernorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// SeasonsTests/GovernorTests.swift
import XCTest
@testable import Seasons

final class GovernorTests: XCTestCase {
    func testScaleDropsWhenOverBudget() {
        var g = Governor(targetFrameTime: 1.0/120.0)   // 8.33ms
        let s0 = g.scale
        // simulate slow frames (16ms) → must reduce scale
        for _ in 0..<10 { g.record(gpuFrameTime: 0.016) }
        XCTAssertLessThan(g.scale, s0)
    }
    func testScaleRecoversWhenUnderBudget() {
        var g = Governor(targetFrameTime: 1.0/120.0)
        for _ in 0..<10 { g.record(gpuFrameTime: 0.016) }      // drop first
        let low = g.scale
        for _ in 0..<60 { g.record(gpuFrameTime: 0.003) }      // plenty of headroom
        XCTAssertGreaterThan(g.scale, low)
    }
    func testScaleClampedToBounds() {
        var g = Governor(targetFrameTime: 1.0/120.0)
        for _ in 0..<200 { g.record(gpuFrameTime: 0.5) }       // absurdly slow
        XCTAssertGreaterThanOrEqual(g.scale, 0.5)
        for _ in 0..<400 { g.record(gpuFrameTime: 0.0001) }    // absurdly fast
        XCTAssertLessThanOrEqual(g.scale, 1.0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/GovernorTests`
Expected: FAIL — `Governor` undefined.

- [ ] **Step 3: Implement the governor**

```swift
// Sources/Governor.swift
/// Closed loop: nudges MetalFX input scale to hold GPU frame time near target.
/// Scale is the ONLY knob; particle count and FX never change.
struct Governor {
    private(set) var scale: Float = 1.0
    private let target: Float
    private let minScale: Float
    private let maxScale: Float
    private var ema: Float = 0
    private var warmed = false

    init(targetFrameTime: Float, minScale: Float = 0.5, maxScale: Float = 1.0) {
        target = targetFrameTime; self.minScale = minScale; self.maxScale = maxScale
    }

    mutating func record(gpuFrameTime t: Float) {
        ema = warmed ? (ema * 0.9 + t * 0.1) : t
        warmed = true
        if ema > target * 1.1 {
            scale = max(minScale, scale - 0.02)
        } else if ema < target * 0.7 {
            scale = min(maxScale, scale + 0.005)   // recover slowly
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/GovernorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Governor.swift SeasonsTests/GovernorTests.swift
git commit -m "feat: performance governor for adaptive render scale"
```

### Task 6.2: MetalFX temporal upscaling wired to the governor — [BUILD]

**Files:**
- Modify: `Sources/Renderer.swift`, `Sources/PostChain.swift`

- [ ] **Step 1: Add MetalFX temporal scaler**

Import `MetalFX`. Render the scene + post chain at internal size `floor(pixelSize * governor.scale)`, then run an `MTLFXTemporalScaler` (created via `MTLFXTemporalScalerDescriptor`, `colorTextureFormat`/`outputTextureFormat = .rgba16Float`, `inputWidth/Height` = internal, `outputWidth/Height` = drawable) to reconstruct to full `pixelSize`, writing into the drawable. Provide motion vectors as zero-filled for v1 (particles are small; jitter the projection per-frame via the scaler's `jitterOffset`). Feed `gpuFrameTime` from `cb.gpuEndTime - cb.gpuStartTime` (read in the command-buffer completion handler) into `governor.record`.

- [ ] **Step 2: Build, install, observe (single display)**

Run: `./install.sh`
Expected: visually unchanged at 4K (scale stays ~1.0 on an M5 Max for one display). Confirm smooth motion. Screenshot.

- [ ] **Step 3: Observe under load (multi-display proxy)**

If only one display is available during dev, temporarily force `internal size = pixelSize * 0.6` to confirm MetalFX reconstruction looks clean (no smearing on the small particles), then revert to governor-driven scale.
Expected: reconstructed image is sharp; motion is stable.

- [ ] **Step 4: Commit**

```bash
git add Sources/Renderer.swift Sources/PostChain.swift
git commit -m "feat: MetalFX temporal upscaling driven by governor"
```

---

## Phase 7 — Reduce Motion, multi-display, preview

### Task 7.1: Reduce Motion → static atmosphere — [BUILD]

**Files:**
- Modify: `Sources/SeasonsView.swift`, `Sources/Renderer.swift`

- [ ] **Step 1: Branch on accessibility setting**

In `SeasonsView`, read `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` at `startAnimation` and observe `NSWorkspace.shared.notificationCenter` for `accessibilityDisplayOptionsDidChangeNotification`. Add `Renderer.renderStatic(to:pixelSize:pointSize:)` that runs only the atmosphere pass (no sim, no particles, no post) and blits. When reduce-motion is on, the display-link tick calls `renderStatic`; otherwise `render`. Keep the display link running but the static path is cheap.

- [ ] **Step 2: Build, observe**

Run: `./install.sh`
Toggle System Settings → Accessibility → Display → Reduce Motion ON, reopen the screensaver preview. Expected: static tinted gradient + grain, zero particle motion. Toggle OFF: particles return. Screenshots of both.

- [ ] **Step 3: Commit**

```bash
git add Sources/SeasonsView.swift Sources/Renderer.swift
git commit -m "feat: honor Reduce Motion with static atmosphere"
```

### Task 7.2: Per-display isolation + preview detection + idempotent teardown — [BUILD]

**Files:**
- Modify: `Sources/SeasonsView.swift`

- [ ] **Step 1: Per-instance state + preview heuristic + teardown**

Confirm each `SeasonsView` owns its own `Renderer`, `CADisplayLink`, and `Governor` (instance properties — already the case). Add `isLikelyPreview`: `isPreview || bounds.width < 480` (mitigates the Tahoe `isPreview` bug). When likely-preview, cap particle count to `min(season.count, 200)` by loading a count-scaled copy of the season for that instance, and clamp the display link to 60Hz. In `stopAnimation` and `deinit`, invalidate the display link, nil the renderer, and drop GPU references so a re-instantiated view never runs two live renderers. Guard `startAnimation` so a second call without an intervening `stopAnimation` is a no-op.

- [ ] **Step 2: Build, observe (preview + full + multi-display if available)**

Run: `./install.sh`
Expected: System Settings preview thumbnail renders (even with the `isPreview` bug, the small-size heuristic catches it); full-screen run is full density; on a multi-monitor rig each screen runs its own field. Screenshot the preview and a full-screen run.

- [ ] **Step 3: Commit**

```bash
git add Sources/SeasonsView.swift
git commit -m "feat: per-display isolation, preview detection, idempotent teardown"
```

---

## Phase 8 — Config sheet (season override + quality toggles)

### Task 8.1: Defaults wrapper — [TDD]

**Files:**
- Create: `Sources/Defaults.swift`
- Test: extend `SeasonsTests/SeasonCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// add to SeasonsTests/SeasonCatalogTests.swift
func testSelectionRoundTrips() {
    XCTAssertEqual(SeasonSelection(storage: "auto"), .auto)
    XCTAssertEqual(SeasonSelection(storage: "off"), .off)
    XCTAssertEqual(SeasonSelection(storage: "winter"), .fixed(.winter))
    XCTAssertEqual(SeasonSelection.auto.storage, "auto")
    XCTAssertEqual(SeasonSelection.fixed(.summer).storage, "summer")
    XCTAssertEqual(SeasonSelection(storage: "garbage"), .auto)  // safe default
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/SeasonCatalogTests/testSelectionRoundTrips`
Expected: FAIL — `SeasonSelection(storage:)` undefined.

- [ ] **Step 3: Implement storage mapping + ScreenSaverDefaults wrapper**

```swift
// Sources/Defaults.swift
import ScreenSaver

extension SeasonSelection {
    init(storage: String) {
        switch storage {
        case "off": self = .off
        case "auto": self = .auto
        default:
            if let id = SeasonID(rawValue: storage) { self = .fixed(id) } else { self = .auto }
        }
    }
    var storage: String {
        switch self {
        case .auto: return "auto"
        case .off: return "off"
        case .fixed(let id): return id.rawValue
        }
    }
}

enum Prefs {
    private static let domain = "me.mdpj.Seasons"
    private static var d: ScreenSaverDefaults { ScreenSaverDefaults(forModuleWithName: domain)! }
    static var selection: SeasonSelection {
        get { SeasonSelection(storage: d.string(forKey: "selection") ?? "auto") }
        set { d.set(newValue.storage, forKey: "selection"); d.synchronize() }
    }
    static var bloom: Bool {
        get { d.object(forKey: "bloom") == nil ? true : d.bool(forKey: "bloom") }
        set { d.set(newValue, forKey: "bloom"); d.synchronize() }
    }
    static var dof: Bool {
        get { d.object(forKey: "dof") == nil ? true : d.bool(forKey: "dof") }
        set { d.set(newValue, forKey: "dof"); d.synchronize() }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Seasons.xcodeproj -scheme Seasons -only-testing:SeasonsTests/SeasonCatalogTests`
Expected: PASS (all catalog tests including the new one).

- [ ] **Step 5: Commit**

```bash
git add Sources/Defaults.swift SeasonsTests/SeasonCatalogTests.swift
git commit -m "feat: defaults wrapper for selection and quality toggles"
```

### Task 8.2: SwiftUI config sheet via configureSheet — [BUILD]

**Files:**
- Create: `Sources/ConfigSheet.swift`
- Modify: `Sources/SeasonsView.swift`

- [ ] **Step 1: Implement the SwiftUI panel + NSWindow host**

```swift
// Sources/ConfigSheet.swift
import SwiftUI
import AppKit

struct ConfigView: View {
    @State private var selection = Prefs.selection.storage
    @State private var bloom = Prefs.bloom
    @State private var dof = Prefs.dof
    let onClose: () -> Void

    private let options = ["auto","winter","spring","summer","autumn","off"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Seasons").font(.title2.bold())
            Picker("Season", selection: $selection) {
                ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
            }.pickerStyle(.menu)
            Toggle("Bloom", isOn: $bloom)
            Toggle("Depth of field", isOn: $dof)
            HStack { Spacer()
                Button("Done") {
                    Prefs.selection = SeasonSelection(storage: selection)
                    Prefs.bloom = bloom; Prefs.dof = dof
                    onClose()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 360)
    }
}

final class ConfigSheetController {
    static func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: ConfigView { NSApp.endSheet(win) })
        return win
    }
}
```

- [ ] **Step 2: Expose configureSheet + apply selection on launch**

In `SeasonsView`: `override var hasConfigureSheet: Bool { true }` and `override var configureSheet: NSWindow? { ConfigSheetController.makeWindow() }`. In the renderer-build path, resolve the active season from `Prefs.selection` (use `SeasonCatalog.resolveActive`; if nil → reduce to the static atmosphere path, mirroring `?effect=off`). Pass `Prefs.bloom`/`Prefs.dof` into the post chain to gate those passes.

- [ ] **Step 3: Build, observe**

Run: `./install.sh`
Open the screensaver's Options/settings button. Expected: the panel appears; choosing Winter then Done switches the effect (will show snow once Phase 9 lands; until then it loads the season config and runs the engine against whatever sprites exist — autumn remains until winter.json is added). Setting Off → static atmosphere. Toggling Bloom/DOF off visibly removes those passes. Screenshot the panel.

- [ ] **Step 4: Commit**

```bash
git add Sources/ConfigSheet.swift Sources/SeasonsView.swift
git commit -m "feat: SwiftUI configuration sheet for season and quality"
```

---

## Phase 9 — Remaining three seasons (config + sprites only)

### Task 9.1: Author winter, spring, summer configs — [BUILD]

**Files:**
- Create: `Resources/seasons/winter.json`, `spring.json`, `summer.json`

- [ ] **Step 1: Author the three JSON configs**

Carry the web `CONFIGS` values forward into the native schema (counts scaled up for the cinematic-faithful target, e.g. snow ~700, petals ~500, summer fireflies ~400):
- `winter.json`: `glyphType:"image"`, `spriteSet:"snow"`, `spriteCount:4`, `color` `oklch(0.95,0,0,0.75)`, `tint` `oklch(0.25,0.03,230,0.15)`, slow `vy` 18–45, `swayAmp` 14, `rotate:true rotateSpeed:0.25`, `tumble:false`, `glow:false pulse:false`, `bloomIntensity` ~0.3.
- `spring.json`: `spriteSet:"petals"`, `spriteCount:6`, `color` `oklch(0.92,0.06,25,0.6)`, `tint` `oklch(0.25,0.04,25,0.15)`, `vy` 10–25, `swayAmp` 28, `rotate:true 0.4`, `tumble:true 0.6`.
- `summer.json`: `glyphType:"glow"`, `spriteSet:null`, `spriteCount:0`, `color` `oklch(0.88,0.16,95,0.65)`, `tint` `oklch(0.25,0.04,95,0.15)`, `vy` -15..15, `vx` -15..15, `swayAmp` 18, `glow:true pulse:true`, `edrHeadroom` 2.0, `bloomIntensity` ~0.9.

Add all three to Copy Bundle Resources under `seasons/`.

- [ ] **Step 2: Build, install, observe each**

Run: `./install.sh`, then via the config sheet select Winter, Spring, Summer in turn.
Expected: Winter = drifting snow; Spring = tumbling petals; Summer = pulsing glowing fireflies wandering both directions (no sprite, pure bloom blobs — see Task 9.2). Screenshot each.

- [ ] **Step 3: Commit**

```bash
git add Resources/seasons/winter.json Resources/seasons/spring.json Resources/seasons/summer.json
git commit -m "feat: winter, spring, summer season configs"
```

### Task 9.2: Firefly glow render path (no sprite) — [BUILD]

**Files:**
- Modify: `Shaders/Particles.metal`, `Sources/Renderer.swift`

- [ ] **Step 1: Add a glow fragment + additive pipeline**

```metal
// append to Shaders/Particles.metal
fragment float4 glowFS(VSOut in [[stage_in]], constant float4& colorP3 [[buffer(0)]],
                       constant float& headroom [[buffer(1)]]) {
    float2 d = in.uv * 2.0 - 1.0;
    float r2 = dot(d, d);
    float core = exp(-r2 * 6.0);                 // soft radial falloff
    float a = core * in.alpha * colorP3.a;
    float3 rgb = colorP3.rgb * headroom * core;  // push into EDR
    return float4(rgb * a, a);
}
```

- [ ] **Step 2: Select glow pipeline for glow seasons**

In `Renderer`, when `season.glyphType == .glow`, build a second render pipeline using `spriteVS` + `glowFS` with additive blend (`sourceRGB=.one`, `destRGB=.one`) and use it instead of the sprite pipeline; bind `season.colorP3` and `season.edrHeadroom`. No texture array. The pulse-driven alpha already comes through `alphaJitter`/`pulse` in the sim — extend `spriteVS` to fold `pulsePhase` into `o.alpha` when pulse flag set: `alpha *= (0.3 + 0.5*(0.5+0.5*sin(p.pulsePhase)))`.

- [ ] **Step 3: Build, install, observe summer**

Run: `./install.sh`, select Summer.
Expected: fireflies as soft glowing blobs, breathing (pulsing) alpha, drifting both up and down, blooming brightly against the dark amber field on the XDR panel. Screenshot.

- [ ] **Step 4: Commit**

```bash
git add Shaders/Particles.metal Sources/Renderer.swift
git commit -m "feat: procedural firefly glow render path"
```

### Task 9.3: Full four-season verification pass — [BUILD]

**Files:** none (verification only)

- [ ] **Step 1: Cycle all four + auto + off**

Run: `./install.sh`. Via the config sheet, verify in turn: Auto (matches current month → autumn), Winter, Spring, Summer, Autumn, Off. For each, confirm correct effect, no flicker on switch, stable motion, bloom/DOF behaving, reduce-motion still falls back. Capture one screenshot per mode (6 total).

- [ ] **Step 2: Confirm no leaked renderers**

Run the screensaver, exit, re-enter several times; confirm via Activity Monitor that `legacyScreenSaver` CPU/GPU returns to idle on exit (no doubled load), validating idempotent teardown.

- [ ] **Step 3: Commit a verification note**

```bash
# no code change; record the pass in CHANGELOG under Unreleased
git add CHANGELOG.md
git commit -m "test: verify all four seasons, auto, and off modes"
```

---

## Phase 10 — Documentation

### Task 10.1: Write the engine, extension, recipe, and config docs — [BUILD]

**Files:**
- Create: `docs/engine.md`, `docs/add-a-season.md`, `docs/sprite-recipe.md`, `docs/config-reference.md`

- [ ] **Step 1: docs/engine.md**

Document the runtime: ScreenSaverView host + CADisplayLink, the compute-sim → atmosphere → sprite/glow → DOF → bloom → MetalFX → drawable pipeline, the governor, EDR/P3 color path, and the file map. Explain the frame loop end to end so a cold reader can trace one frame.

- [ ] **Step 2: docs/add-a-season.md**

Step-by-step: (1) generate sprites via `tools/generate-sprites.md` recipe, (2) post-process with `process-sprites.sh`, (3) drop folder in `Resources/sprites/<name>`, (4) author `Resources/seasons/<name>.json` (point to `config-reference.md`), (5) add to the config sheet options array and `SeasonID` if it is a new season id, (6) `./install.sh`. State explicitly that no engine/shader code changes are needed for a same-mechanics season.

- [ ] **Step 3: docs/sprite-recipe.md**

The fal.ai prompt template (the formula from `reference/sprite-prompts.md`), the model/params, the ImageMagick post-process command, and the 1024px/premultiply/array-packing rationale. Include the exact prompts used for snow/petals/leaves as worked examples.

- [ ] **Step 4: docs/config-reference.md**

Every `Season` JSON field: name, type, range, meaning, and the web-engine origin. Note the native-only fields (`colorP3` derivation from OKLCH, `depthMin/Max`, `bloom*`, `dofStrength`, `edrHeadroom`, `tint`). Document the `flags` derivation and selection/override behavior.

- [ ] **Step 5: Commit**

```bash
git add docs/engine.md docs/add-a-season.md docs/sprite-recipe.md docs/config-reference.md
git commit -m "docs: engine, add-a-season, sprite recipe, config reference"
```

---

## Done criteria

- `./install.sh` installs a working `Seasons.saver`; all four seasons render and match the web look, elevated per the hardware mandate (EDR glow, P3 color, bloom, DOF, grain, 120Hz, MetalFX).
- Month auto-selection + config-sheet override (Auto / four seasons / Off) work and persist.
- Reduce Motion falls back to static atmosphere; preview thumbnail renders; multi-display runs one field per screen; teardown leaks no renderers.
- fal.ai sprite recipe is documented and was run to produce 1024px native sprite sets.
- `SeasonsTests` (Color, Season, SeasonCatalog, Governor) pass.
- Docs let a cold session add a new season as a config + sprites exercise.

## Notes & risks carried from the spec

- Metal 4 command-encoder specifics on the shipping Tahoe SDK should be confirmed at implementation time; the pipeline structure above is encoder-model-agnostic and unchanged if a detail moved.
- The Tahoe `isPreview` bug is mitigated by the small-backing-size heuristic, not fixed.
- Three displays at 8K is the extreme case; the governor + MetalFX are the margin, validated against measured `gpuEndTime - gpuStartTime`, not assumed.
- Notarization/distribution signing is out of scope for v1 (ad-hoc local signing only).
