---
name: meeting-pipe-design
description: Use this skill to generate well-branded interfaces and assets for Meeting Pipe — a mac-first, local-first meeting recorder + transcription tool — either for production or throwaway prototypes/mocks/etc. Contains essential design guidelines, colors, type, fonts, assets, and UI kit components for prototyping.
user-invocable: true
---

Read the README.md file within this skill, and explore the other available files.

If creating visual artifacts (slides, mocks, throwaway prototypes, etc), copy assets out and create static HTML files for the user to view. If working on production code, you can copy assets and read the rules here to become an expert in designing with this brand.

If the user invokes this skill without any other guidance, ask them what they want to build or design, ask some questions, and act as an expert designer who outputs HTML artifacts _or_ production code, depending on the need.

Key entry points:
- `colors_and_type.css` — every design token (colors, type, spacing, radii, shadows, motion). Single source of truth. Import this in any HTML you generate.
- `assets/` — logo, wordmark, app icon, menu-bar template icons.
- `ui_kits/macos_app/` — JSX components recreating the existing menu-bar app surfaces (status bar dropdown, "Meeting detected" HUD prompt, Preferences window).
- `preview/` — design system specimen cards.

Design principles in one breath: **mac-first, paper-warm canvas, hairlines not shadows, signal-blue accent used surgically, no gradients or emoji, sentence-case copy, no exclamation marks, SF Symbols (or Lucide as web fallback) for iconography**.
