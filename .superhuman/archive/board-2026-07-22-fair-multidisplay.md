---
id: sh-20260722-fair-multidisplay
title: "Fair adaptive 30 FPS multi-display scheduler"
status: completed
archived: "2026-07-22T11:58:23-04:00"
created: "2026-07-22T11:23:21-04:00"
updated: "2026-07-22T11:35:15-04:00"
git_tracked: true
total_tasks: 9
completed_tasks: 9
failed_tasks: 0
current_wave: 7
total_waves: 7
rollback_point: "2b1ade8ae9162208a7806f49f8fc4d1456d25291"
---

# Fair Adaptive Multi-Display Scheduler

## Intake Summary

- **Task**: Replace starvation-prone external submission dropping with a complete fair scheduler and adaptive frame-health policy.
- **Type**: cross-cutting bug fix and performance refactor.
- **Complexity**: complex.
- **Problem**: In a successful three-external Ultra-Lite test, two displays animated smoothly while the third remained mostly static because synchronized callbacks repeatedly lost the global submit gate.
- **Success Criteria**: Three 60 Hz external displays target a consistently paced 30 FPS each; commit order is fair and retains at least 2 ms spacing; pressured displays fall to 20 FPS and recover automatically; no routine submit-gate drops; diagnostics identify health; defaults remain fail-closed.
- **Constraints**: Preserve default built-in-only safety, authorization checks, full-quality visuals, and the normal built-in 120 Hz mode. Cap the built-in to 60 FPS only during an explicit Ultra-Lite session with three or more externals. Do not install or launch the saver or run live display tests.
- **Dependencies**: Existing `SubmitGate`, `SeasonsView`, renderer GPU timing, `DisplayPolicy`, XcodeGen, XCTest, and Apple Metal Toolchain.
- **Edge Cases**: Concurrent arrivals, scheduler oversleep, spurious wakeups, drawable starvation, slow GPU completion, topology shutdown, unknown screens, single/dual external sessions, built-in plus three externals, and recovery after pressure clears.
- **Testing Strategy**: Pure deterministic clock/sleeper/concurrency tests first; integration compilation across every target; full existing test suite; no live rendering.
- **Documentation**: Update safe-testing and engine/crash analysis terminology from literal scanout reduction to source-drawable/presentation workload reduction.
- **Rollout**: Behavior remains behind `SEASONS_EXT_ULTRALITE`; unsafe `SEASONS_ALL_DISPLAYS` remains unchanged and discouraged.
- **Priority**: Deliver the complete fair 30/30/30 solution with adaptive fallback in one implementation pass.
- **Board Persistence**: git-tracked; prior completed board archived under `.superhuman/archive/`.

## Project Conventions

- Swift/Metal production sources live in `Sources/`; XCTest files live in `SeasonsTests/`.
- `project.yml` is the source of truth; regenerate `Seasons.xcodeproj` with XcodeGen.
- Pure timing and display policies are AppKit-free and directly unit tested.
- Verification command: `xcodegen generate` followed by `xcodebuild -project Seasons.xcodeproj -scheme Seasons -destination 'platform=macOS' build test`.
- Auxiliary schemes `SeasonsShot`, `SeasonsPreview`, and `SeasonsApp` must also compile.
- Preserve the user-owned repository state and avoid live display execution.

## Task Graph

### Sub-tasks

| ID | Title | Type | Size | Dependencies | Wave | Status |
| --- | --- | --- | --- | --- | --- | --- |
| SH-001 | Write fair submit-coordinator tests | test | S | — | 1 | done |
| SH-002 | Implement FIFO spaced submit coordinator | code | M | SH-001 | 2 | done |
| SH-003 | Write adaptive cadence and display-budget tests | test | M | — | 1 | done |
| SH-004 | Implement adaptive cadence and display budget | code | M | SH-003 | 2 | done |
| SH-005 | Integrate scheduler, health signals, and diagnostics | code | M | SH-002, SH-004 | 3 | done |
| SH-006 | Update operational and engine documentation | docs | S | SH-005 | 4 | done |
| SH-007 | Self code review of all changes | review | M | SH-006 | 5 | done |
| SH-008 | Validate changes against original requirements | verify | S | SH-007 | 6 | done |
| SH-009 | Run full project verification suite | verify | M | SH-008 | 7 | done |

### Dependency Graph

```text
[W1] SH-001 tests ---> [W2] SH-002 fair coordinator ---+
                                                       +--> [W3] SH-005 integration
[W1] SH-003 tests ---> [W2] SH-004 cadence policy -----+             |
                                                                      v
 [W4] SH-006 docs -> [W5] SH-007 review -> [W6] SH-008 validate -> [W7] SH-009 verify
```

### Wave Assignments

- **Wave 1**: SH-001, SH-003 — independent red tests.
- **Wave 2**: SH-002, SH-004 — independent pure implementations.
- **Wave 3**: SH-005 — renderer/view/display integration and diagnostics.
- **Wave 4**: SH-006 — documentation.
- **Wave 5**: SH-007 — structured review and fixes.
- **Wave 6**: SH-008 — requirement mapping.
- **Wave 7**: SH-009 — XcodeGen, complete tests, universal and auxiliary builds.

## Tasks

### SH-001: Write fair submit-coordinator tests

- **Research**: Current secondaries call `tryAcquire` and drop on contention; the miss-streak relaxation explains the observed occasional animation. Existing injected timing seams are deterministic.
- **Plan**: Replace drop expectations with tests proving FIFO completion, actual-wake spacing, no starvation, and bounded first-call behavior.
- **Acceptance**: Concurrent callers all acquire exactly once and return in ticket order with real timestamps separated by the configured minimum.

### SH-002: Implement FIFO spaced submit coordinator

- **Research**: Holding an unfair lock across sleep preserves spacing but not fairness. Ticket ordering plus a condition provides deterministic FIFO service while retaining actual-wake stamping.
- **Plan**: Add a pure coordinator with injected monotonic clock/sleeper; remove routine secondary rejection; return measured scheduling wait for health diagnostics.
- **Acceptance**: All SH-001 tests pass; authorization can still cancel before commit; no routine multi-display frame is dropped by contention.

### SH-003: Write adaptive cadence and display-budget tests

- **Research**: Both 30 and 20 FPS divide a 60 Hz refresh cleanly. Three external 30 FPS producers require 90 submissions/s; fallback must be pressure-driven rather than permanent.
- **Plan**: Test 30 FPS initial state, thresholded 20 FPS fallback, sustained-health recovery, pressure-window expiry, and built-in 60 FPS cap only for explicit three-external Ultra-Lite sessions.
- **Acceptance**: Deterministic tests cover GPU, drawable, and scheduling pressure plus unaffected default/single/dual-display behavior.

### SH-004: Implement adaptive cadence and display budget

- **Research**: `QualityTier.fps` already feeds `CAFrameRateRange`; a pure controller can drive it without changing rendering quality or physical monitor refresh.
- **Plan**: Implement an AppKit-free health controller and display-budget policy with configurable thresholds; preserve 30 FPS externally until three pressure events occur in two seconds; recover after 15 healthy seconds.
- **Acceptance**: SH-003 tests pass; fallback floor is 20 FPS; normal built-in remains 120 FPS.

### SH-005: Integrate scheduler, health signals, and diagnostics

- **Research**: `Renderer` already records completed GPU time under a lock; `SeasonsView` owns drawable acquisition, display-link range, and commit gate.
- **Plan**: Expose a thread-safe GPU health sample; feed drawable misses, coordinator wait, and GPU time to the cadence controller; update display-link range; log five-second per-display health summaries; map three-external Ultra-Lite built-in to 60 FPS.
- **Acceptance**: Three external views target 30 FPS without gate drops, retain 2 ms commit spacing, fall to 20 FPS under pressure, recover to 30 FPS, and leave all default safety behavior intact.

### SH-006: Update operational and engine documentation

- **Plan**: Document fair 30/30/30 behavior, adaptive fallback, diagnostic fields, built-in experiment cap, and correct “scanout” to “source drawable/presentation workload.”
- **Acceptance**: README and safety/engine/crash documents match code and retain explicit kernel-panic caveats.

### SH-007: Self code review of all changes

- **Plan**: Review Security, Correctness, Performance, Design, Readability, Convention, and Testing; fix all major findings and reasonable minor findings.
- **Acceptance**: No major findings remain; minor findings are fixed or documented.

### SH-008: Validate changes against original requirements

- **Plan**: Map fair 30/30/30, 2 ms spacing, adaptive 20 FPS fallback/recovery, diagnostics, built-in control, unchanged defaults, and no-live-test constraint to evidence.
- **Acceptance**: Every approved requirement has code/test/documentation proof.

### SH-009: Run full project verification suite

- **Plan**: Regenerate project; run exact build/test command; build all auxiliary schemes; inspect universal architectures; run diff checks.
- **Acceptance**: All tests and builds pass with Metal shader compilation; no saver is installed or launched.

## Execution Log

- 2026-07-22T11:23:21-04:00 — User approved the complete one-pass plan. Archived the prior completed board, recorded clean rollback point `2b1ade8`, and began Wave 1 red tests.
- 2026-07-22T11:27:00-04:00 — Wave 1 completed. Added four fair-coordinator tests and twelve cadence/budget tests; isolated compilation confirmed expected red failures for the intentionally missing production types. Began Wave 2 pure implementations.
- 2026-07-22T11:29:00-04:00 — Wave 2 completed. FIFO condition/ticket coordinator and adaptive cadence/display-budget policy implemented; all 16 focused tests pass and the universal saver compiles. Began Wave 3 integration.
- 2026-07-22T11:33:19-04:00 — Waves 3–4 completed. Integrated fair commits, per-external adaptive health, five-second diagnostics, renderer timing isolation, and the three-external built-in cap. Full integration build passed 76 tests before the additional early-wake regression test. Updated README and safety/engine/crash documentation; began structured review.
- 2026-07-22T11:34:21-04:00 — Waves 5–6 completed. Security/correctness/performance/design/readability/convention/testing review found no unresolved major issue. Fixed early scheduler-wake handling and corrected scheduler-average diagnostics; all 17 focused tests pass. Requirement mapping: FIFO completion + 2 ms spacing (`FairSubmitCoordinatorTests`), adaptive 30→20→30 (`AdaptiveCadenceTests`), built-in cap isolation (`DisplayCadenceBudgetTests`), default safety (existing display-plan/view tests), operational observability (`SeasonsView` and `SAFE-TESTING.md`), and no live execution (build/test commands only). Began final verification.
- 2026-07-22T11:35:15-04:00 — Wave 7 completed. The exact XcodeGen + `Seasons` build/test command passed all 77 tests with Metal shader compilation. `SeasonsShot`, `SeasonsPreview`, and `SeasonsApp` all built successfully. The saver binary is universal `x86_64 arm64`; `git diff --check` is clean. No saver was installed or launched and no live display session ran. Convergence achieved: all 9 tasks complete, 0 failed.

## Deferred Work

- Physical monitor testing remains human-supervised after implementation verification.
