import ScreenSaver
import QuartzCore
import Metal
import os

private let log = Logger(subsystem: "me.mdpj.Seasons", category: "view")

final class SeasonsView: ScreenSaverView {
    private var device: MTLDevice?
    private var displayLink: CADisplayLink?
    private var renderer: Renderer?
    private var builtRenderer = false
    private var lastRenderTime: CFTimeInterval = 0
    private var frameCount = 0
    private var running = false
    private var hasPresentedStaticFrame = false
    private var staticOnly = false     // no recurring render loop (fail-closed black or capture)
    private var waitingForSafeScreen = false
    private var safetyBlackoutLayer: CALayer?
    private var adaptiveCadence: AdaptiveExternalCadence?
    private var appliedAdaptiveFPS: Int?
    private var healthWindowStarted: CFTimeInterval = 0
    private var healthAttempts = 0
    private var healthSubmissions = 0
    private var healthDrawableMisses = 0
    private var healthRenderFailures = 0
    private var healthSchedulerAdmissions = 0
    private var healthSchedulerWaitTotal: CFTimeInterval = 0
    private var healthSchedulerWaitMax: CFTimeInterval = 0
    private var healthLatestGPUTime: CFTimeInterval = 0

    /// Render budget for THIS display. Primary = .full; secondaries (multi-display mode) = .lite,
    /// and every planned multi-display view routes submissions through the fair coordinator so
    /// no two displays escalate
    /// the display power rail at the same instant (docs/CRASH-ANALYSIS.md).
    var tier: QualityTier = .full
    var isSecondary = false
    var isMultiDisplay = false   // true when SEASONS_MULTI is active (primary also spaces submits)
    /// Set only by the standalone hosts for an authorized group of two or more Ultra-Lite
    /// externals. A directly instantiated `.saver` view remains nil and keeps local simulation.
    var panorama: PanoramaRuntimeContext?
    // Small anti-coincidence guard: enough to avoid two displays submitting in the same ~2ms
    // window (the suspected concurrent-DCP-escalation trigger), not a rate limit. The FIFO
    // coordinator waits for every planned surface rather than starving one through frame drops.
    private let minSubmitSpacing: CFTimeInterval = 0.002

    // A small frame is a useful performance hint, but never a display-safety authorization.
    // Only ScreenSaverView's actual `isPreview` state may bypass screen ownership proof.
    private var likelyPreview: Bool { isPreview || bounds.width < 480 }

    // `SEASONS_FORCE_FPS` caps present rate (clamped 30–120) to relieve the display power rail.
    private var forcedFPS: Double? {
        guard let s = ProcessInfo.processInfo.environment["SEASONS_FORCE_FPS"], let v = Double(s) else { return nil }
        return min(max(v, 30), 120)
    }

    private var preferredFPS: Double {
        var value = tier.fps
        if let adaptiveCadence { value = min(value, Double(adaptiveCadence.targetFPS)) }
        if likelyPreview { value = min(value, 30) }
        if let forcedFPS { value = min(value, forcedFPS) }
        return value
    }

    private var activeFrameRateRange: CAFrameRateRange {
        let cap = Float(preferredFPS)
        let preferred = cap
        return CAFrameRateRange(minimum: min(30, cap), maximum: cap, preferred: preferred)
    }

    private func resetHealthDiagnostics() {
        healthWindowStarted = CACurrentMediaTime()
        healthAttempts = 0
        healthSubmissions = 0
        healthDrawableMisses = 0
        healthRenderFailures = 0
        healthSchedulerAdmissions = 0
        healthSchedulerWaitTotal = 0
        healthSchedulerWaitMax = 0
        healthLatestGPUTime = 0
    }

    private func applyAdaptiveCadenceIfNeeded(previousFPS: Int) {
        guard let adaptiveCadence else { return }
        let target = adaptiveCadence.targetFPS
        guard target != previousFPS || appliedAdaptiveFPS != target else { return }
        appliedAdaptiveFPS = target
        displayLink?.preferredFrameRateRange = activeFrameRateRange
        log.notice("external cadence changed from \(previousFPS) to \(target) FPS")
    }

    private func refreshExternalHealth() {
        guard let adaptiveCadence else { return }
        let previousFPS = adaptiveCadence.targetFPS
        if let gpuTime = renderer?.consumeHealthGPUTime() {
            healthLatestGPUTime = CFTimeInterval(gpuTime)
            adaptiveCadence.recordGPUFrame(duration: CFTimeInterval(gpuTime))
        }
        adaptiveCadence.refresh()
        applyAdaptiveCadenceIfNeeded(previousFPS: previousFPS)
        logHealthDiagnosticsIfNeeded()
    }

    private func recordDrawableMiss() {
        guard let adaptiveCadence else { return }
        healthDrawableMisses += 1
        let previousFPS = adaptiveCadence.targetFPS
        adaptiveCadence.recordDrawableMiss()
        applyAdaptiveCadenceIfNeeded(previousFPS: previousFPS)
    }

    private func recordSchedulerWait(_ duration: CFTimeInterval) {
        guard let adaptiveCadence else { return }
        healthSchedulerAdmissions += 1
        healthSchedulerWaitTotal += duration
        healthSchedulerWaitMax = max(healthSchedulerWaitMax, duration)
        let previousFPS = adaptiveCadence.targetFPS
        adaptiveCadence.recordSchedulerWait(duration: duration)
        applyAdaptiveCadenceIfNeeded(previousFPS: previousFPS)
    }

    private func logHealthDiagnosticsIfNeeded() {
        guard let adaptiveCadence else { return }
        let timestamp = CACurrentMediaTime()
        let elapsed = timestamp - healthWindowStarted
        guard elapsed >= 5 else { return }
        let observedFPSx10 = Int((Double(healthSubmissions) / max(elapsed, 0.001) * 10).rounded())
        let averageWaitMicros = healthSchedulerAdmissions > 0
            ? Int((healthSchedulerWaitTotal / Double(healthSchedulerAdmissions) * 1_000_000).rounded())
            : 0
        let maxWaitMicros = Int((healthSchedulerWaitMax * 1_000_000).rounded())
        let gpuMicros = Int((healthLatestGPUTime * 1_000_000).rounded())
        log.notice("""
        external health targetFPS=\(adaptiveCadence.targetFPS) observedFPSx10=\(observedFPSx10) \
        attempts=\(self.healthAttempts) submits=\(self.healthSubmissions) \
        drawableMisses=\(self.healthDrawableMisses) renderFailures=\(self.healthRenderFailures) \
        waitAvgUs=\(averageWaitMicros) waitMaxUs=\(maxWaitMicros) gpuUs=\(gpuMicros)
        """)
        resetHealthDiagnostics()
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        animationTimeInterval = 1.0 / 60.0  // framework timer; also drives the fallback path
        log.notice("init frame=\(NSStringFromRect(frame), privacy: .public) preview=\(isPreview)")
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? { ConfigSheet.makeWindow() }

    // EDR presentation is opt-in (`SEASONS_EDR=1`). Both observed SoC panics implicate the
    // display power rail, and the 2026-06-10 one reproduced with MetalFX off on one display —
    // the EDR drawable path is the remaining prime suspect (docs/CRASH-ANALYSIS.md). Default is
    // SDR: 10-bit Display P3, no extended-range content, internal pipeline unchanged.
    static let edrPresentation = ProcessInfo.processInfo.environment["SEASONS_EDR"] != nil
    static var drawableFormat: MTLPixelFormat { edrPresentation ? .rgba16Float : .bgra10_xr_srgb }

    /// Resolve the final transfer encoding independently for every surface. Ultra-Lite is always
    /// SDR and sRGB-encoded even when the process was launched with the experimental EDR flag.
    private var presentationPlan: PresentationColorPlan {
        PresentationColorPolicy.plan(ultraLite: tier.present8Bit,
                                     edrRequested: Self.edrPresentation)
    }

    private var effectiveDrawableFormat: MTLPixelFormat {
        switch presentationPlan.pixelEncoding {
        case .bgra8UnormSRGB: return .bgra8Unorm_srgb
        case .bgra10XRSRGB: return .bgra10_xr_srgb
        case .rgba16Float: return .rgba16Float
        }
    }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        // Attach a Metal device only after per-view display authorization succeeds. An installed
        // external saver therefore remains a plain opaque layer with no GPU-backed drawables.
        l.device = nil
        l.framebufferOnly = true
        l.maximumDrawableCount = 2
        l.isOpaque = true
        l.backgroundColor = CGColor(gray: 0, alpha: 1)
        l.pixelFormat = Self.drawableFormat
        if Self.edrPresentation {
            l.wantsExtendedDynamicRangeContent = true
            l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            log.notice("EDR presentation enabled by SEASONS_EDR (experimental)")
        } else {
            l.wantsExtendedDynamicRangeContent = false
            l.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        }
        return l
    }

    override func startAnimation() {
        super.startAnimation()
        guard !running else { return }   // idempotent: framework can re-instantiate/restart
        running = true
        staticOnly = false
        waitingForSafeScreen = false
        hasPresentedStaticFrame = false
        adaptiveCadence = isSecondary && tier.present8Bit
            ? AdaptiveExternalCadence(now: { CACurrentMediaTime() })
            : nil
        appliedAdaptiveFPS = adaptiveCadence?.targetFPS
        resetHealthDiagnostics()
        log.notice("startAnimation bounds=\(NSStringFromRect(self.bounds), privacy: .public) preview=\(self.likelyPreview) secondary=\(self.isSecondary)")
        if let projection = panorama?.projection {
            log.notice("""
            panorama display=\(projection.displayID) world=\(projection.worldSize.x)x\(projection.worldSize.y) \
            cameraOrigin=\(projection.cameraOrigin.x),\(projection.cameraOrigin.y) \
            cameraSize=\(projection.cameraSize.x)x\(projection.cameraSize.y) seed=\(projection.worldSeed)
            """)
        }
        // Final per-view panic guard. ScreenSaverEngine can bypass DisplayPolicy and AppKit can
        // migrate a view after the process-wide plan was made. An unauthorized or not-yet-attached
        // fullscreen view stays layer-only black: no renderer, sprites, drawable, queue, or submit.
        beginAuthorizedRendering()
    }

    /// Starts or resumes rendering only after current screen ownership has been proven safe.
    /// When screen ownership is temporarily unknown, ScreenSaverView's framework timer remains
    /// as a GPU-free poll so a later attachment to the built-in display can recover.
    private func beginAuthorizedRendering() {
        guard isAuthorizedToRender else {
            failClosedForAuthorization()
            return
        }
        waitingForSafeScreen = false
        staticOnly = false
        removeSafetyBlackout()
        guard prepareMetalLayer() else { return }
        // Static capture (SEASONS_CAPTURE_STATIC): render exactly one frame, then stop — safe
        // per-display logging (drawable size, format) with no sustained animation. Validates the
        // External Ultra-Lite clamp without exposing externals to a live render loop.
        if ProcessInfo.processInfo.environment["SEASONS_CAPTURE_STATIC"] != nil {
            staticOnly = true
            renderFrame()
            return
        }
        let link = displayLink(target: self, selector: #selector(displayTick))
        link.preferredFrameRateRange = activeFrameRateRange
        link.add(to: .current, forMode: .common)
        displayLink = link
    }

    override func stopAnimation() {
        super.stopAnimation()
        teardown()
    }

    deinit { teardown() }

    /// Idempotent GPU/timer teardown so a re-instantiated view never leaks a live renderer.
    private func teardown() {
        running = false
        displayLink?.invalidate()
        displayLink = nil
        renderer = nil
        builtRenderer = false
        hasPresentedStaticFrame = false
        waitingForSafeScreen = false
        adaptiveCadence = nil
        appliedAdaptiveFPS = nil
        device = nil
        (layer as? CAMetalLayer)?.device = nil
    }

    // CADisplayLink path (ProMotion, in-window).
    @objc private func displayTick() {
        guard isAuthorizedToRender else {
            failClosedForAuthorization()
            return
        }
        renderFrame()
    }

    // Framework timer fallback: render only when the display link is not firing
    // (e.g. the System Settings preview thumbnail, where CADisplayLink may be inactive).
    override func animateOneFrame() {
        if waitingForSafeScreen {
            guard isAuthorizedToRender else { return }
            beginAuthorizedRendering()
            return
        }
        if staticOnly { return }
        guard isAuthorizedToRender else {
            failClosedForAuthorization()
            return
        }
        if CACurrentMediaTime() - lastRenderTime > 0.1 { renderFrame() }
    }

    /// Per-view authorization is deliberately repeated immediately before each render. This closes
    /// the gap where an AppKit view that was safe at startup migrates onto an external display.
    private var isAuthorizedToRender: Bool {
        let env = ProcessInfo.processInfo.environment
        return ViewDisplaySafety.shouldAnimate(
            isPreview: isPreview,
            screenIsBuiltIn: window?.screen.map { DisplayPolicy.isBuiltin($0) },
            // Only a deliberately budgeted secondary may render on an external. The primary's
            // `isMultiDisplay` flag controls submit spacing and must not authorize migration.
            toolAuthorized: ViewDisplaySafety.toolAuthorizesExternal(
                isSecondary: isSecondary,
                isMultiDisplay: isMultiDisplay
            ),
            allDisplaysOverride: env["SEASONS_ALL_DISPLAYS"] != nil,
            singleDisplayHint: env["SEASONS_SINGLE_DISPLAY"] != nil
        )
    }

    /// GPU-free fallback used for an installed external, clamshell-only, unknown, or migrated view.
    /// Invalidating the link first prevents a callback from retaining live render resources.
    private func enterFailClosedBlackMode(waitForAuthorization: Bool = false) {
        displayLink?.invalidate()
        displayLink = nil
        renderer = nil
        builtRenderer = false
        hasPresentedStaticFrame = false
        device = nil
        (layer as? CAMetalLayer)?.device = nil
        staticOnly = true
        waitingForSafeScreen = waitForAuthorization
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        if safetyBlackoutLayer == nil, let layer {
            let blackout = CALayer()
            blackout.name = "Seasons display-safety blackout"
            blackout.backgroundColor = CGColor(gray: 0, alpha: 1)
            blackout.frame = layer.bounds
            blackout.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.addSublayer(blackout)
            safetyBlackoutLayer = blackout
            log.notice("render denied by per-view display safety; showing layer-only black")
        }
    }

    /// Losing one panoramic member would otherwise leave the remaining frame latch repeating its
    /// last tick forever. Authorization loss is a topology failure for the whole group.
    private func failClosedForAuthorization() {
        if panorama != nil {
            panorama?.invalidate()
            log.error("panorama invalidated: member lost display authorization")
        }
        enterFailClosedBlackMode(waitForAuthorization: true)
    }

    /// Replica divergence is worse than losing the effect: once one panoramic renderer cannot
    /// encode the shared state, invalidate the common context and take this surface GPU-free.
    /// Peers observe the same invalidation on their next callback and fail closed as a group.
    private func invalidatePanorama(reason: String) {
        panorama?.invalidate()
        log.error("panorama invalidated: \(reason, privacy: .public)")
        enterFailClosedBlackMode()
    }

    private func removeSafetyBlackout() {
        safetyBlackoutLayer?.removeFromSuperlayer()
        safetyBlackoutLayer = nil
    }

    /// Lazily creates the Metal device only for a surface that passed the final per-view check.
    /// Failure leaves the opaque black safety layer visible instead of crashing the host process.
    private func prepareMetalLayer() -> Bool {
        guard let metalLayer = layer as? CAMetalLayer else { return false }
        if let device {
            if metalLayer.device == nil { metalLayer.device = device }
            return true
        }
        guard let nextDevice = MTLCreateSystemDefaultDevice() else {
            log.error("no default Metal device; staying fail-closed black")
            enterFailClosedBlackMode()
            return false
        }
        device = nextDevice
        metalLayer.device = nextDevice
        return true
    }

    private var animationRequested: Bool {
        let forced = ProcessInfo.processInfo.environment["SEASONS_FORCE"]
        let rawName = forced.flatMap { $0.isEmpty ? nil : $0 } ?? Prefs.selectionName
        return rawName != "off"
    }

    private func buildRenderer(pointSize: SIMD2<Float>) {
        builtRenderer = true
        guard device != nil else {
            log.error("buildRenderer called without an authorized Metal device")
            return
        }
        // A .saver is a loadable bundle: Bundle.main is the host process, so makeDefaultLibrary()
        // (which reads Bundle.main) cannot find our metallib. Load from our own bundle;
        // Bundle(for:) needs an NSObject-rooted class to resolve here.
        let ownBundle = Bundle(for: SeasonsView.self)
        let month = Calendar.current.component(.month, from: Date()) - 1
        let forced = ProcessInfo.processInfo.environment["SEASONS_FORCE"]
        // Selection precedence: dev/preview env override → persisted preference → auto.
        // Non-seasonal styles (rain, embers, stars) exist only as named configs — they are not
        // representable in SeasonSelection — so any unrecognized non-off name loads by name,
        // whether it came from the env or the menu-bar picker.
        let rawName = forced.flatMap { $0.isEmpty ? nil : $0 } ?? Prefs.selectionName
        if rawName != "off", rawName != "auto",
           SeasonSelection(storage: rawName) == .auto,   // not a recognized season id
           let styled = SeasonCatalog.loadNamed(rawName, bundle: ownBundle) {
            buildRenderer(season: styled, pointSize: pointSize, ownBundle: ownBundle)
            return
        }
        let selection = SeasonSelection(storage: rawName)
        guard let season = SeasonCatalog.displaySeason(selection, month: month, bundle: ownBundle)
                ?? SeasonCatalog.load(SeasonCatalog.seasonByMonth(month), bundle: ownBundle) else {
            log.error("buildRenderer: no season config found in bundle")
            return
        }
        buildRenderer(season: season, pointSize: pointSize, ownBundle: ownBundle)
    }

    private func buildRenderer(season: Season, pointSize: SIMD2<Float>, ownBundle: Bundle) {
        guard let device else {
            log.error("buildRenderer called without an authorized Metal device")
            return
        }
        do {
            let library = try device.makeDefaultLibrary(bundle: ownBundle)
            let sprites = season.speciesResolved.map { sp in
                SpriteLoader.loadArray(set: sp.spriteSet, count: sp.spriteCount,
                                       device: device, library: library, bundle: ownBundle)
            }
            log.notice("buildRenderer ok season=\(season.name, privacy: .public) static=\(!self.animationRequested)")
            let count: Float = likelyPreview ? 0.35 : tier.countScale
            renderer = Renderer(device: device, library: library, season: season,
                                viewport: pointSize, sprites: sprites,
                                targetFPS: preferredFPS,
                                countScale: count,
                                bloom: Prefs.bloom && tier.bloom, dof: Prefs.depthOfField && tier.dof,
                                drawableFormat: effectiveDrawableFormat,
                                clampOutput: tier.present8Bit || !Self.edrPresentation,
                                litePost: tier.litePost, forcedScale: tier.forcedScale,
                                panoramaProjection: panorama?.projection)
        } catch {
            log.error("buildRenderer FAILED: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func renderFrame() {
        guard isAuthorizedToRender else {
            failClosedForAuthorization()
            return
        }
        removeSafetyBlackout()
        let action = FrameActivityPolicy.action(
            surfaceAuthorized: true,
            animationRequested: animationRequested,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            hasPresentedStaticFrame: hasPresentedStaticFrame
        )
        switch action {
        case .showBlackWithoutGPU:
            enterFailClosedBlackMode()
            return
        case .idle:
            // Keep only the lightweight callback so Off/Reduce Motion can resume live.
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: 30, preferred: 30
            )
            lastRenderTime = CACurrentMediaTime()
            return
        case .animate:
            hasPresentedStaticFrame = false
            displayLink?.preferredFrameRateRange = activeFrameRateRange
        case .renderStaticOnce:
            break
        }
        refreshExternalHealth()
        guard prepareMetalLayer() else { return }
        guard bounds.width > 0, bounds.height > 0,
              let metalLayer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pointSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        var pixelW = Int(bounds.width * scale), pixelH = Int(bounds.height * scale)
        // External Ultra-Lite: clamp the source drawable to cut rendering/presentation workload
        // (the panel remains at its configured refresh and output resolution), and use 8-bit BGRA.
        if let maxEdge = tier.presentMaxEdge {
            (pixelW, pixelH) = DisplayPlan.clampDrawable(width: pixelW, height: pixelH, maxEdge: maxEdge)
        }
        let plan = presentationPlan
        if metalLayer.pixelFormat != effectiveDrawableFormat {
            metalLayer.pixelFormat = effectiveDrawableFormat
        }
        metalLayer.wantsExtendedDynamicRangeContent = plan.extendedDynamicRange
        metalLayer.colorspace = CGColorSpace(name: plan.colorSpace == .displayP3
            ? CGColorSpace.displayP3 : CGColorSpace.extendedLinearDisplayP3)
        metalLayer.contentsScale = bounds.width > 0 ? CGFloat(pixelW) / bounds.width : scale
        metalLayer.drawableSize = CGSize(width: pixelW, height: pixelH)

        // Screen ownership can change while a frame is being prepared. Check again before any
        // renderer construction or drawable acquisition so a migrated view fails closed.
        guard isAuthorizedToRender else {
            failClosedForAuthorization()
            return
        }
        if !builtRenderer { buildRenderer(pointSize: pointSize) }
        guard let renderer else {
            if panorama != nil { invalidatePanorama(reason: "renderer construction failed") }
            return
        }
        guard isAuthorizedToRender else {
            failClosedForAuthorization()
            return
        }

        // Join the shared simulation round BEFORE drawable acquisition. A transient drawable miss
        // therefore cannot leave the other replicas waiting on this member or fork their ticks.
        let panoramaFrame: PanoramaRenderFrame?
        if let panorama {
            guard let targetTick = panorama.targetTick(at: CACurrentMediaTime()) else {
                invalidatePanorama(reason: "shared panorama context was invalidated")
                return
            }
            panoramaFrame = PanoramaRenderFrame(
                projection: panorama.projection, targetTick: targetTick,
                startTime: panorama.startTime
            )
        } else {
            panoramaFrame = nil
        }
        if adaptiveCadence != nil { healthAttempts += 1 }
        guard let drawable = metalLayer.nextDrawable() else {
            recordDrawableMiss()
            logHealthDiagnosticsIfNeeded()
            return
        }
        let animate = action == .animate
        // Global desktop origin: makes the wind field continuous across displays.
        let so = window?.screen?.frame.origin ?? .zero

        // Cross-display spacing is decided at the COMMIT, not before the multi-ms encode. Every
        // planned multi-display surface enters one FIFO ticket queue and waits the small remainder
        // needed for a real 2ms separation. Contention never drops a frame or starves one display.
        let gate: () -> Bool
        if isSecondary || isMultiDisplay {
            gate = { [self] in
                guard panorama?.coordinator.isValid != false else {
                    enterFailClosedBlackMode()
                    return false
                }
                guard isAuthorizedToRender else {
                    failClosedForAuthorization()
                    return false
                }
                let admission = FairSubmitCoordinator.shared.acquire(
                    minSpacing: minSubmitSpacing
                )
                recordSchedulerWait(admission.waitDuration)
                guard panorama?.coordinator.isValid != false else {
                    enterFailClosedBlackMode()
                    return false
                }
                // Screen ownership may change while this ticket waits behind another display.
                guard isAuthorizedToRender else {
                    failClosedForAuthorization()
                    return false
                }
                return true
            }
        } else {
            // Even the default single-display path checks at the actual commit boundary. Encoding
            // can take milliseconds, which is enough time for AppKit to migrate the view.
            gate = { [self] in
                guard isAuthorizedToRender else {
                    failClosedForAuthorization()
                    return false
                }
                return true
            }
        }
        // A library/sprite build can be relatively expensive; do one final authorization check
        // before command encoding/submission in case the view migrated during that work.
        guard isAuthorizedToRender else {
            failClosedForAuthorization()
            return
        }
        let submitted = renderer.render(
            to: drawable, pixelSize: SIMD2(pixelW, pixelH), pointSize: pointSize,
            animate: animate, worldOrigin: SIMD2(Float(so.x), Float(so.y)),
            panoramaFrame: panoramaFrame,
            panoramaFailure: { [panorama] in panorama?.invalidate() },
            commitGate: gate
        )
        guard submitted else {
            if adaptiveCadence != nil { healthRenderFailures += 1 }
            logHealthDiagnosticsIfNeeded()
            if panorama != nil { invalidatePanorama(reason: "panoramic frame failed") }
            return
        }
        if adaptiveCadence != nil { healthSubmissions += 1 }
        logHealthDiagnosticsIfNeeded()
        if action == .renderStaticOnce { hasPresentedStaticFrame = true }
        frameCount += 1
        if frameCount == 1 {
            let cs = (metalLayer.colorspace?.name as String?) ?? "nil"
            let fps = displayLink?.preferredFrameRateRange.preferred ?? 0
            log.notice("""
            first frame: screen=\(NSStringFromRect(self.window?.screen?.frame ?? .zero), privacy: .public) \
            backingScale=\(scale) drawable=\(pixelW)x\(pixelH) fmt=\(metalLayer.pixelFormat.rawValue) \
            edr=\(metalLayer.wantsExtendedDynamicRangeContent) colorspace=\(cs, privacy: .public) \
            preferredFPS=\(fps) static=\(!animate) tier=\(self.tier.litePost ? "lite" : "full")
            """)
        }
        lastRenderTime = CACurrentMediaTime()
    }
}
