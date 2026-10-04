import XCTest

final class GovernorTests: XCTestCase {
    private let target: Float = 1.0 / 120.0   // 8.33ms

    func testScaleDropsAfterSustainedOverBudget() {
        var g = Governor(targetFrameTime: target)
        let s0 = g.scale
        // 16ms is well over the high band; hold it past the shed dwell.
        for _ in 0..<20 { g.record(gpuFrameTime: 0.016, dt: 0.1) }
        XCTAssertLessThan(g.scale, s0)
    }

    func testMomentarySpikeDoesNotDropScale() {
        var g = Governor(targetFrameTime: target)
        let s0 = g.scale
        // A few over-budget frames shorter than the shed dwell must not change scale.
        for _ in 0..<3 { g.record(gpuFrameTime: 0.016, dt: 0.05) }   // 0.15s < 0.75s dwell
        XCTAssertEqual(g.scale, s0)
    }

    func testDeadBandHoldsScale() {
        var g = Governor(targetFrameTime: target)
        let s0 = g.scale
        // 8ms sits between the recover (5ms) and shed (10.4ms) thresholds: no pressure.
        for _ in 0..<200 { g.record(gpuFrameTime: 0.008, dt: 0.1) }
        XCTAssertEqual(g.scale, s0)
    }

    func testScaleRecoversAfterSustainedHeadroom() {
        var g = Governor(targetFrameTime: target)
        for _ in 0..<20 { g.record(gpuFrameTime: 0.016, dt: 0.1) }   // drive it down first
        let low = g.scale
        XCTAssertLessThan(low, 1.0)
        for _ in 0..<400 { g.record(gpuFrameTime: 0.003, dt: 0.1) }  // lots of headroom, sustained
        XCTAssertGreaterThan(g.scale, low)
    }

    func testCooldownLimitsChangeRate() {
        var g = Governor(targetFrameTime: target)
        // One pass over the shed dwell should step exactly once even though the trend persists,
        // because the cooldown gates the next change.
        for _ in 0..<8 { g.record(gpuFrameTime: 0.016, dt: 0.1) }   // 0.8s ≈ shed dwell, cooldown engaged
        XCTAssertEqual(g.scale, 0.9, accuracy: 0.001)               // exactly one 0.1 step
    }

    func testScaleClampedToBounds() {
        var g = Governor(targetFrameTime: target)
        for _ in 0..<2000 { g.record(gpuFrameTime: 0.5, dt: 0.1) }    // absurdly slow, sustained
        XCTAssertGreaterThanOrEqual(g.scale, 0.5)
        for _ in 0..<4000 { g.record(gpuFrameTime: 0.0001, dt: 0.1) } // absurdly fast, sustained
        XCTAssertLessThanOrEqual(g.scale, 1.0)
    }
}
