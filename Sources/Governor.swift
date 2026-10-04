/// Closed loop: nudges the MetalFX input scale to hold GPU frame time near a target.
/// Resolution scale is the ONLY knob — particle count and post-FX never change.
///
/// Stability over responsiveness. A naive per-frame nudge drives a limit cycle: scale drops,
/// GPU time drops below target, scale climbs back, and the resolution oscillates frame to frame.
/// Each oscillation rebuilds the MetalFX scaler and reallocates the large rgba16Float HDR
/// targets, which thrashes memory bandwidth and the display power rail hard enough to panic the
/// SoC (see docs/CRASH-ANALYSIS.md). Three guards break the cycle:
///   - coarse steps (0.1) so a change is meaningful and rare,
///   - a dead-band between the shed and recover thresholds so it never flips back immediately,
///   - a sustained-dwell requirement plus a post-change cooldown so momentary spikes are ignored.
/// In the common case the GPU keeps up, scale stays pinned at 1.0, and no scaler is ever built.
struct Governor {
    private(set) var scale: Float
    private let target: Float
    private let minScale: Float
    private let maxScale: Float
    private let step: Float

    // Hysteresis: shed above `highBand`, recover below `lowBand`, hold in between.
    private let highBand: Float
    private let lowBand: Float
    private let shedDwell: Float       // sustained seconds over budget before stepping down
    private let recoverDwell: Float    // sustained seconds under budget before stepping up
    private let cooldownPeriod: Float  // seconds to settle after any change

    private var ema: Float = 0
    private var warmed = false
    private var aboveTime: Float = 0
    private var belowTime: Float = 0
    private var cooldown: Float = 0

    init(targetFrameTime: Float, minScale: Float = 0.5, maxScale: Float = 1.0,
         step: Float = 0.1, highBand: Float = 1.25, lowBand: Float = 0.6,
         shedDwell: Float = 0.75, recoverDwell: Float = 2.5, cooldown: Float = 1.5) {
        target = targetFrameTime
        self.minScale = minScale
        self.maxScale = maxScale
        self.step = step
        self.highBand = highBand
        self.lowBand = lowBand
        self.shedDwell = shedDwell
        self.recoverDwell = recoverDwell
        cooldownPeriod = cooldown
        scale = maxScale
    }

    /// Feed last frame's GPU time and the wall-clock delta. Changes `scale` at most once per
    /// cooldown window, and only after a trend has persisted past the matching dwell.
    mutating func record(gpuFrameTime t: Float, dt: Float) {
        ema = warmed ? (ema * 0.9 + t * 0.1) : t
        warmed = true
        if cooldown > 0 { cooldown = max(0, cooldown - dt) }

        if ema > target * highBand {
            aboveTime += dt; belowTime = 0
        } else if ema < target * lowBand {
            belowTime += dt; aboveTime = 0
        } else {
            aboveTime = 0; belowTime = 0   // inside the dead-band: no pressure either way
        }

        guard cooldown <= 0 else { return }
        if aboveTime >= shedDwell, scale > minScale {
            scale = max(minScale, scale - step)
            aboveTime = 0; cooldown = cooldownPeriod
        } else if belowTime >= recoverDwell, scale < maxScale {
            scale = min(maxScale, scale + step)
            belowTime = 0; cooldown = cooldownPeriod
        }
    }
}
