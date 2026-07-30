# LOCAL17: Retrain the LoRA when a post-FEAT10 evidence-bearing corpus exists

Band origin: filed 2026-07-30 at the owner's request, off the LOCAL9 close the same evening ("fill a task for this to not forget one day revisit it. at the bottom of backlog. with lowest priority"). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

LOCAL9 closed 2026-07-30 as its pre-registered honest negative (full trail in [`q6-final.md`](../q6-final.md), search LOCAL9): the first real training run produced an adapter that lost to the base model on the valid curve, the held-out test triple, and the dogfood side-by-side. The close matters here because it separated the mechanism from the corpus: distillation demonstrably worked (the adapter shifted to cloud-style specificity and normalized the spoken "second three one zero" into ticket 2310), while the corpus failed it in two measured ways. Every training pair predated FEAT10, so the adapter faithfully learned to emit **zero evidence anchors**, a regression against the product's current summary contract; and the 32 GB memory ceiling (`--max-seq-length 8192 --batch-size 1` is the measured maximum; a 12288 backward does not fit at any batch size) kept only 42 of 176 pairs, all short meetings, and 3+ epochs over 33 train examples memorized rather than generalized.

So this is not "try again later and hope": it is "retrain when the textbook is fixed". Evidence-bearing summaries have been accumulating since FEAT10 shipped on 2026-07-24, and every cloud-summarized meeting adds one.

## Promotion trigger (check before doing anything)

Promote when a dry-run reports **at least 100 kept pairs whose summaries carry evidence anchors**, or when the training machine gains materially more RAM (which lifts the 8192 ceiling and readmits the long meetings). As of filing the count is 42 kept pairs with 0 evidence-bearing. Rough arithmetic: at the owner's meeting rate this is quarters away, not weeks, which is why the row sits at the bottom on P3.

## Scope, when promoted

1. Add a `--since <date>` filter to `train_adapter`'s pair builder (tiny, sibling to `--source`), so the run can exclude the pre-FEAT10 evidence-free era instead of diluting the new corpus with it. This is the only code item.
2. Rerun the LOCAL9 protocol exactly, all of it pre-registered there: train at `--max-seq-length 8192 --batch-size 1` under caffeinate + the free-RAM watchdog (group-kill wrapper, preflight orphan sweep), then the loss triple (base via the zero-weight-adapter trick, since `mlx_lm.lora --test` unconditionally loads an adapter), then `mp dogfood --adapter` on an untrained anchor, then the owner hand-grade. Prefer the 100-iter-class checkpoint if train loss memorizes again.
3. Adopt via `summarization.local_adapter_path` only on a win; a second honest negative closes this permanently with "the lever for local quality is the base model (LOCAL13), not an adapter".

## Explicitly not in scope

Training before the trigger fires (a third run on a known-bad corpus spends hours to relearn the same close). Raising `--max-seq-length` past 8192 on a 32 GB machine (measured, not guessed). Re-litigating the LOCAL9 close. Any change to the serving seam (LOCAL15's `adapters`-per-request already works and was verified end to end).

## Acceptance

The trigger measurement is recorded (kept-pair count and evidence-bearing count at promotion time). The `--since` filter lands with a test. The retrain produces the loss triple and one dogfood A/B, and the owner's grade decides adoption; both outcomes are valid terminals, and either way this task closes with the numbers in the archive entry.

## Owner walkthrough (for the session that picks this up)

Added at filing per the 2026-07-30 convention. Steps tagged [owner] / [session].

1. [session] Check the trigger first: `cd pipeline && uv run mp train-adapter --source runs --adapter-path /tmp/l17probe --max-seq-length 8192 --dry-run`, note the kept-pair count, and count how many kept stems date after 2026-07-24. Under 100 evidence-bearing: report the number and stop; the task stays deferred.
2. [owner] Nothing until the trigger is met: normal meeting life is what grows the corpus.
3. [session, on promotion] Build the `--since` filter, then run the LOCAL9 protocol end to end (train, triple, A/B); the LOCAL9 archive entry is the runbook, including every pitfall already paid for.
4. [owner] Grade the A/B side-by-side and call adopt or close-permanently.
