import XCTest

final class ShotPerformancePolicyTests: XCTestCase {
    func testNearestRankPercentilesAndMaximumAreReportedInMilliseconds() {
        let report = ShotPerformancePolicy.analyze(
            gpuSeconds: [0.001, 0.002, 0.003, 0.004, 0.100],
            renderFailures: 0
        )

        XCTAssertEqual(report.sampleCount, 5)
        XCTAssertEqual(report.p50Milliseconds!, 3, accuracy: 0.0001)
        XCTAssertEqual(report.p95Milliseconds!, 100, accuracy: 0.0001)
        XCTAssertEqual(report.maxMilliseconds!, 100, accuracy: 0.0001)
        XCTAssertEqual(report.verdict, .hardStop)
    }

    func testPreferredRequiresP95StrictlyBelowTwentyMilliseconds() {
        let preferred = ShotPerformancePolicy.analyze(
            gpuSeconds: [0.010, 0.019], renderFailures: 0
        )
        let caution = ShotPerformancePolicy.analyze(
            gpuSeconds: [0.010, 0.020], renderFailures: 0
        )

        XCTAssertEqual(preferred.verdict, .preferred)
        XCTAssertEqual(caution.verdict, .caution)
        XCTAssertFalse(caution.shouldHardFail)
    }

    func testP95AtHardLimitFails() {
        let report = ShotPerformancePolicy.analyze(
            gpuSeconds: [0.010, 0.025], renderFailures: 0
        )

        XCTAssertEqual(report.verdict, .hardStop)
        XCTAssertTrue(report.shouldHardFail)
    }

    func testZeroSamplesIsConservativeHardStop() {
        let report = ShotPerformancePolicy.analyze(gpuSeconds: [], renderFailures: 0)

        XCTAssertNil(report.p50Milliseconds)
        XCTAssertEqual(report.verdict, .hardStop)
        XCTAssertTrue(report.shouldHardFail)
    }

    func testAnyRenderFailureIsConservativeHardStop() {
        let report = ShotPerformancePolicy.analyze(
            gpuSeconds: [0.005, 0.006], renderFailures: 1
        )

        XCTAssertEqual(report.renderFailures, 1)
        XCTAssertEqual(report.verdict, .hardStop)
        XCTAssertTrue(report.shouldHardFail)
    }
}
