# ADR 0003: Filesystem as library source of truth

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Accepted           |
| **Date**            | 2026-05-18         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Library            |
| **Related Tasks**   | TECH-A1, TECH-A2   |

## Context

The library needs to list every recorded meeting, surface its title,
attendees, summary, and transcript, and support a fast quick-find from
the menu bar. The library state has to survive daemon restarts, a fresh
checkout on a second Mac, and direct user inspection (the user
periodically opens the recording folder to manually move or delete
files). The pipeline writes one stem per meeting (`<stem>.wav`,
`<stem>.json`, `<stem>.meta.json`, `<stem>.summary.json`) and the daemon
reads them back to build the library list.

The original Q2 plan called this task "SQLite-backed library." On
implementation, the team chose to keep the filesystem layout as the
source of truth and build an in-memory index over it rather than
introducing a database.

## Decision Drivers

- **The recording folder must remain user-inspectable.** The user
  occasionally hand-edits a sidecar JSON, drops a recording into iCloud
  Drive, or moves it to an external archive. A database that does not
  reflect those changes is broken from the user's perspective.
- **Single-user, single-machine scope.** The library does not need
  concurrent writers, transactional updates, or relational queries
  beyond filter-by-date and filter-by-workflow.
- **No new third-party dependency.** Adding GRDB or SQLite.swift means
  a vendored binary, a schema-migration path, and a new failure mode
  (corrupted SQLite, locked WAL file). The dependency surface is
  deliberately small.
- **Re-derivable from disk.** If the index is lost, scanning the
  recording folder rebuilds it in seconds. There is no canonical state
  in the index that the filesystem does not already carry.

## Options Considered

### Option A: SQLite (GRDB or SQLite.swift) with FTS5 for search

Pros: indexed queries, FTS5 for transcript snippet search. Cons: a new
dependency; the database has to be kept in sync with the filesystem,
which means a watcher and a migration story; the user's hand-edits to
sidecars do not automatically reflect; a corrupt DB silently hides
meetings.

### Option B: Core Data

Pros: built into Foundation; nicer integration with SwiftUI via
`@FetchRequest`. Cons: same sync-with-filesystem problem as Option A,
plus the Core Data store is opaque to the user (`xcdatamodeld` is not
human-readable) and the migration story is heavy.

### Option C: Filesystem as source of truth, in-memory index built at startup

Pros: zero new dependency; the filesystem is the canonical state; the
user can move, rename, or delete files and the next library refresh
picks it up; full-text search runs against the on-disk transcript JSONs
directly (or via NSMetadataQuery + Spotlight if needed). Cons: a fresh
scan on every refresh has linear cost in the number of meetings, which
becomes noticeable past about 1000 meetings.

## Decision

**Option C.** `MeetingStore.swift` scans the recording folder, reads
each `<stem>.meta.json` / `<stem>.summary.json`, and holds an in-memory
list. The list is rebuilt on the daemon's refresh tick (or explicit
user-triggered refresh). Quick-find is implemented in-process against
the in-memory list and the on-disk transcripts.

## Consequences

- The library does not scale beyond the user's actual recording volume
  without further work. At the personal-use scale (single user, single
  Mac, a few hundred meetings per year), this is fine.
- Hand-edits to sidecars are honored without explicit invalidation.
- No SQLite or Core Data dependency. Tests are simpler: a fixture
  directory of sidecars is enough.
- TECH-A2 ("Full-text search via FTS5") was reframed during
  implementation; the FTS5 backend is not present in the codebase. If
  search performance becomes a real bottleneck, the trigger to revisit
  is "quick-find takes longer than 200 ms on the user's library."
- TECH-A4 (orphan-recording reaper) is the natural complement: when the
  filesystem is the source of truth, file-vs-row drift is impossible,
  but a sidecar can still reference a missing WAV or vice versa.
