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
