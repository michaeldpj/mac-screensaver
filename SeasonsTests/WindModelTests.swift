import XCTest

final class WindModelTests: XCTestCase {
    private var cfg: WindModel.Config {
        WindModel.Config(base: 30, turbulence: 70, fieldScale: 0.0015, evolve: 0.12,
                         gustEveryMin: 25, gustEveryMax: 60, gustStrength: 140, gustWidth: 900)
    }

    func testDeterministicAcrossCalls() {
        // Same absolute time → identical fronts: the property that keeps three displays in
        // one continuous world with zero IPC.
        let a = WindModel.gusts(at: 12345.678, config: cfg)
        let b = WindModel.gusts(at: 12345.678, config: cfg)
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.head, y.head)
            XCTAssertEqual(x.strength, y.strength)
            XCTAssertEqual(x.dir.x, y.dir.x)
        }
    }

    func testOutputsBounded() {
        var t = 0.0
        while t < 3600 {
            for g in WindModel.gusts(at: t, config: cfg) {
                XCTAssertTrue(g.strength.isFinite && g.head.isFinite && g.width.isFinite)
                XCTAssertGreaterThanOrEqual(g.strength, 0)
                XCTAssertLessThanOrEqual(g.strength, cfg.gustStrength * 1.01)
                XCTAssertGreaterThan(g.width, 0)
                XCTAssertEqual(simd_length(g.dir), 1.0, accuracy: 0.001)
            }
            t += 7.3
        }
    }

    func testGustsActuallyOccur() {
        var seen = 0
        var t = 0.0
        while t < 600 {
            seen += WindModel.gusts(at: t, config: cfg).count
            t += 1.0
        }
        XCTAssertGreaterThan(seen, 10, "gusts should fire regularly over 10 minutes")
    }

    func testHeadsAdvanceMonotonically() {
        // A front observed at two nearby times must have moved forward along its direction.
        var t = 0.0
        var checked = 0
        while t < 1200, checked < 8 {
            let g0 = WindModel.gusts(at: t, config: cfg)
            let g1 = WindModel.gusts(at: t + 0.5, config: cfg)
            if let a = g0.first, let b = g1.first, g0.count == g1.count,
               abs(a.dir.x - b.dir.x) < 1e-5 {   // same front, not an epoch rollover
                XCTAssertGreaterThan(b.head, a.head)
                checked += 1
            }
            t += 3.1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testZeroStrengthDisablesGusts() {
        var c = cfg
        c.gustStrength = 0
        XCTAssertTrue(WindModel.gusts(at: 999, config: c).isEmpty)
    }

    func testHeroScheduleFiresAndStaggersByDisplay() {
        var hits0 = 0, hits1 = 0, simultaneous = 0
        var t = 0.0
        while t < 1800 {
            let a = WindModel.hero(at: t, everyMin: 25, everyMax: 50, count: 3, worldSeed: 0x1111)
            let b = WindModel.hero(at: t, everyMin: 25, everyMax: 50, count: 3, worldSeed: 0x2222)
            if let a { hits0 += 1
                XCTAssertGreaterThanOrEqual(a.t, 0); XCTAssertLessThan(a.t, 1)
                XCTAssertLessThan(a.slot, 3)
                XCTAssertTrue(a.dir == 1 || a.dir == -1)
            }
            if b != nil { hits1 += 1 }
            if a != nil && b != nil { simultaneous += 1 }
            t += 1.0
        }
        XCTAssertGreaterThan(hits0, 30, "heroes should fire regularly")
        XCTAssertGreaterThan(hits1, 30)
        XCTAssertLessThan(simultaneous, min(hits0, hits1), "different seeds should stagger")
    }

    func testHeroDisabledWithZeroCount() {
        XCTAssertNil(WindModel.hero(at: 100, everyMin: 25, everyMax: 50, count: 0, worldSeed: 1))
    }

    func testHash01Range() {
        for i in 0..<10_000 {
            let h = WindModel.hash01(UInt64(i))
            XCTAssertGreaterThanOrEqual(h, 0)
            XCTAssertLessThan(h, 1)
        }
    }
}
