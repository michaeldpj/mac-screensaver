import AppKit
import QuartzCore

/// THE panic-avoidance display policy (docs/CRASH-ANALYSIS.md), shared by every shell that puts
/// the engine on screen. The decision is pure (`DisplayPlan.decide`, `DisplayDecision.swift`);
/// this is the AppKit adapter that resolves `NSScreen`s into specs and back into surfaces.
/// - DEFAULT: the BUILT-IN panel is the only display animated. Every SoC panic was `DCPEXT0` —
///   an external coprocessor. With no built-in present (clamshell), NOTHING animates: every
///   display shows the static graded field.
/// - `SEASONS_MULTI=N` (experimental): built-in primary at full plus up to N externals at the
///   `.lite` tier with cross-display submit spacing. Requires a built-in primary; can still
///   panic the SoC — opt in only for deliberate testing.
/// - `SEASONS_ALL_DISPLAYS=1` opts into the known-dangerous FULL-quality simultaneous mode.
/// - `SEASONS_SINGLE_DISPLAY=1` isolates the built-in (no built-in ⇒ nothing animates).
/// - Seasons.app may pass its explicit persisted External Ultra-Lite opt-in. The default argument
///   is false, so preview and legacy saver callers do not inherit the stored app preference.
enum DisplayPolicy {
    struct Surface {
        let screen: NSScreen
        let animated: Bool
        let tier: QualityTier
        let isSecondary: Bool
        var isMultiDisplay = false   // SEASONS_MULTI active: primary also spaces its submits
        let panorama: PanoramaRuntimeContext?
    }

    static func surfaces(appExternalUltraLite: Bool = false) -> [Surface] {
        let all = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        guard !all.isEmpty else { return [] }
        let env = ProcessInfo.processInfo.environment
        let externalUltraLite = ExternalUltraLiteAuthorization.enabled(
            environmentOptIn: env["SEASONS_EXT_ULTRALITE"] != nil,
            persistedAppOptIn: appExternalUltraLite
        )
        let allDisplays = env["SEASONS_ALL_DISPLAYS"] != nil

        let specs = all.map { ScreenSpec(id: screenID($0), isBuiltin: isBuiltin($0)) }
        let plan = DisplayPlan.decide(screens: specs,
                                      allDisplays: allDisplays,
                                      singleDisplay: env["SEASONS_SINGLE_DISPLAY"] != nil,
                                      multi: env["SEASONS_MULTI"].flatMap { Int($0) },
                                      edr: SeasonsView.edrPresentation,
                                      externalUltraLite: externalUltraLite)
        let animatedUltraLiteExternals = plan.filter {
            $0.animated && $0.tier == .ultraLite
        }.count

        var byID: [Int: NSScreen] = [:]
        for screen in all { byID[screenID(screen)] = screen }

        // Panoramic flow is intentionally narrower than general multi-display rendering: only
        // two or more explicitly authorized Ultra-Lite EXTERNALS share a world. The built-in
        // retains its existing independent full-quality renderer, and the known-dangerous
        // ALL_DISPLAYS reproduction path can never acquire a panorama descriptor.
        var panoramas: [Int: PanoramaRuntimeContext] = [:]
        if !allDisplays {
            let members = plan.compactMap { decision -> (id: Int, screen: NSScreen)? in
                guard decision.animated, decision.tier == .ultraLite,
                      decision.isSecondary, let screen = byID[decision.id],
                      !isBuiltin(screen) else { return nil }
                return (decision.id, screen)
            }
            if members.count >= 2 {
                // SeasonsView requests ticks with CACurrentMediaTime; use the same monotonic clock
                // for the shared epoch so a clock-domain offset cannot trigger instant overrun.
                let startTime = CACurrentMediaTime()
                let geometry = members.map { member in
                    let frame = member.screen.frame
                    return PanoramaDisplayGeometry(
                        id: member.id,
                        x: Float(frame.origin.x), y: Float(frame.origin.y),
                        width: Float(frame.width), height: Float(frame.height)
                    )
                }
                if let layout = try? PanoramaLayout(
                    displays: geometry, sessionSeed: startTime.bitPattern
                ) {
                    let coordinator = PanoramaFrameCoordinator(
                        memberIDs: members.map(\.id), startTime: startTime,
                        hertz: PanoramaRuntimeContext.simulationHertz
                    )
                    for projection in layout.projections {
                        panoramas[projection.displayID] = PanoramaRuntimeContext(
                            projection: projection, coordinator: coordinator,
                            startTime: startTime
                        )
                    }
                }
            }
        }

        return plan.compactMap { d in
            guard let screen = byID[d.id] else { return nil }
            var qtier: QualityTier
            switch d.tier {
            case .full: qtier = .full
            case .lite: qtier = .lite
            case .ultraLite: qtier = .ultraLite
            }
            if isBuiltin(screen) {
                qtier.fps = Double(DisplayCadenceBudget.builtInFPS(
                    requestedFPS: Int(qtier.fps),
                    externalUltraLite: externalUltraLite,
                    externalDisplayCount: animatedUltraLiteExternals
                ))
            }
            return Surface(screen: screen, animated: d.animated, tier: qtier,
                           isSecondary: d.isSecondary, isMultiDisplay: d.isMultiDisplay,
                           panorama: panoramas[d.id])
        }
    }

    /// Stable identity for an `NSScreen` (its CoreGraphics display id; identity hash as fallback).
    private static func screenID(_ s: NSScreen) -> Int {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
            ?? ObjectIdentifier(s).hashValue
    }

    static func isBuiltin(_ s: NSScreen) -> Bool {
        guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return CGDisplayIsBuiltin(num.uint32Value) != 0
    }

    /// Borderless screensaver-level window covering `screen` (black; content set by caller).
    static func makeWindow<W: NSWindow>(_ type: W.Type, on screen: NSScreen) -> W {
        let w = W(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
                  defer: false, screen: screen)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = .black
        w.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        w.setFrame(screen.frame, display: true)
        return w
    }
}
