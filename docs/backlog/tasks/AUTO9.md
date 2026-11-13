---
id: AUTO9
title: Spike: count real MCP use since 2026-08-18 as the agent lens's kill switch, and run a canary fence across every reader that can emit meeting text
category: Automation
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I08's two probe legs only, 15.34 of 20, codebase-engineer pick): every agent-memory idea waits on whether agents read the library at all, and the audit's second-ranked problem is privacy state leaking across meetings (F014, AUTO6). Leg 1 counts mcp_tool_called rows by week and tool (GO 100 calls on 10 days, NO-GO under 20 or under 6 days). Leg 2 is a fixture library with one canary per stance run through every reader; pass is zero leaks, and it stays as a standing fence. Tiers, client profiles and a read ledger only on a usage GO. Child of [EPIC3](./EPIC3.md).
---

# AUTO9: spike, MCP usage count and a cross-reader canary fence

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I08, "One read broker: narrowing tiers, client profiles, receipts and a read ledger"; only its two probe legs are filed now, as all three judges advised). Child of epic [EPIC3](./EPIC3.md). `/spike` shaped. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The questions

1. **Do agents read the library?** If they barely do, the read broker, the decision register ([AUTO10](./AUTO10.md)) and every other agent-memory idea should not be built.
2. **How many readers leak a withheld meeting's content today?** The count is the size of the broker work, and the fence pins it afterwards.

## Context, verified 2026-11-13

- `pipeline/src/mp/visibility.py` is the fail-closed gate; `mcp_tools.py` holds five tools wrapped with `wrap_untrusted`; `mcp_serve.py` emits `mcp_tool_called` (tool name, withheld hit, counts) and `mcp_serve_started` since the 2026-08-18 MCP commit. `mp.events.drop_test_residue` filters test rows.
- The owner chose fail-closed on 2026-07-27 and declined fail-open-on-unknowns, expose-everything and per-workflow opt-in; nothing here revisits that.
- Proven leaks in the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) (defect tasks being filed in parallel; search the backlog for the finding ID): F014 (series continuity sends a withheld meeting's decisions and action owners to the cloud), F005 and F046 (a workflow carried across meetings); [AUTO6](./AUTO6.md) (global regulated mode ignored for older meetings); [AUTO8](./AUTO8.md) (titles and `list_actions` text unfenced); [AUTO5](./AUTO5.md) records a client reading a transcript off disk instead of calling a tool, so a low usage count is ambiguous and an MCP gate binds MCP-only clients at best.

## Pre-registered verdict thresholds (copied from the report)

**Leg 1, usage kill switch (day one, owner-run, counts only).** Count `mcp_serve_started` sessions and `mcp_tool_called` rows in the pipeline event log since 2026-08-18 by week and tool, test residue excluded, earliest retained row's date printed beside the totals.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | 100 or more tool calls across 10 or more distinct days | The agent lens is live: tiers that only narrow a visible meeting, named client profiles in each launch entry, anchors and deep links in every payload, a per-read ledger row and a Diagnostics "what agents read" view, plus `verify_quote` over `evidence.resolve`, become a build task filed with the owner |
| **NO-GO** | Fewer than 20 calls or fewer than 6 distinct days | The broker, the decision register and the agent ideas in the parking epic wait |
| Between | Anything else | Recorded; owner decides |

**Leg 2, canary fence (agent-run, fixtures only).** A fixture library with one meeting per stance (NDA, regulated, no sidecar, visible), each with a unique canary string in transcript, summary, decisions and actions. Run every reader that can emit meeting text: the five MCP tools, ask, digest, summarize with series continuity, each cloud sink (mocked), and the paste bundle. A leak is a withheld canary reaching a cloud engine, a cloud sink or an MCP client, or one meeting's canary appearing in another meeting's run; an NDA meeting written to the local filesystem sink is correct. **Pass is zero leaks.** F014 and AUTO6 are expected to fail today; the failing-surface count is reported, each failure is handed to its defect task, and the fence lands as a standing test marked expected-to-fail per surface until that defect closes.

## Explicitly not

- Tiers or profiles before leg 1 says GO (more settings in a product with too many).
- An MCP write tool (idea I11, parked).
- Any change to the fail-closed decision of 2026-07-27.

## Owner walkthrough

Leg 1 is one command over the real event log (written into the spike doc); the READ line prints GO, NO-GO or between with call and day counts. Leg 2 needs no owner time.

## Deliverables and acceptance

- `docs/spikes/<id-lowercase>-mcp-usage-and-canary-fence.md` with both tables verbatim.
- The usage counter (read-only, residue-filtered, counts only) and the canary fence as a pytest module over a synthetic fixture library with no network (cloud engines and sinks mocked at the transport). ruff, pyright and pytest green, with the per-surface expected failures listed by defect.
- The fence runs inside `bash scripts/ci-local.sh pipeline`.
