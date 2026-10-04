import Foundation

/// The result of one fair submission reservation.
///
/// `ticket` is globally ordered for the coordinator, `admittedAt` is the
/// monotonic time at which the caller may submit, and the wait fields are
/// intentionally separate: `requestedSleep` is scheduler-requested delay,
/// while `waitDuration` includes queueing and scheduler oversleep.
struct FairSubmitAdmission {
    let ticket: Int
    let admittedAt: TimeInterval
    let waitDuration: TimeInterval
    let requestedSleep: TimeInterval
}

/// A FIFO coordinator for spacing submissions without dropping a contender.
///
/// Callers take monotonically increasing tickets. Only the serving ticket may
/// calculate and wait for its slot; every other caller sleeps on the condition
/// and rechecks its turn after every wake. The coordinator deliberately releases
/// the condition lock during the injected sleep so new callers can take tickets,
/// while `servingTicket` prevents them from overtaking the current owner.
final class FairSubmitCoordinator {
    static let shared = FairSubmitCoordinator()

    private let condition = NSCondition()
    private var nextTicket = 0
    private var servingTicket = 0
    private var lastAdmission: TimeInterval?

    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Waits for the caller's FIFO turn and returns its spaced admission.
    ///
    /// Negative spacing is treated as zero. The admission is stamped from the
    /// actual wake time when the scheduler sleeps longer than requested, so the
    /// following ticket spaces itself from reality rather than a stale deadline.
    func acquire(minSpacing: TimeInterval) -> FairSubmitAdmission {
        let startedAt = now()
        let spacing = max(0, minSpacing)

        condition.lock()
        let ticket = nextTicket
        nextTicket += 1

        while ticket != servingTicket {
            condition.wait()
        }

        let beforeSleep = now()
        let deadline = lastAdmission.map { max(beforeSleep, $0 + spacing) } ?? beforeSleep
        let requestedSleep = max(0, deadline - beforeSleep)

        if requestedSleep > 0 {
            condition.unlock()
            var remaining = requestedSleep
            while remaining > 0 {
                sleep(remaining)
                remaining = max(0, deadline - now())
            }
            condition.lock()
        }

        // Always move forward to the real wake time after scheduler oversleep.
        let wakeTime = now()
        let admittedAt = max(deadline, wakeTime)
        lastAdmission = admittedAt
        servingTicket += 1
        condition.broadcast()
        condition.unlock()

        return FairSubmitAdmission(
            ticket: ticket,
            admittedAt: admittedAt,
            waitDuration: max(0, wakeTime - startedAt),
            requestedSleep: requestedSleep
        )
    }
}
