/// Pure panic-avoidance display policy — no AppKit, no NSScreen, unit-testable in isolation.
/// `DisplayPolicy.surfaces` is the thin adapter that resolves real `NSScreen`s into `ScreenSpec`s,
/// calls `decide`, and maps the result back to on-screen surfaces.
///
/// THE rule: the built-in panel is the ONLY display ever animated by default. Every observed SoC
/// panic was `DCPEXT0` — an EXTERNAL display coprocessor escalating an unsatisfiable `power(6)`
/// (docs/CRASH-ANALYSIS.md, four hard reboots). The built-in XDR panel has never faulted. When no
/// built-in panel is present (clamshell or a desktop with only externals), `target` is nil and
/// NOTHING animates: every display shows the static graded field. Externals animate only under the
/// explicit `allDisplays` flag, which exists solely to reproduce the bug for an Apple Feedback.

struct ScreenSpec: Equatable {
    let id: Int
    let isBuiltin: Bool
}

enum DisplayTier: Equatable { case full, lite, ultraLite }

struct DisplayDecision: Equatable {
    let id: Int
    let animated: Bool
    let tier: DisplayTier
    let isSecondary: Bool
    let isMultiDisplay: Bool
}

/// Merges the temporary developer hook with the menu-bar app's explicit persisted opt-in.
/// Callers other than Seasons.app pass the default `false`, so storing the preference never
/// broadens authorization for the legacy saver or preview tool.
enum ExternalUltraLiteAuthorization {
    static func enabled(environmentOptIn: Bool, persistedAppOptIn: Bool) -> Bool {
        environmentOptIn || persistedAppOptIn
    }
}

enum DisplayPlan {
    /// Decide which displays animate. `multi` is the `SEASONS_MULTI=N` count (nil when unset);
    /// `edr` suppresses the multi path because an EDR drawable on an external is the documented
    /// hazard. The default and every experimental path animate only the built-in `target`; a nil
    /// target means no display animates.
    static func decide(screens: [ScreenSpec],
                       allDisplays: Bool,
                       singleDisplay: Bool,
                       multi: Int?,
                       edr: Bool,
                       externalUltraLite: Bool = false) -> [DisplayDecision] {
        let target = screens.first(where: { $0.isBuiltin })?.id

        // External Ultra-Lite (opt-in experiment, SEASONS_EXT_ULTRALITE): animate externals at a
        // clamped low-bandwidth tier instead of forcing them static. A built-in, if present, stays
        // full. This is the only mode that animates an external by intent; the present-bandwidth
        // clamp itself lives in the view (DisplayTier.ultraLite → QualityTier.ultraLite).
        if externalUltraLite {
            let multiDisplay = screens.count > 1
            return screens.map { s in
                let builtIn = s.id == target
                return DisplayDecision(id: s.id, animated: true,
                                       tier: builtIn ? .full : .ultraLite,
                                       isSecondary: !builtIn, isMultiDisplay: multiDisplay)
            }
        }
        // Known-dangerous full SIMULTANEOUS mode: every display animates, ungated. Crash-repro only.
        if allDisplays {
            return screens.map {
                DisplayDecision(id: $0.id, animated: true, tier: .full, isSecondary: false, isMultiDisplay: false)
            }
        }
        // Isolation: animate the built-in only (nil ⇒ none); other screens stay static black.
        if singleDisplay {
            return screens.map {
                DisplayDecision(id: $0.id, animated: $0.id == target, tier: .full, isSecondary: false, isMultiDisplay: false)
            }
        }
        // Experimental multi-display: built-in primary at full, up to N externals at lite, rest black.
        // Requires a built-in primary; without one (clamshell) it collapses to the static default.
        if !edr, let n = multi, n > 0, let target {
            let secondaries = Set(screens.lazy.filter { $0.id != target }.prefix(n).map { $0.id })
            return screens.map { s in
                if s.id == target {
                    return DisplayDecision(id: s.id, animated: true, tier: .full, isSecondary: false, isMultiDisplay: true)
                }
                if secondaries.contains(s.id) {
                    return DisplayDecision(id: s.id, animated: true, tier: .lite, isSecondary: true, isMultiDisplay: true)
                }
                return DisplayDecision(id: s.id, animated: false, tier: .full, isSecondary: false, isMultiDisplay: false)
            }
        }
        // Default safe policy: the built-in animates (nil ⇒ none); every other display is static black.
        return screens.map {
            DisplayDecision(id: $0.id, animated: $0.id == target, tier: .full, isSecondary: false, isMultiDisplay: false)
        }
    }

    /// Clamp a pixel drawable size so its longest edge ≤ `maxEdge`, preserving aspect (integer, min 1).
    /// `maxEdge <= 0` or an already-small drawable returns the input. The External Ultra-Lite present
    /// mode uses this to reduce source rendering/presentation work; the physical display remains at
    /// its configured output resolution and refresh rate.
    static func clampDrawable(width: Int, height: Int, maxEdge: Int) -> (width: Int, height: Int) {
        let w = max(width, 1), h = max(height, 1)
        guard maxEdge > 0 else { return (w, h) }
        let longest = max(w, h)
        guard longest > maxEdge else { return (w, h) }
        let k = Double(maxEdge) / Double(longest)
        return (max(Int((Double(w) * k).rounded()), 1), max(Int((Double(h) * k).rounded()), 1))
    }
}
