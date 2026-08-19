# DIST3: The installed app cannot be found by Spotlight

Band origin: filed 2026-08-04, observed during UX54's walkthrough and deliberately not folded into it (UX54's defect was in the app, this one is in the install path). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

While reproducing UX54's duplicate-instance bug on 2026-08-04, the session established two facts side by side:

- `~/Applications/MeetingPipe.app` **exists and Launch Services knows it.** It enumerates as a peer through `NSRunningApplication.runningApplications(withBundleIdentifier:)`, `open` resolves the bundle path, and launching it by path works.
- **Spotlight cannot find it.** The home volume reports "unknown indexing state", so typing "MeetingPipe" into Spotlight returns nothing and the owner has to navigate to `~/Applications` in Finder to launch it.

So the app is installed correctly and registered correctly; only the search index does not know about it.

**The root cause is machine-level, not an app defect.** A volume whose Spotlight index is in an unknown or damaged state will fail to surface any newly written bundle, MeetingPipe or otherwise. That is why UX54 named it and moved on rather than widening its own scope.

**But the fix that helps is ours.** `install.sh` writes the bundle into `~/Applications` and never tells Spotlight it did. On a healthy volume the file-system events would cause a reindex on their own; on this one they did not, and nothing in the install path forces the issue. `mdimport` exists precisely to ask Spotlight to index a specific path, and running it costs a fraction of a second at the end of an install that already takes much longer.

This sits inside the setup-ease carve-out that CLAUDE.md makes explicit under DOC10 ("a person getting a working install is not selling machinery"). An app the owner cannot find by name is a setup failure in the plain sense, so this is in scope even though distribution polish generally is not.

## Scope

Two small pieces.

1. **`install.sh` runs `mdimport` on the installed bundle** after it lands in `~/Applications`, as the last step of the install path. **Non-fatal on failure**: a missing search index is an annoyance, and failing an otherwise good install over it would be a worse outcome than the bug. Log what happened rather than aborting.
2. **`mp doctor` reports whether the bundle is indexed**, so the next occurrence is diagnosable in one command instead of re-derived from scratch the way this one was. `mdfind` against the bundle path is the check.

Apply the same call in `rebuild.sh` only if it installs to `~/Applications` too; if it does not, leave it alone rather than adding a call with nothing to index.

## Explicitly not / out of scope

- **Do not try to repair the volume's Spotlight index** (`mdutil -E`, rebuilding, toggling indexing). That is the owner's machine-level decision, it can take a long time, and an installer that silently rebuilds a search index is doing something the user did not ask for.
- **Do not add a Spotlight importer or metadata plugin.** The app has no document type that needs one.
- **Do not treat this as the cause of UX54.** UX54's duplicate instances were a guard reading a placeholder `NSRunningApplication.current` (fixed 2026-08-04, `7c0ac1d`); the two findings share a walkthrough and nothing else.
- Code signing and notarization stay deferred per the standing out-of-scope rule, even though a signed bundle interacts with Launch Services registration.

## Acceptance

- After a fresh `./install.sh` on a machine whose index is in a normal state, `mdfind -name MeetingPipe.app` returns the installed bundle path.
- `install.sh` **still exits 0** when `mdimport` is unavailable or fails, and says so in its output rather than silently swallowing it. Pinned by the install script's own test path if one exists, otherwise by a shellcheck-clean guard and a manual note in the task's walkthrough.
- `mp doctor` gains a check that reports the bundle's index state, passing when found and reporting a clear remediation line when not.
- Whatever suites cover the touched trees stay green (`swift test` if `mp doctor` is Swift-side, `ruff` plus `pytest` if the check lands in the pipeline), with new tests for the doctor check.
- If `scripts/` is touched, the mandatory script gates in CLAUDE.md apply.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule: every task gated on an owner action carries one. Steps are tagged [owner] / [session] by who acts.

1. [session] Run `./install.sh`, then `mp doctor`, and report what the new index check says.
2. [owner] Open Spotlight (Cmd+Space) and type "MeetingPipe". Pass: the app appears and launches from there. This is the whole bug.
3. [owner] If it still does not appear, say so: that means the volume's index is damaged beyond what `mdimport` can fix, and the remainder is a machine-level repair the session will walk you through separately rather than an app change.
4. [owner] Say "DIST3 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.

## Progress (2026-08-18, partial: shipped, owner walkthrough owed)

**A filing correction first, because it moves which half of the Scope is the fix.** Scope item 1 was already in the tree when this task was filed. `scripts/install.sh` has run `mdimport` on the installed bundle since 2026-04-30 (`17d947d9`), immediately after its `ditto`, and the comment above it already claimed the call "forces the index to refresh immediately". So the 2026-08-04 observation that Spotlight could not find the app was made **with that call in place**. Asking Spotlight did not help on this volume, which means the mdimport half was never the fix. That corroborates this task's own Context ("the root cause is machine-level, not an app defect") rather than contradicting it, and it makes item 2, diagnosability, the whole of the value.

**What shipped.**

- `scripts/install.sh` now **says which of three things happened** rather than swallowing the result: `mdimport` absent, asked and succeeded, or asked and failed. The Acceptance asked for exactly this ("says so in its output rather than silently swallowing it"), and `>/dev/null 2>&1 || true` is why nothing in the install output ever distinguished them. Still non-fatal, still exits 0. The overstated comment above it is corrected.
- `scripts/rebuild.sh` gets the same ask. It qualifies under the Scope's test because it does write into `~/Applications/MeetingPipe.app`, and it earns its fraction of a second because it is the fast path the owner runs most often, so an index that was missing after an install gets another chance on every rebuild rather than only on a full reinstall. Quiet on success, since a rebuild's output is a progress log rather than a report.
- `mp doctor` gains `check_app_index`, which asks `mdfind -name MeetingPipe.app` (the Acceptance's own form) and looks for the installed path among the results.

**The check reports four states, not two, and that is the design.** "Spotlight answered and does not know the bundle" and "Spotlight could not be asked" are different facts, and reporting the second as the first is how a void measurement gets banked as a real one. That is the DET2 lesson, and it is why `mdfind` being absent, exiting non-zero, or raising all report `[WARN] index state unknown` and never `[FAIL]`. A missing bundle (running from a build tree) is a `[WARN]` too, not a failure.

**Remediation stops where the out-of-scope list says.** It offers `mdimport` and points `mdutil -s /` at the volume's status so the owner can look, and it never suggests `mdutil -E` or any repair: rebuilding an index is a machine-level decision that can take a long time, and an installer that does it silently is doing something nobody asked for.

**7 tests added**, one per state plus the stale-other-copy case, where Spotlight knows a different `MeetingPipe.app` and the check names it, since that is the likeliest reason a search appears to work while the installed copy is unfindable. One test also fences the remediation, asserting `mdutil -s /` is offered and `mdutil -E` is not.

**Verified:** ruff, pyright and pytest green; `swift build` and `swift test` green and untouched by this change; `python3 scripts/truth_fences.py both` green. No new config key, event action, or sidecar field.

**Docs, same commit.** README's build-steps line said the `ditto` was "so Spotlight can launch it", which is precisely the claim this task disproves, so it now says asking is all the install can do and points at troubleshooting. A README troubleshooting entry and a plain-language `docs/SETUP.md` entry were added, the latter because an app the owner cannot find by name is a setup-ease failure and DOC10 puts that in scope.

**One open question, deliberately not resolved.** ~~`install.sh`'s closing text says of the CLI tools that "Everything they do is also in the app, so you do not need a terminal for normal use". `DiagnosticsWindow` reads its signals in Swift rather than shelling out to `mp doctor`, so this new check has no in-app equivalent and that sentence is now slightly false.~~ **Struck 2026-08-19: this paragraph was wrong, and the de-CLI question it raised does not exist.** Correction below; the strikethrough stays rather than a silent delete, because a later reader deserves to see what the claim was.

### The de-CLI question, closed 2026-08-19: the check already has an in-app surface

**The check is already reachable without a terminal, and always was.** `DoctorRunner.spawnMPDoctor` (`daemon/Sources/MeetingPipe/DoctorRunner.swift:51`) runs `mp doctor` as a subprocess and streams its whole stdout into a Preferences sheet, and `check_app_index()` is called from that command's `main` (`pipeline/src/mp/doctor.py:839`). So the Spotlight result, including its `mdimport` fix line, renders in the app verbatim, reached from **Preferences ▸ Integrations ▸ Run doctor...**. `install.sh`'s sentence is true as written and needed no hedge.

**Where the mistake came from, since it is a repeatable one.** The struck paragraph named `DiagnosticsWindow`, which is a different surface: the UX20 event-log viewer, which does read its signals natively in Swift and has no doctor in it. The doctor sheet is `DoctorRunner` plus `PreferencesView`, and it does shell out. Two Swift types with diagnostics-shaped names, one checked and the other reasoned about. The lesson is narrower than "check your claims": **a claim that a capability has no in-app surface is a claim about every surface**, so it wants a search for the capability rather than an inspection of the one surface that came to mind.

**Owner decision 2026-08-19, on the corrected facts: close it, no code.** The de-CLI rule is satisfied. Its purpose is that a user is not sent to a terminal for something the app does, and the app does this one.

**One real weakness found, recorded and not filed.** The only entry point to the doctor sheet is the header of Preferences ▸ **Integrations**, which is a reasonable home for credential checks and an odd one for "why can I not find my app". Someone with an install problem is unlikely to look there. That is a discoverability observation about every doctor check rather than a DIST3 defect, it was offered to the owner and declined as part of closing this, and it is written here rather than filed so a future task that touches Preferences navigation has the note without a row sitting open for it.

**Provenance.** Implemented by the orchestrating session rather than a worktree subagent: five consecutive upstream `529 Overloaded` errors made subagent dispatch unavailable across two ticks. Same scope and the same full verification table, without worktree isolation.

**Remainder: the owner walkthrough above, steps 2 to 4.** The de-CLI decision is closed (see the correction above), so the dev half of this task is done. The row stays in the active backlog rather than moving to [`owner-verification.md`](../owner-verification.md): that move needs the owner's approval and a recorded weight, and neither exists yet.
