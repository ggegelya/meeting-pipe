---
id: ARCH22
title: Split the 71k-line app executable into engine, library-files and UI targets so the compiler enforces boundaries, then add a headless entry point that starts, writes and stops a real recording under test
category: Architecture
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, the rewrite assessor's option 7 stages 1 and 2, "worth doing regardless"): one executable target with no access control lets a view rewrite a sidecar (F007, F061, F063, F066), and the recorder has no headless seam, so no test starts and stops a real recording (F110; MeetingRecorder at 17% line coverage). Stage 1 is target assignment in small landings sequenced by directory after the top data-handling fixes; stage 2 is one integration test over a synthetic source. Stage 3, a separate launchd agent with XPC clients, is explicitly not in scope. Child of [EPIC5](./EPIC5.md).
---

# ARCH22: split the app target and give the recorder a headless seam

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), "Radical options and their verdicts", option 7 "Headless daemon with thin clients: stage it", stages 1 and 2 only; the owner chose to file it on 2026-11-13). Child of epic [EPIC5](./EPIC5.md). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context, verified 2026-11-13

- `daemon/Package.swift` declares one executable target (`MeetingPipe`) plus `MeetingPipeCore` and an ObjC target. The 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md): the 71k-line single target has no access control, which is what lets a view rewrite a sidecar (F007, F061, F063 and F066 share the read-as-absent-then-rewrite shape); F110 and F151 (no test starts and stops a real recording; real daemon coverage 51%, MeetingRecorder 17%, Coordinator 0.3%); F049 (the 1,980-line session controller with 29 mutable flags), where F004, F005 and F046 sit.
- [ARCH7](./ARCH7.md) (P2) describes the session spine and the explicit state machine; [ARCH10](./ARCH10.md) (P2) the `MeetingFiles` owner type and single writers. This task is the target structure both land in; it does not replace either.
- MeetingPipeCore is the precedent for an island target with strict concurrency and pure `decide()` functions (`daemon/Sources/MeetingPipeCore/CLAUDE.md`).

## Scope

**Stage 1, target split** (2 to 3 weeks of small landings, per the assessor): library targets for an engine (session, recorder, post-processing, pipeline launch; no SwiftUI), a library-files target (ARCH10's `MeetingFiles` and single writers), and the UI on top, so access-control violations fail the build instead of being policed by text-grep fences. Start with the smallest target, the per-meeting file contract. Sequence by directory after the audit's top data-handling fixes, since the moves collide with concurrent fix work in the same files.

**Stage 2, headless seam** (about a week): a headless entry point over the engine so one integration test can start, write and stop a real recording from a synthetic audio source and assert the stereo file, the sidecar and the lifecycle events.

## Explicitly not

- Stage 3, the separate launchd agent with XPC clients: closed until a UI-less process is shown to get the Neural Engine on macOS 27.2 ([ASR8](./ASR8.md) measures the agent half) and the binaries have a stable signing identity, which is Developer ID, on the not-for-sale list. The report's idea I18 (headless capture agent) stays parked in [EPIC6](./EPIC6.md).
- Repairing the roughly 90 source-text fence tests that break on file moves: several are vacuous per the audit, so they are replaced by the stage-2 test or by access control rather than re-pointed, each replacement named in its commit.
- A language change of any kind.

## Acceptance

- Stage 1: each landing moves one directory or concern, keeps `swift build`, `swift build -c release`, `swift test` and `bash scripts/ci-local.sh` green, and states which text fence it retired in favour of access control. ARCHITECTURE.md's subsystem map updated in the same commit as each target appears.
- Stage 2: the headless recording test runs in `swift test` on CI (macos-15) without TCC grants, using a synthetic source; it fails if the recorder writes no audio, a mono file, or no sidecar.
