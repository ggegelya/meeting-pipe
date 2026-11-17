"""OBS6: the `env` fence in `scripts/truth_fences.py`: every MP_* the daemon exports is read
under `pipeline/src`. Loaded by path and run over scratch sources (the `test_link_fence.py` precedent)."""
from __future__ import annotations

import importlib.util
from pathlib import Path

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"
_spec = importlib.util.spec_from_file_location("truth_fences_env", _FENCES)
assert _spec and _spec.loader
fences = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fences)


def test_an_unread_setenv_export_fails():
    swift = {"App.swift": 'setenv("MP_FOO", "1", 1)\n'}
    hits = fences.unread_env_exports(swift, {"mp/x.py": 'os.environ.get("MP_BAR")\n'})
    assert hits == ["App.swift:1: `MP_FOO` is exported to `mp` but nothing under pipeline/src reads it"]


def test_every_export_shape_is_seen_and_a_reader_clears_it():
    swift = {"L.swift": (
        'env["MP_A"] = x\n'
        'let extra = ["MP_B": "1"]\n'
        'static let supervisedEnvKey = "MP_C"\n'
        'setenv("MP_D", "1", 1)\n'
        'static let doneCategory = "MP_DONE"\n'   # a notification id, not an env var
    )}
    assert sorted(fences.env_exports(swift)) == ["MP_A", "MP_B", "MP_C", "MP_D"]
    reader = {"mp/x.py": 'for k in ("MP_A", "MP_B", "MP_C", "MP_D"): os.environ.get(k)\n'}
    assert fences.unread_env_exports(swift, reader) == []


def test_the_real_tree_passes(capsys):
    assert fences.check_env()
