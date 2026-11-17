"""OBS6: what the daemon's Verbose logging toggle does to a pipeline run.

The daemon exports ``MP_VERBOSE=1`` when the toggle is on (`AppDelegate`). This sets
the ``mp`` logger, not the root, to DEBUG, so the ``mp.*`` decision lines
(workflow overlay, sink selection, the summarize path, the no-speech and
suspect-transcript guards) reach whatever handler the run configured, while
``httpx``, ``urllib3`` and the mlx stack stay at INFO and cannot log request
detail. A debug line never carries transcript or summary text.
"""
from __future__ import annotations

import logging
import os
from collections.abc import Mapping

ENV = "MP_VERBOSE"


def configure(env: Mapping[str, str] | None = None) -> bool:
    """Set the ``mp`` logger to DEBUG when ``MP_VERBOSE`` is ``"1"``; return whether it did."""
    on = (os.environ if env is None else env).get(ENV) == "1"
    if on:
        logging.getLogger("mp").setLevel(logging.DEBUG)
    return on
