# ADR 0014: Typed MeetingSummary model on the Swift side

| Property            | Value                       |
| ------------------- | --------------------------- |
| **Status**          | Accepted                    |
| **Date**            | 2026-05-28                  |
| **Decision Makers** | Project owner               |
| **Technical Area**  | Library / summary rendering |
| **Related Tasks**   | TECH-A11                    |

## Context

The Library detail surface threaded the parsed summary as `[String: Any]` through the rendering and editing views (`SummaryRenderedView`, `CorrectionSummaryPreview`, `CorrectionViewModel`) and through `MeetingStore`'s search-corpus builder. Every field was read by string subscript (`summary["decisions"]`), so a mistyped section key silently rendered an empty section instead of failing. The pipeline already models this exact shape as a typed pydantic `MeetingSummary` in `pipeline/src/mp/schemas.py`, which is the canonical on-disk contract that Notion publishing depends on.

TECH-A11 replaces the untyped reads in the view layer with a typed Swift `MeetingSummary` that mirrors the Python schema, so a wrong field name is a compile error rather than a blank section.

## Decision Drivers

- **Python schema is the source of truth.** `pipeline/src/mp/schemas.py` defines field names, types, and the JSON shape every publisher expects. The Swift model mirrors it; it does not redefine it.
- **The reader must tolerate partial and legacy files.** A hand-pasted BYO `<stem>.summary.json`, an older file, or a half-written one must still render what it has. A strict decoder that throws on a missing key would regress the Library (a present-but-empty `{}` summary must still produce a `.done` row).
- **The write paths must preserve the exact on-disk shape.** The pipeline writes `owner`/`due` as explicit `null` and always writes `detected_language`. The Swift write bridge has to reproduce that, not emit a subtly different shape (absent keys vs null).

## The one field-level divergence: `detected_language`

The Python schema makes `detected_language: str` a required field with a default of `"en"`, so a Python-written summary always carries the key. The Swift model decodes it as `detectedLanguage: String?` (optional), mapping an absent or empty value to `nil`.

Per the TECH-A11 stop-and-ask ("decide at the Python schema's level; it is the source"):

- **On read**, Swift is tolerant: a file that lacks the key (legacy, hand-pasted, or non-Python-written) decodes to `nil` rather than throwing. The UI hides the language chip when `nil` (see TECH-UI-4), which is the desired "unknown" rendering.
- **On write**, Swift defaults `nil` back to `"en"` in `jsonObject()`, so the on-disk shape stays identical to what Python produces (the key is always present after a Swift write).

Net: Python remains the authoritative writer that always emits the field; the Swift optional is purely a decode-side robustness choice and never changes the on-disk contract.

## Consequences

- New `daemon/Sources/MeetingPipe/Library/MeetingSummary.swift` (`Decodable`, tolerant `init(from:)`, `init?(jsonObject:)`, `load(from:)`, and a `jsonObject()` write bridge that matches the pipeline's shape).
- `SummaryRenderedView`, `CorrectionSummaryPreview`, `CorrectionViewModel`, and `MeetingStore.buildSearchableText` now consume the typed model. A typo in a section name is a compile error.
- The correction record envelope (`CorrectionStore.write`) keeps its generic `[String: Any]` signature; the "looks good" path in `Coordinator` still forwards the raw loaded dict so any unmodeled fields survive in that record. Edited summaries round-trip through the typed model (the modeled fields are the canonical set).
- `detected_language` stays required-with-default on the Python side; no pipeline change. The Swift optional is documented here so a future reader does not "fix" it to non-optional and reintroduce throw-on-missing.
