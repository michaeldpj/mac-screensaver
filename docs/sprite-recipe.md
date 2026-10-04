# Sprite generation recipe

How to author high-quality image sprites for Seasons. The operational runbook is
[tools/generate-sprites.md](../tools/generate-sprites.md); reusable prompt templates are in
[reference/sprite-prompts.md](../reference/sprite-prompts.md).

## Source-art standard

Generate one isolated object per image at the highest useful source quality. Ask for photoreal macro
detail, a sharply resolved silhouette, material-specific texture (veins, crystal facets, translucency),
rich natural color, and soft even lighting. Keep the whole object in frame. Generate each species or
morphology separately; a prompt requesting mixed species commonly produces clusters or hybrid objects.

The source may arrive with transparency or on a clean, uniform key color that can be removed without
damaging the silhouette. Before it enters `tools/raw/<set>/`, it must be a straight-alpha PNG with no
shadow, halo, text, background, or premultiplied matte. Name the complete set contiguously
`1.png..N.png`. Runtime quality comes from clean source detail and filtering, not a larger runtime canvas.

## Normalize and publish atomically

```sh
./tools/process-sprites.sh <set>
python3 tools/validate_sprites.py --json
```

`process-sprites.sh` trims each object, fits it within 880×880, centers it on a rotation-safe 1024×1024
canvas, and writes straight-alpha 8-bit sRGBA. It builds the complete result in a staging directory and
replaces `Resources/sprites/<set>/` only after every numbered input succeeds. A failed conversion leaves
the previous runtime set intact; stale extra outputs cannot survive a successful replacement.

The validator discovers every nested `spriteSet`/`spriteCount` from all season JSON files. Those JSON
declarations are authoritative. It requires exactly `1.png..N.png`, validates 1024×1024 RGBA format,
transparent padding and corners, centering, antialiased alpha, and silhouette survival at small mips.
Update the relevant JSON count before treating validation as complete.

## Runtime quality path

`SpriteLoader` accepts the declared set only as a whole and rejects any missing, undecodable, wrong-format,
or non-1024 image. It creates alpha-weighted linear-light RGB mips with RMS alpha, derives the normal /
thinness / AO maps independently at every mip, and samples albedo and maps with trilinear filtering and
16× anisotropy. This preserves thin details while avoiding transparent-edge color bleed.

The runtime contract is exactly 1024×1024. Do not upscale or advertise 2048px runtime sprites: that would
increase memory without fixing weak source art or filtering.

## Prompt formula

1. “A single isolated [object]” with the exact species or morphology.
2. “Photoreal macro, extremely fine natural detail” plus material cues.
3. Bright, rich, physically plausible color that reads against pure black.
4. Fully visible, centered, no cast shadow; vary top-down, three-quarter, and edge-on source images.
5. A hard exclusion list: multiple objects, clusters, branches/stems unless intrinsic, background,
   surface, frame, text, watermark, glow, clipping, blur, halo, and artificial neon color.

Fireflies and other `glyphType: "glow"` effects remain procedural and need no sprite set.
