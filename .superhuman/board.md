---
id: sh-20260722-persistent-external-ultralite
title: "Persist external Ultra-Lite display mode"
status: completed
created: "2026-07-22T18:35:00-04:00"
updated: "2026-07-22T19:05:00-04:00"
git_tracked: true
total_tasks: 7
completed_tasks: 7
failed_tasks: 0
current_wave: 7
total_waves: 7
rollback_point: "a26344d74f15d15871fb3d828d71273c6846e0a9"
---

# Persistent External Ultra-Lite Mode

## Intake Summary

- **Task**: Make the successfully tested `SEASONS_EXT_ULTRALITE=1` behavior persist for the installed Seasons menu-bar app and Launch at Login.
- **Type**: feature/safety integration.
- **Complexity**: medium.
- **Problem**: the installed app runs on a three-external-display desktop without the temporary environment flag, so the fail-closed policy intentionally creates black surfaces.
- **Success Criteria**: an explicit persisted app menu toggle enables the same 2880, 30 FPS, 15%-particle Ultra-Lite external plan after normal launch and login; the setting is enabled during reinstall; default-off and environment-flag behavior remain intact.
- **Constraints**: app-scoped opt-in only; do not silently enable the legacy `.saver` or preview; preserve `SEASONS_ALL_DISPLAYS` as a separate known-dangerous path; preserve topology shutdown, panorama, adaptive cadence, EDR-off, and all current external safety limits.
- **Dependencies**: existing `Prefs`, `DisplayPolicy`, `DisplayPlan`, `QualityTier.ultraLite`, AppKit menu, SMAppService login flow, Xcode/Metal toolchain.
- **Edge Cases**: no built-in display; settings migration defaults false; environment flag still authorizes test launches; display topology changes while active; normal Launch at Login carries no custom environment.
- **Testing Strategy**: TDD a pure authorization resolver, wire app-scoped persistence, run the full policy/XCTest suite and offscreen checks, build Release, replace/sign the installed app, persist the opt-in, and relaunch without the environment flag. Do not automatically start a fullscreen session.
- **Board Persistence**: git-tracked, consistent with the user-approved prior sessions.

## Project Conventions

- Native Swift/Metal macOS project generated from `project.yml`; all `Sources/` files are shared by the app, preview, saver, and shot target.
- Pure policy belongs outside AppKit and is covered by XCTest; menu-shell behavior lives in `tools/app/main.swift`.
- Persistent shared preferences use the `me.mdpj.Seasons` UserDefaults suite through `Prefs`.
- Verification command: `xcodegen generate && xcodebuild -project Seasons.xcodeproj -scheme Seasons -destination 'platform=macOS' build test`.
- Release app is installed under `~/Applications/Seasons.app`, ad-hoc signed, and Launch at Login is managed by `SMAppService.mainApp`.

## Task Graph

| ID | Title | Type | Size | Dependencies | Wave | Status |
| --- | --- | --- | --- | --- | --- | --- |
| SH-001 | Add persistent authorization policy tests | test | S | — | 1 | done |
| SH-002 | Implement app-scoped persisted authorization | code | S | SH-001 | 2 | done |
| SH-003 | Add external Ultra-Lite menu toggle and policy wiring | code | M | SH-002 | 3 | done |
| SH-004 | Update installation and safety documentation | docs | S | SH-003 | 4 | done |
| SH-005 | Self code review of all changes | review | S | SH-004 | 5 | done |
| SH-006 | Validate changes against original requirements | verify | S | SH-005 | 6 | done |
| SH-007 | Run full project verification and reinstall | verify | M | SH-006 | 7 | done |

## Dependency Graph

```text
SH-001 tests -> SH-002 persistence policy -> SH-003 menu/wiring -> SH-004 docs
  -> SH-005 self review -> SH-006 requirements -> SH-007 verify/reinstall
```

## Tasks

### SH-001: Add persistent authorization policy tests
- **Research Notes**: `DisplayPlan` already proves external Ultra-Lite display decisions. The missing seam is merging environment authorization with an app-owned persisted opt-in.
- **Execution Plan**: Add pure tests for default false, persisted true, and environment true; prove RED before adding the resolver.
- **Acceptance Criteria**: tests establish that persistence can authorize the tested path without weakening the default.

### SH-002: Implement app-scoped persisted authorization
- **Research Notes**: `Prefs` already owns the shared suite. Passing the stored Boolean from the app into `DisplayPolicy.surfaces` prevents the saver and preview from opting in merely because the value exists.
- **Execution Plan**: add a default-false preference and pure resolver; extend the AppKit adapter with a default-false app preference argument while retaining environment precedence.
- **Acceptance Criteria**: default callers remain fail-closed; explicit app preference or environment flag enables only the existing Ultra-Lite plan.

### SH-003: Add external Ultra-Lite menu toggle and policy wiring
- **Execution Plan**: add an explicitly experimental checked menu item, persist changes, and pass the setting only from `Seasons.app` when it creates surfaces.
- **Acceptance Criteria**: normal and Launch-at-Login app starts reuse the stored setting; full-quality all-displays behavior is untouched.

### SH-004: Update installation and safety documentation
- **Execution Plan**: document the permanent menu workflow and distinguish it from the environment test hook and dangerous all-displays path.
- **Acceptance Criteria**: README, safety runbook, and changelog accurately describe the new behavior and residual DCP risk.

### SH-005: Self code review of all changes
- **Execution Plan**: review from rollback `a26344d` across security, correctness, performance, design, readability, convention, and testing; fix all major and reasonable minor findings.
- **Acceptance Criteria**: zero major findings remain.

### SH-006: Validate changes against original requirements
- **Execution Plan**: confirm the installed app launches without an environment variable, reads enabled persistence, still uses Ultra-Lite on all three externals, and retains every safety constraint.
- **Acceptance Criteria**: temporary successful behavior is permanent without broadening unsafe authorization.

### SH-007: Run full project verification and reinstall
- **Execution Plan**: run all tests/builds/tool checks; build Release; quit the old app; replace and ad-hoc sign `~/Applications/Seasons.app`; persist the toggle true; relaunch normally without custom environment; inspect process/defaults/signature. Do not start fullscreen automatically.
- **Acceptance Criteria**: all checks pass and the normally launched installed app is ready to start the verified three-display Ultra-Lite mode.

## Execution Log

- 2026-07-22T18:35:00-04:00 — User confirmed the temporary `SEASONS_EXT_ULTRALITE=1` launch worked and approved making it permanent. Archived the completed star-motion board and recorded clean rollback commit `a26344d`. Began test-first authorization work.
- 2026-07-22T18:43:00-04:00 — SH-001 proved RED on the absent resolver. SH-002 added default-false app persistence and an OR-only authorization resolver; SH-003 injected it solely from Seasons.app and added the explicit experimental menu toggle. Existing environment authorization remains independent. Eighteen focused policy tests passed. SH-004 updated daily-driver installation and safety guidance. Began structured review.
- 2026-07-22T18:48:00-04:00 — SH-005 review found no major or reasonable minor defects. Security/correctness: missing preferences default false; only the app passes persistence; preview and saver call the default-false adapter; the dangerous all-displays flag is not written or enabled; topology shutdown remains unchanged. Performance: the new resolver is a single Boolean OR and selects the already-bounded tier. The app target builds; its only warning is the pre-existing ConfigSheet deprecation. SH-006 mapped all approved requirements successfully. Began exact repository verification and Release installation.
- 2026-07-22T19:05:00-04:00 — SH-007 completed. The exact repository verification passed 128 XCTest cases with zero failures; Python tooling passed 20/20; sprite validation passed all 9 sets and 51 assets; SeasonsShot, SeasonsPreview, and Release SeasonsApp builds succeeded. Re-sealed the Release bundle after detecting its linker-only signature, then strict verification passed with 59 sealed resources. Installed it at `~/Applications/Seasons.app`, saved `externalUltraLite = true`, relaunched normally without a custom environment, and confirmed PID 59870 is running from the installed path. Installed and Release executable SHA-256 hashes match (`db3ef1d…`).

## Convergence Summary

- The app now persists the already-tested three-display Ultra-Lite policy across normal launch and Launch at Login.
- Persistence remains default-off and app-scoped; the preview and legacy saver stay fail-closed.
- The installed Release app is strictly signature-valid and byte-identical to the verified Release executable.
- Fullscreen activation remains an explicit user action through **Start Now**.

## Deferred Work

- Live fullscreen confirmation remains user-triggered via **Start Now** after installation; Codex will not begin the display session automatically.
