# HYG13: the repo has no project skills, so cross-tree contract changes, daemon UI work, ADRs and live verification each depend on a session reassembling the procedure from three CLAUDE.md files

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([AI harness audit](../../audits/2026-10-24-ai-harness-audit.md) proposals B2 to B5 and C5; B1 is [HYG11](./HYG11.md)). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Checked 2026-10-24:

- **No project skill is tracked.** `.gitignore` ignores the whole of `.claude/skills/` ("The impeccable design skill is installed locally ... it is personal tooling, not product code"), so `git ls-files .claude/skills` is empty and any skill a session writes there is silently untracked.
- **`design/SKILL.md` is a portable descriptor, not a project skill.** `design/README.md` says "If you download this folder and drop it into `~/.claude/skills/`, it works as an Agent Skill." Its description targets HTML artifacts and mocks ("generate well-branded interfaces and assets ... for production or throwaway prototypes"). It is never discovered from this repo, and it says nothing about `Tokens.swift`, the CI token greps in `ci-local.sh design_tokens`, or the owner-eyeball handoff that every daemon UI task ends in (the menu-bar app cannot be screenshotted by a session).
- **The contract-change procedure is scattered.** Changing a cross-tree surface (the `<stem>.meta.json` sidecar, `<stem>.publish.json`, the restore plan, a config key, an event category) touches some of: the Swift writer, the Python reader, `scripts/gen_contract_fixtures.py`, `test_workflow_overlay.py`, a `CONVENTIONS.md` section, `truth_fences.py`. The pointers live in the root `CLAUDE.md` Quick reference, `daemon/CLAUDE.md` (`MeetingMetaSidecar.build` rule, `<stem>.summary.json` rule) and `pipeline/CLAUDE.md` (`speaker_overlay` paragraph), and in `CONVENTIONS.md`'s "Cross-tree golden fixtures".
- **The ADR format is repo-specific.** `docs/decisions/NNNN-slug.md`, a property table (`Status`, `Date`, `Decision Makers`, `Technical Area`, `Related Tasks`, `Supersedes`), highest number 0016, and 0012 and 0013 were never used. The owner's global `writing` skill and `writer-agent` pull toward MADR under a `<docs-root>` that is still a placeholder ([DOC18](./DOC18.md) is the precedence half).
- **Live verification has no written procedure**: `scripts/rebuild.sh`, `scripts/tail-events.sh`, `scripts/valid1_check.py`, what to read in `events.jsonl`, and the gate for writing an `owner-verification.md` row (that file's header and `/tech-task` step 8).
- **Backlog queries are done by hand.** The owner has asked sessions for "independent tasks that need no decision from me" and "tasks needing a big recording base"; each time a session reads the 208 KB active backlog from scratch.

## Scope

1. `.gitignore`: ignore `.claude/skills/impeccable/` instead of `.claude/skills/`, so impeccable stays local and project skills are tracked.
2. Four skills under `.claude/skills/<name>/SKILL.md`, each with a description that names its trigger words, each pointing at the files that are the source of truth rather than copying them:
   - **`contract-change`**: one checklist per cross-tree surface (writer, reader, fixture generator, overlay test, CONVENTIONS section, fence). The three `CLAUDE.md` pointers are replaced by one line each naming the skill path, since a skill loads only on a description match, which is too weak to be the only guardrail.
   - **`daemon-ui`**: the token contract (`Tokens.swift` names mirror `design/colors_and_type.css`), the JSX mockup-first flow in `design/ui_kits/macos_app/`, the three `design_tokens` greps, and a structured owner-eyeball handoff (what changed, where to click, what a pass looks like). It references `design/README.md` and `design/SKILL.md` in place. **`design/SKILL.md` is not moved**, a deliberate deviation from the harness audit's proposal: it is the design folder's portable descriptor and moving it breaks the drop-in use its README documents.
   - **`adr`**: the property-table format, numbering (next free number above the highest; do not fill 0012 or 0013), status vocabulary, and that ADRs live in `docs/decisions/`, never a global docs root.
   - **`verify-live`**: the three scripts, the event categories that confirm a recording, lifecycle and publish, and the owner-verification gate quoted by path, not restated.
3. **`/backlog-query`** as `.claude/commands/backlog-query.md`: read-only. Takes a free-text filter, reads the active ToC and `owner-verification.md`, opens `tasks/<ID>.md` only for rows the filter needs, and returns a table (ID, title, status, priority, why it matches, what blocks it). It never edits a file and never commits; the command says so in its first line.

## Explicitly not / out of scope

- The worktree landing text: [HYG11](./HYG11.md) (a shared file, not a skill).
- Moving `daemon/CLAUDE.md`'s UI or capture rules into a skill. Guardrails must load by directory, not by description match; that is the [DOC15](./DOC15.md) amend's nested `CLAUDE.md`.
- `impeccable` (web-oriented, local, stays ignored).
- Changes to [`ARCH10`](./ARCH10.md)'s or `ARCH9` (shipped, in `q6-final.md`)'s surfaces. Whichever lands later updates the `contract-change` checklist in the same commit.
- `/tech-task` process steps: [HYG14](./HYG14.md).

## Acceptance

- `git ls-files .claude/skills` lists the four `SKILL.md` files; `git check-ignore .claude/skills/impeccable/SKILL.md` still matches.
- Each skill names only paths and symbols that exist (`python3 scripts/truth_fences.py links` green covers the relative links; the pickup greps every backticked symbol once).
- The root, `daemon/` and `pipeline/` `CLAUDE.md` contract pointers each name `contract-change` in one line, and `python3 scripts/truth_fences.py claude` stays green with no net growth in any of them.
- `/backlog-query` answers the owner's two recorded questions in a dry run, and its output for "needs no owner decision" excludes every row in `owner-verification.md`.
- `bash scripts/ci-local.sh fences` green. No source code changes.
