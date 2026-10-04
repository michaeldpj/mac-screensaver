# Reference: the web baseline

These files are the design baseline for the screensaver, copied from mdpj.me. Read them before
building. They define the look and behavior to port to native Metal — see `../PROMPT.md`.

| File | What it is |
|---|---|
| `seasonal.js` | The full canvas particle engine (vanilla JS IIFE, ~314 lines). `CONFIGS` = per-season schema. `spawn()` + `frame()` = physics. `edgeFade()` = top/bottom fade. The source of truth for behavior. |
| `atmosphere.css` | Background: per-season radial gradient tint + fractal-noise grain over a dark field. Palette in OKLCH — map to Display P3 natively. |
| `images/seasonal/snow/*.webp` | 4 photoreal snowflake sprites (transparent, 96px) |
| `images/seasonal/petals/*.webp` | 6 cherry-blossom petal sprites |
| `images/seasonal/leaves/*.webp` | 5 autumn-leaf sprites |

Fireflies have no sprite — they are procedural glow blobs (`glyphType: 'glow'`, `shadowBlur` in the
web engine → real bloom natively).

Originals generated with Ideogram v3, trimmed, re-encoded to WebP. New sprite sets should be
generated via the fal.ai MCP to match — see the asset pipeline section in `../PROMPT.md`.
