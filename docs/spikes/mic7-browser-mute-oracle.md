# MIC7 spike: browser/PWA mute oracle via a stable platform signal (Google Meet first)

Spike, 2026-07-12. Probe: [`daemon/scripts/mic7-meet-mute-probe.js`](../../daemon/scripts/mic7-meet-mute-probe.js) (owner-run in the Meet tab's DevTools console, read-only). This spike ships the architecture analysis + the stability-measuring instrument; the DOM-stability verdict is owner-owed because it needs a live Meet call in the owner's browser, and the current Meet DOM (not a stale training-time snapshot).

## Question

Browser-hosted meetings expose no Accessibility mute oracle. `NoOpMuteAdapter` (wired for both the `.meet` and `.browser` surfaces in `Coordinator`) emits nothing, so `MicGate` falls through to HAL VAD + RMS and the recorded mute state for a browser meeting is an energy guess. Under MIC5's offline redaction that means a browser meeting's muted spans are guessed from RMS rather than a real mute signal.

MIC7 asks: does Google Meet's own page carry a **durable** mute signal (an `aria-pressed` / `data-*` boolean, or exposed JS state) that a small browser extension could read and hand to the daemon, so browser meetings get a real mute oracle like native apps do? And is that signal stable enough across Meet's frequent UI churn to be worth a net-new artifact (an extension is a new thing to build, sign, distribute, and gate behind consent)?

The user has blessed tool-scoped oracles **provided they are stable and futureproof against UI/UX changes** (the standing MIC direction). The native mute incident proved that scraping a *localized button title* is fragile; the browser equivalent of that mistake is keying on a localized `aria-label` ("Turn off microphone"). So the spike is specifically about finding a signal that is a stable boolean, not a localized string.

## What this does and does not change (scope)

- It affects **only browser redaction accuracy** under MIC5. MIC4 already removed the *data-loss* failure mode for browsers (capture-first: the full mic is kept, redaction is offline and recoverable), so this is an accuracy improvement, not a correctness fix. That caps the urgency.
- It is hints-adjacent to capture, never a trigger and never a real-time gate by default: a browser mute signal would feed the same `MicGate` fusion the native adapters feed, and under the regulated gate it would need the same trust bar as a native oracle before it could zero audio live.

## Candidate signals (to be confirmed by the probe, not asserted here)

Meet's control DOM changes often and its class names are build-obfuscated, so the durable candidates are semantic attributes on the mic button, in rough descending order of expected stability:

1. A `data-*` boolean on the mic control (Meet has historically carried a `data-is-muted`-style attribute). A stable boolean that flips on every toggle is the ideal signal.
2. `aria-pressed` on the mic toggle (semantic, not localized). Good if present and reliably flipped.
3. The mic button's `aria-label` / `data-tooltip` ("Turn off microphone" vs "Turn on microphone"). **Localized and fragile**, the browser analog of the native-title incident; usable only as a last-resort corroborator, never the primary key.
4. An obfuscated class toggled on mute. Unstable across builds; do not key on it.

The probe dumps all of these on the live mic button and logs which ones flip when the owner toggles their mic, so the choice is made from the current Meet DOM rather than from documentation that rots. This is the crux of "spike the Meet DOM signal's stability before committing" and it is exactly what cannot be answered from inside this harness (no authenticated live Meet call).

## Delivery vehicle

A DOM signal has to cross from the page into the daemon. Options:

- **A small browser extension (content script) + a local channel to the daemon.** The content script reads the chosen mic-state attribute, observes it with a `MutationObserver`, and posts each transition to the daemon over a localhost loopback endpoint (or Native Messaging). This is the only approach that reads the page's own state reliably, and it is the futureproof one the user blessed. Cost: a net-new artifact (per-browser extension packaging), a new install step + a browser permission, and consent gating (it must obey the same per-workflow / regulated rules as the native oracle, and it must be off unless the meeting is being recorded).
- **The daemon reads the browser's AX tree for web content.** Rejected: web-content AX is partial and even more churn-prone than the DOM, and it is the fragile path MIC7 exists to avoid.
- **Meet has no local log or public per-tab mic API on macOS** to read out-of-band (unlike the MIC8 idea for native Zoom/Teams logs), so the in-page extension is the realistic vehicle.

How it wires in with no fusion changes: replace `NoOpMuteAdapter(config: .meet)` with a `MeetMuteAdapter: MicGateAdapter` whose `start(context:handle:sink:)` subscribes to the extension's transition feed and calls `sink(.muted)` / `sink(.unmuted)`, the same `AXMuteButtonProbe.Event` the native adapters emit. Everything downstream (MicGate precedence, MIC5 redaction reading the mute timeline) is unchanged; only the signal source is new.

## The reality check that dominates the verdict

END5 recorded the operative fact: **0 browser meetings in 19.8 days** of dogfood (the 3 Chrome-PWA `lifecycle.ended` events drove no recording). For this owner, browser meetings are currently rare-to-nonexistent. Building, signing, distributing, and consent-gating a per-browser extension for an accuracy improvement on a surface that has produced zero recordings is a poor trade *today*, however feasible.

## Verdict: GO on feasibility, DEFER on build (gate on a real browser meeting), DOM-stability owner-owed

- **Architecture: GO.** The in-page-extension-to-`MicGateAdapter` path is sound and is the futureproof, tool-scoped shape the user approved. If a stable boolean signal exists on the Meet mic button, a real oracle is a clean, well-bounded build with no fusion changes.
- **Signal stability: owner-owed.** Whether a *stable* signal (not just a localized label) exists on the *current* Meet DOM is the one thing this spike cannot assert from here. Run the probe on a live call and read which signal flips every time. If a `data-*` / `aria-pressed` boolean flips reliably: the primary key is found. If only the localized label flips: MIC7 is a NO-GO on Meet until Meet exposes something stabler (do not ship a localized-string oracle, the incident already taught that lesson).
- **Build timing: DEFER.** Even on a GO signal, gate the actual extension build on a real browser meeting appearing in the corpus, aligning with END5's identical promotion trigger (they share the extension artifact and the consent gating; build them together when browser usage is real). Shipping the extension now is net-new surface for a surface with zero recordings.

Net recommendation: **do not build the extension yet.** Keep this doc + the probe; when the owner starts taking meetings in the browser (or wants to validate now), run `mic7-meet-mute-probe.js` on a live Meet call. A stable-boolean result promotes MIC7 (and END5) to a real build; a localized-only result closes the Meet leg until Meet changes.

## Follow-on

- Owner: on the next browser Meet call (or a test call), paste `daemon/scripts/mic7-meet-mute-probe.js` into the Meet tab's console, toggle the mic, and note which signal flips reliably.
- On a stable-boolean GO + a real browser meeting: build the `MeetMuteAdapter` + the content-script extension together with END5's browser end signal (shared artifact + consent gating), Teams-web / Webex-web after Meet.
- On a localized-only result: close the Meet leg of MIC7; revisit if Meet exposes a stable attribute later. MIC8 (native Zoom/Teams logs) remains the stronger futureproofing bet for native surfaces.
