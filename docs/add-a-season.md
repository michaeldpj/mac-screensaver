# Adding a season or style

A same-mechanics season (things that fall/drift and tumble) is **config + sprites only — no engine or
shader code**. The steps:

1. **Generate sprites.** Follow [sprite-recipe.md](sprite-recipe.md). Use single-object, single-species
   prompts (multi-species "variety" prompts produce whole flowers). Save raw PNGs to
   `tools/raw/<set>/`.

2. **Post-process:**
   ```sh
   ./tools/process-sprites.sh <set>         # atomically publish the strict 1024px runtime set
   python3 tools/validate_sprites.py --json # validate all JSON-declared sets and exact counts
   ```
   Output lands in `Resources/sprites/<set>/`. Make the JSON `spriteCount` match before accepting the
   validator result. (Skip sprite processing for a pure-glow style.)

3. **Author `Resources/seasons/<name>.json`** using [config-reference.md](config-reference.md). Set
   `spriteSet`/`spriteCount` to your folder, or `glyphType: "glow"` with `spriteSet: null` for a
   firefly-style light.

4. **Add the mood** in [Sources/Renderer.swift](../Sources/Renderer.swift): a `case "<name>"` in
   `atmosphere(for:)` (backdrop `skyTop`/`skyBottom`/`glowColor`/`glowCenter`/`glowRadius`) and, if
   needed, mesh curvature in [Sources/Mesh.swift](../Sources/Mesh.swift) `curl(for:)`
   (`cup`/`fold`/`curl`/`grid`). Without a case, it uses the default (summer-dusk) mood.

5. **Wire selection** only if it's a *new season id* (not one of the four): add a `case` to
   `SeasonID` ([Sources/Season.swift](../Sources/Season.swift)) and an entry to the config-sheet
   `options` array ([Sources/ConfigSheet.swift](../Sources/ConfigSheet.swift)). A non-seasonal *style*
   that replaces an existing season needs neither.

6. **Preview it** without a full build via the harness:
   ```sh
   xcodebuild -project Seasons.xcodeproj -target SeasonsShot -configuration Debug build
   build/Debug/seasons-shot Resources/seasons/<name>.json Resources/sprites 0 /tmp/out.png 1280 800 150
   ```
   Pass the shared sprites directory, not a set-specific subdirectory. The retained `0` is a
   deprecated compatibility argument; sprite counts come from the JSON. The command fails when
   any image-backed species has a missing or undecodable declared PNG.
   Then build + run the app: `./install.sh` (saver) or the SeasonsPreview target.

Month → season mapping (for `auto`) lives in `SeasonCatalog.seasonByMonth`; change it there if a new
season should claim months.
