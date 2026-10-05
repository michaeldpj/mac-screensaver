# Safe display testing

The changes in this branch materially reduce Seasons' GPU memory and submission load, but they cannot
guarantee that macOS will not panic. The recorded failures occur in AppleDCP/DCPEXT0 kernel/firmware
code, and a single animated external display has panicked this Mac before. Treat every external-animation
flag as experimental. `SEASONS_ALL_DISPLAYS` exists only to reproduce the known-dangerous path for Apple.

## 0. Keep automatic launch disarmed

- Leave the installed `Seasons.saver` disabled and macOS screensaver start time set to Never while testing.
- Leave **External Displays — Ultra-Lite 30 FPS** off until the staged external tests pass.
- Quit any older Seasons app before building. Do not copy a test bundle into `~/Library/Screen Savers`.
- Keep unsaved work closed. A kernel panic is still possible once an external is deliberately animated.

## 1. Verify without presenting to a display

```sh
xcodegen generate
xcodebuild -project Seasons.xcodeproj -scheme Seasons -destination 'platform=macOS' build test
xcodebuild -project Seasons.xcodeproj -scheme SeasonsApp -destination 'platform=macOS' build
xcodebuild -project Seasons.xcodeproj -scheme SeasonsPreview -destination 'platform=macOS' build
```

Expected: Metal shaders compile with the optional Metal Toolchain, the universal `.saver` builds, and
all tests pass. These commands do not start the screensaver or a fullscreen render session.

## 2. Exercise the safe display policy

With the MacBook open and all three external monitors connected, launch the standalone app with no
experimental environment flags. Start one short session.

Expected:

- Only the built-in panel animates.
- Every external is opaque black and owns no Seasons Metal device, drawable, renderer, or command queue.
- Connecting, disconnecting, rearranging, or changing the resolution of a monitor ends the session.
- Activity Monitor shows no runaway memory growth; Console shows no Metal command-buffer errors.

In clamshell/external-only mode, the expected safe default is black on every display with no animation.
That verifies coverage and policy, not the external rendering experiment.

## 3. Optional single-external Ultra-Lite experiment

Do this only if external animation is worth the remaining reboot risk.

1. Disconnect the other external monitors and keep the built-in display available.
2. Confirm EDR and the all-display repro flag are unset.
3. In a Terminal, run `export SEASONS_EXT_ULTRALITE=1`, launch the Preview executable from that same
   Terminal, and keep the Terminal available as the control point. Run only a brief session, then stop
   and review Activity Monitor and Console before increasing duration.
4. Stop immediately for artifacts, UI stalls, rising memory pressure, Metal errors, or abnormal thermals.

Ultra-Lite clamps the external source drawable to at most 2880×1620, renders at forced scale 1.0,
targets 30 FPS in sRGB-encoded 8-bit BGRA/Display-P3 with EDR disabled, uses 15% particles, and
disables bloom and DoF. With both effects disabled, the renderer uses a scene-only composite and
retains only scene+CoC—about 71.2 MiB per 2880×1620 display. The monitor itself remains configured
at its normal 60 Hz refresh and output resolution; 30 FPS is the application's presentation target.
For a 6720×3780@60 source surface, this cuts submitted source-drawable pixel rate about 10.9×. This
is a rendering-work estimate, not a claim about physical link traffic and not proof of safety.

**Panic switch:** quit the Preview immediately, then run `unset SEASONS_EXT_ULTRALITE` in every
Terminal that may launch it. The switch is presence-based; `SEASONS_EXT_ULTRALITE=0` still enables
Ultra-Lite. Relaunch without experimental flags and verify externals are GPU-free black.

## 4. Three-external setup

First repeat step 2 with the full physical setup; the safe result is still built-in-only animation, or
all-black when clamshell. Do not proceed to three animated externals unless the single-external Ultra-Lite
test has completed cleanly and a reboot is acceptable. Never use `SEASONS_ALL_DISPLAYS` for a normal soak.

For the deliberate three-external test, use only `SEASONS_EXT_ULTRALITE=1`. The approved target is
30/30/30 FPS: each external starts at 30 FPS. Three maximum-size 2880×1620 drawables submit about
419.9 million source pixels/s, 2.25× the old 1920×1080 envelope, and retain about 213.6 MiB total for
their scene+CoC pairs. A shared FIFO coordinator admits every display in order and separates command-buffer commits by
at least 2 ms, so synchronized display links cannot starve one monitor. If an external repeatedly misses
drawables, reports GPU frames of at least 25 ms, or waits at least 10 ms for admission, that display drops
to 20 FPS. It returns to 30 FPS after 15 seconds without pressure. With three animated Ultra-Lite
externals and an active built-in display, the built-in is capped at 60 FPS to preserve aggregate headroom.

When at least two authorized Ultra-Lite externals participate, they are camera crops of one shared
30 Hz deterministic particle world. Display arrangement, vertical offsets, and gaps are preserved;
particles traverse those coordinates instead of restarting at each monitor. Simulation is replicated in
small per-display buffers—there is no combined desktop drawable or shared giant render target. A drawable
miss does not block peers. If any replica cannot remain synchronized or exceeds the bounded catch-up,
the shared panorama is invalidated and all participating views fail closed to GPU-free black. Presentation
is deliberately staggered rather than atomic, so a fast object may still show a tiny temporal discontinuity
at a bezel even though its simulation state is shared.

Console emits an `external health` line per animated external every five seconds. Check `targetFPS`,
`observedFPSx10`, `drawableMisses`, `renderFailures`, `waitAvgUs`, `waitMaxUs`, and `gpuUs`. Stop if one
display remains visibly stalled, misses or failures continue rising, waits repeatedly exceed 10,000 µs,
GPU time repeatedly exceeds 25,000 µs, or the machine shows artifacts, stalls, abnormal thermals, or
memory pressure. A change from 30 to 20 FPS is a protective response, not itself a failure.

No automated or assistant-driven test should launch a live external render. A person at the Mac should
start and stop each session and monitor the machine throughout.

Use a staged, human-supervised sequence: one external, then two, then all three, returning to a stopped
and unflagged process between stages. A pass at one stage does not prove the next stage safe. Never use
`SEASONS_ALL_DISPLAYS`; it bypasses Ultra-Lite and exists only as a historical crash-reproduction path.

After the full three-display sequence succeeds, the installed menu-bar app may persist the same
authorization through **External Displays — Ultra-Lite 30 FPS**. This preference is
app-scoped: normal Launch at Login reads it, while the preview and legacy saver do not. To fail closed,
quit the active session, turn the menu item off, and leave `SEASONS_EXT_ULTRALITE` unset. The persisted
option removes repeated Terminal setup; it does not change the residual AppleDCP risk or make
`SEASONS_ALL_DISPLAYS` acceptable.
