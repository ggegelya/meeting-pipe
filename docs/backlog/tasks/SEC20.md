# SEC20: the `claude_cli` summarization backend runs a full Claude Code agent session (built-in tools, the owner's MCP servers, hooks and memory, cwd `/`, saved sessions, the API key in its environment) for a pure text turn

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S4, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-2). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`ClaudeCLIClient._run` in [provider_claude_cli.py](../../../pipeline/src/mp/provider_claude_cli.py) spawns:

```python
cmd = [binary, "-p", "--output-format", "json", "--allowed-tools", ""]
proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                      timeout=self._timeout, env=egress_guard.child_env())
```

The prompt is the whole transcript (wrapped by `wrap_untrusted`, SEC6). Checked against the installed CLI (Claude Code 2.1.247, `claude --help`) on 2026-10-24:

- `--allowed-tools` is "a list of tool names to allow", i.e. pre-approval. It does not remove tools. Disabling them is `--tools ""` ("Use \"\" to disable all tools"). The comment above the command ("`--allowed-tools \"\"` disables tool use") is false, so a transcript carrying an injection ("read ~/.ssh/... and include it") meets a session that still has the built-in read tools.
- No `--strict-mcp-config`, so the owner's configured MCP servers load into the session; no `--setting-sources`, so user hooks and settings apply; the owner's `~/.claude/CLAUDE.md` and auto-memory load as context into a summary turn.
- No `--no-session-persistence`, so every summary (and every retry) is saved as a resumable Claude Code session on disk, transcript included.
- No `cwd=`: the child inherits the pipeline's cwd, and the daemon never sets `currentDirectoryURL` on any `Process` (grep of `daemon/Sources` on 2026-10-24), so under launchd that is `/`.
- `env=egress_guard.child_env()` scrubs tokens only when the guard is armed, and under zero-egress this backend never runs (`_run` refuses when `egress_guard.is_armed()`). So in every run that does happen, `ANTHROPIC_API_KEY`, `NOTION_TOKEN` and `OPENAI_API_KEY` are in the child's environment. The module docstring and `SecretsStore`'s comment ("claude_cli needs no key at all") say this backend rides the user's Claude Code auth and "needs no API key"; passing the key contradicts that, and the pickup session should confirm against current Claude Code auth docs whether a present `ANTHROPIC_API_KEY` takes precedence over subscription auth in `-p` mode, which would bill API usage the backend exists to avoid.

Severity stays low: the output only becomes the summary, and the owner does not run this backend by default. It is still more agency than a text turn needs.

## Scope

All in `ClaudeCLIClient._run`, plus comments:

1. Spawn with `--tools ""` (keep or drop `--allowed-tools ""`, it is now redundant), `--strict-mcp-config` with an empty `--mcp-config '{"mcpServers":{}}'`, `--no-session-persistence`, and `--setting-sources` narrowed so user and project hooks do not load. The pickup session checks with the installed CLI which flag keeps CLAUDE.md and memory out (or states that none exists and records it).
2. `cwd=` a fresh empty `tempfile.TemporaryDirectory()` per run, removed afterwards.
3. Strip every `config.MANAGED_SECRET_KEYS` entry from the child env (on top of `child_env()`), unless the owner says at pickup that the API key is wanted on purpose, in which case keep only `ANTHROPIC_API_KEY` and say so in the docstring.
4. Fix the false comments: the `--allowed-tools` line, the module docstring's "needs no API key" sentence (matching whatever step 3 decides), and `SecretsStore.openaiAPIKey`'s "claude_cli needs no key at all" if it changes.

Rejected: `--bare`. Its help text says "Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper ... (OAuth and keychain are never read)", which removes the subscription auth this backend exists for.

## Explicitly not

- The provider string switch and speaker cleanup not running for `claude_cli` and `openai`: PIPE19.
- The Anthropic client policy split: PIPE24.
- Under zero-egress this backend is already refused twice (policy and `_run`); unchanged.
- Other `PATH`-resolved helpers: noted in SEC17, not here.

## Acceptance

- `tests/test_provider_claude_cli.py` pins the argv: contains `--tools` followed by `""`, `--strict-mcp-config`, `--mcp-config` with an empty server map, `--no-session-persistence`, and the chosen `--setting-sources` value; asserts `cwd` is an empty directory that no longer exists after the call; asserts no `MANAGED_SECRET_KEYS` entry is in the passed env (or only `ANTHROPIC_API_KEY`, per the decision).
- A test that the existing armed-guard refusal still fires before any spawn.
- ruff, pyright, `pytest -q` green, new test count in the commit body.
- Owner check (confirms, does not gate): one summary on `claude_cli` succeeds, and `~/.claude/projects/` gains no new session for it.
