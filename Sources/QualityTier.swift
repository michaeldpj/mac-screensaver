import Foundation

/// Per-display render budget. The primary display runs `.full`; secondaries (multi-display
/// mode) run `.lite` so the AGGREGATE load across all displays stays below the single-display
/// configuration that is known stable — the three-display panic was a display-power-rail
/// (DCP) escalation under combined load, not a per-display feature (docs/CRASH-ANALYSIS.md).
struct QualityTier {
    var fps: Double
    var countScale: Float
    var bloom: Bool
    var dof: Bool
    var forcedScale: Float?   // fixed MetalFX input scale (nil = governor-driven)
    var litePost: Bool        // single half-res bloom, no pyramid, no DoF blur (~4 passes vs ~10)
    var presentMaxEdge: Int? = nil   // External Ultra-Lite: clamp the drawable's longest edge (nil = native)
    var present8Bit: Bool = false    // External Ultra-Lite: sRGB-encoded BGRA8 instead of 10-bit XR

    static let full = QualityTier(fps: 120, countScale: 1.0, bloom: true, dof: true,
                                  forcedScale: nil, litePost: false)

    /// Roughly 1/10 the load of `.full`: 30Hz, half-res via MetalFX (the scaler path is proven
    /// safe — rung 2 passed), ~30% of the particles, one small bloom, no depth-of-field. The
    /// particle fraction and internal scale are tunable live (no rebuild) so the multi-display
    /// test can be pushed lighter without recompiling:
    ///   SEASONS_LITE_COUNT (default 0.3)  — secondary particle fraction
    ///   SEASONS_LITE_SCALE (default 0.5)  — secondary MetalFX internal scale
    static var lite: QualityTier {
        let env = ProcessInfo.processInfo.environment
        let count = (env["SEASONS_LITE_COUNT"].flatMap(Float.init)).map { min(max($0, 0.05), 1.0) } ?? 0.3
        let scale = (env["SEASONS_LITE_SCALE"].flatMap(Float.init)).map { min(max($0, 0.3), 1.0) } ?? 0.5
        return QualityTier(fps: 30, countScale: count, bloom: true, dof: false,
                           forcedScale: scale, litePost: true)
    }

    /// External Ultra-Lite HQ (opt-in, experimental): the approved external presentation envelope.
    /// 30fps, ~15% particles, no bloom, no DoF, and a full-scale drawable clamped to ≤2880px on the
    /// longest edge in 8-bit BGRA. A 2880×1620 source at 30Hz cuts source drawable pixel-rate ~10.9x
    /// versus 6720×3780 at 60Hz (4 B/px), while avoiding scaler softness. The physical display link
    /// remains at its configured output resolution and refresh rate. Whether any external config is
    /// panic-safe on every display topology remains unproven (docs/CRASH-ANALYSIS.md).
    static var ultraLite: QualityTier {
        QualityTier(fps: 30, countScale: 0.15, bloom: false, dof: false,
                    forcedScale: 1.0, litePost: true, presentMaxEdge: 2880, present8Bit: true)
    }
}
