# Photoreal sprite prompt templates

These templates describe the current source-art direction. They are not tied to a vendor or model.
Generate each image separately so it contains exactly one complete object; use separate runs for separate
species. Request transparent output when reliable, or use a uniform removable key background and clean it
to straight alpha before placing it in `tools/raw/<set>/`.

## General template

```text
A single isolated [exact object/species], fully visible and centered, photoreal macro photography,
extremely fine [vein/facet/fiber/crystal] detail, physically plausible translucent material and crisp
silhouette, rich luminous natural [color palette] designed to stand out against pure black, soft even
studio lighting, [top-down / three-quarter / edge-on] view, no cast shadow, transparent background.

Exclude: multiple objects, group, cluster, pile, mixed species, whole plant or branch unless intrinsic,
background, scenery, surface, frame, text, watermark, clipping, blur, haze, halo, glow, neon color,
checkerboard, baked shadow.
```

Vary morphology and viewing angle between calls; do not ask one call for a sheet, collection, or variety
grid. Preserve thin structures and translucent boundaries at full source resolution.

## Snow crystals

```text
A single isolated six-fold snow crystal, fully visible, photoreal extreme macro, razor-fine dendritic
branches and pristine ice facets, luminous icy white and pale blue with restrained natural prismatic
edge color, high microcontrast, centered top-down, soft even lighting, no shadow, transparent background.
Exclude multiple flakes, cluster, snowfall, ground, scene, blur, clipping, halo, text, watermark, neon.
```

## Cherry-blossom petals and blossoms

```text
A single isolated cherry-blossom petal, fully visible, photoreal macro, delicate translucent tissue,
fine vein detail and natural curl, bright blush pink to near-white gradient with a rich rose base,
crisp clean edge, centered three-quarter view, soft even lighting, no shadow, transparent background.
Exclude multiple petals, whole flower, branch, stem, leaves, cluster, scene, blur, clipping, halo, text.
```

For a hero blossom, replace “petal” with “complete five-petal cherry blossom” and explicitly keep it to
one flower with no branch, stem, leaves, buds, or detached petals.

## Autumn leaves

Use one exact species per run—maple, oak, birch, or samara—and vary only that species' morphology:

```text
A single isolated [maple/oak/birch] leaf, fully visible from stem tip to leaf tip, photoreal macro,
crisp serrated silhouette, intricate branching veins, slight natural curl and translucent thin margins,
vivid natural crimson, orange, amber and gold variation, centered [top-down/three-quarter], soft even
lighting, no cast shadow, transparent background.
Exclude multiple leaves, mixed species, branch, pile, scene, clipping, blur, halo, glow, text, watermark.
```

For samaras, request one intact paired winged seed with papery translucent wings and the same isolation
and exclusion rules.

## Fireflies

No sprite is generated. Fireflies use the renderer's procedural `glyphType: "glow"` path.

## Runtime contract

Prompts create source art, not runtime dimensions. Clean accepted images to straight alpha, number them
contiguously, publish with `./tools/process-sprites.sh <set>`, and validate all JSON-declared sets with
`python3 tools/validate_sprites.py --json`. Runtime assets remain exactly 1024×1024.
