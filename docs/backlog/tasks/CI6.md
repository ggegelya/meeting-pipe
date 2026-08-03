# CI6: tests and tooling that cannot fail, and one that has never run

Filed 2026-08-03 by the audit band. P3. From the angle that actually executed both suites on 2026-08-03: 1980 Swift and 1157 Python green, ruff and pyright clean, truth fences clean, both gate scripts pass. Coverage context only, not a finding: daemon 35.07% line / 43.56% region, pipeline 87% statement.

## 1. `scripts/coverage.sh` has never printed its Swift headline and exits 1

`scripts/coverage.sh:87` puts backslash-escaped quotes inside an f-string expression, which is a SyntaxError on every Python version. Verified 2026-08-03 by reading the raw bytes and reproducing the snippet standalone on Python 3.14.2 (exit 1), and by a scratch harness with the identical `set -euo pipefail` + function + `case` structure. Born in `f78ca057` on 2026-07-20 and never touched. `./scripts/coverage.sh swift` and `both` have always exited 1.

Narrower than it sounds, and recorded as such: no coverage number is lost. The per-module llvm-cov table at `:72-75` prints normally before the crash, and `:77-78` says the dead line only restates a number already in that table, so T3's acceptance ("prints per-module numbers for both trees") is genuinely satisfied. Fix is one line.

## 2. The window-title regression fence pins zero real captures and its progress test cannot fail

`daemon/Tests/MeetingPipeTests/WindowRecognizerFixtureTests.swift:10` states the fixture "is the ground truth from running apps". All 21 entries carry `"seeded": true` and none carries `false`, so no row was ever captured from a running app. The suite printed `[fixture] window_titles.json: 0/21 captured, 21 still seeded` on the 2026-08-03 run.

`WindowRecognizerFixtureTests.swift:72-75` is explicit that the progress test always passes: its only assertion is `XCTAssertGreaterThanOrEqual(total, 1)`, which the sibling test already guarantees.

So a Teams window-title change that the seeded guesses happen to model, but the real titles do not, degrades end-detection while all 21 rows stay green, and the one test that would tell a reader the fence is unbacked is written never to speak.

Fix: turn `test_fixture_capture_progress_is_logged` into an assertion with a pre-registered floor that fails while the captured count is zero, and soften the class docstring so it stops asserting ground truth the fixture does not have. Capturing real titles is VALOWN1's job and is owner-gated; note that HYG6 item 3 is fixing the paste path that would otherwise turn that capture into a red suite, so land HYG6 first.

## 3. The SEC13 entry-contract tripwire is a substring test

`pipeline/tests/test_entry_contract.py:62` is `if "entry.prepare" not in src:`, a raw substring test over module text. A mention in a docstring or a comment satisfies it, there is no AST check that a call node exists, and it asserts nothing about `prepare` running **before** the sink, engine or token work it is supposed to gate, which is the entire point of the contract.

Fix: parse the module and assert a real call node, and assert its position relative to the first client construction. LOCAL19 is adding a sibling constructor walk and should use the strengthened shape rather than copying this one.

## 4. `MeetingStore` can pick the wrong per-stem JSON as the transcript

`daemon/Sources/MeetingPipe/MeetingStore.swift:535-537` selects `files.first` matching `.json` with eight suffix exclusions, and the exclusions do not cover `.embeddings.json`, `.filesystem.json` or `.speaker_labels.json`. On a real meeting directory `files.first` can therefore return a sidecar carrying no `audio_seconds`, and the audio-less duration recovery silently yields nil.

Measured caveat, recorded: there are currently **0** audio-less stems that also carry an embeddings sidecar (4 audio-less out of 245, all predating the embeddings feature), so this is latent rather than active, and readdir order is not guaranteed. The test that pins the duration fallback cannot catch it because it builds a directory with only the files it expects.

Fix: exclude the three suffixes, and build the fallback test's directory from the real sidecar inventory rather than from a hand-listed subset.

## 5. `orchestrate._configure_logging` touches the production log path above its own guard

`pipeline/src/mp/orchestrate.py:109-112` does its `mkdir` and `touch` of `~/Library/Logs/MeetingPipe/pipeline.log` above the `if root.handlers: return` guard at `:117`, so a pytest run bumps the real file's mtime, and on a fresh checkout or a CI runner it creates the directory plus an empty `pipeline.log` under the process umask rather than the 0600 SEC14 shipped for that file.

Downgraded to low by a skeptic and recorded as such: **zero bytes are written**, no rotation runs and no generation is dropped, because pytest holds root handlers so the guard fires before the FileHandler. The mode divergence self-heals at the next daemon launch. Also note the claim that "every writer must honour `MEETINGPIPE_LOGS_DIR`" is not what the docs say: `pipeline/src/mp/events.py:8` explicitly carves the text logs out ("The text logs ... stay as-is for tail-based debugging; this module is for grep-based postmortem"). So this is a four-line tidy, not a contract violation.

Fix: move the two lines below the guard.

## Scope

All five. Each is independent and small.

## Acceptance

`./scripts/coverage.sh both` exits 0 and prints both headlines. The fixture progress test fails while the captured count is zero. The entry-contract test asserts a call node and its ordering, and fails against a module that only mentions `entry.prepare` in a comment. The transcript selector excludes the three suffixes and its test builds from the real inventory. A pytest run does not touch `~/Library/Logs/MeetingPipe`. Both suites green.
