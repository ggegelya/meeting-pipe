---
id: SEC32
title: Spike: kernel-enforced zero egress for the mp child under regulated and NDA policy, proven by a standing bypass harness, with a per-meeting egress receipt as the later leg
category: Security
status: partial
priority: P2
comment: Spike shipped 2026-11-17: docs/spikes/sec32-kernel-zero-egress.md plus the read-only probe pipeline/scripts/sec32_kernel_egress_probe.py. Smoke on this Mac (macOS 27.2): 10 of 10 planted bypasses blocked with EPERM under the profile against 2 of 10 for the armed-only guard, loopback control and storage check hold; the golden local summary and its overhead are not run. Owner-owed: `cd pipeline && uv run python scripts/sec32_kernel_egress_probe.py --transcript <synthetic transcript .md>`, then PASS (build the mp re-exec wrap under regulated and NDA) or close in favour of SEC19. [Spec](./SEC32.md)
---

# SEC32: spike, kernel-enforced zero egress for the pipeline child

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I01, "Kernel-enforced zero egress with a per-meeting egress receipt"; folds the distinct legs of its duplicate idea I31, "Egress receipts", and supersedes idea I15's wider airgap). Child of epic [EPIC3](./EPIC3.md). `/spike` shaped. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**Under a macOS sandbox profile that denies every non-loopback connection, is every planted bypass of the pipeline's egress guard blocked in the kernel while a local summary of a golden fixture still completes, so the kernel can be the enforcement and the Python guard only the readable error?**

## Context, verified 2026-11-13

- **Today's enforcement.** `pipeline/src/mp/egress_guard.py` (`arm`, `child_env`) patches httpx transports; `entry.prepare` is the single ordering point and `config.zero_egress` the single predicate. [SEC19](./SEC19.md) (P2) records that any urllib, requests or httpx2 path bypasses it and proposes an in-process `socket.connect` layer; [SEC18](./SEC18.md) covers file-mediated egress (synced folders, BYO bundles, backups); [EGRESS1](./EGRESS1.md) (P4) waived the wire check for the daemon. `summarize_local.py` already re-executes itself, which is the precedent for a sandboxed re-exec.
- **What changed since those tasks.** The 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) found 18 claimed fixes not holding and features walking around the gate, which argues for enforcement outside code that keeps changing; EGRESS1's own promotion trigger (an NDA meeting that depends on the claim) is met, since `visibility.py`'s docstring records NDA meetings in the library.
- **Observed on this host by the codebase-engineer judge (2026-11-12, commit 4949c9c0).** `/usr/bin/sandbox-exec` enforces on macOS 27.2: a profile denying outbound network except localhost returned EPERM for a non-local address and children inherited it. Two cautions that reshape the report's probe: a loopback-only profile still admitted this Mac's own interface address, so a canary on the Mac's LAN address cannot discriminate; and one extra allow clause made an earlier profile silently permissive. The harness, not the ten-line profile, is the piece to trust.
- **What a kernel deny cannot see** (stated in the receipt, never implied): F014, F005 and F046 are policy-layer leaks upstream of any network deny; SEC21 (NDA rule fails open) sits before classification; SEC18 and the iCloud-synced default library are file-mediated; capture, ASR, diarization, the Apple Intelligence summarizer and FluidAudio's model fetch run in the unconfined daemon.

## Pre-registered verdict thresholds (from the report, canary corrected per the judge's finding)

Build a harness of 10 planted bypasses (httpx direct, httpx through an ambient proxy variable, urllib, requests, raw socket, asyncio stream, ctypes connect, child curl, child Python, DNS lookup of a unique name) aimed at a canary listener that is NOT on this Mac's own interface address (a non-routable test address whose connect attempt is observed by the attempt itself: an EPERM against an ECONNREFUSED or timeout, plus a `sys.addaudithook` socket-connect recorder from idea I31 as a second witness). Run each with the guard armed only, then under the profile. Then run a local MLX summary of a golden fixture under the profile, and run the `cloudsync` check (`pipeline/src/mp/cloudsync.py`) against a scratch library with a planted synced-folder marker. Add idea I31's F014 replay: an earlier NDA meeting in the same workflow with the flag switched off afterwards, grepping the outbound request body for the withheld meeting's canary strings.

| Verdict | Measured | Next |
|---|---|---|
| **PASS** | 10 of 10 blocked under the profile, AND the golden summary completes with a schema-valid result, AND wall-time overhead under 5%, AND the storage check reports the planted synced folder as not confined | Build leg below. The armed-only score is recorded as the baseline |
| **FAIL** | `sandbox-exec` refuses on 27.2, or MLX and the loopback model server cannot run under the profile after 2 days of tuning | Stop; fall back to SEC19's in-process layer |

The F014 replay is expected to fail today; it is reported as a count of leaked strings and handed to the F014 defect, not counted against PASS, since a kernel deny cannot see it.

## Scope on PASS (same task, in order)

1. Under regulated or NDA policy `mp` re-executes itself under the profile; the harness becomes a standing CI fence in `scripts/ci-local.sh` (synthetic, no network needed).
2. Later leg, after ARCH10 gives per-meeting files one writer: `<stem>.egress.json` with four separate lines (pipeline network, daemon, storage location, sinks), each naming its enforcement layer and defaulting to the weaker word, and the Library showing the weakest line as Confined, Guarded or Left this Mac with destinations named.

## Explicitly not

- The durable replacements (App Sandbox entitlements, a NetworkExtension filter): they need a Developer ID, which is on the not-for-sale list; P3 if ever.
- Confining the daemon (idea I15); FluidAudio 0.14.8 under a network deny turns a model load error into a deleted cache with no refetch.
- Publishing the harness as a public conformance kit (idea I31's public half) while red rows are open.

**Progress (2026-11-17):** spike shipped probe-first, nothing built. The analysis doc has the decision tree, the closures (App Sandbox and NetworkExtension need a Developer ID, pf needs root, the daemon is not confined, re-exec chosen over in-process `sandbox_init`), the thresholds verbatim plus a pre-registered NOT PASS row for the gap the table left, and the profile text. The probe runs each of the ten bypasses armed-only and then under `sandbox-exec` with the guard off, classifies a case as blocked only on EPERM, adds an audit-hook witness and a loopback positive control, runs the storage check on a planted synced folder, and optionally the golden-summary leg through `docs/spikes/local12_bench.py`. Agent smoke (an instrument check, not the verdict): 2 of 10 blocked by the armed guard (httpx only), 10 of 10 blocked in the kernel, loopback ok, planted synced folder reported as not confined. Departures from the spec's wording: DNS is read through a control lookup because a unique name cannot tell blocked from NXDOMAIN, and the F014 replay is not in this probe (policy-layer, expected to fail, excluded from the PASS count; it goes to the F014 defect). The probe makes outbound attempts (the planted ones at the unrouted TEST-NET-1 canary, and two DNS lookups), so it is not in `ci-local.sh` until a PASS builds the offline fence.

## Owner walkthrough

None for the spike: synthetic content only, agent-run. The owner reads the PASS or FAIL line and approves the re-exec wrap before it lands.

## Deliverables and acceptance

- `docs/spikes/<id-lowercase>-kernel-zero-egress.md` with the thresholds verbatim, the profile text, and the two judge cautions.
- The harness under `pipeline/` (synthetic fixtures, no live library; the only outbound attempts are the planted ones aimed at the non-routable canary, plus one DNS lookup of a unique test name), ruff and pyright green.
- On PASS: the re-exec wrap with tests (wrapped under regulated and NDA, unwrapped otherwise, a refused sandbox fails closed with a named error), the harness wired into `scripts/ci-local.sh`, `bash scripts/ci-local.sh` green, README privacy section and [docs/SETUP.md](../../SETUP.md) stating exactly what is confined and what is not.
