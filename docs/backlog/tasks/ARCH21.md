---
id: ARCH21
title: Spike: write JSON Schemas for six per-meeting file kinds from CONVENTIONS alone and validate the real library counts-only, so the file contract has one executable owner
category: Architecture
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I29, 15.34 of 20, codebase-engineer pick; internal half only, no public "standard"): the audit calls the two-tree seam the main architectural cost (about 26 shared file kinds, about 18 mirrored rules, 10 of roughly 30 contracts fixture-pinned). 5 days: schemas for meta, transcript, speaker overlay, text-correction overlay, summary and publish result from CONVENTIONS.md without opening the writers; owner-run counts-only validator. Pass at 95% per kind and at most 10 violation classes puts the validator in truth_fences as ARCH10's typed owner; under 80% means do ARCH10 first. Child of [EPIC5](./EPIC5.md).
---

# ARCH21: spike, executable schemas for the per-meeting file contract

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I29, "Meeting bundle 0.1: write the per-meeting folder down as a spec with JSON Schemas and a validator, so the file contract has one owner"; the public-format framing is dropped on all three judges' advice). Child of epic [EPIC5](./EPIC5.md). `/spike` shaped. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**Is CONVENTIONS.md really the per-meeting file contract, measured as how much of the real library validates against schemas written from it alone?**

## Context and what changed

ADR [0003](../../decisions/0003-filesystem-library-source-of-truth.md) made files the source of truth; [ARCH10](./ARCH10.md) and [PIPE33](./PIPE33.md) (both P2, open) want a typed owner for the per-meeting contract on each side of the tree. Assets: the CONVENTIONS sections for meta.json, markers, diarize_cleanup, publish.json, evidence anchors and speaker enrollment; the 10 cross-tree golden fixtures in `daemon/Tests/MeetingPipeTests/Fixtures`; `scripts/gen_contract_fixtures.py`; `pipeline/src/mp/schemas.py`; `scripts/truth_fences.py` as the home for a schema fence. What changed: the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) put numbers on the seam (F129) and says every concrete defect it found sits where one rule exists twice. Known incoherences a schema must list as open issues, never freeze: F062 (index-keyed correction overlays), F107 (publishers ignore overlays), F019 (merge treats per-recording labels as global), G004 (name-keyed glossary beside UUID-keyed workflows), Swift as an unvalidated second writer of summary.json, and `try?` collapsing unreadable into absent at 37 read sites. Embeddings and voiceprints are specified as never-exported fields.

## Pre-registered verdict thresholds (copied from the report)

Write JSON Schemas for six file kinds (meta, transcript, speaker-label overlay, text-correction overlay, summary, publish result) from CONVENTIONS.md alone, without opening the writers. The owner runs a read-only validator over the real library that prints counts per file kind and per violated rule, never content.

| Verdict | Measured | Next |
|---|---|---|
| **PASS** | At least 95% of files of every kind validate AND no more than 10 distinct violation classes in total AND every file under `Fixtures/meta-contract` plus the example payloads in the publish-result, speaker-overlay and transcript-corrections golden fixtures validate unchanged AND the schema author needed no more than 5 source look-ups to resolve an ambiguity | The validator lands in `scripts/truth_fences.py` (or `ci-local.sh`) against the golden fixtures, and the schemas become the reference ARCH10 and PIPE33 implement against |
| **FAIL** | Under 80% on any kind, OR more than 15 source look-ups | The documents are not the contract: do ARCH10 internally first and publish nothing |
| Between | Otherwise | Record the classes; each becomes a CONVENTIONS fix or an open-issue line |

## Explicitly not

- A public "Meeting bundle 0.1" or any external standard (nobody else will adopt it; the return is internal).
- A code-generator dependency: schemas are JSON files, the validator is stdlib only.
- Fixing F062, F107 or F019 here; they are listed as open issues in the schema notes.

## Owner walkthrough

One command over the real library (written into the spike doc); the READ line prints PASS, FAIL or between with per-kind percentages and violation classes, no content.

## Deliverables and acceptance

- `docs/spikes/<id-lowercase>-meeting-file-schemas.md` with the thresholds verbatim and the look-up log.
- Six schema files and a stdlib-only counts-only validator; tests that every golden fixture validates and that a planted violation is reported by class; ruff green; on PASS the fence wired into `bash scripts/ci-local.sh` and green.
