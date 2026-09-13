"""Offline process fixture: real command catch boundaries, synthetic exceptions."""
import sys
from pathlib import Path
from types import SimpleNamespace

import anthropic
import httpx

from mp import ask, orchestrate, summarize
from mp.config import Config

command, args = sys.argv[1], sys.argv[2:]
request_id = "req_ask0123456789" if command == "ask" else "req_summary0123456789"


def fail(*args, **kwargs):
    response = httpx.Response(400, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"),
                              headers={"request-id": request_id})
    raise anthropic.BadRequestError(
        "Your credit balance is too low to access the Anthropic API. " + "synthetic frame\n" * 2000 + "diagnostic-end",
        response=response, body={"error": {"type": "invalid_request_error"}},
    )


if command == "ask":
    ask.entry.prepare = Config
    ask.visibility.visible_stems = lambda root: set()
    ask.embed_index.default_embedder = lambda: None
    ask.embed_index.load_or_build = lambda *a, **kw: SimpleNamespace(chunks=[1])
    ask.answer_question = fail
    code = ask.main(args)
elif command == "summarize":
    summarize.summarize = fail
    code = summarize.main(args)
elif command == "run-all":
    orchestrate.run_all = fail
    code = orchestrate.main(args)
else:
    raise AssertionError(command)
assert not list(Path(args[0]).parent.glob("*.error.json")) if command != "ask" else True
sys.exit(code)
