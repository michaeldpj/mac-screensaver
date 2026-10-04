# Apple Feedback report — kernel panic in AppleDCP/DCPEXT0 external-display path

## Summary (one line)

Reproducible kernel panic in AppleDCP/DCPEXT0 external display path triggered by a fullscreen Metal screensaver workload on M5 Max running macOS 26.5.1.

## Description

A userspace Metal application drives a fullscreen, GPU-instanced particle renderer onto external displays. Within seconds to about a minute the machine hard-reboots. The panic faults on the external display coprocessor (DCPEXT0), with AppleDCP listed as the faulting client. The same signature has now occurred four times, and three panic logs are archived. A userspace GPU workload should be throttled, frame-dropped, or returned an error. It should not be able to panic the SoC.

This report states only the observed panic evidence. It does not assert a specific Apple root cause.

## System

- macOS: Tahoe 26.5.1, build 25F80
- Model: MacBook Pro, Mac17,6
- Chip: Apple M5 Max (T6050), 18 CPU cores, 40-core GPU, 64 GB
- Graphics API: Metal 4

## Display configuration at reproduction

- Mode: clamshell, lid closed, external displays only. The built-in panel was not an active display.
- Displays: three Dell U2723QE, 4K, 60 Hz each.
  - Two driven in a scaled HiDPI mode: 6720 x 3780 backing, logical 3360 x 1890 at 60 Hz.
  - One driven at native 3840 x 2160 at 60 Hz (main display).
- Refresh rate: 60 Hz on all three. These panels do not offer ProMotion.
- Connection / dock path: NEEDS CONFIRMATION (USB-C / DisplayPort; possible MST daisy-chain or dock in path).
- HDR / EDR active at crash: NEEDS CONFIRMATION. The panels are HDR-capable. The application's default presentation is SDR, 10-bit Display P3, no extended-range content. An experimental EDR path exists behind a flag and is off by default.

The panic also reproduces with a single external display. One earlier instance occurred about 60 seconds into a single-external run. Three simultaneous displays reach the panic faster. The built-in panel has never faulted in any run.

## Panic signature (recurring across three archived logs)

```
panic(cpu N caller 0x...): DCPEXT0 PANIC - [CED] CLLT escalation detected
 - power(6)
Client: AppleDCP-1041.120.7~580-t605xdcp.RELEASE   RTKit-3255.120.11.release
bug_type: 210   os_version: macOS 26.5.1 (25F80)   product: Mac17,6
```

Most recent instance: timestamp 2026-06-11 18:53:24 -0400, faulting on the first external display coprocessor (DCPEXT0).

## Timeline

- 2026-05-31: panic during a multi-display run.
- 2026-06-10: two panics (one single external, one three displays).
- 2026-06-11 18:53:24: panic in a clamshell, three-external configuration.

All carry the DCPEXT0 / AppleDCP signature on T6050.

## Reproduction context

- Workload: fullscreen Metal 4 screensaver. GPU-instanced particle simulation, internal rgba16Float pipeline, multi-pass post (bloom), presented to a native-resolution fullscreen drawable at 60 Hz.
- Path: the animated surface lands on an external display, and the fault is on that display's coprocessor.
- Threshold: a single external display is sufficient to trigger the panic. Three displays trigger it faster.

## Expected versus actual

- Expected: when a userspace Metal workload exceeds what the display pipeline can sustain, the system throttles it, drops frames, or returns an error to the application.
- Actual: the external display coprocessor reports an unsatisfiable power escalation (CLLT, power(6)) and the SoC panics, rebooting the machine.

## Distinct from the 26.5.1 content-filtering shutdown fix

macOS 26.5.1 addresses an M5 unexpected-shutdown issue tied to content-filtering Network Extensions. This report is a different issue. The panic faults in AppleDCP / DCPEXT0, the display coprocessor, not in NetworkExtension. The system is already running 26.5.1 (build 25F80), which includes that Network Extension fix, and the DCPEXT0 panic still reproduces.

## Current workaround (application side)

The application now avoids the trigger rather than relying on the system to clamp it:

- Built-in display: animation allowed.
- External displays: renderer disabled, static content only.
- Clamshell, external-only: nothing animates on any display.

This prevents the panic in local testing. It also means the product cannot run its intended animation on external displays until the display-stack panic is resolved.

## Attachments

- 2026-06-11 panic: `panic-full-2026-06-11-185324.0002.panic`
- 2026-06-10 panics: two logs with the same DCPEXT0 signature

Archived locally. The full logs are not published because they contain device identifiers.

## Items needing confirmation before submission

- External display connection path: direct USB-C / DisplayPort, MST daisy-chain, or dock (and dock model).
- Cable and adapter specifics.
- Whether HDR was enabled on the displays at crash time, and whether the experimental EDR application path was active during any crashing run.
- The system reports CPU cores as "6 Super and 12 Performance"; confirm preferred wording for the report.
