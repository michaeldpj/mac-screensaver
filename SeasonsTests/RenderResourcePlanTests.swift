import XCTest

/// Locks the post-processing allocation/encoding policy independently of Metal. The renderer
/// should be able to derive both its retained textures and its fullscreen passes from this plan,
/// rather than allocating and encoding the full-quality chain when features are disabled.
final class RenderResourcePlanTests: XCTestCase {
    func testFullQualityUpscaleRetainsBloomDepthOfFieldAndScalerChain() {
        let plan = RenderResourcePlan(
            bloom: true,
            dof: true,
            litePost: false,
            requiresUpscale: true
        )

        XCTAssertEqual(plan.resources, [
            .scene, .coc, .graded, .upscaled,
            .bloomHalfA, .bloomHalfB,
            .bloomQuarterA, .bloomQuarterB,
            .bloomEighthA, .bloomEighthB,
            .sceneBlurA, .sceneBlurB,
        ])
        XCTAssertEqual(plan.passes, [
            .scene,
            .bloomBright, .bloomHalfHorizontal, .bloomHalfVertical,
            .bloomQuarterHorizontal, .bloomQuarterVertical,
            .bloomEighthHorizontal, .bloomEighthVertical,
            .dofHorizontal, .dofVertical,
            .composite, .upscale, .present,
        ])
        XCTAssertEqual(plan.compositePath, .effects)
    }

    func testUltraLiteWithoutBloomOrDepthOfFieldOmitsTheirResourcesAndPasses() {
        let plan = RenderResourcePlan(
            bloom: false,
            dof: false,
            litePost: true,
            requiresUpscale: false
        )

        XCTAssertEqual(plan.resources, [.scene, .coc])
        XCTAssertEqual(plan.passes, [.scene, .compositeNoEffects])
        XCTAssertEqual(plan.compositePath, .noEffects)
        XCTAssertFalse(plan.passes.contains(.composite),
                       "the no-effects tier must not encode the six-texture composite path")
    }

    func testLiteBloomRetainsOnlyTheHalfResolutionPair() {
        let plan = RenderResourcePlan(
            bloom: true,
            dof: false,
            litePost: true,
            requiresUpscale: false
        )

        XCTAssertEqual(plan.resources, [.scene, .coc, .bloomHalfA, .bloomHalfB])
        XCTAssertEqual(plan.passes, [
            .scene, .bloomBright, .bloomHalfHorizontal, .bloomHalfVertical, .composite,
        ])
        XCTAssertEqual(plan.compositePath, .effects)
    }

    func testNativeScaleAvoidsSeparateGradedAndUpscaledTargets() {
        let plan = RenderResourcePlan(
            bloom: true,
            dof: true,
            litePost: false,
            requiresUpscale: false
        )

        XCTAssertFalse(plan.resources.contains(.graded))
        XCTAssertFalse(plan.resources.contains(.upscaled))
        XCTAssertFalse(plan.passes.contains(.upscale))
        XCTAssertFalse(plan.passes.contains(.present))
        XCTAssertTrue(plan.passes.contains(.composite),
                      "native-scale composite should write directly to the drawable")
    }

    func testDisabledEffectsStillPopulateEveryCompositeTextureSlot() {
        let plan = RenderResourcePlan(
            bloom: false,
            dof: false,
            litePost: true,
            requiresUpscale: false
        )

        XCTAssertEqual(Set(plan.compositeBindings.keys), Set(CompositeTextureSlot.allCases))
        XCTAssertTrue(plan.compositeBindings.values.allSatisfy(plan.resources.contains),
                      "fallback bindings must reuse retained textures, not require hidden allocations")
        XCTAssertEqual(plan.compositeBindings[.sceneBlur], .scene)
        XCTAssertEqual(plan.compositeBindings[.bloomHalf], .scene)
        XCTAssertEqual(plan.compositeBindings[.bloomQuarter], .scene)
        XCTAssertEqual(plan.compositeBindings[.bloomEighth], .scene)
    }

    func testLitePostSuppressedDepthOfFieldAlsoUsesNoEffectsComposite() {
        let plan = RenderResourcePlan(
            bloom: false,
            dof: true,
            litePost: true,
            requiresUpscale: false
        )

        XCTAssertEqual(plan.resources, [.scene, .coc],
                       "scene PSOs still require color and CoC render targets")
        XCTAssertEqual(plan.passes, [.scene, .compositeNoEffects])
        XCTAssertEqual(plan.compositePath, .noEffects)
    }
}
