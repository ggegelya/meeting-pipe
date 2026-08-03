# DOC12: prose doc-truth sweep, the 2026-08-03 band

Filed 2026-08-03 by the audit band. Medium. This is the residue of the doc-truth angle after its two largest findings were split out (PIPE14 for the publish-state claims, UX60 for the regulated-mode README bullets).

## Why this is its own row rather than fixed in passing

The 2026-07-31 owner-owed pass established that documentation asserting behaviour the code does not have is this repo's dominant defect class, because sessions steer by these documents and the owner is walked through them. Each item below is small; the class is not.

## The list

**1. The TCC invariant describes signing the app stopped doing.** CONFIRMED by an independent skeptic. `ARCHITECTURE.md:469` says `install.sh` and `rebuild.sh` "codesign adhoc with a stable `--identifier`" and therefore "Screen Recording requires one toggle after rebuild". `scripts/install.sh:368-370` runs `ensure_dev_cert` on every install, and `scripts/lib/dev-cert.sh:32-38` makes ad-hoc the third and last choice. `README.md:162` and `:629` assert the opposite of ARCHITECTURE, correctly: the self-signed "MeetingPipe Dev" identity gives an identity-based designated requirement that does not pin the cdhash, so the grant survives. Two live docs give opposite answers to the same question, and whichever the reader opens first decides whether a real signing regression looks like a bug or expected behaviour. Fix: rewrite `:469` to describe the dev-cert default with ad-hoc as the fallback, and point the invariant at `scripts/lib/dev-cert.sh`.

**2. `--context-tokens` is documented as RAM-clamped without its backend condition.** `README.md:500` says it "is clamped to what your Mac's RAM can answer with", and `mp ask`'s own help text says the same. `ask.context_ceiling` returns `None` for any backend outside `ON_DEVICE_BACKENDS`, so on the shipped default (`anthropic`) an arbitrary value passes through unclamped. This is the same shape as the AI11 step 6 walkthrough failure, which is already recorded: the clamp is on-device-only by design and pinned by a test, and the documentation states it unconditionally. Fix: add the condition. Note AI12 is building a UI control over this budget and should not inherit the wrong mental model.

**3. README's workflow definition claims per-workflow Obsidian vault routing.** `README.md:318` lists "which Obsidian vault" among the per-context routing rules a workflow carries. `WorkflowSink.obsidian` has no associated value, `<stem>.meta.json` carries no vault key, and `mp.workflow.apply_overrides` never touches `obsidian.vault_path`. The vault is global-only. Note UX45 is already filed to add publish-target configuration in-app, so this line may become true; until it does, it is false. Fix: correct the sentence, and cross-reference UX45.

**4. ARCHITECTURE's Key invariants point at `Coordinator` for two things that moved.** `ARCHITECTURE.md:464` says "every transition lives in `Coordinator`" (they live in `Coordination/DetectionStateMachine.swift`), and the following bullet names `Coordinator.processingJobs` as the job queue (it is a private property of `Coordination/SinkDispatcher.swift`). Fix: repoint both.

**5. The Permissions pane's privacy callout understates the app's network reach.** `daemon/Sources/MeetingPipe/Preferences/PreferencesView+Permissions.swift:74` enumerates egress as Anthropic for summarization plus Notion for publishing. The app now also ships the Claude CLI, OpenAI, Obsidian, filesystem and LAN paths. Fix: state the reach in terms of the configured backend and sinks rather than naming two vendors, so it cannot go stale again.

**6. The prompt panel's BYO tooltip names Anthropic unconditionally.** `daemon/Sources/MeetingPipe/MeetingPromptWindow.swift:523` reads "Record, but skip the Anthropic API call. You'll summarize the transcript yourself." That is wrong whenever the resolved backend is local, `claude_cli`, `openai` or `apple_intelligence`. Fix: name the resolved engine, or say "the summarization step" without a vendor.

**7. `docs/SETUP.md` and the installer disagree on the model download size.** `docs/SETUP.md:13` says the speech models are about 475 MB; `install.sh` prints ~630 MB for the same download at the same moment. Fix: make one the source of truth. SETUP.md is the clean-Mac walkthrough, so the installer's figure should win and SETUP should quote it.

**8. README sends the owner to hand-edit a threshold that has a slider.** `README.md:251` says to edit `summarization.skip_above_chars` in `config.toml`; Preferences has shipped a slider over the same value with an explanatory footer. Fix: point at the slider, keep the config key as the secondary route.

**9. The Accessibility rationale diverges between two copies.** `daemon/Sources/MeetingPipe/Preferences/PreferencesView+Permissions.swift:204` returns "Reads browser tab titles to detect Meet and Teams Web sessions", a second diverged copy of `PermissionsCenter.Kind.rationale`. It names a path the owner has never used, while every other surface names native end-detection. Fix: delete the duplicate and read the one rationale. Note DET11 is correcting what those surfaces should *say*; this item is about there being two copies, so land DET11's wording and have this one converge on it.

**10. The `fgFaint` contrast floor, one instance.** `daemon/Sources/MeetingPipe/MeetingDetailView+Header.swift:101` and `:104` render the "Summary edited locally" glyph and caption in `MPColors.fgFaint` at the smallest type step, while the caption twenty lines below explicitly moved off `fgFaint` because it sits near 2.8:1 against a 4.5:1 floor. Fix: use `fgSubtle`, which clears the floor.

## Scope

Fix all ten. They are independent one-liners to one-paragraph edits, and none needs a decision except item 3's cross-reference to UX45 and item 9's ordering against DET11.

## Acceptance

Every item above corrected. `python3 scripts/truth_fences.py both` still clean. Where a string is derivable from code (items 5, 6, 9), prefer deriving it over restating it, so the class stops recurring. No behaviour change, so both suites stay green with no new tests except where a derived string gains one.
