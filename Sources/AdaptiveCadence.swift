import Foundation

/// Adapts external Ultra-Lite rendering between smooth and conservative cadences.
///
/// The owner is expected to call this from a single thread (normally the main thread).
/// Keeping the controller free of AppKit and Metal makes its timing behavior deterministic
/// in tests and reusable by every display surface.
final class AdaptiveExternalCadence {
    private static let normalFPS = 30
    private static let reducedFPS = 20
    private static let pressureThreshold = 3
    private static let pressureWindow: TimeInterval = 2
    private static let healthyRecoveryInterval: TimeInterval = 15
    private static let slowGPUFrameThreshold: TimeInterval = 0.025
    private static let abnormalSchedulerWaitThreshold: TimeInterval = 0.010

    private let now: () -> TimeInterval
    private var pressureEvents: [TimeInterval] = []
    private var lastPressureAt: TimeInterval?

    private(set) var targetFPS = AdaptiveExternalCadence.normalFPS

    init(now: @escaping () -> TimeInterval) {
        self.now = now
    }

    func recordDrawableMiss() {
        recordPressure(at: now())
    }

    func recordGPUFrame(duration: TimeInterval) {
        guard duration >= Self.slowGPUFrameThreshold else { return }
        recordPressure(at: now())
    }

    func recordSchedulerWait(duration: TimeInterval) {
        guard duration >= Self.abnormalSchedulerWaitThreshold else { return }
        recordPressure(at: now())
    }

    /// Re-evaluates recovery without requiring another rendering sample.
    func refresh() {
        guard targetFPS == Self.reducedFPS, let lastPressureAt else { return }
        let currentTime = now()
        guard currentTime - lastPressureAt >= Self.healthyRecoveryInterval else { return }

        targetFPS = Self.normalFPS
        pressureEvents.removeAll(keepingCapacity: true)
        self.lastPressureAt = nil
    }

    private func recordPressure(at timestamp: TimeInterval) {
        lastPressureAt = timestamp

        // Once reduced, each new pressure event only needs to restart the healthy timer.
        guard targetFPS == Self.normalFPS else { return }

        let cutoff = timestamp - Self.pressureWindow
        pressureEvents.removeAll { $0 < cutoff }
        pressureEvents.append(timestamp)

        if pressureEvents.count >= Self.pressureThreshold {
            targetFPS = Self.reducedFPS
            pressureEvents.removeAll(keepingCapacity: true)
        }
    }
}

/// Applies aggregate external-display safety limits without overriding a stricter caller cap.
enum DisplayCadenceBudget {
    static func builtInFPS(requestedFPS: Int,
                           externalUltraLite: Bool,
                           externalDisplayCount: Int) -> Int {
        guard externalUltraLite, externalDisplayCount >= 3 else { return requestedFPS }
        return min(requestedFPS, 60)
    }
}
