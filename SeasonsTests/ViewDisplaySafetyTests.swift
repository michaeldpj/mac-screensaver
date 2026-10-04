import XCTest

/// Locks the per-view, fail-closed safety check that runs independently of the process-wide
/// display plan. ScreenSaverEngine can construct a view without the app's tool configuration,
/// so an installed saver must prove that its current screen is safe before it animates.
final class ViewDisplaySafetyTests: XCTestCase {
    func testOnlyToolPlannedSecondaryAuthorizesAnExternalDisplay() {
        XCTAssertTrue(ViewDisplaySafety.toolAuthorizesExternal(
            isSecondary: true,
            isMultiDisplay: true
        ))
        XCTAssertFalse(ViewDisplaySafety.toolAuthorizesExternal(
            isSecondary: false,
            isMultiDisplay: true
        ), "a multi-display primary that migrates externally must fail closed")
    }

    func testPreviewMayAnimateWithoutAnAttachedScreen() {
        XCTAssertTrue(ViewDisplaySafety.shouldAnimate(
            isPreview: true,
            screenIsBuiltIn: nil,
            toolAuthorized: false,
            allDisplaysOverride: false,
            singleDisplayHint: false
        ))
    }

    func testMissingScreenFailsClosedOutsidePreview() {
        XCTAssertFalse(ViewDisplaySafety.shouldAnimate(
            isPreview: false,
            screenIsBuiltIn: nil,
            toolAuthorized: false,
            allDisplaysOverride: false,
            singleDisplayHint: false
        ))
    }

    func testBuiltInScreenMayAnimateByDefault() {
        XCTAssertTrue(ViewDisplaySafety.shouldAnimate(
            isPreview: false,
            screenIsBuiltIn: true,
            toolAuthorized: false,
            allDisplaysOverride: false,
            singleDisplayHint: false
        ))
    }

    func testExternalScreenFailsClosedByDefault() {
        XCTAssertFalse(ViewDisplaySafety.shouldAnimate(
            isPreview: false,
            screenIsBuiltIn: false,
            toolAuthorized: false,
            allDisplaysOverride: false,
            singleDisplayHint: false
        ))
    }

    func testToolAuthorizedExternalScreenMayAnimate() {
        XCTAssertTrue(ViewDisplaySafety.shouldAnimate(
            isPreview: false,
            screenIsBuiltIn: false,
            toolAuthorized: true,
            allDisplaysOverride: false,
            singleDisplayHint: false
        ))
    }

    func testAllDisplaysOverrideMayAnimateExternalScreen() {
        XCTAssertTrue(ViewDisplaySafety.shouldAnimate(
            isPreview: false,
            screenIsBuiltIn: false,
            toolAuthorized: false,
            allDisplaysOverride: true,
            singleDisplayHint: false
        ))
    }

    func testSingleDisplayHintDoesNotBypassExternalSafety() {
        XCTAssertFalse(ViewDisplaySafety.shouldAnimate(
            isPreview: false,
            screenIsBuiltIn: false,
            toolAuthorized: false,
            allDisplaysOverride: false,
            singleDisplayHint: true
        ))
    }
}
