import Foundation
import simd

/// AppKit-free description of one display in global desktop coordinates. `y` follows AppKit's
/// upward-positive convention; `PanoramaLayout` converts it to the shaders' downward-positive
/// world convention.
struct PanoramaDisplayGeometry: Equatable {
    let id: Int
    let x: Float
    let y: Float
    let width: Float
    let height: Float
}

enum PanoramaLayoutError: Error, Equatable {
    case noDisplays
    case invalidGeometry(displayID: Int)
    case duplicateDisplayID(Int)
    case invalidUnion
}

/// The camera crop shared with one renderer. Particle positions live in the normalized panoramic
/// world; subtracting `cameraOrigin` produces this display's local shader coordinates.
struct PanoramaProjection: Equatable {
    let displayID: Int
    let worldSize: SIMD2<Float>
    let cameraOrigin: SIMD2<Float>
    let cameraSize: SIMD2<Float>
    let windOrigin: SIMD2<Float>
    let worldSeed: UInt32

    func localPoint(forWorldPoint point: SIMD2<Float>) -> SIMD2<Float> {
        point - cameraOrigin
    }
}

/// A deterministic panoramic desktop layout. Display order cannot affect the seed or projections.
struct PanoramaLayout {
    let worldSize: SIMD2<Float>
    let windOrigin: SIMD2<Float>
    let worldSeed: UInt32
    let projections: [PanoramaProjection]

    init(displays: [PanoramaDisplayGeometry], sessionSeed: UInt64) throws {
        guard !displays.isEmpty else { throw PanoramaLayoutError.noDisplays }

        var seen: Set<Int> = []
        for display in displays {
            guard seen.insert(display.id).inserted else {
                throw PanoramaLayoutError.duplicateDisplayID(display.id)
            }
            guard display.x.isFinite, display.y.isFinite,
                  display.width.isFinite, display.height.isFinite,
                  display.width > 0, display.height > 0 else {
                throw PanoramaLayoutError.invalidGeometry(displayID: display.id)
            }
            let maxX = display.x + display.width
            let maxY = display.y + display.height
            guard maxX.isFinite, maxY.isFinite else {
                throw PanoramaLayoutError.invalidGeometry(displayID: display.id)
            }
        }

        let ordered = displays.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
        let minX = ordered.map(\.x).min()!
        let minY = ordered.map(\.y).min()!
        let maxX = ordered.map { $0.x + $0.width }.max()!
        let maxY = ordered.map { $0.y + $0.height }.max()!
        let width = maxX - minX
        let height = maxY - minY
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw PanoramaLayoutError.invalidUnion
        }

        let size = SIMD2<Float>(width, height)
        // Convert the AppKit union's upper-left corner into the y-down coordinate system used by
        // the particle and wind shaders. Adding this to a normalized world point recovers a
        // continuous global wind coordinate across every camera.
        let wind = SIMD2<Float>(minX, -maxY)
        let seed = PanoramaLayout.topologySeed(displays: ordered, sessionSeed: sessionSeed)

        worldSize = size
        windOrigin = wind
        worldSeed = seed
        projections = ordered.map { display in
            PanoramaProjection(
                displayID: display.id,
                worldSize: size,
                cameraOrigin: SIMD2<Float>(display.x - minX,
                                           maxY - (display.y + display.height)),
                cameraSize: SIMD2<Float>(display.width, display.height),
                windOrigin: wind,
                worldSeed: seed
            )
        }
    }

    func projection(for displayID: Int) -> PanoramaProjection? {
        projections.first { $0.displayID == displayID }
    }

    /// Stable FNV-1a-style fold over sorted display identities and exact Float bit patterns.
    /// Swift's `Hasher` is intentionally avoided because it is randomized per process.
    private static func topologySeed(displays: [PanoramaDisplayGeometry],
                                     sessionSeed: UInt64) -> UInt32 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) {
            var word = value
            for _ in 0..<8 {
                hash ^= word & 0xff
                hash &*= 0x100000001b3
                word >>= 8
            }
        }

        mix(sessionSeed)
        mix(UInt64(displays.count))
        for display in displays {
            mix(UInt64(bitPattern: Int64(display.id)))
            mix(UInt64(display.x.bitPattern))
            mix(UInt64(display.y.bitPattern))
            mix(UInt64(display.width.bitPattern))
            mix(UInt64(display.height.bitPattern))
        }
        return UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
    }
}

struct PanoramaFixedStepAdvance: Equatable {
    let ticks: [Int]
}

/// Converts a shared monotonic clock into deterministic simulation ticks and bounds the amount of
/// catch-up work that may be encoded into one frame.
struct PanoramaFixedStepSchedule {
    let hertz: Double
    let maximumCatchUpSteps: Int

    init(hertz: Double, maximumCatchUpSteps: Int) {
        precondition(hertz.isFinite && hertz > 0, "panorama simulation rate must be finite and positive")
        precondition(maximumCatchUpSteps >= 0, "panorama catch-up bound cannot be negative")
        self.hertz = hertz
        self.maximumCatchUpSteps = maximumCatchUpSteps
    }

    func targetTick(at time: TimeInterval, startTime: TimeInterval) -> Int {
        guard time.isFinite, startTime.isFinite else { return 0 }
        let elapsed = max(time - startTime, 0)
        let raw = floor(elapsed * hertz)
        guard raw.isFinite, raw > 0 else { return 0 }
        if raw >= Double(Int.max) { return Int.max }
        return Int(raw)
    }

    /// Returns nil for a rewind or an unsafe catch-up burst. Tick zero is the seeded state, so an
    /// advance from zero through N contains the fixed integration steps 1...N.
    func advance(after completedTick: Int, through targetTick: Int) -> PanoramaFixedStepAdvance? {
        guard completedTick >= 0, targetTick >= completedTick else { return nil }
        let (count, overflow) = targetTick.subtractingReportingOverflow(completedTick)
        guard !overflow, count <= maximumCatchUpSteps else { return nil }
        guard count > 0 else { return PanoramaFixedStepAdvance(ticks: []) }
        return PanoramaFixedStepAdvance(ticks: Array((completedTick + 1)...targetTick))
    }
}

/// Nonblocking frame latch for independently scheduled displays. It never waits for peers: a fast
/// member repeats the current tick until every member has observed it, then the next caller latches
/// the current wall-clock tick for the whole group.
final class PanoramaFrameCoordinator {
    private let members: Set<Int>
    private let startTime: TimeInterval
    private let schedule: PanoramaFixedStepSchedule
    private let lock = NSLock()
    private var consumed: Set<Int> = []
    private var latchedTick: Int?
    private var invalidated = false

    init(memberIDs: [Int], startTime: TimeInterval, hertz: Double) {
        precondition(!memberIDs.isEmpty, "a panorama requires at least one member")
        precondition(Set(memberIDs).count == memberIDs.count,
                     "panorama member identities must be unique")
        precondition(startTime.isFinite, "panorama start time must be finite")
        members = Set(memberIDs)
        self.startTime = startTime
        schedule = PanoramaFixedStepSchedule(hertz: hertz, maximumCatchUpSteps: Int.max)
    }

    func targetTick(for memberID: Int, at time: TimeInterval) -> Int {
        targetTickIfValid(for: memberID, at: time) ?? 0
    }

    func targetTickIfValid(for memberID: Int, at time: TimeInterval) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        guard !invalidated else { return nil }

        let wallTick = schedule.targetTick(at: time, startTime: startTime)
        if latchedTick == nil {
            latchedTick = wallTick
        } else if consumed == members {
            consumed.removeAll(keepingCapacity: true)
            latchedTick = max(latchedTick!, wallTick)
        }

        if members.contains(memberID) {
            consumed.insert(memberID)
        }
        return latchedTick!
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !invalidated
    }
}

/// Per-view handle created once by the display policy and passed through the host into
/// `SeasonsView`. Every handle has its own camera projection while retaining the same coordinator
/// and session epoch as the other displays in the panoramic group.
struct PanoramaRuntimeContext {
    static let simulationHertz: Double = 30
    static let maximumCatchUpSteps = 120

    let projection: PanoramaProjection
    let coordinator: PanoramaFrameCoordinator
    let startTime: TimeInterval

    func targetTick(at time: TimeInterval) -> Int? {
        coordinator.targetTickIfValid(for: projection.displayID, at: time)
    }

    func invalidate() {
        coordinator.invalidate()
    }
}

/// Immutable per-render input. It contains no layer or GPU resource, so replicated renderers remain
/// isolated while consuming the same deterministic tick and world projection.
struct PanoramaRenderFrame {
    let projection: PanoramaProjection
    let targetTick: Int
    let startTime: TimeInterval
}
