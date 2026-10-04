# Crash analysis — SoC power-management panics (2026-05-31, 2026-06-10 ×2, 2026-06-11)

## FIXED 2026-06-11 — fourth panic (clamshell) exposed the residual trigger: the SDR default animated an external

Fourth hard reboot, archived locally as `2026-06-11-clamshell-dcpext0-cllt.panic`, not published
(source `panic-full-2026-06-11-185324.0002.panic`), IDENTICAL signature to the June 10 pair:

```
panic(cpu 5 caller 0xfffffe0038e2e4bc): DCPEXT0 PANIC - [CED] CLLT escalation detected - power(6)
Client: AppleDCP-1041.120.7~580-t605xdcp.RELEASE   RTKit-3255.120.11.release
bug_type: 210   os: macOS 26.5.1 (25F80)   Mac17,6 (M5 Max T6050)   timestamp: 2026-06-11 18:53:24 -0400
```

Configuration: CLAMSHELL — lid closed, external displays only, no built-in panel. The SDR-default
presentation (`9ef45e7`) and primary-only animation (`f54ac59`) were both already in place, and it
still panicked. Why: `DisplayPolicy.animationTarget` returned `NSScreen.main` for the SDR default,
behind the comment "SDR is proven safe on externals." That comment is FALSE — this document's own
rung-1 retest disproves it (SDR on a single external panicked in ~60s). On a clamshell desk
`NSScreen.main` is an external, so the default animated an external surface → `DCPEXT0` → reboot.

The invariant true across all four panics: every one is `DCPEXT0` — an EXTERNAL display coprocessor.
The built-in XDR panel has never faulted. So the durable rule is to NEVER animate an external by
default.

Fix (committed): the display decision is now a pure function `DisplayPlan.decide`
(`Sources/DisplayDecision.swift`, no AppKit, unit-tested) that pins animation to the BUILT-IN panel
in every mode — default, `SEASONS_SINGLE_DISPLAY`, and `SEASONS_MULTI`. With no built-in present
(clamshell) the target is nil and NOTHING animates: every display stays opaque black with no Metal
device, drawable, renderer, or command submission. `DisplayPolicy.surfaces()` is now a thin
`NSScreen`→spec adapter. Externals animate only under the explicit `SEASONS_ALL_DISPLAYS` repro flag,
kept solely to reproduce the bug for an Apple Feedback.

The installed `.saver` does not route through `DisplayPolicy` — the ScreenSaver host instantiates one
`SeasonsView` per display directly — so `SeasonsView` also checks its current screen at startup and
immediately before renderer construction, drawable acquisition, and submission. Unknown and external
screens fail closed to a layer-only black path. The `SEASONS_SINGLE_DISPLAY` hint is not an external
bypass; only tool-planned views or the explicit `SEASONS_ALL_DISPLAYS` crash-reproduction override are
authorized. A view that migrates to an unauthorized screen releases its renderer and display link.

Verification now includes 77 XCTests, including 15 display-plan cases, 8 per-view fail-closed cases,
5 render-resource plans, 5 static-cadence cases, adaptive external cadence coverage, and concurrent
fair-submit coverage. The universal
`.saver`, standalone app, and preview app build with the optional Metal Toolchain. Stale pre-mitigation
`~/Library/Screen Savers/Seasons.saver` (May 30) disarmed (renamed `.DISABLED-20260611`); active macOS
module is Electric Sheep. Apple Feedback still owed — userspace Metal must never be able to assert the
SoC; we can only avoid the trigger.

**Reporting guidance.** The Feedback report (drafted in `docs/apple-feedback-2026-06-11-dcpext0.md`)
states only the observed evidence — a reproducible kernel panic in the AppleDCP/DCPEXT0 external-display
path — and does NOT assert Apple's root cause. The firmware/RTKit interpretation in the sections below
is internal analysis: the faulting client is `AppleDCP-…t605xdcp.RELEASE RTKit`, the real-time OS that
runs on the display coprocessor, so a DCP power-management firmware fault is the working hypothesis. That
hypothesis stays out of the report. Attach the logs and let Apple assign the cause.

## ARCHITECTURE VERIFIED 2026-06-11 — rendering is already per-display; external presentation workload remains high risk

A code audit (Renderer.swift, SeasonsView.swift, DisplayPolicy.swift, ParticleSystem.swift) confirms the
renderer remains per-display even when the optional Ultra-Lite panorama shares simulation coordinates:

- One authorized `SeasonsView` → one `CAMetalLayer` → one `Renderer` → one `ParticleSystem` per
  animated `NSScreen`. Unauthorized screens retain only an opaque black layer. The
  `.saver` host, `tools/app`, and `tools/preview` each create one view per screen. Authorized Ultra-Lite
  externals replicate the same seeded global particle state and use per-view camera crops; built-in and
  non-panorama views keep their local world.
- No offscreen target is allocated at combined multi-display dimensions. `ParticleSystem` is a
  count-sized buffer. Renderer targets are sized from this view's drawable and are now conditional:
  bloom/DoF intermediates do not exist when disabled, and graded/upscaled targets exist only while
  MetalFX is actually upscaling. Panorama computes only a small desktop-layout union descriptor; it never
  uses that union to allocate a drawable, texture, or particle buffer.

So per-screen independence is NOT the safety lever — each screen is already independent, and a single
external panicked on its own. Source drawable size, format, commit cadence, and aggregate GPU work are
controllable risk factors. The physical display-link bandwidth is managed by macOS and the display
hardware and should not be inferred directly from the app's source drawable rate.

Captured 2026-06-11 (zero-render NSScreen read, clamshell, three Dell U2723QE):

| Display | frame (pt) | scale | drawableSize (px) | present @60Hz (SDR, 4 B/px) |
|---|---|---|---|---|
| #0 external | 3360×1890 | 2.0 | 6720×3780 = 25.4M | ~6.1 GB/s |
| #1 external | 3360×1890 | 2.0 | 6720×3780 = 25.4M | ~6.1 GB/s |
| #2 external (main) | 3840×2160 | 1.0 | 3840×2160 = 8.3M | ~2.0 GB/s |

The two monitors in a scaled "more space" HiDPI mode request a 6720×3780 source drawable, three times the
pixels of native 4K. The table's rates are raw source-buffer pixel-rate estimates, not measurements of
physical link traffic. This much larger presentation workload remains a prime risk factor.

MetalFX lowers the INTERNAL render size, but the final drawable otherwise remains
`bounds × backingScale`, so the existing lite tier does not reduce source presentation size. App-level
levers include drawable size, submitted frame cadence, format, and post-processing work. EDR
`rgba16Float` is 8 B/px versus 4 B/px for SDR and is already off by default. `bgra8` and `bgra10_xr`
are both 4 B/px.

The opt-in External Ultra-Lite mode clamps the external `CAMetalLayer.drawableSize` itself to
2880×1620 or lower, forces native 1.0 render scale, uses SDR with EDR off, a 30 FPS target,
sRGB-encoded BGRA8 in Display-P3, 15% particles, no bloom, and no depth of field. With both effects
disabled, a dedicated no-effects composite samples only the scene; it does not allocate or bind dummy
bloom/DoF targets. The retained scene+CoC pair is about 71.2 MiB at 2880×1620 per display, or about
213.6 MiB across three displays. Three maximum-size sources at 30 FPS submit approximately 419.9 million
pixels/s—2.25× the former 1920×1080 Ultra-Lite envelope, but about 8.45× below the captured aggregate
of two 6720×3780 sources plus one 3840×2160 source at 60 FPS. The monitors remain configured at their normal refresh rates and resolutions;
these are source-drawable work estimates, not physical-link measurements. This higher-quality mode
remains explicitly unproven against the kernel panic. The shipped default is unchanged: built-in
animation only, GPU-free black externals, and no animation in clamshell/external-only setups. Follow
`docs/SAFE-TESTING.md` and test only through its staged, human-supervised procedure.

The multi-display Ultra-Lite scheduler is FIFO: all planned surfaces receive a commit slot, with at
least 2 ms between admissions. This replaces the former best-effort gate that could repeatedly drop the
same display's synchronized ticks. Each external starts at 30 FPS and independently reduces to 20 FPS
after repeated drawable misses, GPU frames ≥25 ms, or coordinator waits ≥10 ms; it recovers after 15
healthy seconds. With three Ultra-Lite externals, an active built-in is capped at 60 FPS. These controls
reduce coincidence and aggregate pressure; they do not establish that the AppleDCP path is panic-safe.

The panorama does not increase per-display particle count or retained target dimensions. Replicas advance
the same fixed 30 Hz world tick and crop it locally, allowing cross-screen motion without a combined render
surface. Mixed 30/20 FPS callbacks may integrate two fixed steps on a slower presentation. A 120-step
catch-up bound and shared invalidation prevent a stalled replica from silently diverging; failure takes the
entire external group to GPU-free black. This improves visual consistency but is not an additional claim
about DCP safety.

---

# Crash analysis — SoC power-management panics (2026-05-31, 2026-06-10 ×2)

## LADDER RESULTS 2026-06-10 evening — the trigger is AGGREGATE multi-display load

| Rung | Config | Result |
|---|---|---|
| 1 | SDR, MetalFX off, 60Hz, single display (external 4K, 3840×2160) | **PASS** — clean run, 0 GPU errors, clean exit |
| 2 | SDR, MetalFX ON (`SEASONS_FORCE_SCALE=0.7`), 60Hz, single display | **PASS** — scaler path clean |
| 3 | SDR, MetalFX off, 60Hz, ALL THREE displays | **PANIC** — third hard reboot (~19:33) |

Combined with the 2026-06-10 afternoon panic (single EXTERNAL display + EDR), the picture:

- **EDR on an external display**: panics alone (afternoon, DCPEXT0 CLLT escalation).
- **SDR single display**: stable, even through MetalFX. Per-display load is fine.
- **SDR × three displays simultaneously**: panics. Three full pipelines (compute sim + ~10
  fullscreen rgba16Float passes each at native res, 60Hz, in lockstep) ≈ 3× aggregate
  memory/display-rail traffic. The DCS/DCP power arbitration cannot satisfy the combined
  demand and asserts — same failure family as panic 1 (which also ran every display).
- Observed: a reproducible kernel panic in the AppleDCP/DCPEXT0 external-display path; userspace
  Metal must never be able to panic the SoC. Internal hypothesis (not for the report): M5 (T6050)
  DCP power-management firmware. File Feedback with all three logs, stating only the observed panic.

### Panic 3 parsed (archived locally as `2026-06-10-rung3-dcpext0-cllt.panic`, not published)
```
panic(cpu 6 caller 0xfffffe004e6624bc): DCPEXT0 PANIC - [CED] CLLT escalation detected
 - power(6)
Client: AppleDCP-1041.120.7~580-t605xdcp.RELEASE   RTKit-3255.120.11.release
bug_type: 210   os: macOS 26.5.1 (25F80)   timestamp: 2026-06-10 19:34:05 -0400
```
IDENTICAL signature and faulting-task call-stack shape to panic 2 (offsets differ only by
ASLR). The external display's DCP reaches the same unsatisfiable `power(6)` escalation two
different ways: an EDR surface on that display alone (panic 2), or aggregate bandwidth from
three simultaneous SDR pipelines (panic 3). Single-display SDR — including through MetalFX —
stays comfortably below the threshold (rungs 1–2 passed). One firmware bug, two userspace
paths into it; both now avoided by default (SDR presentation + built-in-only animation).

### Mitigation plan (no further live tests until implemented; NO live tests 2026-06-10)
1. **Built-in-only animation as the default product mode.** Animate the built-in panel;
   other displays get a layer-only pure-black cover with no Metal device, drawable, renderer,
   display link, or command submission. Aggregate load collapses to the
   proven-safe single-display case while every screen is still covered.
2. **"All displays" mode behind an explicit experimental flag**, with aggregate-load reduction
   for whenever it is re-attempted: secondaries at 30Hz + forced 0.6 internal scale (MetalFX
   upscale — rung 2 proved that path), display links phase-staggered so three command buffers
   never land on the rail in the same beat.
3. Single-display soaks (long-form, per season) can continue safely; they are the only live
   testing permitted until 1) ships.


## UPDATE 2026-06-10: second panic ON THE SAFEST LADDER RUNG — hypothesis revised

Rung 1 of the re-test ladder panicked the Mac within ~60 seconds (launched ~18:42, reboot 18:43,
macOS 26.5.1, Xcode 26.5). Configuration: Seasons Preview, autumn, SINGLE display,
`SEASONS_FORCE_FPS=60`, `SEASONS_DISABLE_METALFX=1` — governor pinned at 1.0, no scaler ever
built, no HDR-target reallocation, one screen.

Consequence: **MetalFX scale churn and multi-display EDR are exonerated as necessary
conditions.** The same offscreen pipeline had just rendered 240 frames × 5 seasons with zero
errors. The delta between offscreen (survives) and live rung 1 (panics in under a minute):

| In live path only | Suspicion |
|---|---|
| `CAMetalLayer` with `wantsExtendedDynamicRangeContent = true` → display engine enters EDR/HDR mode | **PRIME** — matches `DISP_CTL` in panic 1 register dump; EDR engagement forces large display-rail DVFS transitions |
| `rgba16Float` (64-bit) drawable scanout | High — doubles scanout bandwidth on the DCS rail |
| `CADisplayLink` 60Hz cap on a 120Hz ProMotion panel (rate switching) | Medium |
| `.screenSaver`-level borderless window compositing | Low |

Revised mitigation (next code change, before ANY further live run):
1. **SDR-P3 presentation mode as default**: drawable `bgra10_xr` or `bgra8Unorm` with
   `wantsExtendedDynamicRangeContent = false`, display-P3 (non-extended) colorspace; internal
   pipeline stays rgba16Float linear — only the final drawable changes. On the XDR panel SDR
   still reaches ~1000 nits with full P3; visual cost is limited to EDR glow accents.
2. `SEASONS_EDR=1` opt-in flag for the EDR path, marked experimental until Apple fixes the rail.
3. Next ladder bisects presentation only: SDR-8bit → SDR-10bit(xr) → 16F+no-EDR-flag → EDR,
   each ≥10 min soak, single display, Michael present, work saved.
4. File Apple Feedback with both panic logs — userspace must not be able to assert the SoC. The
   report sticks to the observed panic (kernel panic in the AppleDCP/DCPEXT0 external-display path);
   the firmware/RTKit reading stays internal. Either way, we can only avoid the trigger.

## CONFIRMED 2026-06-10 (panic log parsed): external-display DCP power escalation

```
panic(cpu 16 caller 0xfffffe004a4224bc): DCPEXT0 PANIC - [CED] CLLT escalation detected
 - power(6)
Client: AppleDCP-1041.120.7~580-t605xdcp.RELEASE   RTKit-3255.120.11.release
bug_type: 210   os: macOS 26.5.1 (25F80)   timestamp: 2026-06-10 18:43:31 -0400
```
Full log archived locally as `2026-06-10-dcpext0-cllt.panic`, not published.

Decode: `DCP` is the Display Coprocessor; `EXT0` is the first EXTERNAL display. Its firmware
panicked on a power-state escalation (`CLLT` — the same register family dumped in panic 1's
`CLLT_STATUS`/`CLLT_GLB_CTL`) that could not be satisfied (`power(6)`).

Refined root cause: `SEASONS_SINGLE_DISPLAY` targets `NSScreen.main` — the focused screen,
which was an external monitor. The view requested a fullscreen EDR surface
(`wantsExtendedDynamicRangeContent` + rgba16Float) on a display whose engine cannot deliver
XDR-class EDR. The DCP chased the power escalation and asserted. The 2026-05-31 panic ran the
saver on every display including externals — same path (its register dump flagged
`DISPEXT0_CTL`). The internal XDR panel is likely fine with EDR; the externals are not, and
macOS lets the request panic the SoC instead of clamping it (Apple bug — file Feedback with
both logs).

The SDR-P3 default presentation (committed 9ef45e7) removes the trigger on every display.
EDR opt-in via `SEASONS_EDR=1` should only ever be pointed at the built-in XDR panel until
Apple fixes the DCP.

---

# Original analysis — panic on 2026-05-31 (19:58:08)

## Verdict
A SoC-level power-management watchdog panic on the M5 Max (T6050), provoked by the renderer's
load pattern. NOT a logic bug in the particle/shader code — that code is clean and bounds-safe
(md5-verified against HEAD). The fault is the silicon's Power Management Controller asserting a
DVFS latency timeout on the memory/display rail.

## The panic (authentic backtrace)
```
panic(cpu 3 caller 0xfffffe0052e764bc): "PMC0 Assert ID: 0x4c, rail:DCS, limit:0x2580,
  latency:0x2ca2, resolved_vec:0x35, target_vec:0x35, current_vec:0x36
  ... DISP_CTL 0x85408001 ... DCS_PERF_DEBUG 0x6ba00000 SOC_PERF_DEBUG 0x00000001
  DISP_PERF_DEBUG 0x00000000 " @AppleSoCErrorHandlerT6050.cpp:3272
bug_type: 210   os: macOS 26.5 (25F71)   kernel: xnu-12377.121.6 RELEASE_ARM64_T6050
timestamp: 2026-05-31 19:58:08 -0400
```

## Decode
- `AppleSoCErrorHandlerT6050` — M5 Max silicon-level error handler (T6050 = the chip). This is a
  hardware/firmware power-rail assertion, not a Metal API or userspace GPU exception.
- `PMC0 Assert, rail:DCS` — the Power Management Controller asserted on the **DCS rail**
  (DRAM / display-coherent subsystem: memory controller + display pipeline).
- `latency:0x2ca2 (11426) > limit:0x2580 (9600)` — a power-state (DVFS) transition exceeded its
  latency watchdog budget. `current_vec:0x36` could not settle to `target_vec:0x35` in time;
  the rail oscillated between vectors and a transition timed out → hardware assert → reboot.
- `DISP_CTL` / `DISP_PERF_DEBUG` register dump — the display controller is part of the implicated
  rail, consistent with the symptom (one display frozen, the other showing green framebuffer
  garbage as the display/memory rail stalled mid-transition).

## Why our renderer triggers it
The DCS rail is memory-bandwidth + display bound. The engine drives it into rapid, oscillating
DVFS transitions:
1. **MetalFX dynamic-scale churn (primary).** The performance governor changes render scale in
   response to per-frame GPU time. On each change `ensureScaler`/`ensureInternal` recreate the
   spatial scaler and reallocate the large `rgba16Float` targets (scene, coc, graded, upscaled +
   half-res bloom/DoF). Reallocating and re-driving big HDR surfaces frame-to-frame thrashes
   memory bandwidth and forces the DCS rail to chase a moving power target — exactly the
   `vec 0x35 ↔ 0x36` oscillation in the panic.
2. **Dual-display EDR at 120Hz.** Two `MTKView`s each presenting `rgba16Float` extended-dynamic-
   range drawables at ProMotion 120Hz doubles the sustained display+memory demand on the same rail.
3. **M5 + Tahoe firmware immaturity.** A userspace app should not be able to panic the SoC; the
   power-controller latency margin on brand-new silicon/OS is unforgiving. We mitigate by not
   producing the pathological load; also worth a macOS update + an Apple Feedback report with
   this panic attached.

## Fix plan (our side — prioritized)
1. **Governor hysteresis + debounce.** Stop oscillating render scale. Quantize scale coarsely,
   require a sustained trend (e.g. N seconds) before changing, and add a dead-band so it never
   flips back and forth. This alone removes the per-frame rail thrash.
2. **No transient reallocation.** Only recreate the MetalFX scaler / reallocate HDR targets on a
   sustained scale change, never on momentary GPU-time spikes. Debounce ties into (1).
3. **MetalFX off switch (safe baseline).** `SEASONS_DISABLE_METALFX` → fixed native scale, no
   scaler, no per-frame realloc. This is the known-safe configuration to validate first.
4. **Reduce rail pressure.** Cap present to 60Hz (`SEASONS_FORCE_FPS=60`), and cut HDR target
   count / consider a cheaper format where EDR is not needed. Optional single-display mode for
   isolation (`SEASONS_SINGLE_DISPLAY`).
5. **Diagnostics.** Log `done.error`/`done.status` in the command-buffer completion handler.

## Re-test safety (every live test can reboot the Mac until fixed)
Keep the screensaver DISARMED. Bisect from zero-risk upward:
1. `tools/shot` — offscreen render, no drawable present, no MetalFX, no display DVFS. Cannot hit
   the DCS/display rail. Proves the pipeline renders.
2. `Seasons Preview.app`, ONE display, MetalFX OFF, 60Hz. 
3. MetalFX ON with the new hysteresis governor, one display.
4. Two displays.
Each step that survives moves up; the first that panics names the remaining trigger.

## Safety state
- Auto-start DISARMED: `defaults -currentHost write com.apple.screensaver idleTime 0`.
- `Seasons.saver` still installed and selected; do NOT restore `idleTime` until the ladder passes.
- Shaders clean vs HEAD (md5). System healthy post-reboot (load normal, no thermal/HW errors).
- Earlier versions of this file blamed particle-code bugs (OOB / div-by-zero); those were written
  from corrupted tool output and are RETRACTED. The panic backtrace above is the ground truth.
