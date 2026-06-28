# DSN18 contrast ratio table (AX5-equivalent acceptance note)

The per-pair WCAG 2.1 contrast ratios for the `MPColors` text tokens, computed from the actual token hexes resolved under each appearance. This is the standing acceptance reference for the "contrast floor met" line on UI tasks (below). The numbers are generated and pinned by `ContrastFloorTests` (`daemon/Tests/MeetingPipeTests/ContrastFloorTests.swift`); the `design-tokens` CI job additionally bans bare native `.secondary`/`.tertiary`/`.quaternary` as a text foreground, so new sites must use these tokens. Pairs with UX14 (which fixed the failing pairings) and DOC6.

Floors: 4.5:1 for body text, 3:1 for large/UI text and icon-paired status tones. Surfaces: `bg` (paper `#FBFAF7` / dark `#1A1B1E`), `bgRaised` (white card / dark `#25272B`), `bgSunk` (paperSunk `#F4F2EC` / dark `#131417`).

## Body text tokens (floor 4.5)

| Token | light bg | light raised | light sunk | dark bg | dark raised | dark sunk |
|---|---|---|---|---|---|---|
| `fg` | 17.35 | 18.11 | 16.18 | 15.24 | 13.24 | 16.30 |
| `fgMuted` | 7.89 | 8.23 | 7.35 | 9.11 | 7.91 | 9.74 |
| `fgSubtle` | 4.50 | 4.70 | 4.20* | 5.36 | 4.66 | 5.73 |

`*` `fgSubtle` on the light `bgSunk` well is 4.20 (clears the 3:1 UI floor, not 4.5). The well is shallow; UX14 keeps real sunk-well text on `fgMuted` (the search match-count badge precedent). `fgSubtle` is the canvas subtle tier, not a sunk-well text tier.

## Accent / semantic text tokens

Inline status tones, always icon-paired (PRODUCT: semantic state is never color-only). Floor 4.5 in light (UX14 tuned the deep `700` step to clear it, the original "ugly white theme" complaint); 3:1 in dark, where the appearance-aware accent resolves to the brighter `600` step that UX14 left as the icon-paired status tone.

| Token | light bg | light raised | dark bg | dark raised |
|---|---|---|---|---|
| `signalAccent` (700 light / 600 dark) | 5.78 | 6.03 | 4.18 | 3.63 |
| `successAccent` (700 / 600) | 5.81 | 6.06 | 4.18 | 3.63 |
| `warningAccent` (700 / 600) | 5.68 | 5.93 | 4.38 | 3.81 |
| `danger600` (fixed) | 5.23 | 5.46 | 3.16 | 2.74** |

`**` `danger600` on a raised card in dark is 2.74, below even the 3:1 UI floor. It is the single sub-3:1 pair and is not asserted by the gate.

## White button label on deep fills (floor 4.5)

The light-mode button fills that carry a white label (UX14 darkened them off the brighter `600` steps, which fail white-on-fill: white-on-`signal600` 4.12, white-on-`pulse600` 3.91).

| Fill | ratio |
|---|---|
| `signal700` | 6.03 |
| `pulse700` | 5.59 |
| `success700` | 6.06 |
| `warning700` | 5.93 |

## Known gap (owner-owed, out of DSN18 scope)

DSN18 measures and guards; it changes no token value. The measurement surfaced that the **dark-mode accent text tokens clear only the 3:1 UI floor, not the 4.5 body-text floor** (3.63 to 4.38), and **`danger600` on a raised card in dark is 2.74** (sub-3:1). UX14 deliberately deferred the dark retune ("verify-only, do not retune"). A follow-up dark-accent pass (the UX14-style sign-off on darkened dark-mode accent tones, or restricting accent text to the base canvas in dark) would close this. Tracked as a DSN18 finding for a future legibility task.

## Standing acceptance line for UI tasks

> **Contrast floor met.** Every new text-on-surface pairing clears 4.5:1 (3:1 for large/UI and icon-paired status text) in both appearances, using the `MPColors` text tokens (`fg` / `fgMuted` / `fgSubtle` / the accent tokens), not bare native `.secondary`/`.tertiary`. `ContrastFloorTests` pins the floor; the `design-tokens` CI guard bans bare native-semantic text foregrounds.
