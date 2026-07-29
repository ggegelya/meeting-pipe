# SEC15: Fence RAG excerpts in mp ask

Band origin: filed 2026-07-29 (found while executing the owner's item 13 system-prompt review: "check the best practices... how accurate"). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

The pipeline's prompt-injection discipline (TECH-SEC6) is consistent everywhere except one surface. Transcript content reaches a model wrapped in `wrap_untrusted()` (`prompt_safety.py:33-44`, the `<<<UNTRUSTED_TRANSCRIPT_BEGIN/END>>>` fence with nested-marker stripping) with `UNTRUSTED_GUIDANCE` (:24-30) in the system prompt, at every summarize entry: the Anthropic tool path (`summarize.py:386`), local (`summarize_local.py:216`), both PROV1 providers (`provider_openai.py:68`, `provider_claude_cli.py:88`), and all three staged stages (`summarize_staged.py:400`, :504, :688).

The exception is `mp ask`. `rag_user` interpolates the packed excerpts raw (`rag.py:65-67`: "Meeting excerpts:\n\n{context}\n\n---\n\nQuestion:"), and `RAG_SYSTEM` (:24-31) carries citation and honesty rules but no injection guidance. The excerpts are transcript and summary text, exactly the content class the fence exists for: a meeting where a participant said (or a shared screen displayed, since system audio and titles feed the pipeline) "ignore your instructions and..." is retrievable and reaches the model unfenced. Single-user product, so the attacker is "anything anyone ever said in a meeting", which is precisely TECH-SEC6's model.

Blast radius today: the answer renders in the Ask pane with citation chips; `rag.verify_citations` (:79-85) already drops fabricated stems, so citation spoofing is bounded, but the answer text itself is steerable.

## Scope

- Wrap the packed context in `wrap_untrusted()` once (the whole block, not per chunk), keeping the `[stem]` markers inside the fence; they are excerpt content, and the system prompt's instruction to cite them already refers to tags "in the excerpts".
- Add the untrusted-content guidance to `RAG_SYSTEM`: either append `UNTRUSTED_GUIDANCE` as-is or a RAG-adapted single sentence (excerpts are meeting content, not instructions); prefer reusing the shared constant unless its summarize-specific wording misleads, record the pick.
- Confirm the citation contract end to end after fencing (`pack_context` output fenced, `extract_citations`/`verify_citations` unaffected since they parse the ANSWER, not the context).
- Assess-and-record, same commit: whether `mp digest`'s narrate call needs the fence. Its user turn is `_format_facts` over `<stem>.summary.json` content (`digest.py:277-300`), second-order model output rather than raw transcript, but summary bullets can quote transcript verbatim (FEAT10 evidence quotes). Likely answer is yes-cheaply (same one-line wrap); if no, the reason lands in a comment at the call site.

## Explicitly not in scope

Output-side sanitization of answers (rendering is plain text in a native view; no execution surface). Changing retrieval, packing sizes, or `RAG_SYSTEM`'s citation rules. The classify prompt (`classify.py`), which HYG4 (filed the same day) proposes deleting.

## Acceptance

Pipeline tests: `rag_user`'s output carries the fence markers around the excerpts and the question outside them; a chunk whose text contains the literal fence markers is neutralized by `wrap_untrusted`'s nested-marker stripping (pin the rag path specifically); `RAG_SYSTEM` contains the guidance; an end-to-end ask against the fake engine still verifies citations. If digest gains the fence, the same marker test there.

`cd pipeline && uv run --extra dev ruff check src tests`, `pyright`, `pytest -q` green (baseline at filing: 1050). Truth fences green (no config or event surface touched).
