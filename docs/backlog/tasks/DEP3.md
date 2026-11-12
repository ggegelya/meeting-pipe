---
id: DEP3
title: The pipeline runs on Python 3.11, which holds numpy at 2.4 and reaches end-of-life in October 2027, while 3.12 is already inside requires-python
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-12 (upgrade review, owner approved): numpy 2.5.x requires Python >= 3.12, so the lock is stuck on 2.4.4, and 3.11 leaves security support in October 2027. Move the venv, CI's UV_PYTHON, pyright pythonVersion and ruff target-version to 3.12 together; requires-python already admits it.
---

# DEP3: the pipeline runs on Python 3.11, which holds numpy at 2.4 and reaches end-of-life in October 2027, while 3.12 is already inside requires-python

Band origin: filed 2026-11-12 from the dependency, platform and AI-model upgrade review (owner approved "File all proposed"). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Measured 2026-11-12:
- The owner's venv runs Python 3.11.15. `pipeline/pyproject.toml` declares `requires-python = ">=3.11,<3.13"`.
- PyPI's latest numpy, 2.5.4 (2026-10-10), declares `requires_python >=3.12`, so `uv.lock` resolves numpy 2.4.4.
- Python 3.11's security support ends in October 2027.

The interpreter version is stated in four places that must move together:
- `.github/workflows/ci.yml` sets `UV_PYTHON: "3.11"` on the pipeline job;
- `[tool.pyright] pythonVersion = "3.11"`;
- `[tool.ruff] target-version = "py311"`;
- the installer's venv. `scripts/lib/pipeline-venv.sh` names no interpreter, so uv picks one inside `requires-python`. The system Python 3.13 is outside the range, and the owner's venv landed on 3.11.15.

The darwin/arm64 mlx stack (mlx 0.31.2, mlx-lm 0.31.3, mlx-embeddings 0.1.0) declares `requires_python >=3.10` / `>=3.11`, so 3.12 is in range for all three.

## Scope

1. Move the four places above to 3.12. For the installer, pin the interpreter explicitly: a `pipeline/.python-version` or `UV_PYTHON` in `pipeline-venv.sh`, so the choice stops being uv's. Keep `requires-python` at `>=3.11,<3.13` unless the owner prefers `>=3.12`.
2. Re-lock and let numpy float to 2.5.
3. Rebuild the owner's venv through the installer path, not by hand.

## Explicitly not

- Not 3.13 or 3.14. `requires-python` caps below 3.13, and lifting that cap is a separate check of the mlx wheels.
- Not the anthropic cap lift (SEC19).

## Acceptance

- `bash scripts/ci-local.sh pipeline` is green under 3.12 locally, and the CI pipeline job runs 3.12.
- `uv.lock` resolves numpy >= 2.5.
- `bash scripts/test-app-relocation.sh --with-pipeline` is green, since this touches the venv the installer builds.
- A fresh `install.sh` venv reports Python 3.12.
- `docs/SETUP.md` stays true (it names no interpreter version today; update it only if the install steps change).
