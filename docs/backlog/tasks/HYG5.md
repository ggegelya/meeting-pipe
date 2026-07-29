# HYG5: Acceptance criteria pin absolute suite totals

Band origin: filed 2026-07-29, measured during the eight-task parallel batch (UX30, UX31, CAL3, UX32, UX33, UX34, UX35, UX36) landed the same day. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Task specs state their verification bar as an absolute suite total. The dominant form, verbatim in 13 active `tasks/` files, is: ``cd daemon && swift build`` and ``swift test`` green (baseline at filing: 1770). Four more carry a two-tree variant citing `1770 Swift, 1050 Python`. Eighteen active specs cite 1770: AUTO4, DET7, DIAR3, FEAT12, LOCAL16, STOR5, UX33, UX35, UX36, UX37, UX39, UX40, UX41, UX42, UX43, UX44, UX45, UX46.

An absolute total is true against exactly one base. It stops being true the moment anything else lands, which during a parallel batch is immediately and repeatedly. The eight-task batch of 2026-07-29 moved the daemon count on seven of its eight commits:

| Commit | Task | Daemon count after landing |
|---|---|---|
| 051914d | UX35 | 1786 |
| 35e6c6b | UX30 | 1798 |
| 45889ad | UX31 | 1816 |
| 7cc42d7 | UX34 | 1821 |
| 137776f | UX36 | 1829 |
| ce25f68 | UX32 | 1839 |
| 6efb07e | UX33 | 1875 |
| aec8788 | CAL3 | 1875 (adds no tests) |

Every agent in that batch measured its suite twice, once against its branch point and once after rebasing onto the siblings that had landed meanwhile, and the two numbers differed in every case that added tests. UX31 measured 1799 then 1816, UX32 measured 1808 then 1839, UX33 measured 1852 then 1875, UX34 measured 1786 then 1821, UX36 measured 1794 then 1829. Five of the eight (UX31, UX32, UX33, UX34, UX36) then had to detect that the figure already written into their ToC row or their `q6-final.md` archive entry was stale, correct it, and amend the correction into their commit. That is rework with no product value, and it recurs on every parallel batch by construction.

The Python figure has drifted by the same mechanism without a batch being involved: four specs cite `1050 Python` against a measured 1086 (`cd pipeline && uv run --extra dev pytest -q`, 2026-07-29, 1086 passed).

This is the class HYG2 closed for config knobs: a documented value that is not true misleads every later reader. Here the reader is a pickup session deciding whether its suite is healthy, and the stale number teaches it to distrust the acceptance bar rather than to check it.

The convention is authored in two places. `.claude/commands/file-task.md:19` tells a filing session to "name the tests to pin (with their scenarios), the suites and linters that must stay green", which is already the correct instruction and does not ask for an absolute total; the absolute totals came in by imitation of neighbouring specs rather than from the template. `.claude/commands/tech-task.md:21` names the verification commands without naming a count, and is likewise not the source.

## Scope

Change the convention, then make the existing specs match it.

- State the bar as the suite being green plus the number of tests the task adds, for example "``swift test`` green, 8 new tests". That survives whatever lands beside it, because both halves stay checkable against any base: green is green, and a task knows how many tests it wrote.
- Sweep the 18 active `tasks/` specs listed above, replacing the absolute total in each acceptance line. A spec that has not been picked up does not yet know its N, so its bar becomes the green half alone plus the scenarios it already names; the N is added by the session that writes the tests, in the same commit.
- Correct the four `1050 Python` citations the same way.
- Record the rule at `.claude/commands/file-task.md:19`, in the Acceptance bullet of step 7, as an explicit "do not pin an absolute suite total; it is stale on the next landing" so a filing session does not reintroduce it by copying a neighbour.
- Add the same one-line rule to the backlog's own "How to pick up a task (delegation)" or "Marking a task done" section, whichever the sweep finds is the one a pickup session actually reads, so the rule is visible from the document being edited rather than only from the command file.

## Explicitly not in scope

The archived `q<N>-final.md` entries. A shipped task's archive entry records what was measured when it shipped, which is a historical fact and correct as written; rewriting those would destroy the trail this backlog exists to keep. Only active `tasks/` specs and the ToC rows of unfinished tasks are swept.

Any change to what the suites run, to CI, or to `scripts/coverage.sh`. This is a documentation convention, not a testing change.

A CI check that greps for absolute totals in acceptance lines. Considered and rejected as disproportionate: the failure costs a few minutes of agent rework, not a defect, and a fence would itself need maintaining. If the convention is reintroduced twice more after this lands, that is the recurrence that justifies revisiting.

Renumbering or restating any acceptance bar beyond the suite-total line. The scenarios, greps, fences, and eyeball clauses in those 18 specs are correct and stay untouched.

## Acceptance

`grep -rE 'baseline[s]? at filing' docs/backlog/tasks/` returns nothing.

`grep -rE '\b1770\b|\b1050\b' docs/backlog/tasks/` returns nothing, and the same grep over `docs/backlog/q6-final.md` still returns its historical citations unchanged, proving the archive was left alone.

`.claude/commands/file-task.md` step 7's Acceptance bullet names the rule explicitly, and the backlog's process section carries the same one-liner.

Each of the 18 swept specs still names its scenarios, its linters, and its eyeball clause; the diff on each is confined to the suite-total sentence. Verified by reading the diff, since no test can assert this.

No code changes, so no suite moves: `cd daemon && swift test` and `cd pipeline && uv run --extra dev pytest -q` are green and unchanged from the pre-task counts, whatever those are when this is picked up. `python3 scripts/truth_fences.py both` green. Repo dash guard green (no U+2014 in changed lines).
