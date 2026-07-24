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
# Every removal is gated, and every gate is a reason to KEEP. A worktree is
# only taken when it is under `.claude/worktrees/`, is not the main checkout,
# is not the caller's own worktree, is on a branch (not detached), has that
# branch fully merged into `main`, has a clean tree, HAS COMMITTED AT LEAST
# ONCE, has an idle git admin dir, and has no live session transcript.
#
# The last three exist because "merged + clean" does NOT mean "finished".
# A session in its first minutes is zero commits ahead of `main`, so it is
# trivially an ancestor, and its tree is clean because it has not written
# anything yet. Both gates pass for the exact opposite of the intended reason,
# and this deleted a live session's worktree on 2026-07-24. The reflog gate is
# the real fix: a branch made by `git worktree add -b` has one reflog entry,
# and the first commit makes it two, so "fewer than two" means "this session
# never got as far as committing". Unreadable or missing reads as zero, which
# also keeps, so the rule fails safe by construction.
#
# MP_PRUNE_MIN_AGE_MIN (default 60) is the idle window for the two age gates.
# Set it to 0 to sweep known-dead debris immediately; it never relaxes the
# reflog, merged, or clean-tree gates.
#
# POSIX sh on purpose, so `sh scripts/prune-worktrees.sh` and a direct call
# behave the same. Exits 0 unconditionally: a session start must never fail
# because of this.

set -u

MIN_AGE_MIN="${MP_PRUNE_MIN_AGE_MIN:-60}"

# True when $1 exists and was modified within MIN_AGE_MIN minutes. Used only to
# KEEP a worktree, so a false negative costs a delayed cleanup, never data.
recently_touched() {
    [ "$MIN_AGE_MIN" -gt 0 ] || return 1
    [ -e "$1" ] || return 1
    [ -n "$(find "$1" -maxdepth 0 -mmin "-$MIN_AGE_MIN" 2>/dev/null)" ]
}

# True when a session transcript for worktree path $1 was written recently.
# Each session gets ~/.claude/projects/<path with / and . turned into ->/*.jsonl.
# That layout is undocumented, so this is a best-effort VETO: finding a live
# transcript keeps the worktree, but finding nothing never grants permission
# to delete. The git gates above remain the real protection.
session_alive() {
    [ "$MIN_AGE_MIN" -gt 0 ] || return 1
    _slug=$(printf '%s' "$1" | tr './' '--')
    _dir="$HOME/.claude/projects/$_slug"
    [ -d "$_dir" ] || return 1
    [ -n "$(find "$_dir" -name '*.jsonl' -mmin "-$MIN_AGE_MIN" 2>/dev/null | head -1)" ]
}

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

    # Never committed: live session, or abandoned before doing anything. Keep.
    reflogs=$(git -C "$MAIN" reflog show "$branch" 2>/dev/null | wc -l | tr -d ' ')
    [ "${reflogs:-0}" -ge 2 ] || continue

    # Still warm: covers a session that just landed and is still open for
    # follow-ups. Deliberately NOT the admin directory's own mtime: the clean
    # check below runs `git status`, which rewrites the index and bumps that
    # directory, so using it would make every worktree look eternally fresh.
    # HEAD and the branch reflog move on commit, rebase, and checkout only.
    recently_touched "$MAIN/.git/worktrees/${wt##*/}/HEAD" && continue
    recently_touched "$MAIN/.git/logs/refs/heads/$branch" && continue
    session_alive "$wt" && continue

    # Cheapest gates first; this one refreshes the index, so it runs last.
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
