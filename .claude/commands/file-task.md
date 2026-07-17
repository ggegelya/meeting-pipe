---
description: File a new backlog task - dedupe, ID, band, ToC row, tasks/<ID>.md spec, one commit
---

You're filing a new task into the active backlog. Input (an incident, a gap, a feature ask, or a finding): $ARGUMENTS

1. Read the active backlog: the highest-numbered `docs/backlog/meetingpipe-q<N>-backlog.md` (currently `meetingpipe-q6-backlog.md`). You need its ToC table, the Priority bands section, and the structural-change notes; full specs live one file per task in `docs/backlog/tasks/<ID>.md`.
2. Dedupe before writing anything: search the ToC, `docs/backlog/tasks/`, and the quarter archives (`q*-final.md`) for tasks covering the same ground, by subsystem keywords as well as the obvious name. If an open task covers it, propose amending that task (a new paragraph in its `tasks/` file plus an updated Comment) instead of filing a duplicate. If a shipped task regressed, say so; that is a reopen conversation with the owner, not a silent refile.
3. Pick the ID: reuse the letter band the work belongs to (PIPE, MIC, DET, END, REC, ASR, DIAR, UX, DOC, CI, T, STOR, LOCAL, AI, DV, CAL, HYG, ARCH, CONC, AUTO, DIST, SEC, FEAT, ...; the ToC and archives are the vocabulary). Take the next free number: grep every `docs/backlog/*.md` AND the whole repo for the candidate, since code comments and ADRs also carry IDs. A new letter band is allowed when nothing fits; say so explicitly.
4. Band it per the backlog's own definitions: P1 is correctness, a broken core promise, or a high-leverage must-have; P2 is polish, power-user payoff, and half-closed loops; P3 is deferred (listed, not built); P4 exists for waived validation legs (the EGRESS1 precedent). When unsure, file P2. When you file P1, name the broken promise in the Comment and note the owner may re-band (the DIAR2 precedent). Never inflate the band to make a task look important.
5. Category: reuse the ToC's existing Category vocabulary (Pipeline, Detection, Recording, Transcription, UX, Docs, CI, Tests, Storage, Intelligence, Local models, Hygiene, Architecture, Automation, Distribution, Feature, Validation, Concurrency, Sync, Brand).
6. Write the ToC row (six columns: ID, Task, Category, Status, Priority, Comment). Status `new`. The Comment is the filing date plus the compressed why (for an incident: what happened, in one breath) plus the one-line scope. Append the row near the end of the table beside its band peers; the table accretes chronologically and exact position is not load-bearing.
7. Write `docs/backlog/tasks/<ID>.md`, matching the existing files:
   - `# <ID>: <Task title>`, then the provenance line (`Band origin: filed <date> (...). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).`).
   - Context: what prompted the task, with the evidence inline (log lines, measurements, stems, `file:line` references) and absolute dates, so the pickup session needs no archaeology. For an incident, the full causal chain, including why each layer behaved as it did.
   - Scope: the smallest change that fixes the class, with the seam named (file + function). Record alternatives only when the pickup session must not re-litigate them.
   - Explicitly not / out of scope: rejected approaches with the reason, and observed-but-unfiled adjacencies named so they are not lost.
   - Acceptance: concretely checkable. Name the tests to pin (with their scenarios), the suites and linters that must stay green, and any log line or event the change must emit. "Works" is not an acceptance bar; a task that cannot fail verification is not ready to file.
8. House rules for everything you write: no em-dashes (CI fails on U+2014 in changed lines); single-line paragraphs, no hard wrap; absolute dates, never "today"; evidence over adjectives.
9. Commit on `main` with the repository's configured git identity: `<ID>: file <short summary>` (e.g. `PIPE10: file the sleep-resilient summarize retry task`). The filing is its own commit, separate from any other work in the session. Don't push.
10. Summarise: the ID, the band and why, what the dedupe step searched, and what you deliberately left out of scope.

If the input is too thin to write a checkable acceptance bar, stop and ask the owner for the missing piece instead of filing a vague task.
