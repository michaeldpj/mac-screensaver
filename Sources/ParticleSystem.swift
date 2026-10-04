import Metal

final class ParticleSystem {
    let buffer: MTLBuffer
    private let seedPSO: MTLComputePipelineState
    private let stepPSO: MTLComputePipelineState
    private var seeded = false
    private var lastPanoramaTick: Int?
    private let panoramaProjection: PanoramaProjection?
    private let windConfig: WindModel.Config

    /// One sub-population of the particle buffer: a contiguous index range simulated and
    /// drawn with its own SimParams (motion model, sizes, sprites, hue jitter).
    struct SpeciesRange {
        let speciesIndex: Int   // index into season.speciesResolved (ranges may skip species)
        let start: Int
        let count: Int
        var params: SimParams
    }
    private(set) var ranges: [SpeciesRange]

    private let choreo: (depthBias: Float, sizeDepthCoupling: Float, baselineFraction: Float,
                         releaseWind: Float, heroCount: Int, heroEveryMin: Float, heroEveryMax: Float)

    init?(device: MTLDevice, library: MTLLibrary, season: Season, viewport: SIMD2<Float>,
          countScale: Float = 1.0, panoramaProjection: PanoramaProjection? = nil) {
        windConfig = season.windConfig
        choreo = season.choreoResolved
        self.panoramaProjection = panoramaProjection
        let n = max(Int(Float(season.count) * countScale), 1)
        guard let buffer = device.makeBuffer(length: MemoryLayout<Particle>.stride * n,
                                             options: .storageModePrivate),
              let seedFunction = library.makeFunction(name: "seedParticles"),
              let stepFunction = library.makeFunction(name: "stepParticles"),
              let seedPSO = try? device.makeComputePipelineState(function: seedFunction),
              let stepPSO = try? device.makeComputePipelineState(function: stepFunction) else {
            return nil
        }
        self.buffer = buffer
        self.seedPSO = seedPSO
        self.stepPSO = stepPSO

        // Partition the buffer: a hero range (if any) takes exactly heroCount slots; the
        // ambient species split the rest by weight, the last absorbing rounding remainder.
        let species = season.speciesResolved
        let heroSlots = species.contains(where: \.isHero) ? min(choreo.heroCount, n / 2) : 0
        let ambient = n - heroSlots
        let totalWeight = species.filter { !$0.isHero }.reduce(0) { $0 + $1.weight }
        var built: [SpeciesRange] = []
        var start = 0
        for (idx, sp) in species.enumerated() {
            let isLast = idx == species.count - 1
            let count = sp.isHero ? heroSlots
                : isLast ? (n - start)
                : max(Int(Float(ambient) * sp.weight / totalWeight), 1)
            guard count > 0 else { continue }
            let worldViewport = panoramaProjection?.worldSize ?? viewport
            let cameraOrigin = panoramaProjection?.cameraOrigin ?? .zero
            let cameraViewport = panoramaProjection?.cameraSize ?? viewport
            var p = ParticleSystem.makeParams(
                season: season, worldViewport: worldViewport,
                cameraOrigin: cameraOrigin, cameraViewport: cameraViewport,
                dt: 0, time: 0
            )
            p.count = UInt32(count)
            p.motionModel = sp.motionModel.raw
            p.sizeMin = sp.sizeMin
            p.sizeMax = sp.sizeMax
            p.spriteCount = UInt32(max(sp.spriteCount, 1))
            p.hueJitterRad = sp.hueJitterRad
            // species-level aero (falls back to season aero, then model defaults)
            p.flutterAmp = sp.aero.flutterAmp
            p.flutterFreq = sp.aero.flutterFreq
            p.tumbleChance = sp.aero.tumbleChance
            p.gyroRadius = sp.aero.gyroRadius
            p.microTurb = sp.aero.microTurb
            p.flashOn = sp.aero.flashOn
            p.flashIntervalMin = sp.aero.flashIntervalMin
            p.flashIntervalMax = sp.aero.flashIntervalMax
            p.attractorWeight = sp.aero.attractorWeight
            // calm-air quota per range; hero slots live in the FIRST range only (which is
            // the dedicated hero range when the season declares one)
            p.heroCount = idx == 0 ? UInt32(max(sp.isHero ? heroSlots : choreo.heroCount, 0)) : 0
            let baseline = Int(Float(count) * choreo.baselineFraction)
            p.baselineCount = sp.isHero ? UInt32(count)
                : UInt32(min(max(baseline, Int(p.heroCount) + 1), count))
            built.append(SpeciesRange(speciesIndex: idx, start: start, count: count, params: p))
            start += count
        }
        ranges = built
    }

    static func makeParams(season s: Season, worldViewport: SIMD2<Float>,
                           cameraOrigin: SIMD2<Float> = .zero,
                           cameraViewport: SIMD2<Float>? = nil,
                           dt: Float, time: Float) -> SimParams {
        var p = SimParams()
        p.dt = dt
        p.time = time
        p.worldViewport = worldViewport
        p.cameraOrigin = cameraOrigin
        p.cameraViewport = cameraViewport ?? worldViewport
        p.topFade = 60; p.botFade = 80
        p.count = UInt32(s.count)
        var flags: UInt32 = 0
        if s.rotate { flags |= 1 }
        if s.tumble { flags |= 2 }
        if s.pulse  { flags |= 4 }
        if s.vxMin != 0 || s.vxMax != 0 { flags |= 8 }
        p.flags = flags
        p.vyMin = s.vyMin; p.vyMax = s.vyMax; p.vxMin = s.vxMin; p.vxMax = s.vxMax
        p.sizeMin = s.sizeMin; p.sizeMax = s.sizeMax
        p.rotateSpeed = s.rotateSpeed; p.tumbleSpeed = s.tumbleSpeed
        p.pulseFreqMin = 2; p.pulseFreqMax = 4
        p.depthMin = s.depthMin; p.depthMax = s.depthMax
        p.spriteCount = UInt32(max(s.spriteCount, 1))
        let w = s.windConfig
        p.windBase = w.base
        p.turbulence = w.turbulence
        p.windFieldScale = w.fieldScale
        p.windEvolve = w.evolve
        p.relaxTau = s.relaxTau
        p.motionModel = s.motionModel.raw
        let a = s.aeroResolved
        p.flutterAmp = a.flutterAmp
        p.flutterFreq = a.flutterFreq
        p.tumbleChance = a.tumbleChance
        p.gyroRadius = a.gyroRadius
        p.microTurb = a.microTurb
        p.flashOn = a.flashOn
        p.flashIntervalMin = a.flashIntervalMin
        p.flashIntervalMax = a.flashIntervalMax
        p.attractorWeight = a.attractorWeight
        let ch = s.choreoResolved
        p.depthBias = ch.depthBias
        p.sizeDepthCoupling = ch.sizeDepthCoupling
        p.releaseWind = ch.releaseWind
        p.heroCount = UInt32(max(ch.heroCount, 0))
        p.heroActiveSlot = 0xFFFF_FFFF
        p.hueJitterRad = s.hueJitterDeg * .pi / 180
        return p
    }

    /// Slow Lissajous roam for the firefly attractors, phase-offset by the display seed so
    /// each screen hosts its own congregations. Deterministic in (time, worldSeed).
    static func attractors(time t: Double, viewport v: SIMD2<Float>, worldSeed: UInt32)
        -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        let base = Float(worldSeed % 628) * 0.01
        let tf = Float(t.truncatingRemainder(dividingBy: 86400))   // caller may pass wrapped or raw
        func at(_ i: Int) -> SIMD2<Float> {
            let ph = base + Float(i) * 2.1
            let x = v.x * (0.5 + 0.38 * sin(tf * 0.043 + ph))
            let y = v.y * (0.45 + 0.30 * sin(tf * 0.059 + ph * 1.7))
            return SIMD2(x, y)
        }
        return (at(0), at(1), at(2))
    }

    /// Advances either the legacy per-view variable-dt simulation or a replicated panoramic world.
    /// Panoramic replicas seed identically and integrate the same integer 30Hz ticks regardless of
    /// their drawable/presentation cadence. False means the replica can no longer safely converge.
    func step(_ enc: MTLComputeCommandEncoder, dt: Float, time: Double,
              viewport: SIMD2<Float>, worldOrigin: SIMD2<Float>,
              panorama: PanoramaRenderFrame?, timeOffset: Double = 0) -> Bool {
        if let configured = panoramaProjection {
            guard let panorama, panorama.projection == configured else { return false }
            return stepPanorama(enc, frame: panorama, timeOffset: timeOffset)
        }
        guard panorama == nil else { return false }

        let originBits = UInt64(worldOrigin.x.bitPattern) << 32 | UInt64(worldOrigin.y.bitPattern)
        let worldSeed = UInt32(truncatingIfNeeded: WindModel.hashBits(originBits))
        let pso = seeded ? stepPSO : seedPSO
        seeded = true
        dispatchSimulation(enc, pso: pso, dt: dt, time: time,
                           worldViewport: viewport, cameraOrigin: .zero,
                           cameraViewport: viewport, windOrigin: worldOrigin,
                           worldSeed: worldSeed)
        return true
    }

    private func stepPanorama(_ enc: MTLComputeCommandEncoder,
                              frame: PanoramaRenderFrame, timeOffset: Double) -> Bool {
        let schedule = PanoramaFixedStepSchedule(
            hertz: PanoramaRuntimeContext.simulationHertz,
            maximumCatchUpSteps: PanoramaRuntimeContext.maximumCatchUpSteps
        )
        let completed = lastPanoramaTick ?? 0
        guard let advance = schedule.advance(after: completed, through: frame.targetTick) else {
            return false
        }

        let projection = frame.projection
        if !seeded {
            let seedTime = frame.startTime + timeOffset
            dispatchSimulation(enc, pso: seedPSO, dt: 0, time: seedTime,
                               worldViewport: projection.worldSize,
                               cameraOrigin: projection.cameraOrigin,
                               cameraViewport: projection.cameraSize,
                               windOrigin: projection.windOrigin,
                               worldSeed: projection.worldSeed)
            seeded = true
            if !advance.ticks.isEmpty { enc.memoryBarrier(scope: .buffers) }
        }

        for (index, tick) in advance.ticks.enumerated() {
            let tickTime = frame.startTime
                + Double(tick) / PanoramaRuntimeContext.simulationHertz
                + timeOffset
            dispatchSimulation(enc, pso: stepPSO,
                               dt: Float(1.0 / PanoramaRuntimeContext.simulationHertz),
                               time: tickTime,
                               worldViewport: projection.worldSize,
                               cameraOrigin: projection.cameraOrigin,
                               cameraViewport: projection.cameraSize,
                               windOrigin: projection.windOrigin,
                               worldSeed: projection.worldSeed)
            if index + 1 < advance.ticks.count { enc.memoryBarrier(scope: .buffers) }
        }
        lastPanoramaTick = frame.targetTick
        return true
    }

    private func dispatchSimulation(_ enc: MTLComputeCommandEncoder,
                                    pso: MTLComputePipelineState,
                                    dt: Float, time: Double,
                                    worldViewport: SIMD2<Float>,
                                    cameraOrigin: SIMD2<Float>,
                                    cameraViewport: SIMD2<Float>,
                                    windOrigin: SIMD2<Float>,
                                    worldSeed: UInt32) {
        let timeWrapped = Float(time.truncatingRemainder(dividingBy: 86400))
        var gs = WindModel.gusts(at: time, config: windConfig)
        let meanWX = WindModel.meanWindX(base: windConfig.base, gusts: gs)
        while gs.count < 4 { gs.append(GustFront()) }
        let gustsT = (gs[0], gs[1], gs[2], gs[3])
        let attractors = ParticleSystem.attractors(
            time: time, viewport: worldViewport, worldSeed: worldSeed
        )
        let hero = WindModel.hero(at: time, everyMin: choreo.heroEveryMin,
                                  everyMax: choreo.heroEveryMax, count: choreo.heroCount,
                                  worldSeed: worldSeed)

        enc.setComputePipelineState(pso)
        let stride = MemoryLayout<Particle>.stride
        let w = pso.threadExecutionWidth
        for i in ranges.indices {
            ranges[i].params.dt = dt
            ranges[i].params.time = timeWrapped
            ranges[i].params.worldViewport = worldViewport
            ranges[i].params.cameraOrigin = cameraOrigin
            ranges[i].params.cameraViewport = cameraViewport
            ranges[i].params.windOrigin = windOrigin
            // salt the seed per range so species don't repeat each other's random streams
            ranges[i].params.worldSeed = worldSeed ^ (UInt32(i) &* 0x9E3779B1)
            ranges[i].params.meanWindX = meanWX
            ranges[i].params.gusts = gustsT
            ranges[i].params.attractors = attractors
            if i == 0, let hero {
                ranges[i].params.heroActiveSlot = hero.slot
                ranges[i].params.heroT = hero.t
                ranges[i].params.heroDir = hero.dir
            } else {
                ranges[i].params.heroActiveSlot = 0xFFFF_FFFF
            }
            enc.setBuffer(buffer, offset: ranges[i].start * stride, index: 0)
            enc.setBytes(&ranges[i].params, length: MemoryLayout<SimParams>.stride, index: 1)
            enc.dispatchThreads(MTLSize(width: ranges[i].count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        }
    }
}
