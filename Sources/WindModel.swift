import simd

/// Deterministic gust scheduler. Gusts are a pure function of absolute time (the shared
/// mach host clock), so every display's independent renderer computes the identical set and
/// a front travels seamlessly across the whole desktop. Four staggered lanes give natural
/// overlap; each lane's epochs are hashed for varied interval, direction, speed, and strength.
enum WindModel {

    struct Config {
        var base: Float          // steady drift (points/sec, signed x)
        var turbulence: Float    // curl amplitude (points/sec)
        var fieldScale: Float    // world points → noise domain
        var evolve: Float        // noise time evolution
        var gustEveryMin: Float  // mean seconds between gusts per lane (range)
        var gustEveryMax: Float
        var gustStrength: Float  // peak front wind (points/sec); 0 disables gusts
        var gustWidth: Float     // gaussian half-width (points)
    }

    /// Splitmix-style stateless integer finalizer — the designated hash for every
    /// determinism-critical schedule and seed in the project.
    static func hashBits(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Stateless integer hash → [0, 1).
    static func hash01(_ x: UInt64) -> Float {
        Float(hashBits(x) >> 40) * (1.0 / Float(1 << 24))
    }

    /// The deterministic epoch core shared by the gust and hero schedulers: which epoch of
    /// length `mean` covers time `t` (offset by `salt`), where it starts, and five stable
    /// random draws for that epoch. Determinism here is what keeps displays in one world.
    static func epochEvent(at t: Double, mean: Double, salt: UInt64)
        -> (start: Double, r0: Float, r1: Float, r2: Float, r3: Float, r4: Float) {
        let epoch = UInt64((t / mean).rounded(.down)) &+ salt
        return ((t / mean).rounded(.down) * mean,
                hash01(epoch &* 3), hash01(epoch &* 5), hash01(epoch &* 7),
                hash01(epoch &* 11), hash01(epoch &* 13))
    }

    /// The up-to-4 active gust fronts at absolute time `t`. Inactive slots have strength 0.
    /// `worldSpan` is how far a front travels before dying (cover the widest desktop generously).
    static func gusts(at t: Double, config c: Config, worldSpan: Float = 14000) -> [GustFront] {
        var out: [GustFront] = []
        guard c.gustStrength > 0 else { return [] }
        for lane in 0..<4 {
            let laneSalt = UInt64(lane) &* 0x9E3779B97F4A7C15
            let meanInterval = Double((c.gustEveryMin + c.gustEveryMax) * 0.5)
            let (epochStart, r0, r1, r2, r3, r4) = epochEvent(at: t, mean: meanInterval, salt: laneSalt)
            let birth = epochStart + Double(r0) * meanInterval * 0.5
            let speed = 700 + r1 * 700                         // points/sec front travel
            let travel = worldSpan + 12000                     // sweep the desktop + margins
            let life = Double(travel / speed)
            let age = t - birth
            guard age >= 0, age < life else { continue }

            let lifeFrac = Float(age / life)
            let envelope = sin(lifeFrac * .pi)                 // ramp in, peak, ramp out
            let dirX: Float = r2 < 0.5 ? 1 : -1                // mostly horizontal travel
            let dir = simd_normalize(SIMD2<Float>(dirX, (r3 - 0.5) * 0.35))
            // head is the projection dot(worldPos, dir) the front has reached; it always
            // advances at `speed`, starting far enough upwind to sweep every display
            let head0: Float = dirX > 0 ? -6000 : -(worldSpan + 6000)

            var g = GustFront()
            g.dir = dir
            g.head = head0 + speed * Float(age)
            g.width = c.gustWidth * (0.7 + r4 * 0.6)
            g.strength = c.gustStrength * (0.6 + r1 * 0.4) * envelope
            g.turbBoost = 0.8 + r3
            out.append(g)
        }
        return out
    }

    /// Rough mean horizontal wind for respawn-side bias (cheap CPU estimate).
    static func meanWindX(base: Float, gusts: [GustFront]) -> Float {
        gusts.reduce(base) { $0 + $1.strength * $1.dir.x * 0.3 }
    }

    /// Deterministic hero-event schedule: every `every` seconds (hashed jitter) one hero slot
    /// performs a 14–20s showcase crossing. `worldSeed` staggers displays so screens never
    /// fire heroes simultaneously. Returns nil when no hero is active.
    static func hero(at t: Double, everyMin: Float, everyMax: Float, count: Int,
                     worldSeed: UInt32) -> (slot: UInt32, t: Float, dir: Float)? {
        guard count > 0 else { return nil }
        let mean = Double((everyMin + everyMax) * 0.5)
        guard mean > 1 else { return nil }
        let salt = UInt64(worldSeed) &* 0x9E3779B97F4A7C15
        let (epochStart, r0, r1, r2, _, _) = epochEvent(at: t, mean: mean, salt: salt)
        let start = epochStart + Double(r0) * mean * 0.4
        let duration = Double(14 + r1 * 6)
        let age = t - start
        guard age >= 0, age < duration else { return nil }
        let epoch = UInt64((t / mean).rounded(.down)) &+ salt
        return (slot: UInt32(epoch % UInt64(count)),
                t: Float(age / duration),
                dir: r2 < 0.5 ? 1 : -1)
    }
}
