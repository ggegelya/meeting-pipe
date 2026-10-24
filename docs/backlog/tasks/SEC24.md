# SEC24: the app never tells its user that the other people in a meeting may need to consent, and it stores a voice embedding for every speaker of every meeting with no switch and no end date

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-3, the posture half of PP-4, and its "Fix before anyone else installs it" item 10). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md). **P3 by the root `CLAUDE.md` selling rule**: compliance posture is deferred while the owner is the only user. Promote it before any second person installs the app or the repo is pushed publicly, whichever comes first.

## Context

Verified 2026-10-24.

**Consent.** The meeting prompt asks the owner whether to record; it says nothing about the other participants. A grep of `daemon/Sources`, `docs/GUIDE.md`, `docs/SETUP.md`, `README.md` and `PRODUCT.md` for "all-party", "two-party", "jurisdiction", "wiretap" or any wording about informing participants finds nothing. The go-live assessment's "`auto_consent_apps` records with no prompt" needs narrowing: `ConfigDefaults.autoConsentApps` is `[]`, so by default every recording is prompted. The no-prompt path is opt-in, through that key or the prompt's "Always for {App}" item, which writes the app to `~/Library/Application Support/MeetingPipe/auto_consent.json` (`ConsentStore`). One click, and no later recording of that app is ever confirmed again.

**Voiceprints.** Two stores, both automatic, neither behind a setting:

- Every finalized meeting writes `<stem>.embeddings.json`: one 256-dimension embedding per diarized speaker, keyed by final label (`orchestrate._write_embeddings_sidecar`, "Persist per-speaker embeddings keyed by FINAL label"). That is a stored voice embedding of every participant of every meeting, kept for as long as the recording is kept.
- The owner's own voice is averaged into `~/.config/meeting-pipe/voiceprint.json` from the mic channel of up to 12 meetings (`_VOICEPRINT_ENROLL_CAP = 12`, `VoiceprintStore.update` in `_me_signals`). Named people additionally go into `roster.json` as centroids.

`docs/GUIDE.md`'s glossary tells the user "A voice you name once is recognised in later meetings, until you remove it." Nothing tells them every unnamed voice is stored too. The go-live assessment notes voiceprints are biometric identifiers under Illinois BIPA and special-category data under GDPR, and that it is not legal advice.

## Scope (when promoted)

1. **A one-time acknowledgement before the first recording ever**: a sheet stating that recording other people may require their consent where the user is, and that the app stores voice profiles of meeting participants on this Mac. Acknowledged once, stored in `UISettings`, never shown again. It is a single sheet on the first recording path, not an onboarding flow (the deferral in the root `CLAUDE.md` stands).
2. **`transcription.speaker_recognition`**, a config key and a Preferences toggle. Off means: no `<stem>.embeddings.json` is written, `voiceprint.json` is not updated, and the roster is not matched. Diarization still clusters speakers in memory, so transcripts still read Speaker 1, Speaker 2. Default **off for a new install** and **on for an existing one that already has a `voiceprint.json` or `roster.json`**, so the owner's library keeps working; both defaults are owner-confirmable when this is picked up.
3. **Disclosure where the user decides**: the toggle's caption, the GUIDE "Voices" section and glossary say what is stored, where, and how to remove it.

## Explicitly not / out of scope

- File modes (`voiceprint.json` is `-rw-r--r--`) and making `roster forget` cascade into every `<stem>.embeddings.json`. That is [SEC22](./SEC22.md).
- Deleting a meeting's derived files ([STOR7](./STOR7.md)) and retention ([REC20](./REC20.md)).
- The iCloud-synced default library location ([STOR6](./STOR6.md)).
- Removing "Always for {App}". It is the owner's convenience; the acknowledgement covers the disclosure.
- Legal review. The owner gets one before any public push; no session writes legal text beyond the plain statement in scope item 1.
- Whether the self-voiceprint surface stays at all: [FEAT18](./FEAT18.md)'s decision table.

## Acceptance

- `MeetingPipeTests`: the acknowledgement shows on the first recording path when not yet acknowledged, and never after; acknowledging persists across relaunch. Nothing on any launch path presents it.
- `pipeline/tests`: with `speaker_recognition = false`, a finalize writes no `<stem>.embeddings.json`, leaves `voiceprint.json` unchanged, and labels speakers without roster names; with it true, behaviour is unchanged from today (existing finalize tests stay green unchanged).
- The default-resolution rule (new install off, existing profile on) is pinned by a test on each branch.
- `python3 scripts/truth_fences.py config` green with the new key documented in `config.example.toml` and README; `bash scripts/ci-local.sh` green.
- `docs/GUIDE.md` updated in the same commit.
