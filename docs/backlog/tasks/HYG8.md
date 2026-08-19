# HYG8: three more dead-link mechanisms HYG6's sweep did not cover, plus two accreted conventions in the backlog's own files

Band origin: filed 2026-08-18 from the ten-task batch that landed the same day (`20e66c7` through `b122e00`). HYG6 swept 88 dead links in that batch; everything below sat outside its named scope, and UX72 independently corroborated the largest group with a link-checker run before and after its own archival. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What was measured, and when

All counts below are from a relative-link resolver run over `docs/backlog/**/*.md` on 2026-08-18 against `b122e00`. It resolves every markdown link that is not a URL scheme or a bare anchor, relative to the file that carries it, and reports the ones whose target does not exist. **25 dead links**, in three groups that fail for three different reasons. One of the 25, in `END9.md`, belongs to [`HYG7`](HYG7.md) and is deliberately not this task's, so **24 are in scope here**.

**The resolver has to ignore links inside code spans, and that is not a detail.** A first pass without that rule reported 28 and was wrong by four: `DOC13.md` appeared to carry four dead links, and all four are *quotations* of links that live in `docs/GUIDE.md`, written inside backticks, in the spec whose whole subject is that the Guide carries repo-relative links a reader in a window cannot follow. `DOC13.md` has no dead link of its own. Any measurement or fence here that does not strip code spans will re-report those four and will be wrong the same way.

Links are named by their target rather than by line number, per the cite-by-symbol rule HYG6 added to `.claude/commands/file-task.md` on 2026-08-18. Line numbers in a 5,500-line archive rot faster than the links do.

### Group 1: archiving a spec kills every citation of it, elsewhere (11 flagged, 10 real)

This is a **third** mechanism, distinct from the two HYG6 fixed. When a task archives, `tech-task.md` step 8 rewrites that spec's own links one level shallower and deletes `docs/backlog/tasks/<ID>.md`. Nothing rewrites the links **into** it from anywhere else, so every other document that cited `./tasks/<ID>.md` now points at a file that was deleted on purpose.

In `q6-final.md`, ten archived rows still link to specs that archived after them: `./tasks/UX57.md`, `./tasks/UX58.md`, `./tasks/UX52.md`, `./tasks/UX49.md`, `./tasks/LANG2.md`, `./tasks/UX44.md`, `./tasks/AI12.md`, `./tasks/UX71.md`, plus `./LOCAL15.md` and a second `./UX58.md` already rewritten one level shallower by an archival and dead at the new depth too.

An eleventh flag in the same file is **not** a defect: `meetingpipe://open?stem=...&t=754` is a deeplink example in prose, and a checker that reads it as a path is wrong about it. UX72 measured 11 flags before its landing and 11 after, an identical set, which is the useful half of that measurement: **today's four archivals added none**, so this is accumulated rather than accelerating.

**The mechanism is not archive-only, and this is the part nobody reported.** `docs/backlog/tasks/DET12.md` carries `[DET11](DET11.md)`, dead since DET11 archived, in a **live** spec that a session may pick up at any time. DET12's other references to archived tasks use the correct post-archive form (`[DET8](../q6-final.md)`), so the file is right about the pattern nine times and wrong once, which is exactly the shape a reader cannot spot by eye.

### Group 2: one-level depth errors in live specs (10 across three specs)

Same class HYG6 characterised, in three specs it did not reach. Every relative link in `docs/backlog/tasks/<ID>.md` is relative to `docs/backlog/tasks/`, so the backlog is `../`, `docs/` is `../../`, and repo-root code is `../../../`. These are each one `../` short:

- `CAL3.md`, 7: `../../pipeline/src/mp/summarize.py`, `../../pipeline/src/mp/action_clusters.py`, `../../daemon/Sources/MeetingPipe/PrepCard.swift`, `../../daemon/Sources/MeetingPipe/MeetingMetaSidecar.swift`, `../../daemon/Sources/MeetingPipe/MeetingTitleResolver.swift`, `../../.claude/commands/spike.md`, `../../CONVENTIONS.md`.
- `AUTO1.md`, 2: `../spikes/auto1-app-intents-metadata.md` and `../../daemon/scripts/auto1-app-intents-probe.sh`.
- `DIAR5.md`, 1: `./q6-final.md`, which needs `../q6-final.md`. LOCAL14's session spotted this one separately and left it, correctly, as somebody else's row.

`CAL3` and `AUTO1` are both P3 deferred and `DIAR5` sits in `owner-verification.md`. None is unreachable: a P3 gets promoted and an owner-verification row gets read during the check.

**`DOC13.md` is not in this group, though a naive checker puts it here.** Its four apparent hits (`./SETUP.md` and three to `../README.md`) are quotations of `docs/GUIDE.md`'s own links, each inside backticks, in the four bullets that record what DOC13 found. They are correct as written and must not be "repaired".

### Group 3: links to source files that were deleted (3, all in `q4-final.md`)

A different cause again, and the one closest to a real archaeology cost: `../../daemon/Sources/MeetingPipe/RawFilesTab.swift`, `../../daemon/Sources/MeetingPipe/SilenceDetector.swift`, and `../../daemon/Sources/MeetingPipeCore/MicGate/MicOnlySilenceBackstop.swift`. The archive is a historical record, so the right repair is usually to keep the name and drop the link rather than to hunt for a successor file.

### The rest of the repo is clean

The same resolver over `docs/`, `README.md`, `CONVENTIONS.md`, `ARCHITECTURE.md` and `PRODUCT.md` flags exactly one thing outside `docs/backlog/`, and it is the same `meetingpipe://` deeplink example, in `CONVENTIONS.md`. So the prose docs need nothing and this task's whole surface is the backlog directory.

## Two accreted conventions in the backlog's own files

Both were noticed and deliberately left by the sessions that found them, and both are judgement calls rather than repairs, which is why they need a row rather than a passing fix.

### The `Bands:` line is half-updated, and two sessions read it two ways

`meetingpipe-q6-backlog.md`'s `Bands:` paragraph under the 2026-08-03 audit section names **20 task IDs**. Measured 2026-08-18: **17 of them are archived in `q6-final.md`**, one (DET9) sits in `owner-verification.md`, and exactly **two are still in the active ToC**, DET10 and FEAT14.

ARCH6 read the line as a live index and edited its own name out of it. CI6 read the same line as the 2026-08-03 audit's historical banding record and left its own name on, noting the list was already mostly archived. **CI6's reading is the one the owner and the orchestrator agreed with**, and the reasoning generalises: pruning one name from a stale list makes the list less internally consistent, not more, because the reader then cannot tell whether an absent ID was never banded or was quietly removed.

So the fix is one deliberate pass over the whole line, and the decision comes first: either it is a historical record of what the 2026-08-03 audit recommended, in which case it is frozen, dated in place, and nobody edits it again; or it is a live index, in which case it is rebuilt from the current ToC and something has to keep it true. Do not do half of either.

### `q6-final.md` carries two competing entry-header styles

Counted 2026-08-18: **132 entries** open with the bold form (`**[DONE] UX72 (P2): ...**`) and **28 with a heading** (27 `# [DONE] ...` plus `## [DONE] DOC14`).

The second-hand report that prompted this filing described one style outlier. It is not one: the heading form has 28 members and **three of today's ten landings used it** (DIAR4, HYG6, DOC12), while ARCH6, CI6 and UX72 used the bold form in the same batch. So this is two live conventions being chosen at random per session, which is a rule that was never written down rather than a slip somebody made.

Deciding it is cheap; restyling 28 or 132 entries is not necessarily worth it. The spec's position is that **writing the rule down is mandatory and the bulk restyle is optional**, since a documented convention stops the divergence growing whether or not the backlog is normalized.

### A run-on hazard worth fencing, if a fence is cheap

UX72 found that concatenating two `[DONE]` bodies during a both-sides-add merge conflict can leave the previous entry's closing line adjacent to the next header **with no blank line**. A `**[DONE] ...**` line is a bold paragraph, not a heading, so markdown treats it as a lazy continuation of the paragraph above and renders both as one run-on. It is invisible in a diff with no conflict markers left in it. FEAT15 hit the same seam in `daemon/docs/gotchas.md` and fixed it by hand.

Measured: **exactly two instances**, both in `q6-final.md`, and **zero** in `q3-final.md`, `q4-final.md` and `q5-final.md`. C7's entry follows a numbered list item directly, and UX32's follows a `**Verified:** ...` paragraph directly. So the hazard is real, rare, and confined to the file that takes the most concurrent writes.

The predicate is one line ("a line beginning `**[DONE]` must be preceded by a blank line"), which is what makes a fence worth considering rather than a style note.

## A ship-note claim that stopped being true about a live file

Found 2026-08-18, hours after the rest of this spec, and it is group 1's mechanism one file over: a dated claim in one document about the state of another, where the other document then changed underneath it.

FEAT14's ToC row records, inside its verification note, that "the command `pipeline/CLAUDE.md` lists in its Build + test block, `uv run --extra dev pyright`, now reports 3 unresolved `mcp.*` imports in AUTO3's `mcp_serve.py`, because CI's typecheck job installs `mcp>=1.29,<2` and that local command does not. A doc-truth gap in the local command rather than a code defect, and not FEAT14's to fix."

Every word of that was true when written. It stopped being true the same day: `46e9d28` changed that block to `uv run --extra dev --extra mcp pyright` and added a note explaining why the extra is needed. FEAT14's row now describes a command `pipeline/CLAUDE.md` does not list.

**The repair is a clause, not a rewrite.** The convention here for a dated finding inside a ship note is to record what became of it rather than to overwrite the record, which is what HYG6 and LOCAL14 both did. So the fix is to append a "fixed by `46e9d28`" clause and leave the finding standing as the dated observation it is.

It is worth doing rather than shrugging at, because of where it is going. Today the claim sits in a live row beside a live file, so a reader can see the discrepancy and resolve it. The moment FEAT14 archives, it becomes an unqualified false statement about a file that still exists, which is exactly group 1's failure mode reached by a different route.

## Scope

Five things, in this order. The first is mechanical, the next two are decisions, the fourth is optional, and the fifth is one clause.

**1. Repair all 24 dead links.** Group 2 and the depth half of group 1 are path repairs. Group 1's cross-archive citations are a judgement per link: a citation of an archived task should point at `q6-final.md` (the form DET12 already uses nine times), not at a resurrected path. Group 3's are best repaired by keeping the file name as text and dropping the link. `END9.md`'s is HYG7's and stays untouched here.

**2. Settle the `Bands:` line** per the decision above, and write the answer beside it so the next session does not have to re-derive which kind of thing it is.

**3. Settle the header style.** Write the rule into `meetingpipe-q6-backlog.md`'s "Marking a task done" section, which is where a session looks before archiving. Restyling existing entries is a separate call and may be declined with the reason recorded.

**4. Consider a link fence.** The seam is `scripts/truth_fences.py`, which already dispatches `both | config | events | claude` from `main` and would take a `links` mode the same way. Two requirements are non-negotiable and both are demonstrated by real content in the tree:

- **Skip non-file URL schemes.** `meetingpipe://` appears in `q6-final.md` and `CONVENTIONS.md` as documentation of the app's own deeplink. A checker that flags it produces a false positive that gets suppressed by hand, and a suppression list is the thing that rots next.
- **Skip links inside inline code spans and fenced code blocks.** Three real cases already demand it: `DOC13.md`'s four quotations of `docs/GUIDE.md`'s links, `HYG7.md`'s quotation of END9's broken `PromptEndPolicy.swift#L7` link, and this spec's own quotation of `DET12.md`'s `DET11.md`. Quoting a broken link is how a spec records that a link is broken, so a fence that fails on it makes this class of finding unwriteable.

If either requirement makes the fence more expensive than the defect, say so and close item 4 with the reasoning rather than shipping a checker the next session has to work around. A fence that fires on correct prose is worse than no fence.

**5. Append the "fixed by `46e9d28`" clause to FEAT14's ToC row**, per the section above. One clause; the original finding stays exactly as written.

## Explicitly not / out of scope

**`END9.md`'s dead `PromptEndPolicy.swift` link.** [`HYG7`](HYG7.md)'s, filed the same day. Repairing it as a path repair would preserve a claim about a comment ARCH6 deleted, so it needs that task's reasoning and not this one's.

**Rewriting any archived entry's content.** Group 3's repair drops a link and keeps the text. The archive is a record of what was decided and when; this task fixes navigation, not history.

**The `tech-task.md` step 8 rule that produces group 1.** Making archival rewrite inbound citations means finding every citation of an archiving task across every backlog file, which is a real change to the archive procedure and belongs to the owner, not to a hygiene sweep. Item 4's fence would at least make the next occurrence loud, which is the cheaper half.

**A citation fence over `file.swift:NNN` line references.** HYG7 names this as out of its scope too, for the same reason: resolving a line citation against the symbol it claims needs a Swift parser. The relative-link half is the tractable one.

**The two `meetingpipe://` occurrences.** Correct as written. They are named here only so a future sweep does not "fix" them.

**Observed but not filed:** `q6-final.md` is 5,519 lines and takes the most concurrent writes of any file in the repo, which is what produced both run-on entries and most of group 1. Whether the running archive should roll per quarter more aggressively is a real question and is the owner's, not a hygiene task's.

## Acceptance

- A relative-link resolver over `docs/backlog/**/*.md` reports **zero** dead links, excluding `END9.md`'s if HYG7 has not landed yet. The resolver treats a non-file URL scheme and a link inside a code span as not-a-link, so the two `meetingpipe://` examples, `DOC13.md`'s four quotations and HYG7's quoted broken link are not counted and are not edited. A run that reports 28 rather than 25 is the code-span rule missing, not four more defects.
- Every repaired link resolves from the file that carries it, at that file's own depth. Spot-checkable by opening any three from `docs/backlog/tasks/` and any three from `q6-final.md`.
- The `Bands:` line states which kind of thing it is, in the line or immediately beside it, and its contents match that statement. If it is frozen as historical, it says so and carries the 2026-08-03 date; if it is rebuilt as live, every ID it names is in the active ToC.
- `meetingpipe-q6-backlog.md`'s "Marking a task done" section names one entry-header form for `q6-final.md`. If existing entries are not restyled, that decision and its reason are recorded there too.
- The two run-on `[DONE]` entries in `q6-final.md` are separated by a blank line, and both render as their own paragraph.
- If item 4 ships a fence: it fails on a deliberately reintroduced run-on and on a deliberately broken relative link, and passes on both `meetingpipe://` examples and on HYG7's quoted broken link. All four cases pinned, since a fence that has not been run against the bug is CI6's exact finding. If item 4 is declined, the reason is recorded in this task's ship note.
- FEAT14's ToC row records that its pyright-command finding was fixed by `46e9d28`, with the finding itself left intact rather than rewritten.
- `python3 scripts/truth_fences.py both` green. If a `links` mode is added, `python3 scripts/truth_fences.py links` green and `both` covers it.
- No production code change. If `scripts/truth_fences.py` is touched, say so explicitly in the ship note, since it is the one file in this task's scope that CI executes.
- No em-dashes in changed lines.

## Progress, 2026-08-19: item 4 shipped, owner said yes to the fence

**Owner decision 2026-08-19: ship it.** Walkthrough step 4 answered directly, so the fence was built rather than closed with reasoning.

**`scripts/truth_fences.py` was touched, and the acceptance asks that this be said explicitly**: it is the one file in this task's scope that CI executes. CI invokes it with no argument (`.github/workflows/ci.yml:103`), which resolves to `both`, so the new mode is covered without a workflow edit.

**The mode is named `links` although it carries two checks**, because `links` is the command this task's acceptance pins. The second check is the UX72 run-on: a `**[DONE]` line with no blank line above it, which markdown renders as a continuation of the paragraph before it. Renaming the mode to fit both checks would have broken the acceptance's own command, so the docstring carries the explanation instead.

**The two skips are implemented as structure, not as a suppression list**, which item 4 required. Fenced blocks and inline code spans are blanked before any link is extracted (line count preserved, so a finding can still name its line), and a target carrying a URL scheme, a bare anchor, or a protocol-relative prefix is never resolved as a path.

**Measured on the tree as it stands, 2026-08-19:** 231 markdown files scanned, 709 inline links found, 597 resolved as real paths, 112 skipped. **Zero findings**, which is what HYG6's 88 repairs and this task's 24 leave behind.

**A correction to this task's own earlier note, found by measuring instead of assuming.** The item 1 ship note said the `meetingpipe://` occurrences "are all correctly not flagged", which is true but not for the reason it implies. **Not one of them is a markdown link target**: all 89 occurrences in the tree are prose or code-span text, so the link extractor never sees them and the scheme skip is not what saves them. The skip is still load-bearing, just for a different population, and the measurement says which: the 112 skipped targets are **80 `https:` links and 32 bare in-page anchors**. Written down because "the fence passes on `meetingpipe://`" reads like evidence the skip works, and it is not; the evidence that the skip works is the mutant below.

**Verified red first, which is the half that matters**, since a fence that has never failed is CI6's exact finding. A probe file carrying all four acceptance cases produced exactly two errors: the broken relative link and the run-on. The quoted broken link in an inline code span, the same in a fenced block, both `meetingpipe://` forms and a real link all stayed silent. Three mutants of the implementation were then each caught by the suite (dropping the inline-code strip, dropping the blank-line requirement, dropping the scheme skip). Worth recording: **every one of the three also turned the real tree red**, which is independent evidence that this repo genuinely does quote broken links in prose, rather than that being a hypothetical the skip was written for.

**Pinned in `pipeline/tests/test_link_fence.py`** (17 tests), which loads the script by path the way `test_feat17_probe.py` loads the spike probes. It includes a walker-floor test and a "the real tree is currently clean" assertion, so the next archive move that drops a `../` level fails in `pytest` as well as in CI5.

**One stale claim corrected in passing.** The root `CLAUDE.md` verify-table row said the fence fails on a `CLAUDE.md` "over its 12 KB budget". The real budgets are 800 bytes per entry and 24 KB whole-file, and DOC15 hit the second of those one day before this. The row was being edited anyway to add the new mode, so the number was corrected rather than left for a later sweep to find.

### Amendment, same day: the first version passed over a live instance of its own bug

The run-on check as first written matched only `**[DONE]` lines, which is the shape UX72 reported. It landed green, and the very next file this batch opened, `design/ui_kits/macos_app/README.md`, contained the same defect in a different shape: DSN30's item 2 answer, added the previous day, sat directly under a list item with no blank line, so markdown was rendering that whole paragraph **inside the OnboardingPermissions bullet**. A fence that misses the bug in the file the same batch is editing is not a fence worth keeping narrow.

**Widened on evidence rather than instinct.** Before changing anything, the general shape ("a bold line directly under a list item") was counted across the tree: **exactly one hit in 231 files**, and that hit was the defect. So the widening catches a real bug and costs zero false positives. The broader rule that suggests itself, "a bold line under any non-blank line", was rejected: a bold lead-in after a sentence is ordinary style here, and a fence nobody can keep green is worse than no fence. Both boundaries are pinned by tests.

Re-verified red first in the new shape: the widened fence failed on the real file, naming the list item rather than an archive entry, and went green when the blank line was added. The finding's message is now shape-aware, since the first draft reported the list-item case as a `**[DONE]` entry, which would have sent the next reader looking for an archive problem in a design document.

**What this fence still cannot see**, stated so a green run is not over-read:

- **Reference-style links** (`[text][ref]`). Only inline `[text](target)` is extracted. This repo does not use the reference form anywhere today, so the gap is theoretical, but a document that adopted it would go unchecked.
- **Anchors.** `./doc.md#section` is resolved to `./doc.md` and the anchor is discarded, so a link to a heading that no longer exists still passes. Checking anchors means parsing every heading and matching GitHub's slug rules, which is a different and much larger job.
- **`file.swift:NNN` line citations**, which this task and HYG7 both put out of scope: resolving one against the symbol it claims needs a Swift parser.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

The link repairs and the run-on fix need nobody: they are mechanically checkable and the acceptance says how. Two of the four items are decisions the owner may want.

1. [session] Do item 1 and the run-on fix, then report the before and after counts from the resolver.
2. [owner] Item 2, the `Bands:` line: say whether it is a frozen record of the 2026-08-03 audit or a live index. If you have no preference, the session takes frozen, since that is CI6's reading and the one already agreed.
3. [owner] Item 3, the header style: say bold or heading, and whether the 28 or 132 non-conforming entries are worth restyling. If you have no preference, the session takes the majority form and does not restyle.
4. [owner] Item 4: say whether a fourth CI5 fence is wanted at all. A no closes item 4 and is not a failure.
5. [owner] Say "HYG8 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
