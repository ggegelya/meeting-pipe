"""OBS5: `mp logs` leaves the daemon's per-process `launch_id` out of a listing.

Every daemon row carries it, so printing it would add the same 36 characters to every line;
`--json` still emits it, since `_format` only shapes the human listing.
"""

from mp.logs_cmd import _format


def test_format_leaves_launch_id_out_of_the_listing() -> None:
    line = _format({
        "ts": "2026-11-18T10:00:00.000Z",
        "category": "main",
        "action": "launched",
        "launch_id": "5f0c0000-0000-0000-0000-000000000000",
        "previous_exit": "quit",
    })
    assert "launch_id" not in line
    assert 'previous_exit="quit"' in line
