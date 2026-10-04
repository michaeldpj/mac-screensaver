/// Pure per-callback rendering policy. Keeping the decision independent of AppKit/Metal makes
/// it possible to prove that static accessibility and preference states stop ongoing GPU work.
enum FrameActivityPolicy {
    enum Action: Equatable {
        /// Leave the view's opaque black layer in place. No drawable or renderer is required.
        case showBlackWithoutGPU
        /// Encode and present the normal animated frame.
        case animate
        /// Present one atmosphere-only frame after entering a static state.
        case renderStaticOnce
        /// Keep the display callback alive only to observe a state change; submit no GPU work.
        case idle
    }

    static func action(surfaceAuthorized: Bool,
                       animationRequested: Bool,
                       reduceMotion: Bool,
                       hasPresentedStaticFrame: Bool) -> Action {
        guard surfaceAuthorized else { return .showBlackWithoutGPU }
        if animationRequested && !reduceMotion { return .animate }
        return hasPresentedStaticFrame ? .idle : .renderStaticOnce
    }
}
