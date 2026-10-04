# Seasons Safety and Performance Hardening Board

> Archived after successful completion; superseded by the fair multi-display scheduler session.

## Metadata

- status: completed
- git_tracked: true
- created: 2026-07-22T09:34:31-04:00
- updated: 2026-07-22T09:58:00-04:00
- current_wave: 7
- total_waves: 7
- total_tasks: 13
- completed_tasks: 13
- rollback_point: `992b1624849e67f44ad9e31db950a4487e07d63c`

## Intake

Harden the native macOS Seasons screensaver before a three-external-4K-display test. Eliminate known crash-amplifying behavior, make external-display safety fail closed, stop unnecessary GPU work, reduce render-target memory, and preserve full-quality visual output. The user approved implementation after a read-only audit and requested performance improvements alongside the safety fixes.

### Constraints

- `project.yml` is the Xcode project source of truth.
- Production changes follow tests wherever a pure policy seam is practical.
- Full-quality rendering must remain visually unchanged.
- Keep the existing 120 Hz built-in-display premium mode.
- Do not install or activate the `.saver` during implementation.
- Do not run a live multi-display render test during implementation.
- Preserve the user's untracked `AGENTS.md` file.
- Verify with `xcodegen generate` and the repository's documented `xcodebuild ... build test` command.

## Project Conventions

- Swift and Metal sources live under `Sources/`.
- XCTest coverage lives under `SeasonsTests/`.
- App entry points live under `tools/app/` and `tools/preview/`.
- Generated Xcode project changes must originate in `project.yml`.
- Source edits use small, reviewable patches with no unrelated cleanup.

## Dependency Graph

```text
SH-001 -> SH-002 -> SH-003 --+
SH-004 -> SH-005 -----------+|
SH-006 -> SH-007 ----------+|+-> SH-010 -> SH-011 -> SH-012 -> SH-013
SH-008 -> SH-009 ---------+|
```

## Wave Plan

| Wave | Tasks | Purpose |
| --- | --- | --- |
| 1 | SH-001, SH-004, SH-006, SH-008 | Add red tests for safety and performance policies |
| 2 | SH-002, SH-005, SH-007, SH-009 | Implement fail-closed safety, submit serialization, conditional resources, and GPU idling |
| 3 | SH-003 | Handle display-topology changes in running app/preview sessions |
| 4 | SH-010 | Correct documentation and operational guidance |
| 5 | SH-011 | Perform implementation self-review and fix defects |
| 6 | SH-012 | Validate every approved requirement against code and tests |
| 7 | SH-013 | Regenerate, build, and run the complete test suite |

## Task Ledger

| ID | Status | Depends On | Description | Acceptance |
| --- | --- | --- | --- | --- |
| SH-001 | completed | — | Safety-policy tests | Tests cover preview, unknown screen, internal/external screens, tool authorization, and explicit all-display override. |
| SH-002 | completed | SH-001 | Fail-closed view/static path | Installed saver never constructs a renderer or submits GPU work on an unauthorized/unknown external surface; single-display environment no longer bypasses safety. |
| SH-003 | completed | SH-002 | Topology-change handling | App and preview safely stop when display topology changes so a full renderer cannot migrate onto a newly unsafe surface. |
| SH-004 | completed | — | Submit-gate tests | Concurrent callers cannot reserve submissions closer than the configured spacing; deterministic seams avoid flaky timing assertions. |
| SH-005 | completed | SH-004 | Atomic spacing fix | Check, wait, and reservation are serialized without the prior unlock/recheck race. |
| SH-006 | completed | — | Render-plan tests | A pure plan proves which targets and passes are required for full, ultra-lite, and no-upscale configurations. |
| SH-007 | completed | SH-006 | Conditional resources and passes | Renderer omits disabled bloom/DoF targets and passes, avoids needless graded target allocation, uses graceful texture allocation failure, keeps full-quality output intact, and reduces drawable buffering. |
| SH-008 | completed | — | Static-state tests | A pure policy proves Off and Reduce Motion do not require continuous GPU submission and can resume when state changes. |
| SH-009 | completed | SH-008 | Off/Reduce Motion GPU idling | Off and Reduce Motion render at most one safe static frame where authorized, then submit no ongoing GPU work; callbacks remain sufficient to observe state changes. |
| SH-010 | completed | SH-003, SH-005, SH-007, SH-009 | Documentation | Safety behavior, testing steps, and external ultra-lite cost claims match the implementation; incorrect ~50x claim is corrected. |
| SH-011 | completed | SH-010 | Self-review | Review all diffs for correctness, races, force unwraps in touched paths, visual regressions, and unrelated changes; fix findings. |
| SH-012 | completed | SH-011 | Requirements validation | Map every approved finding/recommendation in scope to code, tests, documentation, or an explicit deferral. |
| SH-013 | completed | SH-012 | Full verification | `xcodegen generate` and full macOS build/test succeed with Metal shader compilation and zero test failures. |

## Test and Implementation Plans

### SH-001 / SH-002 — View Display Safety

- Add a pure decision policy consumed by `SeasonsView`.
- Treat a missing screen as unsafe outside previews.
- Permit previews, explicit tool-provided authorization, internal screens, and the explicit crash-reproduction all-display override.
- Remove `SEASONS_SINGLE_DISPLAY` as a safety bypass for the installed saver.
- Make the unauthorized path layer-only/static-black, without renderer creation, sprite loading, command queue creation, drawable acquisition, or command submission.
- Re-evaluate the policy while callbacks continue so a changing screen cannot fail open.

### SH-003 — Display Topology

- Observe macOS screen-parameter changes in the preview and standalone app.
- End the active session rather than rebuilding heavyweight renderers during a topology transition.
- Remove observers during shutdown/deinitialization.

### SH-004 / SH-005 — Submission Spacing

- Add injectable monotonic-clock and sleep seams to the gate where needed for deterministic tests.
- Serialize reading the prior submission, waiting, and recording the next reservation.
- Retain the small spacing cap and avoid behavior changes for the normal single-display path.

### SH-006 / SH-007 — Conditional Render Resources

- Represent bloom, depth-of-field, and upscaling needs in a pure render-resource plan.
- Full quality retains its current bloom, DoF, and composite passes.
- Ultra-lite omits disabled full-resolution bloom and DoF resources/passes while retaining only the lite bloom resources actually used.
- Native-scale rendering skips the separate graded target when compositing can write directly.
- Replace force-unwrapped large transient texture allocation in touched paths with graceful frame failure.
- Keep required shader bindings valid through minimal neutral fallback textures or an equivalent safe binding strategy.
- Set `framebufferOnly` when the drawable is render-only and bound drawable queuing where supported.

### SH-008 / SH-009 — Static State

- Model render cadence for active, Off, Reduce Motion, and unauthorized external states.
- Off and Reduce Motion may produce one static presentation on transition, then idle.
- Unauthorized external surfaces use the zero-GPU black path.
- Continue lightweight state observation so changing settings can resume animation without recreating the host.

### SH-010 — Documentation

- Correct external scanout ratio language from ~50x to approximately 24.5x for the cited modes.
- Describe the fail-closed external-display path and topology-change shutdown behavior.
- Add a staged test checklist: preview/offscreen first, one external display next, then the full three-display setup while monitoring GPU/memory/thermal pressure.

## Execution Log

- 2026-07-22T09:34:31-04:00 — Recorded rollback point and began Wave 1 test work. Existing untracked `AGENTS.md` is explicitly out of scope.
- 2026-07-22T09:38:15-04:00 — Wave 1 completed. Xcode test-target compilation confirmed the expected red failures for the four missing policy seams. Began Wave 2 implementations.
- 2026-07-22T09:46:30-04:00 — Wave 2 completed. Universal saver build succeeded with the optional Metal Toolchain and all 62 tests passed. Unauthorized surfaces now remain device-free black; Off/Reduce Motion idle after one static frame; disabled post effects no longer allocate or encode their graphs; renderer initialization failures are graceful. Began Wave 3 topology handling.
- 2026-07-22T09:47:50-04:00 — Wave 3 completed. Standalone app and preview app compile with fail-closed display-topology shutdown handling.
- 2026-07-22T09:49:30-04:00 — Wave 4 completed. Updated runtime documentation, corrected the 24.5× bandwidth calculation, and added staged human-supervised external-display testing guidance. Began Wave 5 self-review.
- 2026-07-22T09:55:00-04:00 — Wave 5 completed. Two independent reviews found and fixed a migrated-primary authorization hole, size-based preview fail-open, unknown-screen recovery issue, submission oversleep race, unpropagated encoder failures, a broken SeasonsShot target, and allocation-failure retry churn. Render-plan tests now require exact graphs. Began Wave 6 validation.
- 2026-07-22T09:57:30-04:00 — Wave 6 completed. Every approved safety/performance item is mapped below to code, tests, documentation, or an explicit deferral. Began Wave 7. The universal saver and all auxiliary targets compile; the complete suite passes 64/64 before the final documented-command rerun.
- 2026-07-22T09:58:00-04:00 — Wave 7 completed. Regenerated from `project.yml`; the exact macOS `build test` verification succeeded with a universal arm64/x86_64 saver and 64/64 tests passing. SeasonsShot, SeasonsPreview, and SeasonsApp also build successfully. No saver was installed or launched.

## Requirements Validation

| Approved requirement | Evidence | Result |
| --- | --- | --- |
| Installed external/unknown surfaces must do zero GPU work by default | `ViewDisplaySafety`, device-lazy `SeasonsView`, and safety-policy tests | Implemented; layer-only black before device, drawable, renderer, queue, or submission |
| A safe view must fail closed if AppKit migrates it | Repeated ownership checks, commit-boundary gate, secondary-only tool authorization, topology observers, and migration-role regression test | Implemented |
| A temporarily unattached view must recover without GPU polling | `waitingForSafeScreen` uses the framework callback to retry authorization before allocating Metal | Implemented |
| Small windows must not gain preview safety authorization | `likelyPreview` is performance-only; safety consumes `ScreenSaverView.isPreview` | Implemented |
| Cross-display submissions must retain real spacing under concurrency and scheduler oversleep | Locked `SubmitGate.recordSpaced`, injected clock/sleeper, concurrency and oversleep tests | Implemented |
| Disabled bloom/DoF/native upscale paths must omit unused targets and passes | `RenderResourcePlan`, conditional renderer encoding, and exact resource/pass tests | Implemented |
| Memory/Metal failures must fail a frame safely instead of crashing or presenting unwritten content | Failable queue/pipeline/buffer/texture setup, encoder-result propagation, allocation retry backoff | Implemented |
| Off and Reduce Motion must stop recurring GPU submissions | `FrameActivityPolicy` and one-static-frame/idle tests | Implemented |
| Bound drawable queuing and preserve drawable render-only optimization | `maximumDrawableCount = 2`, `framebufferOnly = true` | Implemented |
| Preserve full-quality visual pass graph and built-in 120 Hz mode | Exact full graph tests plus independent static pass-order review; 120 Hz tier unchanged | Implemented; no live visual run performed |
| Correct operational and bandwidth guidance | `README.md`, `docs/CRASH-ANALYSIS.md`, `docs/engine.md`, `docs/SAFE-TESTING.md` | Implemented |
| Install/activate or live-test the saver | Explicitly outside the approved implementation run | Not performed; staged human-supervised test remains next |

## Deferred Recommendations

- Change the built-in default from 120 Hz to 60 Hz: deferred to preserve the user's requested premium behavior.
- MTL heaps/aggressive aliasing and multiple command queues: deferred because they add complexity and regression risk beyond the approved hardening pass.
- Cross-view sprite caching: deferred unless implementation evidence shows it is necessary after the zero-GPU external path removes the dominant duplication.
