"""`mp index-prune [--index-dir P] <stem>...`: drop deleted meetings' rows from the
semantic search index cache (STOR7). The daemon runs it after a delete, once per batch.

Touches only the index under `~/Library/Caches/meeting-pipe/ai2-index`: no library file,
no config, no sink, no engine, so it does not arm the egress guard (see
`test_entry_contract.py`'s exemptions)."""

from __future__ import annotations

import argparse
from pathlib import Path

from .embed_index import DEFAULT_INDEX_DIR, prune_stems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="mp index-prune",
        description="Drop deleted meetings' rows from the semantic search index cache.",
    )
    parser.add_argument("--index-dir", type=Path, default=DEFAULT_INDEX_DIR)
    parser.add_argument("stems", nargs="+")
    args = parser.parse_args(argv)
    removed = prune_stems(args.index_dir, args.stems)
    print(f"pruned {removed} rows for {len(args.stems)} meetings")
    return 0
