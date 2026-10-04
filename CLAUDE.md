# Seasons

Native macOS ambient screensaver: a Metal-rendered seasonal particle effect (snow, petals, fireflies, leaves) ported from mdpj.me, shipped as a `.saver` bundle plus a Seasons Preview app.

## Commands

- `xcodegen generate` — regenerate `Seasons.xcodeproj` from `project.yml` (source of truth)
- `xcodebuild -project Seasons.xcodeproj -scheme Seasons -destination 'platform=macOS' build test` — build all targets and run `SeasonsTests`

## Ship

verify: xcodegen generate && xcodebuild -project Seasons.xcodeproj -scheme Seasons -destination 'platform=macOS' build test
push: yes
deploy: none
