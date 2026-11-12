# Security review, 2026-11-12

Whole-repo, read-only review focused on prompt injection and other AI threats plus common vulnerability classes. Method: four parallel finder passes (AI/LLM, Python pipeline, Swift daemon, supply chain and CI) produced 31 raw findings; each was deduplicated against the filed backlog and then adversarially verified by a separate pass that re-read the code, and in places ran in-process checks or a throwaway offline probe. Severities below are the verified ones, not the finders'. Code is cited by symbol; the commit reviewed was `c3d5fc0d` (LOCAL22).

No finding is High unconditionally. Finding 1 is High whenever the local model server is up (local, `auto`, NDA and regulated runs, and the opt-in warm preload), and Medium as exposure on a config whose backend is `anthropic` with preload off.

## New findings and where they were filed

| # | Severity | Finding | Filed as |
|---|---|---|---|
| 1 | High while up / Medium | `mlx_lm.server` loads any model a request names (`model`, `draft_model`, `adapters`) and executes its `config.json` `model_file`; no auth, CORS `*`, text/plain POST accepted | [SEC27](../backlog/tasks/SEC27.md) |
| 2 | Medium | Every online server start re-resolves Hugging Face `main` and pulls `*.py`, so an upstream commit is code execution (SEC11 pinned only prefetch) | [SEC27](../backlog/tasks/SEC27.md) |
| 7 | Low | Server reuse fails open: any listener on the port that `served_identity` identifies as not `mlx_lm.server` is reused | [SEC27](../backlog/tasks/SEC27.md) |
| 3 | Medium | Markdown sinks write model text and the meeting title unsanitized: remote-image beacons and exfil, still active under NDA and regulated mode; the title path needs no model | [SEC28](../backlog/tasks/SEC28.md) |
| 3b | Low | `detected_language` written raw into Obsidian front matter; a newline injects keys | [SEC28](../backlog/tasks/SEC28.md) |
| 4 | Medium | The prior-meeting block (AI6) puts transcript-derived decisions and tasks into the trusted system prompt outside the untrusted fence | [SEC29](../backlog/tasks/SEC29.md) |
| 5 | Low | In-app model output renders clickable links of any scheme (`meetingpipe:`, `file:`, `smb:`, https exfil); no `OpenURLAction` anywhere | [SEC30](../backlog/tasks/SEC30.md) |
| 6 | Low | MCP `list_actions` returns `task` and `title` unfenced while its description says returned text is fenced | [AUTO8](../backlog/tasks/AUTO8.md) |
| 8 | Low | The loopback client honours HTTP proxies and the egress guard checks only the URL host | amendment to [SEC19](../backlog/tasks/SEC19.md) |
| 9 | Low | The LAN sink's temp file follows symlinks a share peer can plant | amendment to [PIPE30](../backlog/tasks/PIPE30.md) |
| 10 | Low | A spoken instruction can steer diarization cleanup to reattribute lines to another speaker | [DIAR9](../backlog/tasks/DIAR9.md) |
| 11 | Low | The Swift Apple Intelligence summarizer has no untrusted fence or guidance | amendment to [ARCH11](../backlog/tasks/ARCH11.md) |

## Amendments to existing tasks

- [SEC17](../backlog/tasks/SEC17.md): helpers (ffmpeg, venv python, uv, `mlx_lm.server` via `shutil.which`) resolve from user-writable locations and inherit the app's TCC attribution; SEC17 names this residual but no task owned it.
- [SEC20](../backlog/tasks/SEC20.md): its severity rationale is stale. Ask, digest (including `--publish`) and diarization cleanup also reach `ClaudeCLIClient`.
- [SEC23](../backlog/tasks/SEC23.md): `install.sh`'s `kc_set` passes tokens with `-w "$2"`.
- [DIST1](../backlog/tasks/DIST1.md): `bundle-runtime.sh` fetches the python-build-standalone tarball with no pinned sha256.
- [HYG11](../backlog/tasks/HYG11.md): the committed allowlist also auto-approves `rg --pre` and `git diff/log --output`.
- [SEC22](../backlog/tasks/SEC22.md): recordings and capture intermediates are created 0644 and the launch sweep skips audio.

## Informational, filed as one P3 hardening task

[DIST7](../backlog/tasks/DIST7.md): hatchling build backend unpinned and unhashed; FluidAudio CoreML models fetched from `resolve/main` with no hash; `daemon/Package.resolved` git-ignored with TOMLKit on `from:`; CI actions pinned by tag with no `permissions:` block.

## Verified and dropped

- Restoring a foreign backup re-routing NDA meetings: the owner picks the archive and the confirm says workflows are replaced; no boundary crossed.
- The unfenced local map-reduce merge step: its inputs are schema-validated outputs of fenced map calls.
- LoRA training poisoning: `--source` defaults to owner-edited corrections, and `runs` plus adoption are explicit owner steps.
- The Apple path not scrubbing owner names: publish re-validates through `MeetingSummary`, and MCP `task` is free text on every backend.
- Obsidian attendee quoting (`, [ ] { }` unquoted): a robustness bug with no key injection; noted in SEC28 as a sibling.
- MCP search index keeping its first allowlist: already covered by AUTO6's 2026-10-25 amendment.

## Checked and clean

No `shell=True`, `osascript` or string-built argv in Python; no pickle, `yaml.load`, `eval` or `exec`; `np.load` keeps `allow_pickle=False`; tar restore uses `filter="data"` and regular files only; MCP server is stdio-only with no write tools and an allowlist checked before any path is built; TOML and plist writes go through TOMLKit and `PropertyListSerialization`; `RichTextShare` escapes before converting; no secrets in 1,057 commits of history; `uv.lock` is hash-pinned; no curl-pipe-sh.

## Not covered in depth

`entry.py`, `config.py` above `effective_sinks`, `visibility.py`, `prep.py`, `publish_from_paste.py`.
