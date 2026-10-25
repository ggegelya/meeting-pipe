# HYG18: Fences and written rules are weaker than they read: the design-token fence's word-boundary alternatives never match under Apple Git, 32 user-visible lines carry em-dashes, and three rules are stronger as written than anything checks

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) CV2, CV6, CV9). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-checked on 2026-10-25 against `01e904a`.

**1. Three fence alternatives are dead on the owner's Mac.** `ci-local.sh`'s `design_tokens` job greps `daemon/Sources` with `git grep -nE`. The DSN3 pattern ends in `tint: \.(red|orange|green)\b|return \.(red|orange|green)\b` and the DSN18 pattern in `return \.(secondary|tertiary|quaternary)\b`. macOS's ERE has no `\b`, so under Apple Git those three alternatives match nothing, while the rest of each pattern still works. Reproduced in a scratch repo with git 2.50.1 (Apple Git-155): `tint: .red`, `return .orange` and `return .secondary` give no hit (exit 1) while `Color.red` and `.foregroundStyle(.secondary)` still do; the same three lines hit under `git grep -P`, `[[:>:]]` and BSD `grep -E`, and `git grep --no-index` fails the same way. CI runs the job on `ubuntu-latest`, where glibc supports `\b`, so a local `ci-local.sh fences` is weaker than CI, the direction that hides a regression. `git grep -P` finds no hit for the three in today's tree, so nothing has slipped through yet.

**2. Em-dashes in text a user reads.** `daemon/Sources` and `daemon/Resources` have 0 lines with U+2014 and the pre-commit hook keeps them there. `pipeline/src` has 57 and `scripts/` 12, almost all comments and docstrings, which [HYG11](./HYG11.md) leaves unswept on purpose. 32 lines are user-visible:
- `mp doctor`, 21: the `_ok`, `_warn`, `_fail`, `_info` and `print` calls across the secret, config, Anthropic, OpenAI, Notion, HuggingFace and ScreenCaptureKit checks, plus the `mp doctor` preflight banner `main` prints first. The in-app doctor sheet shows this output.
- `mp --help`, 1: `__main__.USAGE`'s first line, which joins `mp` and `meeting-pipe pipeline` with one.
- The BYO bundle, 3: two lines of `orchestrate._write_manual_bundle`'s `<stem>.READY_FOR_MANUAL.md` body and `_read_meeting_summary_prompt`'s fallback string.
- Run log lines, 3: `orchestrate`'s "Transcript has no speaker turns", "BYO summary requested" and `skip_above_chars` messages, which reach stderr and `pipeline.log`.
- A published placeholder, 1: `publish_from_paste`'s "no summary section detected" bullet, which lands in the user's Notion or Obsidian note.
- Scripts, 3: `rebuild.sh`'s missing-plist `die` and `tail-events.sh`'s two hints.

**3. Three written rules stronger than what holds.**
- `CONVENTIONS.md` "Test file naming": "One test file per production type that has logic worth unit-testing." Of 245 `*Tests.swift` files, 53 are not named for any type declared in `daemon/Sources` (by name match): fences (`CoordinatorWiringFenceTests`, `TutorialFenceTests`), contract fixtures (`CI4ContractFixtureTests`, `MetaContractFixtureTests`), cross-type integration suites (`CoordinatorMicGateIntegrationTests`) and task-pinned suites (`MeetingRecorderPinsARCH8Tests`). These are legitimate; the rule is what is wrong.
- `CONVENTIONS.md` "Test discipline" ("No live HTTP, no network sockets") and `pipeline/CLAUDE.md` ("no real network sockets"): `test_engine`, `test_summarize_local` and `test_summarize_staged` each bind `ThreadingHTTPServer(("127.0.0.1", 0), ...)` as a fake model server. Loopback is the sanctioned pattern in practice and nothing forbids it.
- `pipeline/CLAUDE.md`: "Don't spawn a subprocess with an inherited env." Eight `subprocess.run` calls in `src` pass no `env`: `config._keychain_get` (`security`), `doctor.check_claude_cli` (`claude --version`), `doctor._mdfind_app_bundles`, `local_server.pid_command` and `listening_pid` (`ps`, `lsof`), `resource_guard.physical_ram_bytes` and `sample_memory`, and `train_adapter.main` (`mlx_lm.lora`). `egress_guard.arm` already scrubs `os.environ` itself, so an inherited env after arming carries no token; `child_env` exists for a token loaded after arming. Seven are local probes with no network path. `train_adapter.main` is the one child that can fetch weights.

**4. The island rules hold with no fence.** `MeetingPipeCore/CLAUDE.md` says TOMLKit is the only third-party dependency, there is "exactly one `import AppKit`, in `Lifecycle/Signals/WorkspaceSignal.swift`", no SwiftUI, and strict concurrency stays on. All true today: Core imports `Foundation` (38 files), `ApplicationServices` (9), `CoreAudio` (7), and `os`, `TOMLKit`, `ScreenCaptureKit`, `CoreGraphics` and `AppKit` once each; `Package.swift` gives the target only TOMLKit and `-strict-concurrency=targeted`. Nothing fails if a second `import AppKit` lands.

Re-checked at filing: the test-naming exceptions are 53 by name match (the audit said 51), and the socket exceptions are three files binding loopback servers (the audit said 5).

## Scope

1. **Fence.** Replace each `\b` with `([^A-Za-z0-9_]|$)`. Move the two patterns into shell variables, and add a self-test step before them: write a probe file to a temp dir with one line per alternative (`tint: .red)`, `return .orange`, `return .secondary`) and one near miss (`return .redder`), run `git grep --no-index -nE "$pattern"` on it from inside that temp dir (inside the repo, `--no-index` refuses a path outside the work tree), and fail the job unless every positive matches and the near miss does not. That self-test is what would have caught this, and it runs on both runners.
2. **Em-dashes.** Rewrite the 32 lines above with a hyphen, comma or colon, nothing else. Strings only; no comment or docstring sweep.
3. **Rules to match what is enforced.** "Test file naming": a unit-test file is `<TypeUnderTest>Tests.swift`; fences, contract fixtures and cross-type integration suites are named for what they pin. "Test discipline" and `pipeline/CLAUDE.md`: no live HTTP and nothing beyond loopback; a fake server on `127.0.0.1:0` is the sanctioned way to test an HTTP client. `pipeline/CLAUDE.md`'s spawn rule: a child that can reach the network (the model server, a CLI provider, a trainer) gets `env=egress_guard.child_env()`; a local system probe may inherit. Route `train_adapter.main`'s spawn through `child_env()`, which is identical when the guard is not armed. Keep each `pipeline/CLAUDE.md` entry under CI5's 800 B.
4. **Island fence.** A check in `scripts/truth_fences.py`, inside the `sources` check [HYG10](./HYG10.md) adds if that has landed, or as an `island` check run by `both` if not: every `import` under `daemon/Sources/MeetingPipeCore` is in an allowlist (the eight modules above), `AppKit` appears only in `WorkspaceSignal.swift`, no `SwiftUI`, and `Package.swift`'s `MeetingPipeCore` target lists only the TOMLKit product and still passes a `-strict-concurrency=` flag (`targeted` or stricter, so [CONC6](./CONC6.md) raising it does not trip the fence). `MeetingPipeCore/CLAUDE.md` names the fence. If the check is a new subcommand, the root `CLAUDE.md` truth-fences row lists it.

## Explicitly not / out of scope

- The six docs that say CI blocks em-dashes, and any em-dash hook: HYG11. The owner dropped the CI em-dash job on 2026-08-18, so this task adds no em-dash fence either.
- `daemon/CLAUDE.md`'s size: [DOC15](./DOC15.md). Nothing here adds to that file.
- The 25 comment and docstring em-dash lines left in `pipeline/src`, the 9 in `scripts/` comments, and the 42 in the two test trees. `publish_from_paste`'s action-item regex, whose character class holds an em-dash and a hyphen, parses user input and keeps accepting an em-dash.
- `prompts/meeting_summary.md`'s two em-dashes. The prompt is sent to the model, so changing it is a summary-behaviour change, not hygiene; observed, not filed.
- Making the other seven spawns use `child_env()`, and the "decisions are pure" island rule, which a grep cannot check.

## Acceptance

- On the owner's Mac, `bash scripts/ci-local.sh design-tokens` fails on a planted `return .orange` in `daemon/Sources` (tried and reverted, said in the commit body), and the self-test step fails if one pattern is put back to `\b`.
- `git grep -nF` for U+2014 over `pipeline/src/mp/doctor.py`, `__main__.py`'s `USAGE`, `scripts/rebuild.sh` and `scripts/tail-events.sh` returns nothing; `mp doctor` and `mp --help` output carries none.
- The island check fails on a planted `import AppKit` in a second Core file and on a planted `import SwiftUI` (both tried and reverted), and passes on today's tree.
- `bash scripts/ci-local.sh fences` and `python3 scripts/truth_fences.py` green; `cd pipeline && uv run --extra dev pytest -q` green with no test count change from the string edits.
