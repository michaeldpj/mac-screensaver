# Generate high-quality sprite source art

This is the operational workflow for the current native renderer. It is generator-agnostic: use an
image generator capable of high-resolution photoreal art, then enforce the repository's deterministic
1024px runtime contract locally.

## 1. Plan one JSON-declared set

Choose the exact `spriteSet` name and variant count. Generate one object and one species per image;
create separate runs for distinct species or morphologies. The season JSON's nested
`spriteSet`/`spriteCount` fields are the source of truth, including hero and multi-species declarations.

Use [../reference/sprite-prompts.md](../reference/sprite-prompts.md) as the prompt template. Prioritize:

- photoreal macro detail and a crisp complete silhouette;
- visible veins, crystal facets, fibers, translucency, or other material-specific structure;
- bright, rich, natural color designed for a pure-black background;
- soft even lighting with no cast shadow, halo, label, or scene;
- genuinely different shapes and viewing angles across separately generated images.

## 2. Prepare straight-alpha numbered sources

Export or clean the result to a straight-alpha PNG. If generation uses a uniform key background,
remove it at source resolution and inspect fine edges for colored spill or erased translucent detail.
Do not leave a checkerboard baked into RGB. Do not premultiply the PNG.

Save the final source files as an exact contiguous sequence:

```text
tools/raw/<set>/1.png
tools/raw/<set>/2.png
...
tools/raw/<set>/N.png
```

No other file type or numbering is accepted by the publisher.

## 3. Atomically build the runtime set

```sh
./tools/process-sprites.sh <set>
```

The script trims transparent margins, fits the object inside 880×880, centers it on a transparent
1024×1024 canvas, and writes 8-bit straight-alpha sRGBA. It stages the whole numbered set before an
atomic directory swap. If any input or conversion fails, the prior runtime directory remains intact.

## 4. Make JSON match, then validate everything

Update the applicable season JSON declaration to the exact published count, then run:

```sh
python3 tools/validate_sprites.py --json
```

Treat the JSON result as the acceptance gate. It validates every referenced set, not just the one edited,
and fails for missing or extra numbered files, wrong dimensions/format, poor padding or centering, opaque
corners, aliased edges, or alpha that vanishes too early under minification.

## 5. Render representative sizes

Build once, then pass the shared sprites base directory—not a set-specific folder—and keep the deprecated
numeric argument at `0`; JSON counts are authoritative:

```sh
xcodebuild -project Seasons.xcodeproj -target SeasonsShot -configuration Debug build
build/Debug/seasons-shot Resources/seasons/autumn.json Resources/sprites 0 /tmp/autumn.png 1280 800 180
/usr/bin/time -l build/Debug/seasons-shot Resources/seasons/autumn.json Resources/sprites 0 /tmp/autumn-2880.png 2880 1620 300
```

Inspect both normal and small particles for silhouette stability, detail, edge halos, and vivid-but-natural
color. The renderer loads strict 1024px arrays, creates alpha-weighted linear-light / RMS-alpha mips,
bakes maps at each mip, and samples with 16× anisotropy. Do not create a 2048px runtime set.
