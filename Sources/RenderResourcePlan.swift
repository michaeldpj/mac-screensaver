import Foundation

/// Retained textures used by the renderer's post-processing graph.
enum RenderResource: Hashable {
    case scene
    case coc
    case graded
    case upscaled
    case bloomHalfA
    case bloomHalfB
    case bloomQuarterA
    case bloomQuarterB
    case bloomEighthA
    case bloomEighthB
    case sceneBlurA
    case sceneBlurB
}

/// Fullscreen/render passes encoded for one frame.
enum RenderPassKind: Hashable {
    case scene
    case bloomBright
    case bloomHalfHorizontal
    case bloomHalfVertical
    case bloomQuarterHorizontal
    case bloomQuarterVertical
    case bloomEighthHorizontal
    case bloomEighthVertical
    case dofHorizontal
    case dofVertical
    case composite
    case compositeNoEffects
    case upscale
    case present
}

/// Selects the final grading implementation. The no-effects path samples only the scene color;
/// the effects path retains the existing six-texture composite contract.
enum CompositePath: Equatable {
    case effects
    case noEffects
}

/// Texture argument slots required by the composite shader.
enum CompositeTextureSlot: CaseIterable, Hashable {
    case scene
    case bloomHalf
    case sceneBlur
    case coc
    case bloomQuarter
    case bloomEighth
}

/// A Metal-independent description of the resources and work needed by a renderer tier.
/// Disabled effects bind retained scene/bloom textures into otherwise-unused shader slots, so
/// Metal sees a complete argument table without requiring hidden placeholder allocations.
struct RenderResourcePlan {
    let resources: Set<RenderResource>
    let passes: Set<RenderPassKind>
    let compositePath: CompositePath
    let compositeBindings: [CompositeTextureSlot: RenderResource]

    init(bloom: Bool, dof: Bool, litePost: Bool, requiresUpscale: Bool) {
        let pyramidBloom = bloom && !litePost
        let depthOfField = dof && !litePost
        let noEffects = !bloom && !depthOfField

        var resources: Set<RenderResource> = [.scene, .coc]
        var passes: Set<RenderPassKind> = [.scene, noEffects ? .compositeNoEffects : .composite]

        if bloom {
            resources.formUnion([.bloomHalfA, .bloomHalfB])
            passes.formUnion([.bloomBright, .bloomHalfHorizontal, .bloomHalfVertical])
        }
        if pyramidBloom {
            resources.formUnion([
                .bloomQuarterA, .bloomQuarterB,
                .bloomEighthA, .bloomEighthB,
            ])
            passes.formUnion([
                .bloomQuarterHorizontal, .bloomQuarterVertical,
                .bloomEighthHorizontal, .bloomEighthVertical,
            ])
        }
        if depthOfField {
            resources.formUnion([.sceneBlurA, .sceneBlurB])
            passes.formUnion([.dofHorizontal, .dofVertical])
        }
        if requiresUpscale {
            resources.formUnion([.graded, .upscaled])
            passes.formUnion([.upscale, .present])
        }

        let halfBloom: RenderResource = bloom ? .bloomHalfA : .scene
        self.resources = resources
        self.passes = passes
        compositePath = noEffects ? .noEffects : .effects
        compositeBindings = [
            .scene: .scene,
            .bloomHalf: halfBloom,
            .sceneBlur: depthOfField ? .sceneBlurB : .scene,
            .coc: .coc,
            .bloomQuarter: pyramidBloom ? .bloomQuarterA : halfBloom,
            .bloomEighth: pyramidBloom ? .bloomEighthA : halfBloom,
        ]
    }
}
