---
id: sh-20260722-panorama-vivid
title: "Panoramic external particle world and vivid SDR color"
status: completed
created: "2026-07-22T11:58:23-04:00"
updated: "2026-07-22T12:24:00-04:00"
git_tracked: true
total_tasks: 12
completed_tasks: 12
failed_tasks: 0
current_wave: 9
total_waves: 9
rollback_point: "4524e51c20775beaa1a26a9d8af0f4c9a357a25c"
---

# Panoramic External World and Vivid SDR Color

## Intake Summary

- **Task**: Make the three Ultra-Lite external displays behave as camera crops of one continuous particle world and make image sprites bright and saturated against exact black.
- **Type**: cross-cutting feature and color-correctness bug fix.
- **Complexity**: complex.
- **Problem**: External views currently own different particle seeds, local viewports, variable callback integration, and buffers; only wind is spatially continuous. Ultra-Lite also writes linear Display-P3 shader output to non-sRGB `bgra8Unorm`, causing dark/dull midtones.
- **Success Criteria**: Identical particles cross adjacent external display boundaries at consistent position, motion, size, and time; display arrangement offsets/gaps are respected; each drawable remains per-display and clamped; external SDR sprites have correct transfer encoding and visibly higher chroma/luminance while background remains zero black.
- **Constraints**: Retain separate per-display CAMetalLayers, queues, renderers, FIFO 2 ms commits, adaptive 30→20→30 cadence, fail-closed authorization, topology shutdown, Ultra-Lite count/bloom/DoF/drawable budgets, and external EDR prohibition. Do not install or launch the saver or run a live display session.
- **Dependencies**: AppKit screen frames, deterministic Swift/Metal simulation, XcodeGen/XCTest, headless SeasonsShot, and the installed Apple Metal Toolchain. No new external packages.
- **Edge Cases**: Negative origins, y-up AppKit to y-down shader mapping, vertical offsets, gaps, differing screen sizes/scales, 30/20 Hz callback mixtures, duplicate/missed ticks, long pauses, drawable misses, direct ScreenSaverEngine views without a host panorama plan, and exact black preservation.
- **Testing Strategy**: Pure red tests for layout/timeline/presentation/color policies; deterministic shader integration; headless stitched crop renders and pixel statistics; full safety regressions and all target builds. Human three-display validation remains subsequent and supervised.
- **Documentation**: Update README, engine, safe-testing, and crash-analysis descriptions of panoramic semantics and vivid SDR encoding.
- **Rollout**: Panorama applies only to two or more authorized animated Ultra-Lite external surfaces. Built-in rendering remains independent; default and crash-repro paths remain unchanged.
- **Priority**: Deliver panorama and color correction together in one complete implementation pass.
- **Board Persistence**: git-tracked; previous completed scheduler board archived.

## Project Conventions

- Swift/Metal production code lives in `Sources/` and `Shaders/`; XCTest files live in `SeasonsTests/`.
- `project.yml` is the source of truth and must regenerate `Seasons.xcodeproj` through XcodeGen.
- Pure policies remain Foundation/simd-only and are explicitly included in the test target.
- Exact verification is `xcodegen generate && xcodebuild -project Seasons.xcodeproj -scheme Seasons -destination 'platform=macOS' build test`.
- `SeasonsShot`, `SeasonsPreview`, and `SeasonsApp` must also compile; headless rendering may run, but GUI/live display execution may not.
- Existing user work is clean at rollback commit `4524e51`; preserve all prior safety behavior.

## Task Graph

### Sub-tasks

| ID | Title | Type | Size | Dependencies | Wave | Status |
| --- | --- | --- | --- | --- | --- | --- |
| SH-001 | Write panoramic layout/timeline tests | test | M | — | 1 | done |
| SH-002 | Write presentation and vivid-color policy tests | test | S | — | 1 | done |
| SH-003 | Implement panoramic layout and fixed timeline | code | M | SH-001 | 2 | done |
| SH-004 | Implement presentation and vivid-color policies | code | M | SH-002 | 2 | done |
| SH-005 | Wire panoramic descriptors through policy and hosts | code | M | SH-003 | 3 | done |
| SH-006 | Implement deterministic fixed-step world and camera crops | code | M | SH-005 | 4 | done |
| SH-007 | Integrate vivid SDR color and material tuning | code | M | SH-004, SH-006 | 5 | done |
| SH-008 | Add deterministic headless panorama/color QA | test | M | SH-007 | 5 | done |
| SH-009 | Update operational and engine documentation | docs | S | SH-007, SH-008 | 6 | done |
| SH-010 | Self code review of all changes | review | M | SH-009 | 7 | done |
| SH-011 | Validate changes against original requirements | verify | S | SH-010 | 8 | done |
| SH-012 | Run full project verification suite | verify | M | SH-011 | 9 | done |

### Dependency Graph

```text
[W1] SH-001 panorama tests -> [W2] SH-003 pure panorama --+
                                                            +-> [W3] SH-005 host wiring
[W1] SH-002 color tests ----> [W2] SH-004 color policy -----+             |
                                                                          v
 [W4] SH-006 fixed-step Metal panorama -> [W5] SH-007 vivid integration
                                                        +-> SH-008 headless QA
                                                               |
 [W6] SH-009 docs -> [W7] SH-010 review -> [W8] SH-011 requirements -> [W9] SH-012 verify
```

### Wave Assignments

- **Wave 1**: SH-001, SH-002 — independent red tests in parallel.
- **Wave 2**: SH-003, SH-004 — pure implementations in parallel.
- **Wave 3**: SH-005 — policy/host/view descriptor integration.
- **Wave 4**: SH-006 — shader ABI, deterministic stepping, and camera projection.
- **Wave 5**: SH-007, SH-008 — vivid integration followed by deterministic headless QA, reconciled as one boundary.
- **Wave 6**: SH-009 — documentation.
- **Wave 7**: SH-010 — structured bottom-up review.
- **Wave 8**: SH-011 — requirement mapping.
- **Wave 9**: SH-012 — complete repository verification.

## Tasks

### SH-001: Write panoramic layout/timeline tests

- **Research**: AppKit frames are y-up; the shader world is y-down. Current world origin only affects wind and seeds differ per display.
- **Plan**: Test union normalization, negative/stacked/offset/gapped screens, camera transforms, seam projection, stable shared seed/session, fixed 30 Hz ticks, 20 Hz catch-up, duplicate ticks, and bounded long pauses.
- **Acceptance**: Pure tests prove every external gets the same world/timeline and only its camera crop differs; no union-sized drawable is exposed.

### SH-002: Write presentation and vivid-color policy tests

- **Research**: Ultra-Lite incorrectly selects non-sRGB BGRA8 for linear P3 output; image alpha, lighting, fade, and Hable compression further reduce contrast.
- **Plan**: Test output transfer selection, EDR isolation, exact sRGB transfer references, linear-sRGB→linear-P3 conversion, image-only opacity/visibility resolution, bounded chroma enhancement, and exact zero preservation.
- **Acceptance**: Tests fail on current Ultra-Lite presentation and encode the bright-SDR/black-background contract without affecting glow/rain semantics.

### SH-003: Implement panoramic layout and fixed timeline

- **Plan**: Add pure layout/projection/timeline types with normalized y-down cameras, stable topology seed, nonblocking group tick latching, fixed-step schedules, and bounded overrun behavior.
- **Acceptance**: SH-001 passes; single/local rendering remains representable by a zero-origin camera.

### SH-004: Implement presentation and vivid-color policies

- **Plan**: Add pure transfer/color helpers and a presentation plan that maps Ultra-Lite SDR to sRGB-encoded BGRA8/P3 without EDR. Resolve conservative vivid image parameters separately from procedural glow/streak styles.
- **Acceptance**: SH-002 passes; black maps exactly to black and vivid transforms remain finite, nonnegative, and hue-stable.

### SH-005: Wire panoramic descriptors through policy and hosts

- **Plan**: Build one descriptor set for two or more authorized Ultra-Lite externals, excluding the built-in. Pass projections through `DisplayPolicy.Surface`, both standalone hosts, and `SeasonsView`; direct saver views remain local/fail-closed.
- **Acceptance**: Every participating external shares world/seed/start/count budget; built-in/default/all-displays behavior is unchanged.

### SH-006: Implement deterministic fixed-step world and camera crops

- **Plan**: Split simulation world size from render camera in `SimParams`; seed replicas identically; advance state by fixed integer ticks; project world particles through per-view cameras in mesh/glow/streak paths; remove seam edge fades; retain per-display local targets and submission controls.
- **Acceptance**: Same tick and topology produce bit-equivalent particle evolution inputs across views; particles cross horizontal/vertical seams without respawn or fade; catch-up is bounded.

### SH-007: Integrate vivid SDR color and material tuning

- **Plan**: Use `bgra8Unorm_srgb` for Ultra-Lite, correctly convert sampled linear sRGB art to linear P3, preserve exact black, raise image opacity/far visibility/ambient light, soften filmic compression, and apply restrained chroma enhancement. Do not enable bloom, DoF, or EDR externally.
- **Acceptance**: Image sprites are materially brighter/more colorful under SDR while procedural styles retain intentional alpha and background remains zero.

### SH-008: Add deterministic headless panorama/color QA

- **Plan**: Extend SeasonsShot with explicit panorama/tick inputs and color-correct Display-P3 PNG export. Render matching camera crops at fixed ticks and calculate seam/color/black metrics without opening a GUI.
- **Acceptance**: Headless artifacts demonstrate continuous world crops, exact black, improved nonblack luma/chroma, and no union-sized present target.

### SH-009: Update operational and engine documentation

- **Plan**: Document external-only panorama scope, replicated deterministic simulation, per-display safety envelope, vivid SDR encoding, limitations (non-atomic presents/profiles/gaps), diagnostics, and supervised validation.
- **Acceptance**: README and safety/engine/crash docs match implementation without weakening panic caveats.

### SH-010: Self code review of all changes

- **Plan**: Review Security, Correctness, Performance, Design, Readability, Convention, and Testing from rollback point; fix all major and reasonable minor findings, then repeat.
- **Acceptance**: Zero major findings remain; minor findings are fixed or recorded.

### SH-011: Validate changes against original requirements

- **Plan**: Map true cross-screen flow, bright colorful images, black background, safety preservation, and one-pass delivery to code, tests, headless artifacts, and docs.
- **Acceptance**: Every approved requirement has direct evidence with no undocumented deviation.

### SH-012: Run full project verification suite

- **Plan**: Regenerate Xcode project; run exact build/test command; build all auxiliary schemes; inspect universal architectures; run diff checks; do not install or launch.
- **Acceptance**: All tests/builds/shaders pass and no live display session occurs.

## Execution Log

- 2026-07-22T11:58:23-04:00 — User approved true external panorama plus vivid SDR correction in one pass. Archived completed scheduler board, recorded clean rollback point `4524e51`, completed three parallel read-only research tracks, and began Wave 1 red tests.
- 2026-07-22T12:02:00-04:00 — Wave 1 completed. Added 11 panorama layout/timeline/coordinator tests and 11 presentation/color tests; Xcode compilation confirmed expected RED failures for missing production types. Began parallel Wave 2 pure implementations.
- 2026-07-22T12:05:00-04:00 — Wave 2 completed. Implemented AppKit-free panorama layout/fixed schedule/nonblocking group latch plus SDR presentation/color math/vivid image policy. All 22 focused tests pass and the universal saver compiles. Began Wave 3 descriptor wiring.
- 2026-07-22T12:07:00-04:00 — Wave 3 completed. Authorized Ultra-Lite externals now receive one shared layout/session/coordinator and per-view camera projection through DisplayPolicy, both standalone hosts, and SeasonsView. Built-in, direct saver, single-display, and ALL_DISPLAYS paths remain local. All production targets build; began fixed-step Metal panorama integration.
- 2026-07-22T12:11:00-04:00 — Wave 4 completed. Added replicated fixed-step global simulation, camera-crop projection in every glyph path, bounded catch-up, pre-drawable tick consumption, and group fail-closed invalidation. Twelve panorama tests and all production target builds passed.
- 2026-07-22T12:15:00-04:00 — Wave 5 color integration completed. Ultra-Lite now uses sRGB-encoded BGRA8/Display-P3 with EDR forced off. Image art converts from linear sRGB to linear P3 and receives bounded image-only vivid opacity/exposure/chroma plus improved far visibility; procedural paths remain authored. Eleven color tests and Metal compilation passed.
- 2026-07-22T12:17:00-04:00 — Wave 5 headless QA completed without GUI launch. Three deterministic Ultra-Lite camera crops stitched against a full-width reference with 89/172800 differing pixels (0.0515%, normalized MAE 0.000000711), exact-black-dominant output, visible vivid color, and zero clipped channels. Panorama disables local-UV grain/vignette to avoid repeated seams.
- 2026-07-22T12:18:00-04:00 — Wave 6 documentation completed. README, engine, safe-testing, and crash analysis now describe panorama semantics, vivid SDR encoding, fail-closed behavior, and retained DCP risk. Began structured self-review.
- 2026-07-22T12:20:00-04:00 — Wave 7 self-review completed across safety, correctness, performance, design, readability, convention, and tests. Fixed a clock-domain risk by using CACurrentMediaTime for both epoch and ticks, scoped vivid enhancement to SDR, invalidated the group on member authorization loss, and removed per-camera post seams. No major findings remain.
- 2026-07-22T12:21:00-04:00 — Wave 8 requirements validation completed. Shared cross-screen flow, brighter colorful images on exact black, unchanged per-display safety resources, one-pass delivery, tests, headless evidence, and operational documentation all map directly to the approved request. Began final repository verification.
- 2026-07-22T12:24:00-04:00 — Wave 9 and board completed. XcodeGen regeneration succeeded; exact universal saver build/test passed; dedicated result bundle reports 100/100 tests with zero failures; SeasonsApp, SeasonsPreview, and SeasonsShot builds passed with Metal; saver contains arm64 and x86_64; diff checks are clean. No GUI, saver installation, or live display render was launched.

## Deferred Work

- Physical three-display visual validation remains human-supervised after automated verification.
- Cross-display presentation cannot be atomic; the existing deliberate 2 ms commit separation remains.
