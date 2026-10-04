import XCTest

final class PanoramaLayoutTests: XCTestCase {
    func testHorizontalDisplaysNormalizeIntoOneYDownWorldAndMeetAtTheSeam() throws {
        let layout = try PanoramaLayout(displays: [
            PanoramaDisplayGeometry(id: 10, x: -1920, y: 0, width: 1920, height: 1080),
            PanoramaDisplayGeometry(id: 20, x: 0, y: 0, width: 2560, height: 1440),
        ], sessionSeed: 0xA11CE)

        XCTAssertEqual(layout.worldSize, SIMD2<Float>(4480, 1440))
        XCTAssertEqual(layout.windOrigin, SIMD2<Float>(-1920, -1440))

        let left = try XCTUnwrap(layout.projection(for: 10))
        let right = try XCTUnwrap(layout.projection(for: 20))
        XCTAssertEqual(left.cameraOrigin, SIMD2<Float>(0, 360))
        XCTAssertEqual(left.cameraSize, SIMD2<Float>(1920, 1080))
        XCTAssertEqual(right.cameraOrigin, SIMD2<Float>(1920, 0))
        XCTAssertEqual(right.cameraSize, SIMD2<Float>(2560, 1440))

        let seam = SIMD2<Float>(1920, 720)
        XCTAssertEqual(left.localPoint(forWorldPoint: seam), SIMD2<Float>(1920, 360))
        XCTAssertEqual(right.localPoint(forWorldPoint: seam), SIMD2<Float>(0, 720))
    }

    func testNegativeAndStackedOriginsInvertAppKitYAndPreserveGaps() throws {
        let layout = try PanoramaLayout(displays: [
            PanoramaDisplayGeometry(id: 1, x: -1600, y: -900, width: 1600, height: 900),
            PanoramaDisplayGeometry(id: 2, x: 200, y: 600, width: 1200, height: 800),
        ], sessionSeed: 7)

        XCTAssertEqual(layout.worldSize, SIMD2<Float>(3000, 2300))
        XCTAssertEqual(layout.windOrigin, SIMD2<Float>(-1600, -1400))

        let lowerLeft = try XCTUnwrap(layout.projection(for: 1))
        let upperRight = try XCTUnwrap(layout.projection(for: 2))
        XCTAssertEqual(lowerLeft.cameraOrigin, SIMD2<Float>(0, 1400))
        XCTAssertEqual(upperRight.cameraOrigin, SIMD2<Float>(1800, 0))

        // The 200-point horizontal and 600-point vertical holes remain part of the world;
        // particles traverse them invisibly rather than snapping between cameras.
        XCTAssertEqual(upperRight.cameraOrigin.x - lowerLeft.cameraSize.x, 200)
        XCTAssertEqual(lowerLeft.cameraOrigin.y - upperRight.cameraSize.y, 600)
    }

    func testEveryProjectionSharesOrderIndependentTopologySeed() throws {
        let displays = [
            PanoramaDisplayGeometry(id: 42, x: 0, y: 0, width: 1920, height: 1080),
            PanoramaDisplayGeometry(id: 7, x: -1920, y: 0, width: 1920, height: 1080),
            PanoramaDisplayGeometry(id: 99, x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let forward = try PanoramaLayout(displays: displays, sessionSeed: 1234)
        let reversed = try PanoramaLayout(displays: Array(displays.reversed()), sessionSeed: 1234)

        XCTAssertEqual(forward.worldSeed, reversed.worldSeed)
        XCTAssertEqual(Set(forward.projections.map(\.worldSeed)), Set([forward.worldSeed]))
        XCTAssertEqual(Set(reversed.projections.map(\.worldSeed)), Set([reversed.worldSeed]))

        let changedTopology = try PanoramaLayout(
            displays: Array(displays.dropLast()), sessionSeed: 1234
        )
        XCTAssertNotEqual(forward.worldSeed, changedTopology.worldSeed)
    }
}

final class PanoramaFixedStepScheduleTests: XCTestCase {
    func testThirtyHertzTargetsAreDerivedFromSharedTimeNotCallbackDelta() {
        let schedule = PanoramaFixedStepSchedule(hertz: 30, maximumCatchUpSteps: 120)

        XCTAssertEqual(schedule.targetTick(at: 100.000, startTime: 100), 0)
        XCTAssertEqual(schedule.targetTick(at: 100.034, startTime: 100), 1)
        XCTAssertEqual(schedule.targetTick(at: 100.067, startTime: 100), 2)
        XCTAssertEqual(schedule.targetTick(at: 100.101, startTime: 100), 3)
    }

    func testTwentyHertzPresentationCatchesUpWithAlternatingFixedSteps() throws {
        let schedule = PanoramaFixedStepSchedule(hertz: 30, maximumCatchUpSteps: 120)
        let callbackTimes: [TimeInterval] = [0.000, 0.050, 0.100, 0.150, 0.200]
        let targets = callbackTimes.map { schedule.targetTick(at: $0, startTime: 0) }
        XCTAssertEqual(targets, [0, 1, 3, 4, 6])

        var completed = 0
        var stepCounts: [Int] = []
        for target in targets.dropFirst() {
            let advance = try XCTUnwrap(schedule.advance(after: completed, through: target))
            stepCounts.append(advance.ticks.count)
            completed = target
        }
        XCTAssertEqual(stepCounts, [1, 2, 1, 2])
    }

    func testDuplicateTickDoesNotAdvanceSimulation() throws {
        let schedule = PanoramaFixedStepSchedule(hertz: 30, maximumCatchUpSteps: 120)
        let advance = try XCTUnwrap(schedule.advance(after: 19, through: 19))

        XCTAssertTrue(advance.ticks.isEmpty)
    }

    func testDifferentCallbackSchedulesProduceIdenticalFixedTickSequence() throws {
        let schedule = PanoramaFixedStepSchedule(hertz: 30, maximumCatchUpSteps: 120)

        let direct = try XCTUnwrap(schedule.advance(after: 0, through: 6)).ticks
        var accumulated: [Int] = []
        var completed = 0
        for target in [1, 3, 4, 6] {
            let advance = try XCTUnwrap(schedule.advance(after: completed, through: target))
            accumulated.append(contentsOf: advance.ticks)
            completed = target
        }

        XCTAssertEqual(accumulated, direct)
        XCTAssertEqual(direct, [1, 2, 3, 4, 5, 6])
    }

    func testCatchUpBeyondBoundIsRejectedInsteadOfEncodingUnboundedWork() {
        let schedule = PanoramaFixedStepSchedule(hertz: 30, maximumCatchUpSteps: 4)

        XCTAssertNil(schedule.advance(after: 10, through: 15))
        XCTAssertNotNil(schedule.advance(after: 10, through: 14))
    }
}

final class PanoramaFrameCoordinatorTests: XCTestCase {
    func testInvalidationIsSharedAndFutureTickRequestsFailClosed() throws {
        let layout = try PanoramaLayout(displays: [
            PanoramaDisplayGeometry(id: 1, x: 0, y: 0, width: 100, height: 100),
            PanoramaDisplayGeometry(id: 2, x: 100, y: 0, width: 100, height: 100),
        ], sessionSeed: 1)
        let coordinator = PanoramaFrameCoordinator(
            memberIDs: [1, 2], startTime: 0, hertz: 30
        )
        let first = PanoramaRuntimeContext(
            projection: try XCTUnwrap(layout.projection(for: 1)),
            coordinator: coordinator, startTime: 0
        )
        let second = PanoramaRuntimeContext(
            projection: try XCTUnwrap(layout.projection(for: 2)),
            coordinator: coordinator, startTime: 0
        )

        XCTAssertNotNil(first.targetTick(at: 0.05))
        second.invalidate()

        XCTAssertFalse(coordinator.isValid)
        XCTAssertNil(first.targetTick(at: 0.10))
        XCTAssertNil(second.targetTick(at: 0.10))
    }

    func testGroupLatchesOneTickUntilEveryMemberConsumesIt() {
        let coordinator = PanoramaFrameCoordinator(
            memberIDs: [1, 2, 3], startTime: 0, hertz: 30
        )

        XCTAssertEqual(coordinator.targetTick(for: 1, at: 0.040), 1)
        // A fast member gets the already-latched tick; it cannot run the world ahead.
        XCTAssertEqual(coordinator.targetTick(for: 1, at: 0.080), 1)
        XCTAssertEqual(coordinator.targetTick(for: 2, at: 0.080), 1)
        XCTAssertEqual(coordinator.targetTick(for: 3, at: 0.080), 1)

        // The next round may now catch up to wall time, and every member shares that tick.
        XCTAssertEqual(coordinator.targetTick(for: 1, at: 0.080), 2)
        XCTAssertEqual(coordinator.targetTick(for: 2, at: 0.120), 2)
        XCTAssertEqual(coordinator.targetTick(for: 3, at: 0.120), 2)
    }

    func testLatchIsNonblockingWhenOtherMembersHaveNotArrived() {
        let coordinator = PanoramaFrameCoordinator(
            memberIDs: [11, 22, 33], startTime: 0, hertz: 30
        )

        let start = ProcessInfo.processInfo.systemUptime
        let first = coordinator.targetTick(for: 11, at: 1)
        let duplicate = coordinator.targetTick(for: 11, at: 2)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertEqual(first, 30)
        XCTAssertEqual(duplicate, 30)
        XCTAssertLessThan(elapsed, 0.1)
    }

    func testIrregularThirtyAndTwentyHertzMembersKeepOneSharedSequence() {
        let coordinator = PanoramaFrameCoordinator(
            memberIDs: [30, 20], startTime: 0, hertz: 30
        )

        var thirtyHz: [Int] = []
        var twentyHz: [Int] = []
        for slowTime in stride(from: 0.0, through: 0.20, by: 0.05) {
            thirtyHz.append(coordinator.targetTick(for: 30, at: slowTime))
            // Extra fast callback must repeat rather than advance the group.
            _ = coordinator.targetTick(for: 30, at: slowTime + 0.025)
            twentyHz.append(coordinator.targetTick(for: 20, at: slowTime))
        }

        XCTAssertEqual(thirtyHz, twentyHz)
        XCTAssertEqual(thirtyHz, [0, 1, 3, 4, 6])
    }
}
