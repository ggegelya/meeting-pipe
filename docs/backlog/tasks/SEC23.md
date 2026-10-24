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
