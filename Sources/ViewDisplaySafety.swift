/// Per-view display authorization for the final safety check immediately before rendering.
///
/// Process-wide display planning is not sufficient for a `.saver`: ScreenSaverEngine can create
/// views itself, and AppKit can move an existing view to another screen after the plan was made.
/// Keep this policy free of AppKit so its fail-closed behavior remains directly unit-testable.
enum ViewDisplaySafety {
    /// Only a view explicitly created as a budgeted secondary by our standalone tools may use
    /// tool authorization on an external display. A multi-display primary must remain a primary:
    /// if AppKit migrates it externally, the per-view check must fail closed.
    static func toolAuthorizesExternal(isSecondary: Bool, isMultiDisplay _: Bool) -> Bool {
        isSecondary
    }

    static func shouldAnimate(isPreview: Bool,
                              screenIsBuiltIn: Bool?,
                              toolAuthorized: Bool,
                              allDisplaysOverride: Bool,
                              singleDisplayHint _: Bool) -> Bool {
        // System Settings' small preview may be evaluated before it has an attached NSScreen.
        if isPreview { return true }

        // A fullscreen view must prove which display currently owns it. Tool flags and explicit
        // overrides describe intent, but cannot make an unknown physical target safe.
        guard let screenIsBuiltIn else { return false }

        if screenIsBuiltIn { return true }
        if toolAuthorized { return true }

        // Crash-reproduction escape hatch. This is intentionally the only environment override
        // that authorizes a live external surface.
        return allDisplaysOverride
    }
}
