# MIC7 spike: browser/PWA mute oracle via a stable platform signal (Google Meet first)

Spike, 2026-07-12. Probe: [`daemon/scripts/mic7-meet-mute-probe.js`](../../daemon/scripts/mic7-meet-mute-probe.js) (owner-run in the Meet tab's DevTools console, read-only). This spike ships the architecture analysis + the stability-measuring instrument; the DOM-stability verdict is owner-owed because it needs a live Meet call in the owner's browser, and the current Meet DOM (not a stale training-time snapshot).

## Measured signal verdict (2026-07-20): candidate 1 confirmed, `data-is-muted`

The owner ran the probe on a live Meet call and toggled the mic. Per-toggle dump:

| Signal | Behaviour | Verdict |
|---|---|---|
| `data-is-muted` | flips `'false'` / `'true'` on every toggle | **primary key** |
| `aria-label` | flips every toggle, but localized (`Вимкнути мікрофон` / `Увімкнути мікрофон`) | rejected, the native-title mistake |
| `className` | flips (`aLTxue MNEgVb` / `Y3DJRd GgyKtd`) | rejected, build-obfuscated |
| `aria-pressed` | `null`, absent entirely | not available |
| `data-muted`, `data-tooltip` | `null` | not available |

So the spike's candidate 1 exists and candidate 2 does not. **The signal-stability gate is GO**, and the primary key is `data-is-muted`.

Two implementation notes the dump makes explicit, both easy to get wrong:

1. **The attribute is state; the label is the inverse action.** `data-is-muted='false'` pairs with the label `Вимкнути мікрофон` ("turn off microphone"), because the button advertises the action available, not the state held. Anyone keying on the label rather than the attribute gets inverted polarity on top of the localization problem. `data-is-muted` is read directly: `true` means muted.
2. **It is the string `'true'` / `'false'`, not a boolean**, and it can be absent (the other probed attributes came back `null`). Parse it explicitly and treat absent as unknown rather than as unmuted, so a DOM change degrades to "no signal" instead of to "mic is live".

**Caveat on what was measured.** This is 4 toggles in one session against one Meet build. It establishes that the attribute exists and flips reliably right now; it does not measure stability across Meet's deploy churn, which is the actual long-term risk and cannot be measured in one sitting. That argues for the same defensive shape as note 2: a `MeetMuteAdapter` that reports unknown when the attribute vanishes, plus something that notices the signal has gone quiet, rather than silently falling back to an RMS guess.

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

**Still true after the 2026-07-20 probe call, and worth recording precisely.** That session put a real Meet call in Chrome on the machine, and the daemon handled it correctly: `shareable_content_window_present` plus `lifecycle/starting`, then `prompt_shown` at 13:05:15 local (timed out unanswered 30 s later) and again at 13:12:19 (`user_skipped` 4 s later). So browser *detection* works and asks; what is still missing is a browser meeting the owner actually wants recorded. The corpus count of recorded browser meetings remains **0**. A probe call the owner deliberately declined twice is not the promotion trigger, so the build gate below stands unchanged.

## Verdict: GO on feasibility, DEFER on build (gate on a real browser meeting), DOM-stability owner-owed

- **Architecture: GO.** The in-page-extension-to-`MicGateAdapter` path is sound and is the futureproof, tool-scoped shape the user approved. If a stable boolean signal exists on the Meet mic button, a real oracle is a clean, well-bounded build with no fusion changes.
- **Signal stability: RESOLVED 2026-07-20, GO.** `data-is-muted` flips on every toggle and is the primary key (measured verdict at the top of this doc). `aria-pressed` does not exist on Meet's mic button, so the fallback candidate is unavailable and the localized `aria-label` stays rejected. This bullet was the spike's owner-owed half and it is now closed.
- **Build timing: DEFER.** Even on a GO signal, gate the actual extension build on a real browser meeting appearing in the corpus, aligning with END5's identical promotion trigger (they share the extension artifact and the consent gating; build them together when browser usage is real). Shipping the extension now is net-new surface for a surface with zero recordings.

Net recommendation after the measurement: **the signal question is settled GO, and the build is still the right thing not to do yet.** Of the two gates this spike set, one has fallen (a stable boolean exists) and one has not (a browser meeting the owner actually records). Both were required, deliberately, so one falling does not promote the task.

## Follow-on

- ~~Owner: run the probe on a live Meet call.~~ **Done 2026-07-20:** `data-is-muted` is the stable boolean; see the measured verdict above.
- Remaining gate: a real browser meeting in the corpus. When one appears, build the `MeetMuteAdapter` + the content-script extension together with END5's browser end signal (shared artifact + consent gating), Teams-web / Webex-web after Meet. Build against `data-is-muted`, parsed as a string with absent treated as unknown, never the `aria-label`.
- If the owner wants the oracle before that trigger fires, the signal work is no longer blocked on research; it is a scoped build decision. MIC8 (native Zoom/Teams logs) remains the stronger futureproofing bet for native surfaces, which are where this owner's meetings actually happen.
- Re-run the probe before starting the build regardless. The verdict is one session against one Meet build, and Meet's churn is the standing risk; a cheap re-run at build time confirms the key is still there.
