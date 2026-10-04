import Metal
import MetalFX
import QuartzCore
import simd
import os

private let log = Logger(subsystem: "me.mdpj.Seasons", category: "renderer")

final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let meshPSO: MTLRenderPipelineState
    private let glowPSO: MTLRenderPipelineState
    private let streakPSO: MTLRenderPipelineState
    private let atmospherePSO: MTLRenderPipelineState
    private let brightPSO: MTLRenderPipelineState
    private let blurPSO: MTLRenderPipelineState
    private let compositePSO: MTLRenderPipelineState
    private let compositeOutPSO: MTLRenderPipelineState
    private let compositeNoEffectsPSO: MTLRenderPipelineState
    private let compositeNoEffectsOutPSO: MTLRenderPipelineState
    private let presentPSO: MTLRenderPipelineState
    private let system: ParticleSystem
    /// Per-species draw unit: own mesh curvature, sprite textures, and surface material,
    /// drawing the matching contiguous range of the shared particle buffer.
    private struct SpeciesUnit {
        let mesh: Mesh
        let textures: SpriteTextures?
        var material: MaterialParams
    }
    private let speciesUnits: [SpeciesUnit]
    private let season: Season
    private var light: LightParams
    private var atmo: AtmosphereParams

    private var resourceInputSize = SIMD2<Int>(0, 0)
    private var resourceOutputSize = SIMD2<Int>(0, 0)
    private var resourceSet: Set<RenderResource> = []
    private var textures: [RenderResource: MTLTexture] = [:]
    private var failedResourceInput = SIMD2<Int>(0, 0)
    private var failedResourceOutput = SIMD2<Int>(0, 0)
    private var failedResourceSet: Set<RenderResource> = []
    private var resourceRetryAfter: CFTimeInterval = 0

    // MetalFX adaptive upscaling. `SEASONS_DISABLE_METALFX` forces the known-safe baseline:
    // fixed native scale, no scaler, no per-frame HDR-target reallocation.
    private let metalFXEnabled: Bool
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey = SIMD4<Int>(0, 0, 0, 0)   // inW,inH,outW,outH

    // Performance governor (resolution scale is the only knob).
    private var governor: Governor
    private let gpuTimeLock = NSLock()
    private var pendingGPUTime: Float = 0
    private var pendingHealthGPUTime: Float = 0

    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    // QA fast-forward: lands the deterministic gust/hero schedule on a chosen moment.
    private let timeOffset = Double(ProcessInfo.processInfo.environment["SEASONS_TIME_OFFSET"] ?? "") ?? 0

    /// `drawableFormat` is the format of the texture handed to `render`/`renderFrame` — the
    /// internal chain stays rgba16Float regardless. `clampOutput` caps composite at 1.0 for SDR
    /// presentation (the 2026-06-10 panic implicates the EDR display path; see CRASH-ANALYSIS).
    // Lite post chain (secondary displays in multi-display mode): one half-res bloom, no
    // pyramid, no DoF blur — ~4 fullscreen passes vs ~10. Cuts aggregate display-rail load.
    private let litePost: Bool
    private let bloomEnabled: Bool
    private let dofEnabled: Bool
    private let forcedScaleConst: Float?
    private let vividImageSDR: Bool

    init?(device: MTLDevice, library: MTLLibrary, season: Season,
          viewport: SIMD2<Float>, sprites: [SpriteTextures?], targetFPS: Double = 120,
          countScale: Float = 1.0, bloom: Bool = true, dof: Bool = true,
          drawableFormat: MTLPixelFormat = .rgba16Float, clampOutput: Bool = true,
          litePost: Bool = false, forcedScale: Float? = nil,
          panoramaProjection: PanoramaProjection? = nil) {
        self.device = device
        self.library = library
        self.season = season
        self.litePost = litePost
        self.bloomEnabled = bloom
        self.dofEnabled = dof
        self.forcedScaleConst = forcedScale
        self.vividImageSDR = clampOutput
        guard let queue = device.makeCommandQueue(),
              let system = ParticleSystem(device: device, library: library, season: season,
                                          viewport: viewport, countScale: countScale,
                                          panoramaProjection: panoramaProjection) else {
            log.error("renderer initialization failed: command queue or particle system unavailable")
            return nil
        }
        self.queue = queue
        self.system = system
        // Build draw units FROM the sim's ranges so alignment is structural — a species whose
        // weight rounds to zero particles simply has no range and no unit.
        let resolved = season.speciesResolved
        var units: [SpeciesUnit] = []
        units.reserveCapacity(system.ranges.count)
        for range in system.ranges {
            let sp = resolved[range.speciesIndex]
            guard let mesh = Mesh.make(
                device: device, curl: Mesh.curl(for: sp.motionModel, overrides: sp.curl)
            ) else {
                log.error("renderer initialization failed: mesh buffer allocation")
                return nil
            }
            units.append(SpeciesUnit(
                mesh: mesh,
                textures: range.speciesIndex < sprites.count ? sprites[range.speciesIndex] : nil,
                material: sp.material
            ))
        }
        speciesUnits = units
        light = Renderer.defaultLight()
        Renderer.apply(season.light, to: &light)
        atmo = Renderer.atmosphere(for: season)
        Renderer.apply(season.grade, to: &atmo)
        if panoramaProjection != nil {
            // Vignette and grain are defined in drawable UVs. Repeating either per camera would
            // reveal monitor boundaries, so panoramic crops use a uniform, exact-black grade.
            atmo.vignette = 0
            atmo.grain = 0
        }
        atmo.maxOutput = clampOutput ? 1.0 : 0.0
        if !bloom { atmo.bloomIntensity = 0 }
        if !dof { atmo.dofStrength = 0 }
        governor = Governor(targetFrameTime: Float(1.0 / max(targetFPS, 30)))
        let disableFX = ProcessInfo.processInfo.environment["SEASONS_DISABLE_METALFX"] != nil
        metalFXEnabled = MTLFXSpatialScalerDescriptor.supportsDevice(device) && !disableFX
        if disableFX { log.notice("MetalFX disabled by SEASONS_DISABLE_METALFX — native scale only") }

        // Particle pipeline (premultiplied blend over backdrop, color + CoC attachments).
        let mp = MTLRenderPipelineDescriptor()
        mp.vertexFunction = library.makeFunction(name: "meshVS")
        mp.fragmentFunction = library.makeFunction(name: "meshFS")
        for k in 0...1 {
            let a = mp.colorAttachments[k]!
            a.pixelFormat = .rgba16Float
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        guard let meshPSO = try? device.makeRenderPipelineState(descriptor: mp) else {
            log.error("renderer initialization failed: mesh pipeline")
            return nil
        }
        self.meshPSO = meshPSO

        // Glow pipeline: additive light for fireflies (no sprite).
        let gp = MTLRenderPipelineDescriptor()
        gp.vertexFunction = library.makeFunction(name: "glowVS")
        gp.fragmentFunction = library.makeFunction(name: "glowFS")
        for k in 0...1 {
            let g = gp.colorAttachments[k]!
            g.pixelFormat = .rgba16Float
            g.isBlendingEnabled = true
            g.rgbBlendOperation = .add; g.alphaBlendOperation = .add
            g.sourceRGBBlendFactor = .one; g.sourceAlphaBlendFactor = .one
            g.destinationRGBBlendFactor = .one; g.destinationAlphaBlendFactor = .one
        }
        guard let glowPSO = try? device.makeRenderPipelineState(descriptor: gp) else {
            log.error("renderer initialization failed: glow pipeline")
            return nil
        }
        self.glowPSO = glowPSO

        // Streak pipeline: rain — premultiplied alpha over backdrop, color + CoC.
        let stp = MTLRenderPipelineDescriptor()
        stp.vertexFunction = library.makeFunction(name: "streakVS")
        stp.fragmentFunction = library.makeFunction(name: "streakFS")
        for k in 0...1 {
            let s = stp.colorAttachments[k]!
            s.pixelFormat = .rgba16Float
            s.isBlendingEnabled = true
            s.rgbBlendOperation = .add; s.alphaBlendOperation = .add
            s.sourceRGBBlendFactor = .one; s.sourceAlphaBlendFactor = .one
            s.destinationRGBBlendFactor = .oneMinusSourceAlpha
            s.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        guard let streakPSO = try? device.makeRenderPipelineState(descriptor: stp) else {
            log.error("renderer initialization failed: streak pipeline")
            return nil
        }
        self.streakPSO = streakPSO

        let ap = MTLRenderPipelineDescriptor()
        ap.vertexFunction = library.makeFunction(name: "postTri")
        ap.fragmentFunction = library.makeFunction(name: "atmosphere")
        ap.colorAttachments[0].pixelFormat = .rgba16Float
        ap.colorAttachments[1].pixelFormat = .rgba16Float
        guard let atmospherePSO = try? device.makeRenderPipelineState(descriptor: ap) else {
            log.error("renderer initialization failed: atmosphere pipeline")
            return nil
        }
        self.atmospherePSO = atmospherePSO

        func fullscreen(_ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "postTri")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        func fullscreenOut(_ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "postTri")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = drawableFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let brightPSO = fullscreen("brightPass"),
              let blurPSO = fullscreen("blur"),
              let compositePSO = fullscreen("composite"),
              let compositeOutPSO = fullscreenOut("composite"),
              let compositeNoEffectsPSO = fullscreen("compositeNoEffects"),
              let compositeNoEffectsOutPSO = fullscreenOut("compositeNoEffects"),
              let presentPSO = fullscreenOut("present") else {
            log.error("renderer initialization failed: post-processing pipeline")
            return nil
        }
        self.brightPSO = brightPSO
        self.blurPSO = blurPSO
        self.compositePSO = compositePSO
        self.compositeNoEffectsPSO = compositeNoEffectsPSO
        // Drawable-format variants: in the common no-upscale path composite goes STRAIGHT to
        // the drawable (no extra full-res pass); `present` converts only after MetalFX.
        self.compositeOutPSO = compositeOutPSO
        self.compositeNoEffectsOutPSO = compositeNoEffectsOutPSO
        self.presentPSO = presentPSO
    }

    /// Current GPU-frame-time-driven render scale (1.0 = native). Exposed for diagnostics.
    var renderScale: Float { governor.scale }

    private static func defaultLight() -> LightParams {
        var l = LightParams()
        l.keyDir = normalize(SIMD3<Float>(-0.4, 0.55, 0.72))
        l.keyIntensity = 1.3
        l.keyColor = SIMD3<Float>(1.0, 0.97, 0.92)       // near-white key (keeps petals white)
        l.ambientIntensity = 0.44
        l.ambientColor = SIMD3<Float>(0.5, 0.54, 0.66)   // cool fill
        l.translucency = 1.05                            // backlit petals glow
        l.specular = 0.3
        l.rimDir = normalize(SIMD3<Float>(0.2, 0.7, -0.6))   // cool top-back track light
        l.rimColor = SIMD3<Float>(0.62, 0.74, 1.0)
        l.rimIntensity = 0.45
        return l
    }

    private static func atmosphere(for season: Season) -> AtmosphereParams {
        var a = AtmosphereParams()
        // Plain-black direction: pure black backdrop, no gradient, no radial glow. The sprites
        // and their motion carry the frame; restrained highlight bloom only.
        a.grain = 0.015
        a.vignette = 0.10                // retain focus without muddying bright sprites at the edges
        a.exposure = 1.25                // filmic toe eats a little brightness; keep it vibrant
        a.bloomIntensity = 0.28          // subtle highlight bloom only (was 0.95)
        a.saturation = 1.08
        a.dofStrength = 1.6
        a.caStrength = 0.6               // px of R/B split at full CoC — micro, lens-like
        a.filmicWhite = 4.0              // HDR values roll off into the shoulder above ~1
        a.shadowTint = SIMD3<Float>(0.96, 0.98, 1.04)      // cool shadows
        a.highlightTint = SIMD3<Float>(1.04, 1.01, 0.97)   // warm highlights
        a.bloomMixHalf = 0.5
        a.bloomMixQuarter = 0.3
        a.bloomMixEighth = 0.2
        // Black background for every season: zero sky gradient and zero glow.
        a.skyTop = SIMD3<Float>(0, 0, 0)
        a.skyBottom = SIMD3<Float>(0, 0, 0)
        a.glowColor = SIMD3<Float>(0, 0, 0)
        a.glowCenter = SIMD2<Float>(0.5, 0.5)
        a.glowRadius = 1.0
        return a
    }

    private static func apply(_ o: LightOverrides?, to l: inout LightParams) {
        guard let o else { return }
        if let v = o.keyDir, v.count == 3 { l.keyDir = normalize(SIMD3(v[0], v[1], v[2])) }
        if let v = o.keyColorP3 { l.keyColor = v }
        if let v = o.keyIntensity { l.keyIntensity = v }
        if let v = o.ambientColorP3 { l.ambientColor = v }
        if let v = o.ambientIntensity { l.ambientIntensity = v }
        if let v = o.translucency { l.translucency = v }
        if let v = o.specular { l.specular = v }
        if let v = o.rimDir, v.count == 3 { l.rimDir = normalize(SIMD3(v[0], v[1], v[2])) }
        if let v = o.rimColorP3 { l.rimColor = v }
        if let v = o.rimIntensity { l.rimIntensity = v }
    }

    private static func apply(_ o: GradeOverrides?, to a: inout AtmosphereParams) {
        guard let o else { return }
        if let v = o.exposure { a.exposure = v }
        if let v = o.saturation { a.saturation = v }
        if let v = o.vignette { a.vignette = v }
        if let v = o.grain { a.grain = v }
        if let v = o.caStrength { a.caStrength = v }
        if let v = o.filmicWhite { a.filmicWhite = v }
        if let v = o.shadowTintP3 { a.shadowTint = v }
        if let v = o.highlightTintP3 { a.highlightTint = v }
        if let v = o.bloomMix, v.count == 3 {
            a.bloomMixHalf = v[0]; a.bloomMixQuarter = v[1]; a.bloomMixEighth = v[2]
        }
    }

    /// Quantized internal render size from the governor scale (multiples of 8, clamped to full).
    /// `SEASONS_FORCE_SCALE` (0.3–1.0) overrides the governor for QA of the MetalFX path.
    private func computeInternalSize(_ full: SIMD2<Int>) -> SIMD2<Int> {
        guard metalFXEnabled else { return full }
        var s = governor.scale
        if let fixed = forcedScaleConst { s = min(max(fixed, 0.3), 1.0) }   // secondary: fixed scale
        if let f = ProcessInfo.processInfo.environment["SEASONS_FORCE_SCALE"], let v = Float(f) {
            s = min(max(v, 0.3), 1.0)
        }
        func q(_ v: Int) -> Int { min(max(64, (Int(Float(v) * s) / 8) * 8), v) }
        return SIMD2(q(full.x), q(full.y))
    }

    private func makeTex(_ w: Int, _ h: Int,
                         usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                    width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = usage; d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private var loggedTargets = false

    private func ensureResources(_ plan: RenderResourcePlan,
                                 input: SIMD2<Int>, output: SIMD2<Int>) -> Bool {
        if resourceInputSize == input,
           resourceOutputSize == output,
           resourceSet == plan.resources,
           textures.count == plan.resources.count {
            return true
        }

        // Allocation failure usually means transient memory pressure. Avoid rebuilding and
        // logging the entire graph at display cadence; retry this exact request at most once per
        // second. A changed size/tier is a different request and may try immediately.
        let allocationStart = CACurrentMediaTime()
        if failedResourceInput == input,
           failedResourceOutput == output,
           failedResourceSet == plan.resources,
           allocationStart < resourceRetryAfter {
            return false
        }

        // A scaler can retain its prior input/output textures. Drop it before replacing the
        // resource set so a failed resize cannot leave a previous large frame graph resident.
        // Release the old graph before allocating the new one to avoid a full-graph memory spike.
        scaler = nil
        scalerKey = .zero
        textures.removeAll(keepingCapacity: false)
        resourceInputSize = .zero
        resourceOutputSize = .zero
        resourceSet = []

        func dimensions(for resource: RenderResource) -> SIMD2<Int> {
            switch resource {
            case .scene, .coc, .graded:
                return input
            case .upscaled:
                return output
            case .bloomHalfA, .bloomHalfB, .sceneBlurA, .sceneBlurB:
                return SIMD2(max(input.x / 2, 1), max(input.y / 2, 1))
            case .bloomQuarterA, .bloomQuarterB:
                return SIMD2(max(input.x / 4, 1), max(input.y / 4, 1))
            case .bloomEighthA, .bloomEighthB:
                return SIMD2(max(input.x / 8, 1), max(input.y / 8, 1))
            }
        }

        var allocated: [RenderResource: MTLTexture] = [:]
        allocated.reserveCapacity(plan.resources.count)
        for resource in plan.resources {
            let size = dimensions(for: resource)
            let usage: MTLTextureUsage = resource == .upscaled
                ? [.renderTarget, .shaderRead, .shaderWrite]
                : [.renderTarget, .shaderRead]
            guard let texture = makeTex(size.x, size.y, usage: usage) else {
                log.error("texture allocation failed resource=\(String(describing: resource), privacy: .public) size=\(size.x)x\(size.y)")
                failedResourceInput = input
                failedResourceOutput = output
                failedResourceSet = plan.resources
                resourceRetryAfter = allocationStart + 1
                return false
            }
            allocated[resource] = texture
        }

        textures = allocated
        resourceInputSize = input
        resourceOutputSize = output
        resourceSet = plan.resources
        failedResourceInput = .zero
        failedResourceOutput = .zero
        failedResourceSet = []
        resourceRetryAfter = 0
        return true
    }

    private func ensureScaler(input: SIMD2<Int>, output: SIMD2<Int>) -> Bool {
        let key = SIMD4(input.x, input.y, output.x, output.y)
        if scalerKey == key, scaler != nil { return true }
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = input.x; d.inputHeight = input.y
        d.outputWidth = output.x; d.outputHeight = output.y
        d.colorTextureFormat = .rgba16Float
        d.outputTextureFormat = .rgba16Float
        d.colorProcessingMode = .hdr        // scene is linear HDR/EDR
        guard let nextScaler = d.makeSpatialScaler(device: device) else {
            log.error("MetalFX scaler creation failed input=\(input.x)x\(input.y) output=\(output.x)x\(output.y)")
            scaler = nil
            scalerKey = .zero
            return false
        }
        scaler = nextScaler
        scalerKey = key
        return true
    }

    private func fullscreenPass(_ cb: MTLCommandBuffer, into tex: MTLTexture,
                                pso: MTLRenderPipelineState,
                                configure: (MTLRenderCommandEncoder) -> Void) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else {
            log.error("fullscreen render encoder creation failed")
            return false
        }
        e.setRenderPipelineState(pso)
        configure(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        return true
    }

    /// Renders the full graded frame into `target`. `animate` false → static backdrop (Reduce Motion / Off).
    private func renderInto(_ target: MTLTexture, pixelSize: SIMD2<Int>, pointSize: SIMD2<Float>,
                            cb: MTLCommandBuffer, animate: Bool,
                            worldOrigin: SIMD2<Float>,
                            panoramaFrame: PanoramaRenderFrame?,
                            panoramaFailure: (() -> Void)?) -> Bool {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 0.05)); lastTime = now
        atmo.time = Float(now - startTime)

        // feed last frame's GPU time into the governor before sizing this frame
        gpuTimeLock.lock(); let gt = pendingGPUTime; pendingGPUTime = 0; gpuTimeLock.unlock()
        if gt > 0 { governor.record(gpuFrameTime: gt, dt: dt) }

        let internalPx = computeInternalSize(pixelSize)
        let upscale = metalFXEnabled && internalPx != pixelSize
        let plan = RenderResourcePlan(bloom: bloomEnabled, dof: dofEnabled,
                                      litePost: litePost, requiresUpscale: upscale)
        guard ensureResources(plan, input: internalPx, output: pixelSize),
              let scene = textures[.scene], let cocTex = textures[.coc] else {
            return false
        }

        if !loggedTargets {
            loggedTargets = true
            let s = internalPx
            log.notice("targets: present=\(pixelSize.x)x\(pixelSize.y) internal=\(s.x)x\(s.y) retained=\(plan.resources.count) passes=\(plan.passes.count) metalFX=\(upscale)")
        }

        if animate {
            guard let ce = cb.makeComputeCommandEncoder() else {
                log.error("particle compute encoder creation failed")
                return false
            }
            guard system.step(ce, dt: dt, time: now + timeOffset, viewport: pointSize,
                              worldOrigin: worldOrigin, panorama: panoramaFrame,
                              timeOffset: timeOffset) else {
                ce.endEncoding()
                log.error("panorama simulation could not remain synchronized")
                return false
            }
            ce.endEncoding()
        }

        // backdrop + particles → scene + CoC
        let sp = MTLRenderPassDescriptor()
        sp.colorAttachments[0].texture = scene
        sp.colorAttachments[0].loadAction = .dontCare
        sp.colorAttachments[0].storeAction = .store
        sp.colorAttachments[1].texture = cocTex
        sp.colorAttachments[1].loadAction = .dontCare
        sp.colorAttachments[1].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: sp) else {
            log.error("scene render encoder creation failed")
            return false
        }
        e.setRenderPipelineState(atmospherePSO)
        e.setFragmentBytes(&atmo, length: MemoryLayout<AtmosphereParams>.stride, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        var color = season.colorP3
        if !animate {
            // static atmosphere only — no particles
        } else if season.glyphType == .glow {
            var params = system.ranges[0].params
            e.setRenderPipelineState(glowPSO)
            e.setVertexBuffer(system.buffer, offset: 0, index: 1)
            e.setVertexBytes(&params, length: MemoryLayout<SimParams>.stride, index: 2)
            e.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            var headroom = season.edrHeadroom
            e.setFragmentBytes(&headroom, length: MemoryLayout<Float>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                             instanceCount: system.ranges[0].count)
        } else if season.glyphType == .streak {
            var params = system.ranges[0].params
            e.setRenderPipelineState(streakPSO)
            e.setVertexBuffer(system.buffer, offset: 0, index: 1)
            e.setVertexBytes(&params, length: MemoryLayout<SimParams>.stride, index: 2)
            e.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            var op = season.spriteOpacity
            e.setFragmentBytes(&op, length: MemoryLayout<Float>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                             instanceCount: system.ranges[0].count)
        } else {
            // one instanced draw per species: its own mesh, textures, material, and
            // SimParams, over its contiguous slice of the shared particle buffer
            e.setRenderPipelineState(meshPSO)
            let vividProfile = VividSDRProfile.standard
            var vivid = VividImageParams()
            vivid.exposure = vividImageSDR ? vividProfile.exposure : 1
            vivid.chroma = vividImageSDR ? vividProfile.chroma : 1
            for (unit, range) in zip(speciesUnits, system.ranges) {
                guard let textures = unit.textures else { continue }
                var params = range.params
                e.setVertexBuffer(unit.mesh.vertexBuffer, offset: 0, index: 0)
                e.setVertexBuffer(system.buffer, offset: 0, index: 1)
                e.setVertexBytes(&params, length: MemoryLayout<SimParams>.stride, index: 2)
                e.setFragmentTexture(textures.albedo, index: 0)
                e.setFragmentTexture(textures.maps, index: 1)
                var op = season.spriteOpacity
                var mat = unit.material
                if vividImageSDR {
                    color.w = vividProfile.effectiveOpacity(configured: color.w, isImage: true)
                }
                e.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                e.setFragmentBytes(&op, length: MemoryLayout<Float>.stride, index: 1)
                e.setFragmentBytes(&light, length: MemoryLayout<LightParams>.stride, index: 2)
                e.setFragmentBytes(&mat, length: MemoryLayout<MaterialParams>.stride, index: 3)
                e.setFragmentBytes(&vivid, length: MemoryLayout<VividImageParams>.stride, index: 4)
                e.drawIndexedPrimitives(type: .triangle, indexCount: unit.mesh.indexCount,
                                        indexType: .uint16, indexBuffer: unit.mesh.indexBuffer,
                                        indexBufferOffset: 0,
                                        instanceCount: range.count,
                                        baseVertex: 0,
                                        baseInstance: range.start)
            }
        }
        e.endEncoding()

        // separable gaussian helper: one H or V tap chain from src into dst
        func blurPass(from src: MTLTexture, into dst: MTLTexture, dir: SIMD2<Float>) -> Bool {
            var d = dir
            return fullscreenPass(cb, into: dst, pso: blurPSO) { e in
                e.setFragmentTexture(src, index: 0)
                e.setFragmentBytes(&d, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            }
        }
        let H = SIMD2<Float>(1, 0), V = SIMD2<Float>(0, 1)

        // bloom: bright-pass, then a blur pyramid — half (halation), quarter (glow),
        // eighth (wide soft atmosphere), composited with the bloomMix* weights. Disabled
        // effects have no retained intermediates and encode no fullscreen work.
        if plan.passes.contains(.bloomBright) {
            guard let bloomA = textures[.bloomHalfA], let bloomB = textures[.bloomHalfB] else {
                return false
            }
            var threshold = season.bloomThreshold
            guard fullscreenPass(cb, into: bloomA, pso: brightPSO, configure: { e in
                e.setFragmentTexture(scene, index: 0)
                e.setFragmentBytes(&threshold, length: MemoryLayout<Float>.stride, index: 0)
            }),
                  blurPass(from: bloomA, into: bloomB, dir: H),
                  blurPass(from: bloomB, into: bloomA, dir: V) else { return false }
        }
        var frameAtmo = atmo
        if litePost {
            // collapse the pyramid into the single half-res bloom; no DoF
            frameAtmo.bloomMixHalf = atmo.bloomMixHalf + atmo.bloomMixQuarter + atmo.bloomMixEighth
            frameAtmo.bloomMixQuarter = 0; frameAtmo.bloomMixEighth = 0
            frameAtmo.dofStrength = 0
        }
        if plan.passes.contains(.bloomQuarterHorizontal) {
            guard let bloomA = textures[.bloomHalfA],
                  let bloomQA = textures[.bloomQuarterA],
                  let bloomQB = textures[.bloomQuarterB],
                  let bloomEA = textures[.bloomEighthA],
                  let bloomEB = textures[.bloomEighthB] else {
                return false
            }
            guard blurPass(from: bloomA, into: bloomQB, dir: H),
                  blurPass(from: bloomQB, into: bloomQA, dir: V),
                  blurPass(from: bloomQA, into: bloomEB, dir: H),
                  blurPass(from: bloomEB, into: bloomEA, dir: V) else { return false }
        }
        if plan.passes.contains(.dofHorizontal) {
            guard let sceneBlurA = textures[.sceneBlurA],
                  let sceneBlurB = textures[.sceneBlurB] else {
                return false
            }
            guard blurPass(from: scene, into: sceneBlurA, dir: H),
                  blurPass(from: sceneBlurA, into: sceneBlurB, dir: V) else { return false }
        }

        // Composite straight to the drawable in the common native-res path; use graded + MetalFX
        // + a format-converting present only when upscaling. The no-effects path samples scene
        // alone; the existing effects path retains its complete six-texture binding contract.
        func compositeTexture(_ slot: CompositeTextureSlot) -> MTLTexture? {
            guard let resource = plan.compositeBindings[slot] else { return nil }
            return textures[resource]
        }
        guard let compositeScene = compositeTexture(.scene) else { return false }

        func compositeEffects(into tex: MTLTexture, pso: MTLRenderPipelineState) -> Bool {
            guard let compositeBloomHalf = compositeTexture(.bloomHalf),
              let compositeSceneBlur = compositeTexture(.sceneBlur),
              let compositeCoc = compositeTexture(.coc),
              let compositeBloomQuarter = compositeTexture(.bloomQuarter),
              let compositeBloomEighth = compositeTexture(.bloomEighth) else {
                return false
            }
            return fullscreenPass(cb, into: tex, pso: pso) { e in
                e.setFragmentTexture(compositeScene, index: 0)
                e.setFragmentTexture(compositeBloomHalf, index: 1)
                e.setFragmentTexture(compositeSceneBlur, index: 2)
                e.setFragmentTexture(compositeCoc, index: 3)
                e.setFragmentTexture(compositeBloomQuarter, index: 4)
                e.setFragmentTexture(compositeBloomEighth, index: 5)
                e.setFragmentBytes(&frameAtmo, length: MemoryLayout<AtmosphereParams>.stride, index: 0)
            }
        }
        func compositeNoEffects(into tex: MTLTexture, pso: MTLRenderPipelineState) -> Bool {
            fullscreenPass(cb, into: tex, pso: pso) { e in
                e.setFragmentTexture(compositeScene, index: 0)
                e.setFragmentBytes(&frameAtmo, length: MemoryLayout<AtmosphereParams>.stride, index: 0)
            }
        }
        func composite(into tex: MTLTexture,
                       effectsPSO: MTLRenderPipelineState,
                       noEffectsPSO: MTLRenderPipelineState) -> Bool {
            switch plan.compositePath {
            case .effects:
                return compositeEffects(into: tex, pso: effectsPSO)
            case .noEffects:
                return compositeNoEffects(into: tex, pso: noEffectsPSO)
            }
        }
        if upscale {
            guard let graded = textures[.graded], let upscaled = textures[.upscaled] else {
                return false
            }
            guard composite(into: graded,
                            effectsPSO: compositePSO,
                            noEffectsPSO: compositeNoEffectsPSO) else { return false }
            if ensureScaler(input: internalPx, output: pixelSize), let scaler {
                scaler.colorTexture = graded
                scaler.outputTexture = upscaled
                scaler.encode(commandBuffer: cb)
                guard fullscreenPass(cb, into: target, pso: presentPSO, configure: { e in
                    e.setFragmentTexture(upscaled, index: 0)
                }) else { return false }
            } else {
                // scaler creation failed: never present an unwritten drawable — show the
                // internal-res frame (present samples linearly, so it stretches to fit)
                log.error("MetalFX scaler unavailable — presenting internal-res frame")
                guard fullscreenPass(cb, into: target, pso: presentPSO, configure: { e in
                    e.setFragmentTexture(graded, index: 0)
                }) else { return false }
            }
        } else {
            guard composite(into: target,
                            effectsPSO: compositeOutPSO,
                            noEffectsPSO: compositeNoEffectsOutPSO) else { return false }
        }

        cb.addCompletedHandler { [weak self] done in
            if done.status == .error || done.error != nil {
                let msg = done.error?.localizedDescription ?? "unknown"
                log.error("command buffer failed status=\(done.status.rawValue) error=\(msg, privacy: .public)")
                panoramaFailure?()
            }
            guard let self else { return }
            let t = Float(done.gpuEndTime - done.gpuStartTime)
            if t > 0 {
                self.gpuTimeLock.lock()
                self.pendingGPUTime = t
                self.pendingHealthGPUTime = t
                self.gpuTimeLock.unlock()
            }
        }
        return true
    }

    /// Returns the latest completed GPU duration once for the view's external-cadence health
    /// controller. The renderer governor consumes its own copy, so diagnostics never perturb
    /// dynamic resolution behavior.
    func consumeHealthGPUTime() -> Float? {
        gpuTimeLock.lock()
        defer { gpuTimeLock.unlock() }
        guard pendingHealthGPUTime > 0 else { return nil }
        let value = pendingHealthGPUTime
        pendingHealthGPUTime = 0
        return value
    }

    /// `commitGate`, when supplied, runs immediately before `cb.commit()` — after the entire
    /// frame is encoded — and returning false drops this frame (no present, no commit). This
    /// lets the multi-display submit-spacing decision and timestamp land microseconds from the
    /// real GPU submission rather than before the multi-millisecond encode (docs/CRASH-ANALYSIS).
    @discardableResult
    func render(to drawable: CAMetalDrawable, pixelSize: SIMD2<Int>, pointSize: SIMD2<Float>,
                animate: Bool = true, worldOrigin: SIMD2<Float> = .zero,
                panoramaFrame: PanoramaRenderFrame? = nil,
                panoramaFailure: (() -> Void)? = nil,
                commitGate: (() -> Bool)? = nil) -> Bool {
        guard let cb = queue.makeCommandBuffer() else { return false }
        guard renderInto(drawable.texture, pixelSize: pixelSize, pointSize: pointSize, cb: cb,
                         animate: animate, worldOrigin: worldOrigin,
                         panoramaFrame: panoramaFrame,
                         panoramaFailure: panoramaFailure) else { return false }
        if let commitGate, !commitGate() { return false }   // dropped: drawable released uncommitted
        cb.present(drawable)
        cb.commit()
        return true
    }

    @discardableResult
    func renderFrame(into target: MTLTexture, pointSize: SIMD2<Float>, animate: Bool = true,
                     worldOrigin: SIMD2<Float> = .zero,
                     panoramaFrame: PanoramaRenderFrame? = nil) -> Bool {
        guard let cb = queue.makeCommandBuffer() else { return false }
        guard renderInto(target, pixelSize: SIMD2(target.width, target.height), pointSize: pointSize,
                         cb: cb, animate: animate, worldOrigin: worldOrigin,
                         panoramaFrame: panoramaFrame, panoramaFailure: nil) else { return false }
        cb.commit()
        cb.waitUntilCompleted()
        return cb.status == .completed && cb.error == nil
    }
}
