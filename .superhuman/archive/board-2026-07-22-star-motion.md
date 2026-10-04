---
id: sh-20260722-star-motion
title: "Guarantee burn-in-safe star motion"
status: completed
created: "2026-07-22T15:05:00-04:00"
updated: "2026-07-22T15:25:00-04:00"
git_tracked: true
total_tasks: 6
completed_tasks: 6
failed_tasks: 0
current_wave: 6
total_waves: 6
rollback_point: "bc1a0a01049c79c378c9121d2154f27ed8557143"
---

# Star Burn-In-Safety Motion

<!-- Archived after completion; superseded by the persistent external Ultra-Lite session. -->

## Intake Summary

- **Task**: Keep the optional Stars style while ensuring every bright star moves continuously.
- **Type**: bug/safety fix.
- **Complexity**: simple.
- **Problem**: `stars.json` configures zero horizontal and vertical velocity, so twinkling changes intensity but leaves bright pixels fixed on OLED displays.
- **Success Criteria**: every star has guaranteed nonzero translational motion; the field remains calm, panoramic, and smoothly animated; twinkling is retained; regression coverage prevents stationary values from returning.
- **Constraints**: retain the Stars option, existing generic particle engine, panorama projection, Ultra-Lite safety tier, and particle count; no live saver launch; no new dependencies.
- **Dependencies**: existing JSON season configuration, generic particle integration, Python configuration tests, Xcode/XCTest.
- **Testing Strategy**: write a failing source-of-truth configuration test first, update only the motion parameters, run offscreen star QA, then the exact repository build/test command.
- **Board Persistence**: git-tracked, approved by the user.

## Project Conventions

- Native Swift/Metal macOS project generated from `project.yml` with XcodeGen.
- Source of truth lives in `Sources/`, `Shaders/`, and `Resources/seasons/`; generated Xcode project must remain synchronized.
- XCTest is run through `xcodebuild`; deterministic configuration/tool tests use Python `unittest` under `tools/tests/`.
- Ship verification is `xcodegen generate && xcodebuild -project Seasons.xcodeproj -scheme Seasons -destination 'platform=macOS' build test`.

## Task Graph

| ID | Title | Type | Size | Dependencies | Wave | Status |
| --- | --- | --- | --- | --- | --- | --- |
| SH-001 | Add stationary-star regression test | test | S | — | 1 | done |
| SH-002 | Configure guaranteed calm panoramic star drift | config | S | SH-001 | 2 | done |
| SH-003 | Document burn-in-safe Stars behavior | docs | S | SH-002 | 3 | done |
| SH-004 | Self code review of all changes | review | S | SH-003 | 4 | done |
| SH-005 | Validate changes against original requirements | verify | S | SH-004 | 5 | done |
| SH-006 | Run full project verification suite | verify | S | SH-005 | 6 | done |

## Dependency Graph

```text
SH-001 regression test -> SH-002 star drift -> SH-003 docs
  -> SH-004 self review -> SH-005 requirements -> SH-006 full verification
```

## Tasks

### SH-001: Add stationary-star regression test
- **Research Notes**: `Resources/seasons/stars.json` currently sets all velocity endpoints to zero. Existing deterministic JSON policy tests live in `tools/tests/test_hq_season_config.py`.
- **Execution Plan**: Add a test that requires the minimum possible Stars translation magnitude to remain nonzero, proving RED against the current config.
- **Acceptance Criteria**: the test fails for zero velocity and directly reads the shipped JSON source of truth.

### SH-002: Configure guaranteed calm panoramic star drift
- **Research Notes**: generic particles already integrate `vx`/`vy`, apply depth parallax, cross panoramic camera origins, and recycle after leaving the shared world bounds. A same-sign nonzero velocity range guarantees motion without shader changes.
- **Execution Plan**: use modest positive horizontal and vertical ranges so the slowest, deepest star still moves visibly while preserving a calm starfield; retain count, size, glow, pulse, and wind settings.
- **Acceptance Criteria**: no velocity endpoint allows a stationary star; test passes; offscreen frames demonstrate displacement and render without GPU failure.

### SH-003: Document burn-in-safe Stars behavior
- **Execution Plan**: add concise changelog/config documentation describing continuous drift and retained twinkle.
- **Acceptance Criteria**: user-facing behavior and the OLED-safety rationale are accurate.

### SH-004: Self code review of all changes
- **Execution Plan**: review the diff from rollback point `bc1a0a0` for correctness, OLED-safety effectiveness, performance, design, and tests; fix all major and reasonable minor findings.
- **Acceptance Criteria**: zero major findings remain.

### SH-005: Validate changes against original requirements
- **Execution Plan**: map implementation evidence to continuous motion or removal requirement and confirm Stars remains useful and safe by design.
- **Acceptance Criteria**: every requested outcome is met without a permanently fixed star.

### SH-006: Run full project verification suite
- **Execution Plan**: run Python tooling tests, regenerate Xcode, run the exact full build/test command, build auxiliary targets as appropriate, run diff/syntax checks, and do not launch a window or live saver.
- **Acceptance Criteria**: all configured checks pass.

## Execution Log

- 2026-07-22T15:05:00-04:00 — User approved the preferred continuous-motion solution and a new tracked follow-up board. Archived the completed 2880 HQ board, recorded rollback commit `bc1a0a0`, and began the test-first wave. No live screen process launched.
- 2026-07-22T15:12:00-04:00 — SH-001 proved RED at 0.0 projected points/sec. SH-002 then set same-sign 8–14 horizontal and 3–7 vertical point/sec ranges; the deepest star is guaranteed more than 4 projected points/sec and the focused test turned GREEN. SH-003 corrected the changelog and velocity documentation. Began structured diff review.
- 2026-07-22T15:18:00-04:00 — SH-004 review found no major or reasonable minor defects: the generic step adds configured velocity every frame, panoramic world coordinates and depth parallax are retained, modest turbulence cannot make the field permanently stationary, and boundary recycling remains intact. Offscreen 300-frame sequence produced distinct frame hashes with zero GPU failures, 0.573 ms p95, and no clipped channels. SH-005 confirmed the approved retain-and-move requirement, unchanged count/twinkle, no live launch, and direct OLED regression coverage. Began exact full verification.
- 2026-07-22T15:25:00-04:00 — SH-006 completed. XcodeGen regeneration and the exact scheme build/test passed 125/125 tests; SeasonsShot, SeasonsPreview, and SeasonsApp all built; 20/20 Python tooling tests passed; all 9 sprite sets and 51 assets validated; shell syntax and `git diff --check` were clean. No live display or GUI process launched.

## Convergence Summary

- **Files changed**: `Resources/seasons/stars.json`, configuration regression tests, changelog/config documentation, and the tracked board/archive.
- **Tests added**: one source-of-truth regression proving the minimum projected Stars translation stays at or above 4 points/sec.
- **Key decision**: retain Stars and use same-sign nonzero horizontal/vertical ranges, which guarantees calm continuous motion through the existing generic panoramic simulation without adding shader cost.
- **Deferred work**: none.
- **Suggested commit**: `Prevent stationary stars on OLED displays`.

## Deferred Work

- None.
