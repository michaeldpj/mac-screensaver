import XCTest

/// Locks the approved three-external-display HQ envelope. These assertions intentionally exercise
/// the production tier rather than duplicating its constants in a test helper, so a future quality
/// change cannot silently increase presentation work or re-enable expensive effects.
final class UltraLiteQualityPolicyTests: XCTestCase {
    func testUltraLiteUsesApprovedHQBudget() {
        let tier = QualityTier.ultraLite

        XCTAssertEqual(tier.fps, 30)
        XCTAssertEqual(tier.countScale, 0.15, accuracy: 0.000_001)
        XCTAssertEqual(tier.forcedScale, 1.0,
                       "HQ Ultra-Lite must render at the full 2880 drawable scale")
        XCTAssertEqual(tier.presentMaxEdge, 2880,
                       "Ultra-Lite must never exceed the approved 2880-pixel presentation edge")
    }

    func testUltraLiteKeepsExpensiveEffectsDisabled() {
        let tier = QualityTier.ultraLite

        XCTAssertFalse(tier.bloom)
        XCTAssertFalse(tier.dof)
        XCTAssertTrue(tier.litePost)
    }

    func testUltraLiteKeepsEightBitSDRPresentationEvenWhenEDRIsRequested() {
        let tier = QualityTier.ultraLite
        XCTAssertTrue(tier.present8Bit)

        for edrRequested in [false, true] {
            let presentation = PresentationColorPolicy.plan(ultraLite: tier.present8Bit,
                                                            edrRequested: edrRequested)
            XCTAssertEqual(presentation.pixelEncoding, .bgra8UnormSRGB)
            XCTAssertEqual(presentation.colorSpace, .displayP3)
            XCTAssertFalse(presentation.extendedDynamicRange)
        }
    }

    func testApprovedClampPreservesLandscapeAspectRatio() {
        let size = DisplayPlan.clampDrawable(width: 6720, height: 3780, maxEdge: 2880)

        XCTAssertEqual(size.width, 2880)
        XCTAssertEqual(size.height, 1620)
    }

    func testApprovedClampPreservesPortraitAspectRatio() {
        let size = DisplayPlan.clampDrawable(width: 2160, height: 3840, maxEdge: 2880)

        XCTAssertEqual(size.width, 1620)
        XCTAssertEqual(size.height, 2880)
    }

    func testApprovedClampDoesNotUpscaleSmallerDrawable() {
        let size = DisplayPlan.clampDrawable(width: 2560, height: 1440, maxEdge: 2880)

        XCTAssertEqual(size.width, 2560)
        XCTAssertEqual(size.height, 1440)
    }
}
