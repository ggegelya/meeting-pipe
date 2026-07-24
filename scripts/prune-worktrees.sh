#!/bin/sh
# Remove session worktrees whose work is already on `main`, plus their branches.
#
# Parallel sessions each run in a git worktree under `.claude/worktrees/`
# (see the Git workflow section of CLAUDE.md). A session lands its own commit
# on `main` but cannot delete the directory it is standing in: removing it
# works, and then every later tool call in that session dies with
# "cd: no such file or directory". So no session cleans up after itself.
# This janitor cleans up after the *previous* ones, and runs from the
# SessionStart hook in `.claude/settings.json` plus step 1 of the backlog
# commands.
#
# Every removal is gated. A worktree is only taken when it is under
# `.claude/worktrees/`, is not the main checkout, is not the caller's own
# worktree, is on a branch (not detached), has that branch fully merged into
# `main`, and has a clean tree. An in-flight session fails at least one of
# those, always: unmerged commits, or uncommitted work, or both.
#
# POSIX sh on purpose, so `sh scripts/prune-worktrees.sh` and a direct call
# behave the same. Exits 0 unconditionally: a session start must never fail
# because of this.

set -u

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# The first `worktree list` entry is always the main checkout.
MAIN=$(git worktree list --porcelain | head -1 | cut -d' ' -f2-)
[ -n "$MAIN" ] && [ -d "$MAIN" ] || exit 0

# Where this script was invoked from, so we never saw off the branch we sit on.
SELF=$(git rev-parse --show-toplevel 2>/dev/null || true)

removed=0

# Drop admin entries for worktrees whose directory is already gone.
git -C "$MAIN" worktree prune >/dev/null 2>&1

# Split on newlines only, so worktree paths containing spaces survive.
worktrees=$(git -C "$MAIN" worktree list --porcelain | sed -n 's/^worktree //p')
branches=$(git -C "$MAIN" for-each-ref --format='%(refname:short)' 'refs/heads/claude/*')

OLDIFS=$IFS
IFS='
'

# Pass 1: merged, clean worktrees. Remove the worktree first, then the branch,
# because `git branch -d` refuses a branch that is still checked out somewhere.
for wt in $worktrees; do
    [ "$wt" = "$MAIN" ] && continue
    [ -n "$SELF" ] && [ "$wt" = "$SELF" ] && continue
    case "$wt" in
        "$MAIN/.claude/worktrees/"*) ;;
        *) continue ;;
    esac

    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] || continue

    git -C "$MAIN" merge-base --is-ancestor "$branch" main 2>/dev/null || continue
    [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue

    git -C "$MAIN" worktree remove "$wt" >/dev/null 2>&1 || continue
    git -C "$MAIN" branch -d "$branch" >/dev/null 2>&1
    echo "pruned worktree ${wt##*/} ($branch)"
    removed=$((removed + 1))
done

# Pass 2: `claude/*` branches left behind by a worktree that is already gone.
# Scoped to the app's own prefix so this can never touch a branch you made,
# and `-d` refuses anything not fully merged.
for branch in $branches; do
    [ -n "$branch" ] || continue
    git -C "$MAIN" merge-base --is-ancestor "$branch" main 2>/dev/null || continue
    if git -C "$MAIN" branch -d "$branch" >/dev/null 2>&1; then
        echo "pruned branch $branch"
        removed=$((removed + 1))
    fi
done

IFS=$OLDIFS

[ "$removed" -gt 0 ] && echo "worktree janitor: $removed removed"
exit 0
