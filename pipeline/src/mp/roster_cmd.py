"""mp roster: manage named-speaker voiceprints (FEAT3-ROSTER).

`enroll` names one of a meeting's speakers (e.g. the "THEM-A" cluster): it reads
that speaker's embedding from `<stem>.embeddings.json` and folds it into the named
person's roster profile. By default it also relabels the meeting's finalized
transcript in place so the name shows immediately (the CLI path). The daemon's
in-app naming passes `--no-relabel` and shows the name through a reversible overlay
instead (FEAT3-UNDO), so an undo can always restore the original diarization label.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from . import storage


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="mp roster", description="Manage the named-speaker voiceprint roster."
    )
    sub = parser.add_subparsers(dest="action", required=True)

    enroll = sub.add_parser("enroll", help="Enroll a meeting speaker under a name.")
    enroll.add_argument("--name", required=True, help="Name to enroll the speaker as.")
    enroll.add_argument(
        "--label", required=True,
        help="The speaker's current transcript label (embeddings key), e.g. THEM-A.",
    )
    enroll.add_argument(
        "--wav", required=True, type=Path, help="Path to the meeting WAV (locates its sidecars)."
    )
    enroll.add_argument(
        "--no-relabel", action="store_true",
        help="Only fold the voiceprint into the roster; leave the transcript labels "
             "untouched. The daemon's in-app naming uses this (FEAT3-UNDO): it shows "
             "the name through a reversible overlay instead of rewriting <stem>.json, "
             "so the original diarization label always survives an undo.",
    )

    unenroll = sub.add_parser(
        "unenroll",
        help="Take back the one voice sample a meeting speaker added to a person (FEAT24).",
    )
    unenroll.add_argument("--name", required=True, help="The person the speaker was enrolled as.")
    unenroll.add_argument(
        "--label", required=True, help="The speaker's transcript label when it was enrolled."
    )
    unenroll.add_argument(
        "--wav", required=True, type=Path, help="Path to the meeting WAV (locates its sidecars)."
    )

    sub.add_parser("list", help="List enrolled roster names.")

    forget = sub.add_parser("forget", help="Remove a name from the roster.")
    forget.add_argument("--name", required=True)
    forget.add_argument(
        "--purge-embeddings", action="store_true",
        help="Also strip the name from every meeting's <stem>.embeddings.json in the "
             "library (SEC22). Opt-in: a whole-person erasure of every meeting's "
             "voice for that name. Undo naming and rename no longer run `forget` "
             "(they run `unenroll`, FEAT24).",
    )
    forget.add_argument(
        "--library", type=Path, default=None,
        help="Library directory for --purge-embeddings (default: recording.output_dir).",
    )

    rename = sub.add_parser("rename", help="Rename a roster person, keeping their voiceprint.")
    rename.add_argument("--old", required=True, help="Current name.")
    rename.add_argument("--new", required=True, help="New name.")

    args = parser.parse_args(argv)

    from .roster import RosterStore

    roster = RosterStore()

    if args.action == "list":
        for name in roster.names():
            print(name)
        return 0

    if args.action == "unenroll":
        wav = args.wav
        # The label's vector is only needed to recognise a sample enrolled before
        # provenance existed; a missing sidecar or label means provenance-only
        # matching, not an error.
        embedding = None
        try:
            edata = json.loads((wav.parent / f"{wav.stem}.embeddings.json").read_text(encoding="utf-8"))
            embedding = (edata.get("embeddings") or {}).get(args.label)
        except (OSError, ValueError, AttributeError):
            pass
        removed, person_removed = roster.unenroll(args.name, wav.stem, args.label, embedding)
        from . import events

        events.emit(
            "pipeline", "roster_unenrolled",
            name=args.name, label=args.label, stem=wav.stem,
            removed=removed, person_removed=person_removed,
        )
        print(f"unenrolled {removed} sample(s) of {args.name!r} for {args.label!r}"
              + (" (person removed)" if person_removed else ""))
        return 0

    if args.action == "forget":
        removed = roster.forget(args.name)
        print(f"{'removed' if removed else 'not found'}: {args.name}")
        purged = 0
        if args.purge_embeddings:
            library = args.library
            if library is None:
                from .config import Config

                library = Config.load().recording.output_dir
            purged = roster.forget_embeddings(args.name, library)
            from . import events

            events.emit("pipeline", "roster_embeddings_forgotten", files=purged)
            print(f"embeddings removed from {purged} meeting(s)")
        return 0 if (removed or purged) else 1

    if args.action == "rename":
        renamed = roster.rename(args.old, args.new)
        if renamed:
            from . import events
            events.emit("pipeline", "roster_renamed", old=args.old, new=args.new)
        print(f"{'renamed' if renamed else 'not renamed'}: {args.old!r} -> {args.new!r}")
        return 0 if renamed else 1

    # enroll
    wav: Path = args.wav
    emb_path = wav.parent / f"{wav.stem}.embeddings.json"
    try:
        data = json.loads(emb_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print(f"no embeddings sidecar at {emb_path}")
        return 2
    embedding = (data.get("embeddings") or {}).get(args.label)
    if not embedding:
        print(f"no embedding for label {args.label!r} in {emb_path}")
        return 2

    roster.enroll(args.name, embedding, stem=wav.stem, label=args.label)
    if not args.no_relabel:
        _relabel_transcript(wav, args.label, args.name)

    from . import events

    events.emit(
        "pipeline", "roster_enrolled",
        name=args.name, label=args.label, stem=wav.stem, relabeled=not args.no_relabel,
    )
    print(f"enrolled {args.label!r} as {args.name!r}")
    return 0


def _relabel_transcript(wav: Path, old_label: str, new_label: str) -> None:
    """Rename a speaker in the meeting's finalized transcript (`<stem>.json` +
    `.md`) and keep the embeddings sidecar key in sync, so the Library shows the
    name at once and a later re-name still resolves."""
    from .markdown import render_markdown

    json_path = wav.parent / f"{wav.stem}.json"
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    segments = data.get("segments") or []
    changed = False
    for seg in segments:
        if seg.get("speaker") == old_label:
            seg["speaker"] = new_label
            changed = True
    if not changed:
        return
    # Atomic (SEC22): a kill mid-rewrite used to truncate the only copy of a transcript.
    storage.atomic_write_text(json_path, json.dumps(data, ensure_ascii=False, indent=2))
    storage.atomic_write_text(wav.parent / f"{wav.stem}.md", render_markdown(data))

    emb_path = wav.parent / f"{wav.stem}.embeddings.json"
    try:
        edata = json.loads(emb_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    embeddings = edata.get("embeddings") or {}
    if old_label in embeddings:
        embeddings[new_label] = embeddings.pop(old_label)
        storage.atomic_write_text(emb_path, json.dumps(edata))
