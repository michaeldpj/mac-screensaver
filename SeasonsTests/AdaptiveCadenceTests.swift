import XCTest

final class AdaptiveCadenceTests: XCTestCase {
    func testExternalCadenceStartsAtThirtyFPS() {
        let clock = CadenceTestClock()
        let controller = AdaptiveExternalCadence(now: clock.now)

        XCTAssertEqual(controller.targetFPS, 30)
    }

    func testRepeatedDrawableMissesReduceCadenceToTwentyFPS() {
        let clock = CadenceTestClock()
        let controller = AdaptiveExternalCadence(now: clock.now)

        controller.recordDrawableMiss()
        controller.recordDrawableMiss()
        XCTAssertEqual(controller.targetFPS, 30, "isolated pressure must not reduce cadence")
        controller.recordDrawableMiss()

        XCTAssertEqual(controller.targetFPS, 20)
    }

    func testSlowGPUFramesAtOrAboveTwentyFiveMillisecondsReduceCadence() {
        let clock = CadenceTestClock()
        let controller = AdaptiveExternalCadence(now: clock.now)

        controller.recordGPUFrame(duration: 0.025)
        controller.recordGPUFrame(duration: 0.030)
        controller.recordGPUFrame(duration: 0.025)

        XCTAssertEqual(controller.targetFPS, 20)
    }

    func testAbnormalSchedulerWaitsReduceCadence() {
        let clock = CadenceTestClock()
        let controller = AdaptiveExternalCadence(now: clock.now)

        controller.recordSchedulerWait(duration: 0.010)
        controller.recordSchedulerWait(duration: 0.012)
        controller.recordSchedulerWait(duration: 0.010)

        XCTAssertEqual(controller.targetFPS, 20)
    }

    func testSubthresholdSamplesDoNotCountAsPressure() {
        let clock = CadenceTestClock()
        let controller = AdaptiveExternalCadence(now: clock.now)

        controller.recordGPUFrame(duration: 0.0249)
        controller.recordSchedulerWait(duration: 0.0099)
        controller.recordDrawableMiss()

        XCTAssertEqual(controller.targetFPS, 30)
    }

    func testPressureEventsExpireOutsideTwoSecondWindow() {
        let clock = CadenceTestClock()
        let controller = AdaptiveExternalCadence(now: clock.now)

        controller.recordDrawableMiss()
        controller.recordDrawableMiss()
        clock.advance(by: 2.001)
        controller.recordDrawableMiss()

        XCTAssertEqual(controller.targetFPS, 30,
                       "expired pressure must not combine with a new event")
    }

    func testReducedCadenceRecoversAfterFifteenHealthySeconds() {
        let clock = CadenceTestClock()
        let controller = AdaptiveExternalCadence(now: clock.now)
        controller.recordDrawableMiss()
        controller.recordDrawableMiss()
        controller.recordDrawableMiss()
        XCTAssertEqual(controller.targetFPS, 20)

        clock.advance(by: 14.999)
        controller.refresh()
        XCTAssertEqual(controller.targetFPS, 20)

        clock.advance(by: 0.001)
        controller.refresh()
        XCTAssertEqual(controller.targetFPS, 30)
    }

    func testPressureRestartsHealthyRecoveryPeriod() {
        let clock = CadenceTestClock()
        let controller = AdaptiveExternalCadence(now: clock.now)
        controller.recordDrawableMiss()
        controller.recordDrawableMiss()
        controller.recordDrawableMiss()

        clock.advance(by: 10)
        controller.recordDrawableMiss()
        clock.advance(by: 5)
        controller.refresh()
        XCTAssertEqual(controller.targetFPS, 20)

        clock.advance(by: 10)
        controller.refresh()
        XCTAssertEqual(controller.targetFPS, 30)
    }
}

final class DisplayCadenceBudgetTests: XCTestCase {
    func testNormalBuiltInDisplayRetainsOneHundredTwentyFPS() {
        XCTAssertEqual(
            DisplayCadenceBudget.builtInFPS(requestedFPS: 120,
                                            externalUltraLite: false,
                                            externalDisplayCount: 3),
            120
        )
    }

    func testBuiltInIsCappedAtSixtyOnlyForThreeUltraLiteExternals() {
        XCTAssertEqual(
            DisplayCadenceBudget.builtInFPS(requestedFPS: 120,
                                            externalUltraLite: true,
                                            externalDisplayCount: 3),
            60
        )
    }

    func testSingleAndDualUltraLiteExternalsLeaveBuiltInUnchanged() {
        for externalCount in [1, 2] {
            XCTAssertEqual(
                DisplayCadenceBudget.builtInFPS(requestedFPS: 120,
                                                externalUltraLite: true,
                                                externalDisplayCount: externalCount),
                120
            )
        }
    }

    func testBudgetNeverRaisesAnExistingBuiltInCap() {
        XCTAssertEqual(
            DisplayCadenceBudget.builtInFPS(requestedFPS: 30,
                                            externalUltraLite: true,
                                            externalDisplayCount: 3),
            30
        )
    }
}

private final class CadenceTestClock {
    private var value: TimeInterval = 100

    func now() -> TimeInterval { value }

    func advance(by interval: TimeInterval) {
        value += interval
    }
}
