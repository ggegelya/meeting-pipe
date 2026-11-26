---
id: STOR19
title: With no output_dir in config.toml, all three library resolvers read an old default library they cannot list as empty and pick ~/Meetings/raw, so the trees can split and the rebuild guard can proceed without asking
category: Storage
status: new
priority: P2
comment: Filed 2026-11-26 (owner approved 2026-11-25/26): the 2026-11-21 second fix review's storage L5, never filed (DIST9's 2026-11-26 note says so). LibraryDefaultPin.hasEntries, Python _has_entries and live-recording.sh's find all collapse a listing error into "no entries". Scope: only "does not exist" picks the new default; any other listing error keeps the old one; plus DIST9's cannot-tell refusal still says "Stop the recording first".
---

# STOR19: With no output_dir in config.toml, all three library resolvers read an old default library they cannot list as empty and pick ~/Meetings/raw, so the trees can split and the rebuild guard can proceed without asking

Band origin: filed 2026-11-26 from the [2026-11-21 second fix review](../../audits/2026-11-21-second-fix-review.md), storage report finding L5 ("STOR6: 'the old folder could not be listed' is 'the old folder is empty', in all three resolvers"), which was not filed with the review's other findings on 2026-11-21; [DIST9](./DIST9.md)'s 2026-11-26 progress note names it as the one configuration its fix does not cover. Owner approved filing on 2026-11-25/26. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**The STOR6 rule.** New installs default to `~/Meetings/raw` and `~/Meetings/published`. A `config.toml` that names no `output_dir` keeps an existing library at the old default (`~/Documents/Meetings/raw`, `~/Documents/Meetings/published`) when that folder holds files. Three resolvers apply it, read at HEAD `0f141418` on 2026-11-26:

- Swift `LibraryDefaultPin.hasEntries(_:fileManager:)`: `guard let entries = try? fileManager.contentsOfDirectory(atPath: expanded) else { return false }`, used by `effectiveDefault` and `ConfigStore.pinLegacyDefaults`.
- Python `mp.config._has_entries`: `return any(entry.name != ".DS_Store" for entry in path.iterdir())` under `except OSError: return False`, used by `_pin_legacy_defaults` for both `recording` and `filesystem`.
- Shell `live_recording_output_dir` in `scripts/lib/live-recording.sh`: `[[ -d "$home/Documents/Meetings/raw" ]] && [[ -n "$(find ... -print -quit 2>/dev/null)" ]]`, else `~/Meetings/raw`.

Each turns "could not list the folder" into "the folder is empty". A missing folder (`ENOENT`) is correctly "no old library"; a permission or TCC denial, an `EIO`, or a folder that cannot be searched is not, but takes the same branch.

**Who is affected.** Only a `config.toml` with no `output_dir` (install.sh seeds the key, so a hand-made or trimmed config). Each process has its own Files and Folders answer for `~/Documents`: the daemon, its `mp` children, a launchd-spawned scheduled backup, and the owner's Terminal. One that is denied resolves to `~/Meetings/raw` while another records into `~/Documents/Meetings/raw`, so the two trees can disagree on the library root. [STOR6](./STOR6.md)'s 2026-11-21 amendment (M1, the launch pin that never reaches `config.toml`) narrows this once fixed: after a launch whose check succeeded writes the key, no resolver runs the rule again. Until then, and on any launch whose check failed, every run decides it afresh.

**The rebuild guard.** DIST9's 2026-11-26 fix taught `live_recording_manifests` to return "cannot tell" for a folder it cannot list or cannot see under a parent it cannot search. That only helps when it is handed the right folder. With no `output_dir`, a Terminal denied `~/Documents` fails the `[[ -d ]]` test, resolves to `~/Meetings/raw`, finds that absent under a listable `~`, and reports no live recording, so `rebuild.sh` and `install.sh` stop the daemon without asking while it records into `~/Documents/Meetings/raw`.

**DIST9's wording gap.** `guard_live_recording` prints, on a refusal with no TTY, "No terminal to ask on, so nothing was changed. Stop the recording first, or pass --force." for both verdicts. On the cannot-tell path, which DIST9 added, the preceding lines say the folder "could not be read, so a recording may be in progress", and "Stop the recording first" presumes one exists. The fix there is the folder's access, or checking the menu bar.

## Scope

1. In all three resolvers, only a folder that does not exist means "no old library". Any other listing error keeps the old default (the same answer as "it holds files"), since the old default is where an existing library would be. Swift: `contentsOfDirectory` in a `do`/`catch`, `false` only for `NSFileReadNoSuchFileError` / `ENOENT`. Python: `except FileNotFoundError: return False`, other `OSError` returns `True`. Shell: tell "absent under a listable parent" from "cannot list" the way DIST9's `live_recording_manifests` already does (reuse its predicate rather than a third copy of the rule), and keep `~/Documents/Meetings/raw` when it cannot tell.
2. Whether the pin (`ConfigStore.pinLegacyDefaults`) may write the old default into `config.toml` on a listing error: no. It writes only when the folder was actually listed and holds files; a listing error keeps the old default in memory and leaves the file alone, so a later launch with access decides properly.
3. In `guard_live_recording`, give the cannot-tell refusal its own last line, for example "No terminal to ask on, so nothing was changed. Give this terminal access to that folder, or pass --force." The pickup words it in the register of the lines above it.
4. Same commit: README's STOR6 paragraph in the privacy section ("a config that names no `output_dir` and whose old default already holds files has the old path written into it at the first launch") says what a folder that cannot be listed does, and the comments on the three resolvers match. At filing no doc quotes the refusal line (grep of README, `docs/`, and both gotchas files, 2026-11-26).

## Explicitly not

- STOR6's M1 amendment (the pin is a no-op under UX96's changed-only save): its own task text, unchanged here; this task only changes what the check answers.
- A `config.toml` that names `output_dir`: unaffected, no resolver runs the rule.
- Asking for Files and Folders access from the shell, or a doctor check for split roots: the second is a reasonable follow-up, not needed to stop the silent default.
- STOR6 item 4's Swift half (download-status checks before playback and transcription): still STOR6's.

## Acceptance

- `daemon/Tests/MeetingPipeTests/LibraryDefaultSTOR6Tests.swift`: `hasEntries` (or its replacement) over a chmod-000 old-default folder holding a file answers "keep the old default"; over an absent folder answers "new default"; `pinLegacyDefaults` over the chmod-000 folder writes nothing to `config.toml`. Skipped when run as root.
- `pipeline/tests/test_library_default_stor6.py`: the same three cases through `_pin_legacy_defaults` and `Config.load`, `iterdir` raising `PermissionError` via a chmod-000 folder.
- `scripts/test-rebuild-guard.sh`: `live_recording_output_dir` with no `output_dir` and an unlistable `$OLDH/Documents/Meetings/raw` resolves to the old default, and a stubbed `rebuild.sh` run in that layout with no TTY refuses (exit 2) with the cannot-tell last line, not "Stop the recording first".
- Each new case red against the pre-fix code.
- `cd daemon && swift build` and `swift test` green; `cd pipeline && uv run --extra dev ruff check src tests ../scripts`, `uv run --extra dev --extra mcp pyright` and `uv run --extra dev pytest -q` green; `bash scripts/test-rebuild-guard.sh` green; the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
