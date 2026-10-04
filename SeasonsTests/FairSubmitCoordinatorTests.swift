import Foundation
import XCTest

final class FairSubmitCoordinatorTests: XCTestCase {
    func testConcurrentCallersAllReceiveAdmissionInTicketOrderWithoutDrops() {
        let clock = CoordinatorTestClock(100)
        let coordinator = FairSubmitCoordinator(
            now: clock.now,
            sleep: { clock.advance(by: $0) }
        )
        let admissions = LockedAdmissions()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "FairSubmitCoordinatorTests.concurrent",
            attributes: .concurrent
        )

        for _ in 0..<32 {
            group.enter()
            queue.async {
                let admission = coordinator.acquire(minSpacing: 0.002)
                admissions.append(admission)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success,
                       "contention must block fairly rather than drop or starve a caller")

        let ordered = admissions.values.sorted { $0.ticket < $1.ticket }
        XCTAssertEqual(ordered.count, 32)
        XCTAssertEqual(ordered.map(\.ticket), Array(0..<32),
                       "each caller must receive one contiguous FIFO ticket")

        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1.admittedAt - pair.0.admittedAt,
                0.002 - 0.000_001,
                "every admitted submit must retain the minimum spacing"
            )
        }
    }

    func testSpacingUsesActualWakeTimeAfterSchedulerOversleep() {
        let clock = CoordinatorTestClock(100)
        let coordinator = FairSubmitCoordinator(
            now: clock.now,
            sleep: { requested in clock.advance(by: requested + 0.003) }
        )

        let first = coordinator.acquire(minSpacing: 0.002)
        let second = coordinator.acquire(minSpacing: 0.002)
        let third = coordinator.acquire(minSpacing: 0.002)

        XCTAssertEqual(first.admittedAt, 100, accuracy: 0.000_001)
        XCTAssertEqual(second.admittedAt, 100.005, accuracy: 0.000_001)
        XCTAssertEqual(third.admittedAt, 100.010, accuracy: 0.000_001)
        XCTAssertEqual(second.admittedAt - first.admittedAt, 0.005, accuracy: 0.000_001)
        XCTAssertEqual(third.admittedAt - second.admittedAt, 0.005, accuracy: 0.000_001,
                       "the following ticket must space from the actual delayed wake")
    }

    func testAdmissionReportsMeasuredWaitRatherThanOnlyRequestedSleep() {
        let clock = CoordinatorTestClock(42)
        let coordinator = FairSubmitCoordinator(
            now: clock.now,
            sleep: { requested in clock.advance(by: requested + 0.004) }
        )

        let first = coordinator.acquire(minSpacing: 0.002)
        let delayed = coordinator.acquire(minSpacing: 0.002)

        XCTAssertEqual(first.waitDuration, 0, accuracy: 0.000_001)
        XCTAssertEqual(delayed.waitDuration, 0.006, accuracy: 0.000_001,
                       "diagnostics need wall-clock waiting, including scheduler oversleep")
        XCTAssertEqual(delayed.requestedSleep, 0.002, accuracy: 0.000_001)
    }

    func testEarlySleeperIsRetriedUntilTheReservedDeadline() {
        let clock = CoordinatorTestClock(20)
        var sleepCalls = 0
        let coordinator = FairSubmitCoordinator(
            now: clock.now,
            sleep: { requested in
                sleepCalls += 1
                clock.advance(by: sleepCalls == 1 ? requested / 2 : requested)
            }
        )

        _ = coordinator.acquire(minSpacing: 0.002)
        let admission = coordinator.acquire(minSpacing: 0.002)

        XCTAssertEqual(sleepCalls, 2)
        XCTAssertEqual(admission.admittedAt, 20.002, accuracy: 0.000_001)
        XCTAssertEqual(admission.waitDuration, 0.002, accuracy: 0.000_001)
    }

    func testZeroSpacingStillUsesFIFOAndCompletesEveryCaller() {
        let clock = CoordinatorTestClock(7)
        let coordinator = FairSubmitCoordinator(now: clock.now, sleep: { _ in })

        let first = coordinator.acquire(minSpacing: 0)
        let second = coordinator.acquire(minSpacing: 0)
        let third = coordinator.acquire(minSpacing: -1)

        XCTAssertEqual([first.ticket, second.ticket, third.ticket], [0, 1, 2])
        XCTAssertEqual([first.waitDuration, second.waitDuration, third.waitDuration], [0, 0, 0])
    }
}

private final class LockedAdmissions {
    private let lock = NSLock()
    private var storage: [FairSubmitAdmission] = []

    var values: [FairSubmitAdmission] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ admission: FairSubmitAdmission) {
        lock.lock()
        storage.append(admission)
        lock.unlock()
    }
}

private final class CoordinatorTestClock {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) { self.value = value }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}
