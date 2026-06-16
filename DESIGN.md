---
name: meeting-pipe
description: Local-first macOS meeting recorder. Paper, ink, and one signal-teal accent for live capture.
colors:
  # Ink -- foreground ramp, warm near-black down to cool grey
  ink-900: "#14161A"
  ink-800: "#1F2227"
  ink-700: "#2C3037"
  ink-600: "#4A4F58"
  ink-500: "#6E747F"
  ink-400: "#9098A4"
  ink-300: "#B7BDC6"
  ink-200: "#D8DCE2"
  ink-100: "#ECEEF2"
  ink-50: "#F5F6F8"
  # Paper -- the canvas surfaces
  paper: "#FBFAF7"
  paper-sunk: "#F4F2EC"
  paper-raised: "#FFFFFF"
  on-signal: "#FFFFFF"
  # Signal teal -- the one accent: live capture and primary action
  signal-700: "#0A6F67"
  signal-600: "#0E8C82"
  signal-500: "#14A89B"
  signal-400: "#4FC7BC"
  signal-100: "#DCF1EF"
  # Pulse coral -- recording dot and destructive confirm only
  pulse-600: "#E5484D"
  pulse-500: "#F5595E"
  pulse-100: "#FFE4E4"
  # Semantic state
  success-600: "#1F8F4E"
  success-100: "#DCF1E2"
  warning-600: "#B27300"
  warning-100: "#FFF1CC"
  danger-600: "#C92A2A"
  danger-100: "#FCE4E4"
typography:
  display:
    fontFamily: "Inter Tight, SF Pro Display, -apple-system, sans-serif"
    fontSize: "56px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "Inter Tight, SF Pro Display, -apple-system, sans-serif"
    fontSize: "40px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Inter Tight, SF Pro Display, -apple-system, sans-serif"
    fontSize: "28px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  heading:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "22px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  panel-title:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "0em"
  body-prominent:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.45
  caption:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.3
  label:
    fontFamily: "-apple-system, SF Pro Text, Inter, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    letterSpacing: "0.08em"
  mono:
    fontFamily: "JetBrains Mono, SF Mono, ui-monospace, monospace"
    fontSize: "12px"
    fontWeight: 400
rounded:
  xs: "4px"
  sm: "6px"
  md: "10px"
  lg: "14px"
  xl: "20px"
  full: "999px"
spacing:
  "1": "4px"
  "2": "8px"
  "3": "12px"
  "4": "16px"
  "5": "20px"
  "6": "24px"
  "8": "32px"
  "10": "40px"
  "12": "48px"
  "16": "64px"
components:
  button-primary:
    backgroundColor: "{colors.signal-600}"
    textColor: "{colors.on-signal}"
    rounded: "{rounded.sm}"
    height: "28px"
    padding: "0 12px"
  button-primary-hover:
    backgroundColor: "{colors.signal-700}"
    textColor: "{colors.on-signal}"
  button-secondary:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink-900}"
    rounded: "{rounded.sm}"
    height: "28px"
    padding: "0 12px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink-600}"
    rounded: "{rounded.sm}"
    height: "28px"
    padding: "0 12px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.danger-600}"
    rounded: "{rounded.sm}"
    height: "28px"
    padding: "0 12px"
  input-text:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink-900}"
    rounded: "{rounded.sm}"
    height: "24px"
    padding: "0 8px"
  status-pill:
    backgroundColor: "{colors.ink-100}"
    textColor: "{colors.ink-600}"
    rounded: "{rounded.full}"
    height: "22px"
    padding: "0 10px 0 8px"
  workflow-chip:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink-600}"
    rounded: "{rounded.full}"
    height: "22px"
    padding: "0 8px"
  scope-row-active:
    backgroundColor: "{colors.signal-600}"
    textColor: "{colors.on-signal}"
    rounded: "{rounded.sm}"
    height: "28px"
    padding: "0 8px"
  kbd:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink-600}"
    rounded: "{rounded.xs}"
    height: "18px"
    padding: "0 5px"
  card:
    backgroundColor: "{colors.paper-raised}"
    rounded: "{rounded.md}"
    padding: "16px"
---

# Design System: meeting-pipe

## 1. Overview

**Creative North Star: "The Private Record"**

The system serves one invariant that outlasts every surface: a complete, local, trustworthy record of your meetings, kept on your own Mac, that you capture, read, search, and reason over. meeting-pipe is a menu-bar utility first, seen at only four moments (the prompt when a call is detected, the recording HUD, the done-notification, the Library), but the design is built so the record it keeps can be browsed, re-published, edited, and one day analyzed for patterns without inventing a new visual language each time. Whatever gets added stays in one register: local-first, quiet, deliberate.

Three motifs carry the whole thing. Paper: the canvas reads as a calm, barely-warm document where transcripts and summaries live, something you would want to read, not a chrome panel. Hairlines, not shadows: mac-native chrome separates surfaces with 1px and 0.5px borders, reserving shadow for the few surfaces that genuinely float. One signal: a single electric teal that means capture-in-progress and earns its place by rarity, never a decorative gradient or a fill on a large surface. Density is tight and mac-native throughout, a 13px body on a compact 1.125 ramp, a 4px spacing grid living mostly on the 8 / 12 / 16 / 20 ticks, fixed window sizes. This is interface, not a content site.

The system explicitly rejects three families. It rejects the SaaS marketing cliche: no gradients, no "powered by Claude" sparkle, no decorative AI iconography, no emoji in microcopy, no celebration toasts. It rejects the generic Electron-app feel: no web-rendered chrome pretending to be a desktop app, no wrong density, no wrong fonts, no missing SF Symbols. It rejects the modern dark-glass fintech and AI-tool family: no glassy floating cards, no neon accents, no gradient borders, no "futuristic" framing. The AI is used under the hood and acknowledged in plain grey text; it is never branded and never celebrated.

**Key Characteristics:**
- Local-first as a visual commitment: the on-device option always renders at the same weight as the cloud one, never tucked into "Advanced".
- Quiet by default: literal state labels, no celebration, the summary just appears.
- Warm ink on paper, never pure black on pure white.
- One signal-teal accent, held to roughly 10% of any surface.
- Hairlines over shadows; a shadow means "this floats".
- Fixed window sizes and mac-native density; SF Pro at 13px is canonical.

## 2. Colors: Paper, Ink, and One Signal

A calm paper-and-ink neutral base, exactly one electric accent, one reserved alarm color, and a small set of functional semantic states. Nothing decorative carries color.

### Primary
- **Live-Signal Teal** (#0E8C82): The single accent, the color of capture in progress. It fills the one payoff action on a surface (Record, Save, Publish), marks the current selection and the active tab, drives the playhead and waveform, and tints selected rows at about 8% as **Signal Wash** (#DCF1EF). **Deep Signal** (#0A6F67) is the hover and pressed state; **Bright Signal** (#14A89B) is the processing spinner and audio scrubber; **Pale Signal** (#4FC7BC) is a soft highlight. Never a decorative gradient, never a background fill on a large surface.

### Secondary
- **On-Air Coral** (#E5484D): Reserved for exactly two jobs, the recording dot and the destructive confirm in dialogs. Borrowed from the universal REC red but warmer and less alarmed. It never tints a button, a background, a success state, or a workflow.

### Neutral
- **Warm Graphite** (#14161A): The primary ink for foreground text, warmer than pure black so it reads gentler against paper. The ramp steps down through **Slate** (#4A4F58, muted text), **Stone** (#6E747F, subtle text), and **Ash** (#9098A4, faint text), then lifts into **Fog** (#ECEEF2, the hover-tint surface) and **Haze** (#F5F6F8).
- **Soft Document White** (#FBFAF7): The canvas, a barely-warm off-white that reads as a calm document. **Recessed Paper** (#F4F2EC) sinks wells, sidebars, and toolbars; **Lifted White** (#FFFFFF) is reserved for raised cards and sheets so layering stays legible.
- **Hairline Ink**: borders are ink at low alpha, not grey fills. 1px at 10% is the default separator, 18% strengthens inputs, 0.5px Retina hairlines divide internal table rows.

### Tertiary (semantic state)
- **Verified Green** (#1F8F4E), **Caution Amber** (#B27300), **Fault Red** (#C92A2A): Functional only. They appear in inline status rows and pills, each paired with an icon and a label, never as the background of an entire toast. Each carries a wash (#DCF1E2 / #FFF1CC / #FCE4E4) for callout backgrounds.

### Named Rules
**The One Signal Rule.** Live-Signal Teal appears on no more than about 10% of any surface. It marks one family of things: capture, the active path, the primary action. Its rarity is the point. Decorative teal is forbidden.

**The Coral-Is-Recording Rule.** On-Air Coral is the recording dot and the destructive confirm, nothing else. If coral is tinting a button or a background, it is wrong.

**The No-System-Blue Rule.** The accent is teal, end-state; macOS system blue is never the accent. The shipped `--mp-focus-ring` token is still blue and is mid-migration, so until it is recolored, derive teal focus rings inline with `color-mix(in srgb, var(--mp-signal-600) 32%, transparent)`.

**The Same-Level Rule.** Wherever the user routes data, the local option renders at the same visual weight as the cloud option. Local-first is shown, not hidden.

## 3. Typography

**Display Font:** Inter Tight (with SF Pro Display, -apple-system fallback)
**Body Font:** SF Pro via -apple-system / BlinkMacSystemFont (with Inter, Helvetica Neue fallback)
**Label / Mono Font:** JetBrains Mono (with SF Mono, ui-monospace fallback)

**Character:** System-native and quiet. The UI inherits SF Pro on every Mac, so chrome looks like the operating system, not a web app. Inter Tight's slight condensation gives hero and marketing moments an engineered feel without shouting. JetBrains Mono carries everything literal and machine-readable: timecodes, durations, file paths, bundle IDs, counts, and key bindings.

### Hierarchy
- **Display** (Inter Tight, 600, 56px, 1.15, -0.02em): Hero and marketing only; never in product chrome.
- **Headline** (Inter Tight, 600, 40px, 1.15, -0.02em): The largest in-product title; marketing h1.
- **Title** (Inter Tight, 600, 28px, 1.30, -0.01em): Page titles.
- **Heading** (SF Pro, 600, 22px, 1.30, -0.01em): Preferences section headers; switches to the system font.
- **Panel title** (SF Pro, 600, 17px, 1.30): The NSPanel and window title weight; the prompt question, the list-pane title.
- **Body** (SF Pro, 400, 13px, 1.45): Default body and button label, mac-native. Prose caps at 65 to 75ch; transcripts and dense UI may run tighter.
- **Body prominent** (SF Pro, 400, 15px, 1.45): A step up for reading-weight content.
- **Caption** (SF Pro, 400, 12px, 1.30): Secondary labels.
- **Label / eyebrow** (SF Pro, 600, 11px, +0.08em, UPPERCASE): Sidebar and source-list section headers (LIBRARY, WORKFLOWS), the app-name eyebrow over the prompt question, and compare-column titles. A functional label, not a decorative section kicker.
- **Mono** (JetBrains Mono, 400, 12px, ss01 / cv02): Timecodes, durations, paths, identifiers, counts, and key caps.

### Named Rules
**The Thirteen-Pixel Rule.** Body and chrome default to 13px, mac-native, on a compact 1.125 ramp. This is interface, not a content reader. Marketing surfaces may climb to display sizes; product chrome never inflates.

**The No-Bold Rule.** Weights stop at semibold (600); regular (400) and medium (500) carry the rest. Bold (700 and up) is not in the system, per Apple convention.

**The System-Font-Is-Canonical Rule.** The -apple-system and SF Pro stack leads every UI surface. Inter Tight appears only at 28px and above.

## 4. Elevation

The system is flat by default and mac-native. Depth comes from hairline borders and tonal surface layering (Recessed Paper underneath, Soft Document White at rest, Lifted White raised), not from shadows. A shadow is a signal that a surface genuinely floats over the desktop. Resting cards in a list carry a 1px hairline and no shadow at all. Raised surfaces such as a sheet inside a window take the smallest ambient shadow. Floating surfaces, the HUD prompt and popovers and the menu-bar dropdown, take the full layered HUD shadow plus a translucent fill and a 0.5px stroke, mirroring `NSPanel hasShadow = true` over `NSVisualEffectView .hudWindow`.

### Shadow Vocabulary
- **Hairline** (`inset 0 0 0 0.5px rgba(20,22,26,0.10)`): The Retina divider for internal table rows and surface edges.
- **Resting / xs** (`0 1px 1.5px rgba(20,22,26,0.06)`): A barely-there lift for a single raised control.
- **Raised / sm** (`0 1px 2px rgba(20,22,26,0.08), 0 2px 6px rgba(20,22,26,0.06)`): Sheets and panels inside a window.
- **Popover / md** (`0 1px 2px rgba(20,22,26,0.08), 0 6px 16px rgba(20,22,26,0.10)`): Menus and popovers.
- **HUD float** (`0 1px 2px ..., 0 12px 32px ..., 0 24px 60px ...`): Only the meeting prompt and floating panels, always paired with the `--mp-hud-bg` fill (paper at 0.78 alpha) and `backdrop-filter: blur(24px) saturate(180%)`.

### Named Rules
**The Hairlines-Not-Shadows Rule.** Surfaces at rest separate with 1px or 0.5px borders, never a drop shadow. If a resting card has a shadow, remove it.

**The Float-Earns-Blur Rule.** Translucency and backdrop blur belong only to surfaces that float over the desktop (the HUD, the menu-bar dropdown). Cards inside windows are fully opaque. Never double-blur.

**The No-Inner-Shadow Rule.** Inner shadows are forbidden everywhere.

## 5. Components

Every interactive component ships its full state set (default, hover, focus, active, disabled, and where relevant loading and error). The vocabulary is consistent surface to surface: the same button shape, the same form-control family, the same pill everywhere.

### Buttons
Confident but quiet, at mac-bezel proportions (28px tall, 26px in dense clusters), never playful.
- **Shape:** 6px radius (`--mp-radius-sm`), matching `NSButton.bezelStyle = .rounded`.
- **Primary:** Live-Signal Teal fill, white label, no border, a 1px bottom inner light. Hover darkens to Deep Signal (#0A6F67). The one payoff action per surface (Record, Save, Publish, Use candidate).
- **Secondary:** Lifted White, Warm Graphite label, 1px strong border. Hover tints to Fog (#ECEEF2). (Skip, Always for Zoom, Cancel, Keep current.)
- **Ghost:** Transparent, muted label, no border; hover fills Fog. Toolbar and icon actions.
- **Danger:** Transparent with a Fault Red label; hover fills the danger wash. Destructive only (Discard recording).
- **States:** Disabled drops to about 50% opacity. Focus is a 3px teal outer ring, always visible (the accessibility floor). Press adds an 8% darken and a 1px translate-y on raised buttons. No scale, no ripple, no shadow growth.

### Inputs and form controls
- **Text input and select:** 24px tall, Lifted White, 1px strong border, 6px radius; monospace inside path fields. Focus shifts the border to Live-Signal Teal and adds the teal ring.
- **Toggle:** a 34x20 track, a soft grey (#B7BDC6) off, Live-Signal Teal on, with a white knob that slides on a 180ms ease-out. Binary settings (Regulated mode, Auto-record).
- **Checkbox:** 14px, 3px radius, 1px border when off; teal fill with a white check when on.
- **Required states:** every control carries default, hover, focus, active, and disabled. No color-only state; a paired text or icon always accompanies the tint.

### Status pills
The workhorse state component: a rounded-full pill (19 to 22px) carrying a dot or icon plus a text label, with a tinted background, a matching border, and matching text color. Variants are Idle (Fog), live Detected (Signal Wash with a teal dot), Recording (coral wash with a pulsing coral dot), Processing (teal spinner with a stage label), Published (green wash with a check), plus Paste pending, Failed, Partial, Unpublished, and Local only. The recording dot pulses on a 1.6s opacity loop, never a scale pulse.

### Chips
- **Workflow chip:** rounded-full, a curated tonal dot (teal, deep-teal, amber, or ink, never coral) plus the workflow name, on Lifted White or Recessed Paper with a 0.5px border. The dot is the workflow's identity across the whole surface.
- **Filter chip:** rounded 6px, 22px, a muted label plus a chevron; opens a filter menu.
- **Mini chip:** 18px, an attribute marker on action items (owner in teal, due in amber, confidence in green), tinted with a `color-mix` of its own currentColor at about 12%.

### Cards and containers
- **Corner style:** 10px for cards (`--mp-radius-md`), 14px for panels and sheets (`--mp-radius-lg`, matching `NSPanel cornerRadius`), 20px for hero and marketing only.
- **Resting card:** Lifted White, 1px hairline, no shadow. **Floating panel:** the `--mp-hud-bg` fill, 14px radius, the HUD shadow, and a 0.5px stroke.
- **Padding:** 16 / 20 / 24, never below 12. Dense by default; do not pad to "modern web".
- **Callout** (publish-state, save-error, reprocess prompt): Recessed Paper or a semantic wash, a 0.5px border, and a leading state icon plus text. Never a side-stripe.

### Navigation
- **Smart-folder rail (220px):** Recessed Paper, uppercase functional headers (LIBRARY, WORKFLOWS), 28px scope rows. The active row is a full Live-Signal Teal fill with white text and an inverted count; an attention scope ("Needs you") carries an amber count badge. Workflow rows show the tonal dot plus a mono count.
- **Detail tab strip:** sentence-case tabs (Summary / Transcript / Audio) with a 2px Live-Signal Teal underline on the active tab; inactive tabs are muted, with no box and no pill.
- **Toolbar and breadcrumb:** a Recessed Paper bar with a 0.5px bottom hairline, a sidebar toggle, a `Library > Scope` breadcrumb, the idle or recording state pill, and the primary Record control.

### Signature: the Meeting Prompt (HUD)
A 600x64 horizontal pill that floats near the top of the screen (80pt inset), with `hudWindow` translucency (`blur(24px) saturate(180%)`), a 14px radius, the HUD shadow, and a 0.5px stroke. Left to right: a top-left close-x that means Skip (Notion's idiom), the app glyph (28px), a stacked uppercase app-name eyebrow over the 17px question "Record this meeting?", a live 4-bar mic waveform in Live-Signal Teal (level only, nothing captured yet), the workflow chip, and then the action cluster [Record (BYO)] [Record] [chevron]. A 2px hairline along the bottom drains over the timeout (default 30s) in teal at 60% opacity, and pauses at 30% on hover so a reader never loses the prompt.

### Signature: the two-channel waveform
The audio tab stacks two channels, Mic in Live-Signal Teal above System in Stone (#6E747F), each a 160-bar field tinted at about 5% of its own hue, with a single 1.5px Live-Signal Teal playhead and dot. It mirrors the stereo WAV (mic left, system right). A Mono / Stereo segmented control and a zoom chip sit in the transport row. Speaker dots in the transcript reuse a curated three-hue set (teal, amber, ink), never arbitrary hex.

## 6. Do's and Don'ts

### Do:
- **Do** hold Live-Signal Teal (#0E8C82) to about 10% of any surface: primary action, current selection, active tab, playhead, capture indicator. Use Signal Wash (#DCF1EF) for selected-row tints.
- **Do** separate resting surfaces with hairlines (1px at 10%, 0.5px Retina dividers); reserve shadow for surfaces that float.
- **Do** keep On-Air Coral (#E5484D) for the recording dot and the destructive confirm only.
- **Do** default to SF Pro at 13px on a compact ramp, and stop weights at semibold (600).
- **Do** label every state with text or an icon, not color alone; both light and dark must be color-blind safe.
- **Do** acknowledge the AI in plain grey provenance text ("Summarized by Claude Opus 4.8, cloud"), at the same weight as the on-device line.
- **Do** keep fixed window sizes and mac-native density (prompt 600x64, preferences 480x560).
- **Do** use the uppercase label only as a functional header (sidebar sections, field labels), never as decoration.
- **Do** honor `prefers-reduced-motion`: the recording-dot loop, the panel fades, and the tint transitions degrade to crossfades or instant changes.

### Don't:
- **Don't** ship the SaaS marketing cliche: no gradients, no "powered by Claude" sparkle, no decorative AI iconography, no emoji in microcopy, no celebration toasts ("Successfully published your summary! 🎉" is the exact failure mode). Not the Notion AI, ChatGPT, or Perplexity surface aesthetic.
- **Don't** produce a generic Electron-app feel: web-rendered chrome pretending to be a desktop app, the wrong density, the wrong fonts, no SF Symbols. Not Slack, not Discord, not Linear's desktop wrapper.
- **Don't** reach for the modern dark-glass fintech and AI-tool family: glassy floating cards, neon accents, gradient borders, "futuristic" framing. Wrong even when well-crafted, for a calm menu-bar utility.
- **Don't** use macOS system blue as the accent; the accent is teal, end-state.
- **Don't** use a side-stripe (a `border-left` or `border-right` over 1px as a colored accent) on rows, cards, callouts, or alerts. Use a full hairline, a wash tint, or a leading icon instead.
- **Don't** use gradient text (`background-clip: text` on a gradient). Emphasis is weight or size, in a single solid color.
- **Don't** use glassmorphism by default; blur belongs only to surfaces that float over the desktop, and cards inside windows stay fully opaque (never double-blur).
- **Don't** use pure black (#000) or stack pure white on pure white; ink is Warm Graphite (#14161A) on Soft Document White (#FBFAF7).
- **Don't** add inner shadows, scale or bounce pulses, skeleton shimmer, or decorative motion; motion conveys state only, at 120 to 280ms with no overshoot.
- **Don't** use em-dashes as punctuation in chrome or copy; use commas, hyphens, or rewrite. Reserve the ellipsis for an in-flight state ("Processing...") or an action that opens another surface ("Preferences...").
- **Don't** let a heading stretch past its container; product windows are fixed-size, so test the real copy at the real width.
