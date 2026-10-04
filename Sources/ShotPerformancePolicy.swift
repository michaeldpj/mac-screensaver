import Foundation

enum ShotPerformanceVerdict: String, Equatable {
    case preferred
    case caution
    case hardStop
}

struct ShotPerformanceReport: Equatable {
    let sampleCount: Int
    let renderFailures: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let maxMilliseconds: Double?
    let verdict: ShotPerformanceVerdict

    var shouldHardFail: Bool { verdict == .hardStop }
}

enum ShotPerformancePolicy {
    static let preferredP95Milliseconds = 20.0
    static let hardStopP95Milliseconds = 25.0

    /// Uses nearest-rank percentiles: for N sorted values, percentile P selects
    /// `ceil(P * N)`. This is intentionally conservative for small QA samples.
    static func analyze(gpuSeconds: [Float], renderFailures: Int) -> ShotPerformanceReport {
        let seconds = gpuSeconds
            .filter { $0.isFinite && $0 > 0 }
            .sorted()

        func percentileSeconds(_ fraction: Double) -> Float? {
            guard !seconds.isEmpty else { return nil }
            let rank = Int(ceil(fraction * Double(seconds.count)))
            return seconds[min(max(rank - 1, 0), seconds.count - 1)]
        }

        let p50Seconds = percentileSeconds(0.50)
        let p95Seconds = percentileSeconds(0.95)
        let maximumSeconds = seconds.last
        let p50 = p50Seconds.map { Double($0) * 1_000 }
        let p95 = p95Seconds.map { Double($0) * 1_000 }
        let maximum = maximumSeconds.map { Double($0) * 1_000 }
        let failures = max(renderFailures, 0)
        let verdict: ShotPerformanceVerdict
        if failures > 0 || p95Seconds == nil
            || p95Seconds! >= Float(hardStopP95Milliseconds / 1_000) {
            verdict = .hardStop
        } else if p95Seconds! >= Float(preferredP95Milliseconds / 1_000) {
            verdict = .caution
        } else {
            verdict = .preferred
        }

        return ShotPerformanceReport(
            sampleCount: seconds.count,
            renderFailures: failures,
            p50Milliseconds: p50,
            p95Milliseconds: p95,
            maxMilliseconds: maximum,
            verdict: verdict
        )
    }
}
