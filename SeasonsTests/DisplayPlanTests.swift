import XCTest

/// Locks the panic-avoidance display policy (docs/CRASH-ANALYSIS.md). Every observed SoC panic was
/// `DCPEXT0` — an external display coprocessor. The rule under test: the built-in panel is the only
/// display animated by default, and with no built-in present (clamshell) NOTHING animates.
final class DisplayPlanTests: XCTestCase {
    private func animatedIDs(_ d: [DisplayDecision]) -> [Int] { d.filter { $0.animated }.map { $0.id } }

    // The exact configuration that hard-rebooted the Mac on 2026-06-11 18:53: clamshell, externals
    // only, no built-in. The default policy must animate nothing.
    func testClamshellAnimatesNothing() {
        let screens = [ScreenSpec(id: 1, isBuiltin: false), ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false, multi: nil, edr: false)
        XCTAssertEqual(animatedIDs(plan), [], "no built-in present ⇒ no display may animate (DCPEXT0 avoidance)")
        XCTAssertEqual(plan.count, screens.count, "every display still gets a (static) surface")
    }

    func testSingleExternalStaysStatic() {
        let screens = [ScreenSpec(id: 7, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false, multi: nil, edr: false)
        XCTAssertEqual(animatedIDs(plan), [])
    }

    func testBuiltInIsTheOnlyAnimatedByDefault() {
        let screens = [ScreenSpec(id: 1, isBuiltin: false),
                       ScreenSpec(id: 9, isBuiltin: true),
                       ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false, multi: nil, edr: false)
        XCTAssertEqual(animatedIDs(plan), [9], "only the built-in animates; externals stay static")
    }

    func testAllDisplaysFlagAnimatesEveryDisplay() {
        let screens = [ScreenSpec(id: 1, isBuiltin: false), ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: true, singleDisplay: false, multi: nil, edr: false)
        XCTAssertEqual(animatedIDs(plan).sorted(), [1, 2], "explicit repro flag still exercises all pipelines")
    }

    func testSingleDisplayIsolatesBuiltInOnly() {
        let screens = [ScreenSpec(id: 9, isBuiltin: true), ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: true, multi: nil, edr: false)
        XCTAssertEqual(animatedIDs(plan), [9])
    }

    func testSingleDisplayWithoutBuiltInAnimatesNothing() {
        let screens = [ScreenSpec(id: 1, isBuiltin: false), ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: true, multi: nil, edr: false)
        XCTAssertEqual(animatedIDs(plan), [], "isolation flag must not fall back to an external")
    }

    func testMultiRequiresBuiltIn() {
        let screens = [ScreenSpec(id: 1, isBuiltin: false), ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false, multi: 1, edr: false)
        XCTAssertEqual(animatedIDs(plan), [], "no built-in primary ⇒ multi collapses to static (no external pipelines)")
    }

    func testMultiWithBuiltInAddsLiteSecondary() {
        let screens = [ScreenSpec(id: 9, isBuiltin: true),
                       ScreenSpec(id: 1, isBuiltin: false),
                       ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false, multi: 1, edr: false)
        let primary = plan.first { $0.id == 9 }
        let lites = plan.filter { $0.tier == .lite && $0.animated }
        XCTAssertEqual(primary?.animated, true)
        XCTAssertEqual(primary?.tier, .full)
        XCTAssertEqual(lites.count, 1, "exactly one external promoted to a lite secondary")
        XCTAssertTrue(lites.allSatisfy { $0.isSecondary })
    }

    func testMultiSuppressedUnderEDR() {
        let screens = [ScreenSpec(id: 9, isBuiltin: true),
                       ScreenSpec(id: 1, isBuiltin: false),
                       ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false, multi: 2, edr: true)
        XCTAssertEqual(animatedIDs(plan), [9], "EDR forbids external (lite) surfaces ⇒ built-in only")
    }

    // MARK: External Ultra-Lite (opt-in experiment)

    func testExternalUltraLiteAnimatesClamshellExternalsAtUltraLite() {
        let screens = [ScreenSpec(id: 1, isBuiltin: false), ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false,
                                      multi: nil, edr: false, externalUltraLite: true)
        XCTAssertEqual(animatedIDs(plan).sorted(), [1, 2], "externals animate under the opt-in flag")
        XCTAssertTrue(plan.allSatisfy { $0.tier == .ultraLite && $0.isSecondary },
                      "clamshell externals are ultra-lite secondaries")
    }

    func testExternalUltraLiteKeepsBuiltInFull() {
        let screens = [ScreenSpec(id: 9, isBuiltin: true),
                       ScreenSpec(id: 1, isBuiltin: false),
                       ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false,
                                      multi: nil, edr: false, externalUltraLite: true)
        let builtIn = plan.first { $0.id == 9 }
        XCTAssertEqual(builtIn?.tier, .full)
        XCTAssertEqual(builtIn?.isSecondary, false)
        XCTAssertTrue(plan.filter { $0.id != 9 }.allSatisfy { $0.tier == .ultraLite && $0.isSecondary })
    }

    func testExternalUltraLiteDefaultOffUnchanged() {
        let screens = [ScreenSpec(id: 1, isBuiltin: false), ScreenSpec(id: 2, isBuiltin: false)]
        let plan = DisplayPlan.decide(screens: screens, allDisplays: false, singleDisplay: false,
                                      multi: nil, edr: false)   // flag defaults to false
        XCTAssertEqual(animatedIDs(plan), [], "without the flag, clamshell still animates nothing")
    }

    // MARK: drawable clamp (External Ultra-Lite present-bandwidth cut)

    func testClampScaledHiDPIToTarget() {
        let (w, h) = DisplayPlan.clampDrawable(width: 6720, height: 3780, maxEdge: 1920)
        XCTAssertEqual(w, 1920); XCTAssertEqual(h, 1080)   // 16:9 preserved
    }

    func testClampNative4KToTarget() {
        let (w, h) = DisplayPlan.clampDrawable(width: 3840, height: 2160, maxEdge: 1920)
        XCTAssertEqual(w, 1920); XCTAssertEqual(h, 1080)
    }

    func testClampNoOpWhenAlreadySmall() {
        let (w, h) = DisplayPlan.clampDrawable(width: 1600, height: 900, maxEdge: 1920)
        XCTAssertEqual(w, 1600); XCTAssertEqual(h, 900)
    }
}

final class ExternalUltraLiteAuthorizationTests: XCTestCase {
    func testDefaultRemainsFailClosed() {
        XCTAssertFalse(ExternalUltraLiteAuthorization.enabled(
            environmentOptIn: false,
            persistedAppOptIn: false
        ))
    }

    func testPersistedAppPreferenceAuthorizesUltraLite() {
        XCTAssertTrue(ExternalUltraLiteAuthorization.enabled(
            environmentOptIn: false,
            persistedAppOptIn: true
        ))
    }

    func testEnvironmentHookRemainsAnIndependentAuthorization() {
        XCTAssertTrue(ExternalUltraLiteAuthorization.enabled(
            environmentOptIn: true,
            persistedAppOptIn: false
        ))
    }
}
