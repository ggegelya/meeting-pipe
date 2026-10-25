# ARCH17: Date formatting has no owner: the recorder's stem formatter lacks the en_US_POSIX locale its reader sets, and ISO-8601 parsing is hand-rolled four ways

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) SW7). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-read in code and measured on 2026-10-25 (base `01e904a`, macOS 26.5.1). Re-checked at filing: the audit's suspicion that `MeetingStore.parseRunTimestamp` and `DiagnosticsLog.isoDate` fail on a Python microsecond timestamp does not hold on this OS, and no current writer of the fields they read emits microseconds, so that half is a latent risk, not a live defect; the stem-locale half reproduces through the calendar, not the 12-hour setting.

**The stem writer and its reader disagree on locale.** The stem is every meeting's primary key: `MeetingRecorder`'s start path builds it with a fresh `DateFormatter()` and only `formatter.dateFormat = "yyyyMMdd-HHmmss"`, then names `\(stamp).wav`, `.mic.wav` and `.system.wav`. The reader, `MeetingFormatters.stem` (beside `MeetingStore`, used by `MeetingStore.parseStem`), sets the same format plus `f.locale = Locale(identifier: "en_US_POSIX")` and `f.timeZone = TimeZone.current`. Apple's Technical Q&A QA1480 ("NSDateFormatter and Internet Dates") is the rule: a fixed-format string must set `en_US_POSIX`, or the user's locale and calendar settings rewrite the output. Measured with a scratch script on 2026-10-25, a formatter built like the recorder's renders a 2026-06-21 instant as `25690621-...` with `-AppleLocale th_TH` as the default locale (Buddhist calendar), and with the locale set to `ja_JP@calendar=japanese` as `00080621-...` and to `ar_SA` as Arabic-Indic digits for the Hijri date 1448-01-06, while a POSIX formatter gives `20260621-...` in every case. The consequences are concrete: `MeetingStore.parseStem` reads `25690621-135320` as the year 2569 (so the meeting sorts 543 years in the future) and the `ar_SA` stem as 1448-01-06; Python's `prep` stem parse (`datetime.strptime(stem, "%Y%m%d-%H%M%S")`, documented as mirroring `parseStem`) also returns 2569 and raises on the Arabic digits, which it turns into `None`. QA1480's classic 12-hour case did not reproduce: `-AppleICUForce12HourTime YES` left `HH` at 24-hour on this OS. The owner's locale is `en_US@rg=uazzzz` (Gregorian, Latin digits), so nothing has misfired yet; one Language & Region calendar change would.

**ISO-8601 parsing is hand-rolled in four helpers with three strategies.** `.withInternetDateTime` appears at 10 sites in 7 files under `daemon/Sources/MeetingPipe`, and `ISO8601DateFormatter()` is constructed 11 times. The four parsers:

- `LastBackup.parseISO8601`: fractional first, then strips `\.\d+` and retries plain. Its comment says the "naive two-attempt version (fractional, then plain) silently fails on every real Python timestamp" because fractional mode "expects milliseconds". Measured on 2026-10-25, that is false on macOS 26.5.1: a `[.withInternetDateTime, .withFractionalSeconds]` formatter parses `2026-07-11T14:32:05.123456+00:00` and `...123456Z` (truncating to milliseconds). Whether it held on an earlier OS, or on the declared macOS 14 floor, is unmeasured.
- `MeetingStore.parseRunTimestamp` (`run.json`'s `ts`): plain first, then fractional.
- `DiagnosticsLog.isoDate` (events log `ts`): fractional first, then plain.
- `CorrectionsTab.prettyTimestamp`: plain only, with a new `ISO8601DateFormatter()` per call.

What they read today: `run.json`'s `ts` comes from `corrections._now_utc_iso` (`isoformat(timespec="seconds")`, `+00:00` spelled `Z`) or a caller's `isoformat(timespec="seconds")` (`dogfood`); Python's `events.py` writes `isoformat(timespec="milliseconds")` with `Z`, and Swift's `Logger` writes fractional milliseconds. Every one parses on this OS. All four fail on a naive timestamp with no offset (`2026-07-11T14:32:05.123456`), the shape the audit's seven Python DTZ findings (naive `datetime` calls) can produce, though none of those feeds these fields today.

So nothing misreads a date today, but four parsers encode three beliefs about the same format, one documents a failure that does not occur, and the next timestamp field added picks whichever copy is nearest.

## Scope

1. **One stem formatter.** Add `MeetingFormatters.stemString(from: Date) -> String` over the existing `MeetingFormatters.stem` (POSIX locale, current time zone), and have `MeetingRecorder` call it in place of its local `DateFormatter()`. `DateFormatter` is thread-safe for formatting on macOS, so sharing the static is fine.
2. **One ISO-8601 owner**, `ISO8601` in a new `daemon/Sources/MeetingPipe/Util/ISO8601.swift`: `parse(_:) -> Date?` accepting whole seconds or any fraction length, with `Z` or a numeric offset (fractional formatter, then plain, then the strip-and-retry kept as a belt for older OSes, with its comment stating the 2026-10-25 measurement), and `format(_:fractional:)` whose output is byte-identical to today's writers. Migrate the four parsers above, and the writers in `Logger`, `CorrectionStore`, `PipelineFailureSidecar`, `PipelineLauncher` (the `"ts"` write) and `FailurePresentation`. `LastBackup.parseISO8601` and `RestoreFlow`'s use of it go through `ISO8601.parse`.
3. **Correct the false comment** in `LastBackup` as part of 2.

## Explicitly not / out of scope

- `MeetingPipeCore`'s `LogMuteAdapter` and `SlimCoreMuteLog` formatters: they parse Teams' own log formats (not ISO-8601 in our sense), already set `en_US_POSIX`, and Core cannot depend on the executable target.
- Display formatters (`MeetingFormatters.shortTime`, `fullDateTime`, `RelativeMeetingDateFormatter`, `DiagnosticsView`, `QuickFindWindow`, `DigestsView`): user-facing, so they are meant to follow the user's locale.
- Python's naive datetimes: the audit counted seven DTZ findings and proposed no task for them (TYPE2's rule selection leaves DTZ off), so they are an observed, unfiled adjacency. Python's stem derivation is PIPE33's (`mp.meeting_files`). `WorkflowCorrectionStore`'s `JSONDecoder` `.iso8601` strategy is its own private round-trip and stays.
- Renaming or migrating existing stems. No owner stem is affected (Gregorian locale), and a stem is a primary key.

## Acceptance

- New `ISO8601Tests`: `parse` accepts `...05Z`, `...05+00:00`, `...05.123Z`, `...05.123456+00:00`, `...05.123456Z`, `...05.1+00:00`, each to the expected instant at millisecond precision; returns `nil` for a naive `...05.123456` and for garbage; `format` then `parse` round-trips in both modes; `format` output equals today's `Logger` and `CorrectionStore` strings for a fixed date.
- `MeetingStore.namesChangedSinceSummary` and `DiagnosticsLog.parseLine` tests with a microsecond Python `isoformat()` `ts`.
- A stem test: `MeetingStore.parseStem(MeetingFormatters.stemString(from: d))` equals `d` truncated to whole seconds, the string is 15 ASCII characters, and `MeetingFormatters.stem.locale.identifier == "en_US_POSIX"`. A source fence: `MeetingRecorder.swift` contains no `DateFormatter()`, and `ISO8601DateFormatter(` appears in `daemon/Sources/MeetingPipe` only in `Util/ISO8601.swift`.
- Evidence (confirms, does not gate): the scratch script run with `-AppleLocale th_TH` shows `stemString(from:)` giving a `2026...` stem, quoted in the commit body.
- `cd daemon && swift build` and `swift test` green, about 8 new tests with the count in the commit body; `bash scripts/ci-local.sh daemon` green.
