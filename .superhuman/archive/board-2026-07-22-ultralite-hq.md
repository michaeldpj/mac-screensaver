---
id: sh-20260722-ultralite-hq
title: "Ultra-Lite 2880 premium graphics pass"
status: completed
created: "2026-07-22T13:05:00-04:00"
updated: "2026-07-22T14:55:00-04:00"
git_tracked: true
total_tasks: 13
completed_tasks: 13
failed_tasks: 0
current_wave: 8
total_waves: 8
rollback_point: "704dd809e11a79856246bae500566e9d146915a9d"
---

# Ultra-Lite 2880 Premium Graphics Pass

<!-- Archived after completion; superseded by the star burn-in-safety follow-up board. -->

## Intake Summary

- **Task**: Replace inconsistent low-quality seasonal art and raise external Ultra-Lite presentation to true 2880 while retaining the proven three-display safety architecture.
- **Type**: cross-cutting rendering, asset, performance, QA, and documentation upgrade.
- **Complexity**: complex.
- **Success Criteria**: cohesive photoreal seasonal particles; sharp halo-free motion at oblique angles; 2880x1620 internal/present resolution; vivid SDR P3 on exact black; three-display 30/30/30 target with existing 20 FPS pressure fallback.
- **Constraints**: 15% particle count; no bloom, DoF, EDR, 3840 mode, shared union drawable, saver installation, GUI launch, or automated live-display test. Preserve panorama, fair stagger, per-display renderers/queues/resources, fail-closed authorization, and topology shutdown.
- **Dependencies**: built-in image generation, local alpha processing, ImageMagick, Swift/Metal, XcodeGen/XCTest, and installed Apple Metal Toolchain. No new external packages.
- **Testing Strategy**: TDD for policies and resource resolution; deterministic asset validation; shader/build checks; offscreen 2880 image/performance QA; staged live validation remains human-only.
- **Art Direction**: photoreal macro/studio specimens, physically and botanically plausible, vivid natural color, neutral diffuse lighting, fine surface detail, one object per particle, no baked rim/glow/shadow, watercolor, clip art, or neon fantasy geometry.
- **Board Persistence**: git-tracked; prior completed panorama/vivid board archived.

## Task Graph

| ID | Title | Type | Size | Dependencies | Wave | Status |
| --- | --- | --- | --- | --- | --- | --- |
| SH-001 | Write 2880 quality and safety policy tests | test | M | — | 1 | done |
| SH-002 | Build deterministic sprite and mip validation | test/tool | M | — | 1 | done |
| SH-003 | Repair headless resource resolution and failure semantics | code/test | M | — | 1 | done |
| SH-004 | Generate and curate winter HQ art | asset | L | SH-002 | 2 | done |
| SH-005 | Generate and curate spring HQ art | asset | L | SH-002 | 2 | done |
| SH-006 | Generate and curate autumn HQ art | asset | L | SH-002 | 2 | done |
| SH-007 | Implement native 2880, sampling, alpha-correct mips, and no-FX composite | code | L | SH-001, SH-002 | 2 | done |
| SH-008 | Integrate HQ assets, material tuning, and smaller sizing | code/asset | M | SH-004, SH-005, SH-006, SH-007 | 3 | done |
| SH-009 | Run deterministic 2880 visual and performance QA | test | M | SH-003, SH-008 | 4 | done |
| SH-010 | Update operational, asset, and architecture documentation | docs | S | SH-009 | 5 | done |
| SH-011 | Self-review all changes | review | M | SH-010 | 6 | done |
| SH-012 | Validate approved requirements | verify | S | SH-011 | 7 | done |
| SH-013 | Run full repository verification | verify | M | SH-012 | 8 | done |

## Dependency Graph

```text
[W1] SH-001 quality policy tests ---------+--> [W2] SH-007 renderer quality/performance --+
[W1] SH-002 asset/mip validator ----------+                                             |
                                           +--> SH-004 winter art -------------------------+
                                           +--> SH-005 spring art -------------------------+--> [W3] SH-008 integration
                                           +--> SH-006 autumn art -------------------------+             |
[W1] SH-003 headless repair ----------------------------------------------------------------> [W4] SH-009 QA
                                                                                                      |
[W5] SH-010 docs -> [W6] SH-011 review -> [W7] SH-012 requirements -> [W8] SH-013 verification
```

## Acceptance Gates

- Ultra-Lite policy is fixed at max edge 2880, forced internal scale 1.0, 30 FPS, 15% count, BGRA8 sRGB/P3 SDR, with bloom/DoF/EDR disabled.
- Existing adaptive cadence, panic switch, fair stagger, topology shutdown, and fail-closed external authorization tests remain green.
- Every JSON-referenced image set loads atomically and has exact contiguous indices, 1024x1024 straight-alpha RGBA, nonempty centered content, transparent corners, clean edge bleed, and validated mip coverage.
- Headless runs fail on missing assets and demonstrate exact 2880 output, exact-black backdrop, finite pixels, controlled clipping, sharp silhouettes, and no visible halo.
- Offscreen p95 GPU duration target is below 20 ms; 25 ms is a hard stop for recommending the three-display trial. Memory must stabilize after warmup and command-buffer failures must remain zero.
- Full XcodeGen build/test plus auxiliary targets pass. No live display process is launched by Codex.

## Execution Log

- 2026-07-22T13:05:00-04:00 — User approved the complete 2880 HQ plan. Confirmed clean rollback commit `704dd80`, archived the completed panorama/vivid board, and began Wave 1 test-first work. No GUI or live display session launched.
- 2026-07-22T13:18:00-04:00 — Wave 1 completed. Six quality-policy tests proved the prior 1920/nil behavior RED before the isolated 2880/1.0 production slice turned GREEN. Eight dependency-free validator tests and the full 51-asset baseline passed. Six Shot resource tests, universal Shot build, valid offscreen smoke, and exact missing-file failure passed outside the sandbox using the installed Metal toolchain. Began parallel winter/spring art generation and no-effects render planning.
- 2026-07-22T13:34:00-04:00 — SH-007 completed. Ultra-Lite now presents and internally renders at 2880 with fixed 1.0 scale. The no-effects composite samples one scene texture instead of six; sprites use 16x anisotropy, linear-light alpha-weighted/RMS-preserving layered mips, per-level surface-map derivation, and atomic strict loading. Universal Shot build, autumn/winter offscreen GPU smokes, and 12 focused tests passed. Began autumn generation alongside winter and spring.
- 2026-07-22T13:49:00-04:00 — SH-005 completed. Generated, alpha-processed, and visually inspected ten distinct single sakura petals plus three botanically correct five-petal hero blossoms. Transparent masters and optimized 1024 runtime art pass the full 51-asset validator with no fallback model/API and no visible green fringe.
- 2026-07-22T13:53:00-04:00 — SH-004 completed. Generated eight physically plausible single snowflakes and two detailed hero crystals, replacing clustered/neon art. Transparent 1254 masters and optimized 1024 runtime assets passed dark/magenta contact-sheet inspection and the full validator with no fallback model/API.
- 2026-07-22T14:18:00-04:00 — SH-006 and SH-008 completed. Generated six maple, six oak, four birch, and four paired-samara assets with clean alpha and coherent vivid photoreal art. Reduced image-particle size ranges about 15–20% without raising counts and added brighter winter-only lighting/grade. All 43 live image assets and 51 configured assets pass validation.
- 2026-07-22T14:22:00-04:00 — SH-009 completed. Enforced offscreen 2880x1620/30-frame p95 GPU results: spring 1.248 ms, winter 0.929 ms, autumn 1.583 ms, summer 0.857 ms; all had zero render failures, complete image species, and zero clipped channels. A 300-frame autumn soak passed at 0.489 ms p95, zero failures/swaps, 143.3 MB maximum resident set, and 879.2 MB reported peak memory footprint. No window or display presentation occurred.
- 2026-07-22T14:23:00-04:00 — SH-010 completed. Operational, crash, engine, asset-generation, prompt, and changelog documentation now matches the HQ implementation and preserves explicit DCP uncertainty and human-only staged validation. Began structured self-review.
- 2026-07-22T14:32:00-04:00 — SH-011 completed. Repeat review fixed traversal/input validation, atomic-pipeline rollback, headless allocation limits/failure semantics, shared shader grading, required-library loading, and misleading failed-frame output. Review evidence: 125/125 Xcode tests, 19/19 tooling tests, universal Shot build, valid Metal smoke, and clean diff/syntax checks. No major or reasonable minor defects remain.
- 2026-07-22T14:34:00-04:00 — SH-012 completed. Requirement mapping confirms approved true-2880 presentation/internal scale, cohesive photoreal art for all 43 live image variants, slightly smaller sprites, vivid SDR on exact black, no 2048 runtime expansion, preserved three-display safety architecture, enforced offscreen performance evidence, complete documentation, and no assistant-launched live display session. Began exact final ship verification.
- 2026-07-22T14:55:00-04:00 — SH-013 completed. Regenerated the Xcode project; the exact repository build/test command passed 125/125 tests; SeasonsShot, SeasonsPreview, and SeasonsApp all built successfully; 19/19 Python tooling tests passed; all 9 configured sprite sets and 51 assets validated; shell syntax and `git diff --check` were clean; and the shipped saver executable remained universal x86_64/arm64. No GUI or display presentation was launched.

## Deferred Work

- Human-supervised staged one/two/three-display validation after automated completion.
- Authored per-asset normal/roughness/thickness maps remain optional unless generated albedo plus corrected mip/material fallback fails visual QA.
