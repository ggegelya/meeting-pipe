# SEC23: every Preferences token edit rewrites all three API tokens through `security ... -w <value>`, putting them in `ps` output, and the daemon `setenv`s them into its own environment for every child to inherit

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S9, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) DI-17 and PP-11). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

SEC8 moved the tokens into the login Keychain and accepted two residuals in code comments. Both are wider than those comments say. Re-read on 2026-10-24:

**Argv exposure, three tokens at a time.** `SecretsStore` debounces every keystroke in any of the three token fields (`scheduleSave`, a 0.5 s `Timer`), then `persist()` calls `write` for `ANTHROPIC_API_KEY`, `NOTION_TOKEN` and `OPENAI_API_KEY` unconditionally. Each non-empty one runs `KeychainBackend.set`, which spawns `/usr/bin/security add-generic-password -U -s com.meetingpipe.daemon -a <account> -w <value>`. Its comment accepts that "the secret rides the argv here, so it is briefly visible in `ps`". So typing one character into the Notion field also republishes the Anthropic and OpenAI keys to any same-user `ps` reader, once per debounce.

**Process-wide environment.** `Secrets.loadIfPresent` (`Config.swift`) `setenv`s every managed key into the daemon at launch, and `AppDelegate`'s `secrets.didPersist` sink `setenv`s three of them again after each save. Every `Process()` the daemon starts inherits them unless the spawn site scrubs: SEC14 added `Secrets.scrubbedEnvironment` for the three ffmpeg spawns, and `PipelineLauncher.freshEnvironment` strips per SEC5 policy, but four other callers of `PipelineLauncher.freshEnvironment()` pass no strip flags and so hand every token over: `DoctorRunner`, `DoctorCommand`, `MCPStatusStore` (`mp mcp-serve --status`, which reads no token at all) and a spawn in `PreferencesView+Pipeline`. A Python child does not need the daemon's copy: `config.load_secrets` fills any missing managed key from the Keychain itself (a `security find-generic-password -w` read whose value comes back on stdout, not argv), and refills nothing once the egress guard is armed (SEC13). The only in-daemon reader is `NotionDatabaseList`, which does `ProcessInfo.processInfo.environment["NOTION_TOKEN"]`.

**Stale comments.** `AppDelegate`: "a missing secrets.env is normal on first run; the file is created (mode 0600) on the first Preferences save" (no such file since SEC8), and "PipelineLauncher.freshEnvironment also re-reads at spawn time" (it copies `ProcessInfo.processInfo.environment`; it reads nothing).

## Scope

1. **Write only what changed.** `SecretsStore` remembers the last persisted value per account and `persist()` writes (or removes) only accounts whose trimmed value differs. `didPersist` still fires.
2. **Keep the value out of argv.** `KeychainBackend.set` drives `security -i` and sends the `add-generic-password ... -w <value>` command on stdin, so `ps` shows only `security -i`. The pickup session verifies the quoting rule for that mode against a value with spaces and quotes, and rejects (with an error the Preferences field shows) any value it cannot quote safely; tokens are ASCII in practice. Moving to `SecItemAdd` was considered and rejected here: it changes the item's ACL subject from `/usr/bin/security` to the daemon's own identity, which is exactly the cross-tree contract `KeychainSecrets` documents, and the Python and bash readers would start prompting.
3. **Per-spawn environment.** Drop the `setenv` calls (launch and `didPersist`). `freshEnvironment` stops copying tokens from the process environment; `runMP` alone adds the tokens its SEC5 policy keeps, read from `SecretsStore`, and its strips keep working as today. The other four callers get no tokens, and their Python children read their own from the Keychain when they need one, as `load_secrets` already does. `NotionDatabaseList` reads the token from `SecretsStore` instead of the process environment.
4. Fix the two stale `AppDelegate` comments and `KeychainBackend.set`'s argv comment.

## Explicitly not

- The Keychain ACL trusting `/usr/bin/security`, so any same-user process can read the items with no prompt (PP-11's first clause). Closing that needs an app-specific ACL subject, which a self-signed identity makes fragile; it waits for D8 (Developer ID).
- The 14 hand-rolled `Process()` sites and their lifecycle: CONC5. This task touches only how env is built, and if CONC5's shared spawn helper lands first, step 3 goes through it.
- Python-side token handling (SEC13's scrub, `child_env()`): unchanged.

## Acceptance

- `SecretsStoreTests` (in-memory `SecretsBackend` fake that records calls): editing one field produces exactly one `set` for that account and none for the others; clearing a field produces one `remove`; an edit that trims to the stored value writes nothing.
- A `KeychainBackend` test with an injected runner: `set` launches `security` with argv `["-i"]` and the secret appears only in the stdin payload; a value that cannot be quoted is refused with an error.
- A test that the `runMP` environment carries exactly the tokens the SEC5 policy keeps (from a fake `SecretsStore`, with a base environment that carries none), and that `freshEnvironment()` with no arguments carries no managed key even when the base environment does.
- A grep fence (Swift test or `truth_fences.py`) that `setenv("ANTHROPIC_API_KEY"`, `setenv("NOTION_TOKEN"` and `setenv("OPENAI_API_KEY"` appear nowhere in `daemon/Sources`.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body; `bash scripts/ci-local.sh` green.
- Owner check (confirms): with `while true; do ps -axo args | grep -c "[a]dd-generic-password.*-w"; done` running, typing in the Notion field never shows a match, and a Notion publish and the database picker still work.

## Amended 2026-10-25 (observability audit band)

Two findings from the [observability audit](../../audits/2026-10-25-observability-audit.md) (SW-6, and the Keychain half of PY-9) widen this task's Keychain leg. The audit's skeptic pass confirmed that scope item 1 already covers the worst consequence SW-6 named, an unedited account deleted after a read that failed, because `persist()` will write or remove only the accounts whose value changed. What item 1 does not cover is below, re-read in code on 2026-10-25. All of it is low: the read collapse needs a locked Keychain or a failed `security` spawn at the moment of the read, and the one-time migration ran on this Mac on 2026-07-06 (`main.log`) and `~/.config/meeting-pipe/secrets.env` no longer exists.

### What is still wrong

- **Every read failure is "absent", on both sides.** `KeychainBackend.value(for:)` is `guard let result = Self.run([... "find-generic-password" ...]), result.status == 0 else { return nil }`, so not found (status 44), a locked Keychain, a denied ACL, and a spawn that never ran all become `nil`, and `SecretsStore.init` stores `""` for it. Python's `config._keychain_get` is the same: `except (OSError, subprocess.SubprocessError): return None` and `if out.returncode != 0: return None`, with the status and stderr discarded. The user is then told `$ANTHROPIC_API_KEY is not set. Set it in the daemon's Preferences...` (`MissingSecretError`) when the key may be set and unreadable, so the advice cannot fix it. The daemon's events.jsonl has `pipeline_failed` with exactly that text at 2026-10-16T09:46:34Z; which of the two it was cannot be told from the logs, which is the point.
- **Remove's result is discarded.** `KeychainBackend.remove` is `_ = Self.run(["delete-generic-password", ...])`, so a delete that failed reads as done.
- **Both migrations delete the file after a failed set.** `SecretsStore.migrateEnvFileIfPresent` runs `try? backend.set(value, for: key)` per key, then `try? FileManager.default.removeItem(at: url)`, then logs "migrated secrets.env into the Keychain and removed the file (SEC8)" whatever happened. Its "already present" test is `backend.value(for: key) == nil`, so a key that failed to read is overwritten with the file's older value. `scripts/install.sh` does the same in shell: `kc_set "$key" "$val" && say "  migrated $key"`, then `rm -f "$LEGACY_SECRETS"` regardless, and its `case` list (`ANTHROPIC_API_KEY|NOTION_TOKEN|HF_TOKEN`) omits `OPENAI_API_KEY`, one of the four `KeychainSecrets.managedKeys`, so that token is deleted with the file and never migrated.

### Added scope

5. **Typed reads.** `SecretsBackend.value(for:)` returns `found(String)`, `notFound` (status 44) or `unreadable(status, stderr)`. `SecretsStore` keeps the field empty for both of the last two but remembers which, and item 1's last-persisted map treats an `unreadable` account as untouchable: no set and no remove until the user edits that field. An unreadable read at launch writes a `main.log` line and `Log.event(category: "main", action: "keychain_read_failed", ...)` with the account name and status, never the value. `_keychain_get` logs the status for anything but 44, and `load_secrets` raises a distinct `KeychainUnreadableError` whose message says the token could not be read (not that it is unset) and names `security unlock-keychain`; the PIPE16 failure mapping treats it like `MissingSecretError`.
6. **Checked remove.** `remove` throws on a status other than 0 or 44, and `persist()` surfaces it like a failed set.
7. **Migrations delete only after every set succeeded.** The Swift migration removes `secrets.env` only when every managed key in it was set (or was already `found`), logs each failure, and leaves the file in place otherwise, retrying at the next launch. `install.sh` does the same and its `case` list becomes the four managed keys.

### Added acceptance

- `SecretsStoreTests` with the recording fake: an `unreadable` account at init is never set or removed by a save that edits another field; a migration whose second `set` fails keeps the file and logs the failure; a migration skips (does not overwrite) a `found` key and does not treat `unreadable` as absent.
- A `KeychainBackend` test with the injected runner that status 44 maps to `notFound`, 51 (or any other nonzero) to `unreadable`, and a failed delete throws.
- `test_config.py`: `_keychain_get` with a fake runner returning 44 is `None`, returning 36 (locked) raises `KeychainUnreadableError` from `load_secrets` with a message that does not say "not set".
- A shell test (or a `test-*.sh` beside the others in `scripts/`) that the install migration keeps `secrets.env` when `kc_set` fails and migrates `OPENAI_API_KEY`.
- `python3 scripts/truth_fences.py events` green for `keychain_read_failed`; `swift test` and `pytest -q` green with new test counts in the commit body.
- The run-all exit code on a missing secret (1 against the documented 2) is OBS3's, not this task's.
