---
id: DIST7
title: Supply-chain pins have four gaps outside uv.lock: the hatchling build backend, the speech models' `resolve/main` fetch, the git-ignored Package.resolved, and CI actions pinned by tag with no permissions block
category: Distribution
status: new
priority: P3
comment: Filed 2026-11-12 ([security review](../../audits/2026-11-12-security-review.md), informational): each needs an upstream compromise first, so none is a concrete exploit, and local builds stay pinned and fingerprint-checked. Pin hatchling with a hashed build constraint, hash-check FluidAudio models, commit Package.resolved and use exact: for TOMLKit, SHA-pin actions and add permissions: contents: read. Parked as hardening. [Spec](./DIST7.md) Amended 2026-11-12 (upgrade review): the three actions are also majors behind (checkout v4 to v7.0.1, setup-python v5 to v7.1.0, setup-uv v3 to v10.3.3) and CI warns they are forced from Node 20 to Node 24; bump the majors in the same pass as the SHA pins, and FluidAudio 0.15.8 already pins diarizer artifacts (ASR6).
---

# DIST7: supply-chain pins have four gaps outside uv.lock: the hatchling build backend, the speech models' `resolve/main` fetch, the git-ignored Package.resolved, and CI actions pinned by tag with no permissions block

Band origin: filed 2026-11-12 from the [2026-11-12 security review](../../audits/2026-11-12-security-review.md), informational findings. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified 2026-11-12; each gap needs a third party compromised first, so this is hardening, parked at P3:

1. **hatchling.** `pipeline/pyproject.toml` has `requires = ["hatchling"]` with no version and `uv.lock` has no hatchling entry. `scripts/lib/pipeline-venv.sh` runs `uv sync --frozen --no-editable --reinstall-package meeting-pipe`, which builds the project each time in an isolated environment with whatever hatchling PyPI serves; `bundle-runtime.sh`'s `pip install --no-deps "$REPO_ROOT/pipeline"` does the same outside `--require-hashes`. This also makes [DIST5](./DIST5.md)'s "both install paths consume the lock" slightly inaccurate.
2. **Speech models.** `PrefetchModelsCommand` calls FluidAudio's `AsrModels.downloadAndLoad` and `DiarizerModels.downloadIfNeeded`; FluidAudio's `ModelRegistry` builds `.../resolve/main/<file>` URLs and `DownloadUtils` checks presence only, no hash. CoreML models cannot carry code, so a swap means wrong transcripts or speaker labels, not execution. The embedder (`embed_index.MLXEmbedder`) floats `main` the same way.
3. **Package.resolved.** `.gitignore` ignores `daemon/Package.resolved`; `Package.swift` has TOMLKit `from: "0.6.0"` (anything below 1.0) and FluidAudio `exact: "0.14.8"` (a tag). The owner's local file and SwiftPM's fingerprint store (strict by default) keep local builds pinned; a fresh clone or a CI runner re-resolves.
4. **CI.** `.github/workflows/ci.yml` uses `actions/checkout@v4`, `actions/setup-python@v5`, `astral-sh/setup-uv@v3` by tag and has no `permissions:` block. No secrets, no `pull_request_target`, `BEFORE` passed through `env:`.

## Scope

1. Pin hatchling to an exact version with a hash via uv's build constraints, and make `bundle-runtime.sh` install the project from the locked backend; correct DIST5's sentence.
2. After FluidAudio downloads, check each model file against a pinned sha256 table in the daemon; fail the prefetch with a message naming the file on mismatch. Same for the embedder snapshot (pin a revision).
3. Commit `daemon/Package.resolved`, drop it from `.gitignore`, change TOMLKit to `exact:`, and build with `--only-use-versions-from-resolved-file` in `install.sh`, `rebuild.sh` and `ci-local.sh`.
4. Pin the three actions by commit SHA (tag in a trailing comment) and add `permissions: contents: read` at the workflow top.

## Explicitly not

- The local LLM's floating `main`, which is code execution: [SEC27](./SEC27.md).
- The python-build-standalone tarball checksum: [DIST1](./DIST1.md)'s 2026-11-12 amendment.

## Acceptance

- `bash scripts/ci-local.sh` and CI green after each item; `git check-ignore daemon/Package.resolved` returns nothing.
- A daemon test that the model hash check rejects a file whose sha256 differs from the table, with an injected file reader.
- A `truth_fences.py` or shell check that `ci.yml` uses no `uses: <action>@v<N>` form and declares `permissions:`.

## Amendment 2026-11-12 (upgrade review)

**Actions are majors behind, not just tag-pinned.** Latest releases on 2026-11-12:
- `actions/checkout` v7.0.1 (we use `@v4`);
- `actions/setup-python` v7.1.0 (`@v5`);
- `astral-sh/setup-uv` v10.3.3 (`@v3`).

CI run 43189769485 (2026-11-12) annotates: "Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on Node.js 24: actions/checkout@v4, astral-sh/setup-uv@v3". It also annotates that `ubuntu-latest` migrates to Ubuntu 26 from 2026-10-19.

Added scope:
- Item 4 pins the **current** majors' commit SHAs, not v4/v5/v3.
- Name the runner image explicitly (`ubuntu-26.04` or the chosen one) rather than `ubuntu-latest`.
- CI11 adds setup-uv's `version:` input on the same line.

**Speech-model artifacts.** FluidAudio v0.15.8 (2026-09-20) pins diarization artifacts to an immutable revision (upstream #927). So the diarizer half of item 2 arrives with ASR6's bump; the ASR model fetch and the embedder snapshot remain this task's.
