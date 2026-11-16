# SEC32 spike: kernel-enforced zero egress for the pipeline child

Spike, 2026-11-17. Probe: [`pipeline/scripts/sec32_kernel_egress_probe.py`](../../pipeline/scripts/sec32_kernel_egress_probe.py) (owner-run, read-only, stdlib plus the pipeline venv's httpx and requests, not in CI). Epic: [EPIC3](../backlog/tasks/EPIC3.md). Fallback if this fails: [SEC19](../backlog/tasks/SEC19.md)'s in-process socket layer. Nothing here changes production behaviour; no kernel deny is built before the verdict.

## The question

**Under a macOS sandbox profile that denies every non-loopback connection, is every planted bypass of the pipeline's egress guard blocked in the kernel while a local summary of a golden fixture still completes, so the kernel can be the enforcement and the Python guard only the readable error?**

## Why this is a spike, and what part of it this harness could already answer

The decisive number is a golden local summary run through MLX under the profile, with its wall-time overhead, which needs the owner's cached local model and the owner's Mac; that is the part only the owner can measure. The bypass half is runnable anywhere `sandbox-exec` works, so it was run on the development Mac as a smoke test of the instrument (below). That smoke is evidence about the instrument, not the verdict: the verdict needs the summary leg, and it is the owner's to read.

## What closes without a measurement

- **App Sandbox entitlements and a NetworkExtension filter** are the durable replacements, and both need a Developer ID, which the root `CLAUDE.md` selling rule defers. Closed here, P3 if ever.
- **`pf` or any firewall rule** needs root and is machine-wide, not per run. Closed.
- **Confining the daemon.** FluidAudio 0.14.8 under a network deny turns a model load error into a deleted cache with no refetch (SEC36's gotcha), and the daemon owns capture. Closed; the wrap is the `mp` child only.
- **`sandbox_init` inside the process versus `sandbox-exec` re-exec.** Both are the same private Seatbelt mechanism, so the deprecation risk is identical; the re-exec has the precedent (`summarize_local.py` already re-executes itself) and keeps the profile out of the process it constrains. Re-exec chosen.
- **The profile is inherited by children** (the 2026-11-12 judge observed it on macOS 27.2), which is why `child_curl` and `child_python` are in the ten.
- **What a kernel deny cannot see**, stated up front so no PASS is read wider than it is: F014, F005 and F046 (policy-layer leaks upstream of any network call), SEC21 (the NDA rule failing open before classification), SEC18 and the synced default library (file-mediated egress), and capture, ASR, diarization, the Apple Intelligence summarizer and FluidAudio's model fetch in the unconfined daemon.

## The decision tree

1. `sandbox-exec` refuses on this macOS: **FAIL**, fall back to SEC19.
2. Every planted bypass blocked with EPERM under the profile, loopback still connects, the golden summary completes and validates, overhead under 5%, and the storage check reports a planted synced folder as not confined: **PASS**, build the re-exec wrap.
3. Anything else: **NOT PASS**, tune the profile inside the 2 day budget and rerun; a bypass no profile closes, or MLX and the loopback server unable to run under any profile that blocks the rest, is the **FAIL** condition.

## Pre-registered verdict thresholds

Written before any owner measurement and not to be edited after one. The first two rows are the task's table verbatim; the third is the pre-registration of the gap the table leaves.

| Verdict | Measured | Next |
|---|---|---|
| **PASS** | 10 of 10 blocked under the profile, AND the golden summary completes with a schema-valid result, AND wall-time overhead under 5%, AND the storage check reports the planted synced folder as not confined | Build the re-exec wrap (SEC32's scope on PASS). The armed-only score is recorded as the baseline |
| **FAIL** | `sandbox-exec` refuses on 27.2, or MLX and the loopback model server cannot run under the profile after 2 days of tuning | Stop; fall back to SEC19's in-process layer |
| **NOT PASS** (not FAIL yet) | fewer than 10 blocked, or the summary invalid, or overhead 5% or more, or loopback blocked, inside the 2 day tuning budget | Tune the profile (printing it verbatim is part of the report) and rerun; every edit is a new measurement |

Two definitions the probe applies, fixed here: a case is **blocked** only when the attempt itself failed with EPERM ("Operation not permitted", what a Seatbelt deny returns), never on ECONNREFUSED, ENETUNREACH, a timeout or success, which all mean the connect left the process; and the profile leg runs with the in-process guard **not** armed, so the kernel alone is what is measured. A `sys.addaudithook` recorder is the second witness that an attempt was made (it cannot see the two child cases, which are classified from the child's own stderr).

The F014 replay the spec asks for (an earlier NDA meeting with the flag switched off afterwards, grepping an outbound request body for the withheld meeting's canary strings) is **not in this probe**. It needs an NDA workflow and a request-body capture, it is expected to fail today, and the spec already excludes it from the PASS count because a kernel deny cannot see it; it goes to the F014 defect as its own replay.

## The two cautions from the 2026-11-12 judge, and how the probe honours them

- **A loopback-only profile still admitted this Mac's own interface address**, so a canary on the Mac's LAN address cannot discriminate. The canary is `192.0.2.1` (and `192.0.2.2` for the proxy case), TEST-NET-1, reserved and never routed.
- **One extra allow clause silently turned an earlier profile permissive.** So the profile is four lines, printed verbatim by every run, and the positive control `loopback_control` proves the one allow clause works without widening anything: under the profile a process must still connect to its own loopback listener (the local model server and its client do exactly that), and the probe reports NOT PASS if it cannot.

## The profile

```
(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote ip "localhost:*"))
```

`allow default` keeps the interpreter, the venv and Metal working; the deny and the single loopback allow are the whole policy.

## The ten planted bypasses

httpx direct; httpx through an ambient `HTTP_PROXY` (aimed at the canary proxy address); urllib; requests; raw socket; asyncio stream; ctypes `connect()` straight into libc; child `curl`; child Python; and a DNS lookup. The DNS case reads differently from the other nine because a lookup of a unique name alone cannot tell "blocked" from NXDOMAIN: the probe also resolves a fixed control name (`example.com`), and DNS counts as blocked only if the control resolved in the armed-only baseline and fails under the profile. If the baseline control does not resolve the Mac is offline and the probe says the DNS case cannot be read. This reads the spec's "DNS lookup of a unique name" with a control added, and it is the one place the probe departs from the spec's wording.

## Smoke measured on the development Mac (2026-11-17, macOS 27.2): instrument check, not the verdict

| | armed-only guard | kernel profile |
|---|---|---|
| httpx direct, httpx via proxy env | blocked by the guard | blocked (EPERM) |
| urllib, requests, raw socket, asyncio stream, ctypes `connect`, child curl, child Python, DNS | **reached the network** | blocked (EPERM; DNS control failed) |
| score | 2 of 10 | **10 of 10** |

Loopback control under the profile: connected. Storage check on a planted `~/Library/CloudStorage/Dropbox-*` folder: reported as synced by Dropbox, so not confined. The baseline row is SEC19's whole argument in one column: the in-process guard sees httpx and nothing else. Not measured here and owed: the golden summary under the profile, and its overhead.

Two instrument bugs the smoke found and fixed, recorded because they change how to read the output: the ctypes case used a blocking `connect()` and hung for the kernel timeout (now non-blocking), and `curl -sS` hides the errno (now `-sSv`, whose "Immediate connect fail ...: Operation not permitted" line is what is classified).

## Owner-owed remainder: one command

The golden summary leg needs a small synthetic transcript and the cached local model (the 3B per SEC27). From the repo root:

```bash
cd pipeline && uv run python scripts/sec32_kernel_egress_probe.py --transcript <a synthetic transcript .md>
```

It runs the ten cases twice, the loopback control, the storage check, and `docs/spikes/local12_bench.py` over the transcript open and then under the profile. Its last line is the READ, mapped onto the table above:

- `READ: PASS ...`: build the re-exec wrap (`mp` re-executes itself under the profile when `config.zero_egress` is true, a refused sandbox fails closed with a named error, the harness becomes a standing fence in `scripts/ci-local.sh`, README and SETUP say exactly what is confined and what is not), then the later receipt leg after ARCH10.
- `READ: NOT PASS ...`: tune the profile and rerun, inside the 2 day budget.
- `READ: FAIL ...`: close SEC32 and build SEC19's in-process layer instead.

If no synthetic transcript is to hand, the probe without `--transcript` still prints `PASS PENDING` once the bypass half holds, which is the state it is in on the development Mac today.

## Docs checked

README, ARCHITECTURE, CONVENTIONS and SETUP are unaffected (production is untouched, and the probe is not in CI). `scripts/ci-local.sh` deliberately does not run it: it makes outbound attempts, so it stays owner-run until a PASS builds the offline, synthetic fence the spec describes.
