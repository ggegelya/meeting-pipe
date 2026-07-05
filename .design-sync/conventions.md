# Meeting Pipe design system — how to build with it

Meeting Pipe is a local-first macOS menu-bar app that records meetings and publishes summaries. The register is quiet, deliberate, and privacy-forward: calm copy, no exclamation marks, no hype. Everything here renders as real React from `window.MeetingPipe`.

## Styling idiom: CSS custom properties, not utility classes

There is **no class-name system** (no Tailwind, no CSS modules the agent writes). You style with the design system's `--mp-*` CSS custom properties, applied through inline `style` or your own CSS. The tokens are defined globally in the bound stylesheet and are always in scope. Never hardcode a hex color or a raw px font size when a token exists — the tokens are the contract, and a token swap is how the whole app re-skins.

Use the real token names (all defined in the bound `_ds/<folder>/styles.css` closure — read it before styling):

| Role | Tokens |
|---|---|
| Type families | `--mp-font-sans` (UI text; SF Pro / system), `--mp-font-display` (Inter Tight, for headings), `--mp-font-mono` (JetBrains Mono, for filenames, keys, timers) |
| Type sizes | `--mp-text-xs` `--mp-text-sm` `--mp-text-base` `--mp-text-md` `--mp-text-lg` `--mp-text-xl` … up to `--mp-text-4xl` |
| Foreground ink | `--mp-fg` (primary), `--mp-fg-muted`, `--mp-fg-subtle`, `--mp-fg-faint`, `--mp-fg-on-signal` (text on the accent) |
| Surfaces | `--mp-bg` (window), `--mp-bg-raised` (cards), `--mp-bg-sunk` (wells, tracks) |
| Borders | `--mp-border`, `--mp-border-faint`, `--mp-border-strong` |
| Accent (the ONE brand color) | `--mp-signal-600` (primary action, selection), scale `--mp-signal-100…700` |
| Status | `--mp-success-600` (granted/ready), `--mp-warning-600` (needs attention), `--mp-danger-600` (failed), `--mp-pulse-500/600` (live recording) |
| HUD (translucent overlays) | `--mp-hud-bg`, `--mp-hud-stroke`, `--mp-hud-shadow` |
| Radius / space | `--mp-radius-xs…xl`, `--mp-radius-full`; `--mp-space-1…16` |

## Wrapping and setup

There is **no provider to wrap**. Components read tokens straight from the global stylesheet, so a component renders correctly the moment the DS styles are present. The one setup rule: on a screen's root, set the base type and color so children inherit them, e.g. `style={{ fontFamily: "var(--mp-font-sans)", color: "var(--mp-fg)", background: "var(--mp-bg)" }}`.

Two composition facts that are easy to miss:

- **HUD surfaces are translucent.** `MeetingPrompt`, `MenuBarDropdown`, and `Notification` use `--mp-hud-bg` (a frosted, semi-transparent fill) and are designed to float over the desktop. Put them on a **dark or busy backdrop**, never plain white, or they wash out. The kit's own idiom is a dark desk gradient behind them.
- **`Icon` is the shared glyph set.** `name` is a fixed union of ~47 Lucide-style glyphs (see `Icon`'s `.d.ts`); it draws with `currentColor`, so set the parent's CSS `color` to tint it. An unknown name renders nothing.

## Where the truth lives

- The token stylesheet (the `_ds/<folder>/styles.css` closure, which imports the fonts and the compiled component CSS) — read it before inventing any value.
- Each component's `<Name>.d.ts` is the exact prop contract; each `<Name>.prompt.md` has a usage note and a composition example. Read those two before using a component.

## The component vocabulary

Compose from the parts rather than restyling whole windows. Grouped as **surfaces** (`MeetingPrompt`, `MenuBarDropdown`, `Notification`, `OnboardingPermissions`, `PreferencesWindow`, `SummaryLibrary` — whole app screens), **controls** (`Icon`, `PromptButton`, `MenuItem`, `MenuSep`, `PWToggle`, `PWField`, `PWSegmented`, `PWSlider`, `PWStatusPill`, `PWTag`, `SLSegmented`, `SLStatusPill`), and **structure** (`PWGroup`, `PWRow`, `PermRow`, `SLSection`, `SLBullets`, `SLActionItem`, `SLEmpty`). Settings screens are built from `PWGroup` wrapping `PWRow`s; meeting detail from `SLSection` wrapping `SLBullets` / `SLActionItem`; status is always one of the `SLStatusPill` states, never an invented badge.

## One idiomatic snippet

```jsx
import { PWGroup, PWRow, PWToggle, PWSegmented, PWField } from 'meeting-pipe-design';

function RecordingSettings() {
  return (
    <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', background: 'var(--mp-bg)', padding: 16 }}>
      <PWGroup label="Recording" footer="Recordings land in ~/Recordings as 48 kHz wav.">
        <PWRow label="Launch at login" sublabel="Start the menu-bar daemon when you sign in." first>
          <PWToggle on />
        </PWRow>
        <PWRow label="File format">
          <PWSegmented options={['wav', 'flac']} selected={0} />
        </PWRow>
        <PWRow label="Recordings folder">
          <PWField value="~/Recordings" mono width={180} />
        </PWRow>
      </PWGroup>
    </div>
  );
}
```
