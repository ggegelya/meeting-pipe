#!/bin/sh
# Gate matrix for scripts/prune-worktrees.sh.
#
# That script deletes directories, and it shipped a data-loss bug on
# 2026-07-24 (it swept a live session's worktree because a session that has
# not committed yet looks "merged + clean"). Every gate therefore gets a named
# case here, and the fresh-worktree case is that exact regression.
#
# Builds a scratch repo under a temp dir, touches nothing else, and prints one
# line per case. Exits non-zero if any case fails.

set -u

JANITOR="$(cd "$(dirname "$0")" && pwd)/prune-worktrees.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/prune-wt-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

R="$TMP/repo"
failures=0

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

check_gone()  { [ -e "$R/.claude/worktrees/$1" ] && fail "$2" || ok "$2"; }
check_alive() { [ -e "$R/.claude/worktrees/$1" ] && ok "$2" || fail "$2"; }

# Make a worktree look idle, so the age gates do not mask what we are testing.
age() {
    find "$R/.git/worktrees/$1" -exec touch -t 202001010000 {} + 2>/dev/null
    touch -t 202001010000 "$R/.claude/worktrees/$1" 2>/dev/null
    [ -n "${2:-}" ] && touch -t 202001010000 "$R/.git/logs/refs/heads/$2" 2>/dev/null
    return 0
}

git init -q "$R" || exit 1
cd "$R" || exit 1
git config user.name test
git config user.email test@example.com
printf 'build/\n' > .gitignore
printf 'base\n' > base.txt
git add -A
git commit -q -m base

# --- fixtures, one per gate -------------------------------------------------

# fresh: created, never committed, clean. THE REGRESSION.
git worktree add -q "$R/.claude/worktrees/fresh" -b claude/fresh main

# landed: committed, merged, clean, idle. The only one that should go.
git worktree add -q "$R/.claude/worktrees/landed" -b claude/landed main
(cd "$R/.claude/worktrees/landed" && printf 'x\n' > landed.txt && git add landed.txt && git commit -q -m landed)
git merge -q --ff-only claude/landed
mkdir -p "$R/.claude/worktrees/landed/build" && printf 'o\n' > "$R/.claude/worktrees/landed/build/x.o"

# unmerged: committed but never landed.
git worktree add -q "$R/.claude/worktrees/unmerged" -b claude/unmerged main
(cd "$R/.claude/worktrees/unmerged" && printf 'x\n' > un.txt && git add un.txt && git commit -q -m unmerged)

# dirty: committed and merged, but has uncommitted work.
git worktree add -q "$R/.claude/worktrees/dirty" -b claude/dirty main
(cd "$R/.claude/worktrees/dirty" && printf 'x\n' > dirty.txt && git add dirty.txt && git commit -q -m dirty)
git merge -q --ff-only claude/dirty
printf 'uncommitted\n' >> "$R/.claude/worktrees/dirty/dirty.txt"

# warm: identical to landed, but its admin dir was touched just now.
git worktree add -q "$R/.claude/worktrees/warm" -b claude/warm main
(cd "$R/.claude/worktrees/warm" && printf 'x\n' > warm.txt && git add warm.txt && git commit -q -m warm)
git merge -q --ff-only claude/warm

# outside: merged and idle, but not under .claude/worktrees/.
git worktree add -q "$R/outside" -b claude/outside main
(cd "$R/outside" && printf 'x\n' > out.txt && git add out.txt && git commit -q -m outside)
git merge -q --ff-only claude/outside

# a merged branch that is not the app's, and an orphaned app branch.
git branch feature/mine main
git branch claude/orphan main

for w in fresh landed unmerged dirty outside; do age "$w" "claude/$w"; done

# --- run --------------------------------------------------------------------

printf '\nprune-worktrees gate matrix\n'
sh "$JANITOR" > "$TMP/out1" 2>&1

check_alive fresh    "fresh worktree with no commit survives (2026-07-24 regression)"
check_gone  landed   "committed + merged + clean + idle is pruned"
check_alive unmerged "unmerged commits survive"
check_alive dirty    "dirty tree survives"
check_alive warm     "recently active worktree survives the age floor"
[ -e "$R/outside" ] && ok "worktree outside .claude/worktrees/ survives" || fail "worktree outside .claude/worktrees/ survives"

git show-ref -q --verify refs/heads/feature/mine && ok "non-claude merged branch survives" || fail "non-claude merged branch survives"
git show-ref -q --verify refs/heads/claude/orphan && fail "orphaned merged claude/* branch is pruned" || ok "orphaned merged claude/* branch is pruned"
git show-ref -q --verify refs/heads/claude/fresh && ok "fresh branch survives with its worktree" || fail "fresh branch survives with its worktree"

# The escape hatch drops the age floor only: warm goes, fresh still stays.
MP_PRUNE_MIN_AGE_MIN=0 sh "$JANITOR" > "$TMP/out2" 2>&1
check_gone  warm  "MP_PRUNE_MIN_AGE_MIN=0 prunes the warm worktree"
check_alive fresh "MP_PRUNE_MIN_AGE_MIN=0 still refuses the uncommitted worktree"

# Running from inside a worktree must never remove that worktree.
git worktree add -q "$R/.claude/worktrees/self" -b claude/self main
(cd "$R/.claude/worktrees/self" && printf 'x\n' > s.txt && git add s.txt && git commit -q -m self)
git merge -q --ff-only claude/self
age self claude/self
(cd "$R/.claude/worktrees/self" && MP_PRUNE_MIN_AGE_MIN=0 sh "$JANITOR" > "$TMP/out3" 2>&1)
check_alive self "the caller's own worktree survives"

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'all gates green\n'
    exit 0
fi
printf '%s gate(s) FAILED\n' "$failures"
exit 1
