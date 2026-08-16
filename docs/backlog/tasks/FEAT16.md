# FEAT16: share the summary or the transcript as rich text, so it pastes formatted into a chat

Band origin: filed 2026-08-17 at the owner's request: a Share button for both the summary and the transcript, so the whole thing can be copied out in a WYSIWYG way and pasted into a Teams chat, a Google Meet chat, or anywhere else, "while maintaining basic 'paste without formatting' options I have in all those tools". Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Every get-content-out path this app has writes a file or a page. The four sinks (Notion, Obsidian, filesystem, LAN) are configured in Preferences ▸ Integrations since UX45, and each of them publishes on the pipeline's own schedule to a destination set up in advance. None of that helps when the destination is a chat compose box someone is looking at right now.

The two clipboard affordances that exist carry no content. [`copyMeetingID`](../../../daemon/Sources/MeetingPipe/MeetingDetailView+Header.swift#L673) puts the stem string on the pasteboard, and AUTO4's [`copyTemplate`](../../../daemon/Sources/MeetingPipe/Automation/AutomationReference.swift#L39) puts a `meetingpipe://` URL on it. Neither the Summary tab nor the Transcript tab has any copy or share control at all: grepping both files for copy, share or export returns only unrelated uses of the word "shared".

So the route today is to find the published `.md` and paste its source, which arrives in a chat as literal `## Decisions` and `- point` text. That is the gap.

**A markdown render of a summary is already solved in Swift, and must not be solved a second time.** `render_summary_md` ([`markdown.py:234`](../../../pipeline/src/mp/markdown.py#L234)) has an explicit Swift mirror in `AppleIntelligenceSummarizer.renderMarkdown` ([`:426`](../../../daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift#L426)), and the two are pinned against each other by the CI3 `summary-md-golden.json` fixture precisely so they cannot drift. The missing pieces are the conversion to rich flavors and the pasteboard write, not the markdown.

The transcript is the harder half and is where this task can go quietly wrong. Python has `render_markdown` ([`markdown.py:46`](../../../pipeline/src/mp/markdown.py#L46)), but it renders from the structured file and Swift has no transcript renderer at all. **What is on disk is not what the reader sees.** [`TranscriptDisplay.displayName`](../../../daemon/Sources/MeetingPipe/TranscriptTab.swift#L175) maps `speaker_0` to `Speaker 1`, `speaker_unknown` to `Unknown speaker`, and `THEM-A` to `Unknown A`; speaker renames live in `SpeakerLabelStore` and text edits in `TranscriptCorrectionStore`, both reversible overlays applied at read time rather than written back into `<stem>.json`. A share implemented as "read the file, render it" therefore copies raw internal ids and un-corrected text, and it would look correct in every test that does not specifically check for it. The summary has the same property in a milder form: UX26's action checkboxes write back into `<stem>.summary.json`, so the `MeetingSummary` the tab holds is the truth to render.

**The two halves of the owner's ask are one write, not a tradeoff.** A single `NSPasteboard` item can carry `.html`, `.rtf` and `.string` at the same time; the receiving app takes the richest flavor it understands, and Paste and Match Style (Cmd+Shift+V in Teams, Slack, Notes and the rest) reads the plain-text one. Writing all three is what makes "preserve rich text" and "keep paste without formatting working" the same feature. Writing only HTML is the failure mode: it looks right on the first paste and silently removes the owner's plain-paste option everywhere.

**Do not promise WYSIWYG where the destination has no rich text.** Teams accepts HTML in its compose box on both desktop and web. Google Meet's in-call chat is a plain text field and will take the plain flavor no matter what is offered alongside it. That is not something to work around; it is the reason the plain flavor is mandatory rather than a nicety, and it is why the owner walkthrough below pre-registers Meet arriving plain as a pass.

## Scope

The smallest change that closes the class: one pure renderer, one pasteboard write, one affordance per surface.

**1. A pure renderer, taking what the reader holds rather than a path.** Two entry points, one for a `MeetingSummary` and one for the transcript rows the tab has already resolved (display name after overlays, text after corrections). For the summary's markdown and plain flavors, call the existing `AppleIntelligenceSummarizer.renderMarkdown`; do not write a second summary renderer. For the transcript, a new render is genuinely needed on the Swift side, and it renders the resolved rows.

**2. HTML over the subset these two documents actually use**, which is headings, paragraphs, bullet lists, bold, italic, inline code and links. Not a general markdown engine, and not a dependency.

**3. RTF derived from the HTML**, via `NSAttributedString(html:documentAttributes:)` and then `.rtf` data, so HTML stays the single source and there is no hand-built RTF to keep in step. Named here so the pickup session does not build a parallel path.

**4. The pasteboard write takes the pasteboard as a parameter** rather than reaching for `.general` inside, following AUTO4's precedent at [`AutomationReference.swift:39`](../../../daemon/Sources/MeetingPipe/Automation/AutomationReference.swift#L39), so the tests pin real behaviour against a scratch board instead of stomping the owner's clipboard on every run.

**5. The affordance, on both surfaces.** The natural seam is the detail header's [`actionsMenu`](../../../daemon/Sources/MeetingPipe/MeetingDetailView+Header.swift#L273), where `Copy meeting ID` already lives, routed through [`toolbarAction(_:_:)`](../../../daemon/Sources/MeetingPipe/MeetingDetailView+Header.swift#L508) so the share emits its `detail` / `toolbar_action` event like every other action there. Whether this ships as two menu entries or as one control on each tab that shares the tab you are on is the pickup session's call; both must be reachable, since the owner asked for both. Record which was chosen and why.

Constraints:

- Copy names the mechanism, not the metaphor. This puts formatted text on the clipboard, so a label that says paste is more honest than one that implies a share sheet.
- DSN3 applies to any new chrome: 4.5:1 contrast, no new `.system(size:)` literals on changed lines.
- Read [`docs/GUIDE.md`](../../GUIDE.md) before shipping and add the recipe in the same commit, per the CLAUDE.md rule that a change to user-visible surfaces updates the guide with it.

## Explicitly not / out of scope

**Not `NSSharingServicePicker`.** The macOS share sheet is the obvious reading of "Share button" and it is the wrong mechanism for the named destinations: a Teams or Meet compose box is not a share-service target, and the clipboard is the actual transport the owner described. If a share sheet is ever wanted for mail and AirDrop, it is its own row.

**Not a new publish sink.** The four configured sinks already cover destinations set up in advance; this is deliberately the ad-hoc path for when the destination is a message.

**Not a clamp on NDA or regulated meetings, and not a warning banner either.** The publish clamp exists to stop automatic egress, and the AI/DV standing rule is about engine calls; this makes no engine call and touches no network, and a person pressing a copy control is a deliberate act. Named here so the pickup session neither invents a block nobody asked for nor omits the question by accident.

**Not a third summary markdown renderer.** `renderMarkdown` exists and the CI3 fixture pins it against Python. A new one would drift and would need a fence of its own.

**Not a Python change and not a new cross-tree fixture.** HTML and RTF are Swift-only presentation with no Python counterpart, so `summary-md-golden.json` already covers the only cross-tree surface in reach.

**Not a file export.** Save as `.docx`, `.pdf` or `.html` is a different feature with a different surface.

**Adjacency noticed, not folded in:** UX71 (the Ask pane renders answers as raw markdown) is the same underlying gap seen on a third surface, and a markdown-to-rich step landing here is its most likely reuse. Do not absorb UX71; do leave the renderer callable from outside the detail view.

## Acceptance

- A test asserts that a summary share leaves `.html`, `.rtf` and `.string` all present and non-empty on one scratch pasteboard item. This is the whole contract in one assertion.
- A test asserts the `.string` flavor is the readable plain rendering, so Paste and Match Style yields usable text. This is the half of the owner's ask that a rich-only implementation silently breaks, so it gets its own test.
- A test asserts the HTML flavor carries structure: a summary holding a heading, a bold run and a bullet list produces heading, strong and list markup rather than escaped `##` and `-`.
- A test asserts the transcript share renders the reader's speaker names. A transcript holding `speaker_0`, `THEM-A` and one renamed speaker must produce `Speaker 1`, `Unknown A` and the given name, in every flavor. This must fail against an implementation that reads `<stem>.json` directly, which is the trap.
- A test asserts a text correction held as an overlay appears in the shared text.
- A test asserts the share emits its `detail` / `toolbar_action` event.
- No test touches `NSPasteboard.general`; all use a scratch `NSPasteboard(name:)`, per AUTO4.
- `cd daemon && swift build` clean and `swift test` green, with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total.
- `python3 scripts/truth_fences.py both` clean, no em-dashes on changed lines, dash guard green.
- [`docs/GUIDE.md`](../../GUIDE.md) gains the recipe in the same commit.
- The walkthrough below is what closes the task. A real paste into a real Teams chat is not exercisable in a harness, and it is the only place the claim can actually be checked.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready.
2. [owner] Open a meeting with a real summary, use the new control, and paste into a Teams chat compose box without sending. Pass: headings, bullets and bold arrive as formatting rather than as `##` and `-` characters.
3. [owner] In that same box, undo and paste again with Cmd+Shift+V. Pass: the same text arrives with no formatting and still reads properly. This is the second half of the ask and the step most likely to expose a wrong implementation.
4. [owner] Repeat both pastes with the transcript, checking the speaker names are the ones the app shows: real names where people are named, `Speaker 1` or `Unknown A` where they are not.
5. [owner] Paste into Google Meet's in-call chat. Pre-registered as a pass if it arrives as plain readable text, since that field accepts no rich text from anyone. Report what it actually does.
6. [owner] One paste into a third destination of your choice (Notes, Slack, Obsidian, an email) so "any other place" has evidence rather than an assumption behind it.
7. [owner] Say "FEAT16 good to close", or what is wrong; [session] moves the row and this spec into `q6-final.md` and deletes this file.
