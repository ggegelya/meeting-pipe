# ADR 0005: No em-dashes in code, docs, or commit messages

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Accepted           |
| **Date**            | 2026-05-18         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Conventions        |
| **Related Tasks**   | TECH-F10           |

## Context

The project owner has a strong personal preference against em-dashes in
prose. The preference applies uniformly across the codebase: code
comments, documentation, commit messages, PR bodies, ADRs, and any
other text produced in this repository. Automated assistants (Claude
Code sessions, LLM-drafted commits) default to em-dashes in prose,
which makes the preference impossible to maintain through review alone.

## Decision Drivers

- **Consistency is the load-bearing property.** A document with mixed
  em-dash and hyphen usage reads worse than either choice applied
  uniformly.
- **Review fatigue.** Em-dashes are easy for a reviewer to miss in a
  large diff, especially in unrelated context lines. Automated
  enforcement catches them without reviewer effort.
- **LLM drift.** Sessions started fresh, without the project context
  loaded, will default to em-dashes. The lint is the backstop that
  keeps drift out of `main`.

## Options Considered

### Option A: Convention documented in CONVENTIONS.md, no automation

Pros: low friction. Cons: review catches some, misses many.
Em-dashes accumulate over time.

### Option B: Pre-commit hook only

Pros: catches the issue before commit. Cons: optional install; CI
still needs an enforcement point because not every contributor runs
the hook.

### Option C: CI check + optional pre-commit hook, both diff-based

Pros: CI is the binding gate, pre-commit gives local feedback. Diff
scope means historical em-dashes in untouched files do not have to be
backfilled.

## Decision

**Option C.** The CI workflow (`.github/workflows/ci.yml`, job
`conventions`) fails the build on any em-dash introduced in a PR or
push. The pre-commit hook (`scripts/pre-commit`) fires the same check
locally; install with `ln -sf ../../scripts/pre-commit
.git/hooks/pre-commit`. Both checks compare against the base ref so
only newly added lines are scanned.

## Consequences

- New em-dashes block the build. Hyphens, commas, or a sentence
  rewrite are the available substitutes.
- Historical em-dashes in untouched lines stay until the next time
  someone edits that line for an unrelated reason; backfilling is not
  a goal.
- The lint applies to commit messages too. A commit message with an
  em-dash will be flagged by the pre-commit hook (or the equivalent CI
  check on the merge commit).
- LLM-generated prose (including this document) is run through the
  same check; the convention applies to assistant output without
  exception.
