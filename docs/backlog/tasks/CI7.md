# CI7: `uv sync` cannot build the pipeline package inside a worktree, so the documented verification commands do not run there

Band origin: filed 2026-08-15 (found by three of four parallel sessions in one `/tech-task` batch: PIPE17, LOCAL19, DET10, DET11). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

`pipeline/pyproject.toml:6` is `readme = "../README.md"`. Current hatchling refuses a readme outside the project directory and fails the build with `ValueError: Readme path must be within the project directory: ../README.md`. The package therefore cannot be installed from any checkout whose venv is built today, which in practice means every `git worktree` under `.claude/worktrees/`.

The main checkout does not show the symptom. Its `pipeline/.venv` predates the hatchling version that added the check, so it keeps working and the breakage is invisible from the place the owner normally stands. That is why this survived long enough for four sessions to hit it at once.

Two things this collides with, both in root `CLAUDE.md`:

- The "Verify before declaring done" table names `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev pyright`, and `uv run --extra dev pytest -q` as the verification commands. None of the three runs in a worktree, because `uv run` builds the project first.
- The "Git workflow" section mandates that parallel sessions each run in a worktree under `.claude/worktrees/`. So the workflow the repo requires and the verification the repo requires cannot both be satisfied as written.

CI never hits this. `CLAUDE.md:45` records that CI deliberately installs only light deps and bypasses `uv sync` so the darwin/arm64-only packages never download on the Linux runner. That is an unrelated reason with the accidental effect of hiding this defect from the one gate that would otherwise catch it.

Pinning `hatchling<1.27` through `UV_BUILD_CONSTRAINT` was tried on 2026-08-15 and did not help.

## The workaround in use, for the pickup session's reference

`uv sync --extra dev --no-install-project` inside the worktree installs lock-exact dependencies into that worktree's own `pipeline/.venv` and skips only the editable build of the project itself, which is the failing part. Then `PYTHONPATH=src .venv/bin/python -m pytest -q`, `.venv/bin/ruff check src tests`, and `.venv/bin/pyright` all work (`pyright` resolves through `venvPath`/`venv`, which point at the worktree's own `.venv`).

That workaround carries its own proof of correctness, and the pickup session should preserve the property: bare `.venv/bin/python -c "import mp"` raises `ModuleNotFoundError`, so no stale installed copy can shadow the worktree's source, and a green suite is therefore genuinely about the code under test. An earlier workaround that borrowed the main checkout's interpreter did not have that property and could silently verify the wrong tree.

`pipeline/.venv` is gitignored (`.gitignore:18`), so neither approach leaks into a commit.

## Scope

The seam is `pipeline/pyproject.toml:6`. The smallest fix that clears the class is to stop pointing the package's readme metadata outside the package directory. Two candidates, either acceptable:

- Drop the `readme` key entirely. This is a personal, unpublished package with no PyPI page, so the metadata buys nothing.
- Point it at a pipeline-local file, and keep `README.md` at the repo root as the single copy the docs refer to. Do not create a second copy of the root README that can drift; DOC7 and DOC9 both spent sweeps cleaning up exactly that class.

Then re-check root `CLAUDE.md`'s verification table against reality from a worktree, since the whole point is that its three commands become true again.

## Explicitly not in scope

Changing how CI installs dependencies. Its `uv sync` bypass is deliberate and load-bearing for the Linux runner, and this task must not make the runner start resolving `mlx-lm` or `mlx-embeddings`.

Rebuilding the main checkout's venv. It works, and gratuitously recreating it risks trading a known-good local environment for an unknown one mid-quarter. The fix should make a fresh venv work, not disturb the existing one.

Vendoring or duplicating `README.md`. Named above as the thing not to do.

## Acceptance

`uv sync --extra dev` succeeds inside a freshly created `git worktree` of this repo, with no `--no-install-project` and no build constraint.

From that worktree, all three of `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev pyright`, and `uv run --extra dev pytest -q` run green with no `PYTHONPATH` override.

The main checkout still verifies green by the same three commands, so the fix is not a trade.

`README.md` at the repo root is byte-unchanged, and no second copy of it exists in the tree.

Root `CLAUDE.md`'s "Verify before declaring done" table is true from a worktree, updated in the same commit if the fix changes any command.
