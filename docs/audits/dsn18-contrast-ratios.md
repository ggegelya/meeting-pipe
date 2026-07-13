# DSN18 contrast ratio table (AX5-equivalent acceptance note)

The per-pair WCAG 2.1 contrast ratios for the `MPColors` text tokens, computed from the actual token hexes resolved under each appearance. This is the standing acceptance reference for the "contrast floor met" line on UI tasks (below). The numbers are generated and pinned by `ContrastFloorTests` (`daemon/Tests/MeetingPipeTests/ContrastFloorTests.swift`); the `design-tokens` CI job additionally bans bare native `.secondary`/`.tertiary`/`.quaternary` as a text foreground, so new sites must use these tokens. Pairs with UX14 (which fixed the failing pairings) and DOC6.

Floors: 4.5:1 for body text, 3:1 for large/UI text and icon-paired status tones. Surfaces (DSN23 "Liquid Quiet" porcelain retokening): `bg` (paper `#F5F6F8` / dark `#1B1D21`), `bgRaised` (white card / dark `#26292E`), `bgSunk` (`#ECEEF1` / dark `#15161A`).

Refreshed 2026-07-06 for the DSN23 token port (cool porcelain neutrals, deeper display teal, and `signal600` now flips bright in dark, `#36C6B8`, so it reads as lit).

## Body text tokens (floor 4.5)

| Token | light bg | light raised | light sunk | dark bg | dark raised | dark sunk |
|---|---|---|---|---|---|---|
| `fg` | 16.44 | 17.77 | 15.29 | 15.07 | 13.03 | 16.14 |
| `fgMuted` | 5.94 | 6.42 | 5.53 | 7.71 | 6.66 | 8.26 |
| `fgSubtle` | 4.91 | 5.31 | 4.57* | 5.25 | 4.54 | 5.63 |

`*` `fgSubtle` on the light `bgSunk` well is 4.57 (clears the 3:1 UI floor, not 4.5). The well is shallow; UX14 keeps real sunk-well text on `fgMuted` (the search match-count badge precedent). `fgSubtle` is the canvas subtle tier, not a sunk-well text tier.

## Accent / semantic text tokens

Inline status tones, always icon-paired (PRODUCT: semantic state is never color-only). Floor 4.5 in light (UX14 tuned the deep `700` step to clear it, the original "ugly white theme" complaint). In dark: `signalAccent` now resolves to the bright display teal (`#36C6B8`, DSN23) and clears the full 4.5 body floor; `successAccent` / `warningAccent` / `pulseAccent` / `danger600` keep the 3:1 icon-paired UI floor (the CSS brightened only the signal hue in dark, not the semantic hues). `pulseAccent` (recording / failed pill text) was added when `MPStatusPill` moved off the raw `700` steps, which were paper-only and unreadable on the dark pill.

| Token | light bg | light raised | dark bg | dark raised |
|---|---|---|---|---|
| `signalAccent` (700 light / bright 600 dark) | 5.67 | 6.13 | 7.98 | 6.90 |
| `successAccent` (700 / 600) | 5.61 | 6.06 | 4.10 | 3.54 |
| `warningAccent` (700 / 600) | 5.48 | 5.93 | 4.30 | 3.71 |
| `pulseAccent` (700 / 600) | 5.17 | 5.59 | 4.31 | 3.73 |
| `danger600` (fixed) | 5.05 | 5.46 | 3.09 | ~2.7** |

`**` `danger600` on a raised card in dark is ~2.7, below even the 3:1 UI floor. It is the single sub-3:1 pair and is not asserted by the gate.

## White / backlit label on deep fills (floor 4.5)

The deep fills that carry a legible label. The light-mode `700` button fills (UX14 darkened them off the brighter `600` steps, which fail white-on-fill: white-on-`signal600` 4.12, white-on-`pulse600` 3.91), plus the DSN20/DSN21 fill tokens: `signalFill` (white-label teal surfaces, fixed both modes) and the "Instrument" `recordFill` (white label in light, a near-black backlit `recordLabel` on the brighter fill in dark).

| Fill | ratio |
|---|---|
| `signal700` | 6.13 |
| `pulse700` | 5.59 |
| `success700` | 6.06 |
| `warning700` | 5.93 |
| `signalFill` (white, both modes) | 4.88 |
| `recordFill` + `recordLabel` (light / dark) | 4.88 / 4.88 |

## Known gap (partially closed by DSN23)

DSN18 measured and guarded; the DSN20-23 redesign then retoned the values. **DSN23 closed the signal leg**: the display teal now flips bright in dark (`signal600` `#36C6B8`), so `signalAccent` clears the full 4.5 body floor in dark (7.98 / 6.90) instead of the old ~4.18 / 3.63. The residual gap is the **semantic hues**: `successAccent` / `warningAccent` / `danger600` still clear only the 3:1 icon-paired UI floor in dark (3.09 to 4.30), and **`danger600` on a raised card in dark is ~2.7** (sub-3:1). The CSS brightened only the signal hue in dark, not the semantic hues; a follow-up would brighten the dark semantic accents (or restrict them to the base canvas in dark). Kept icon-paired meanwhile (semantic state is never colour-only). Tracked for a future legibility pass.

## Standing acceptance line for UI tasks

> **Contrast floor met.** Every new text-on-surface pairing clears 4.5:1 (3:1 for large/UI and icon-paired status text) in both appearances, using the `MPColors` text tokens (`fg` / `fgMuted` / `fgSubtle` / the accent tokens), not bare native `.secondary`/`.tertiary`. `ContrastFloorTests` pins the floor; the `design-tokens` CI guard bans bare native-semantic text foregrounds.
