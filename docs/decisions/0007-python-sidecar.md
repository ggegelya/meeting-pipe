# ADR 0007: Retire the Python transcription sidecar

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Accepted           |
| **Date**            | 2026-05-17         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Transcription pipeline |
| **Related Tasks**   | TECH-P2, TECH-P3, TECH-P4 |

## Context

Group P of the Q2 backlog migrated ASR and diarization off the Python
sidecar onto Swift-native, ANE-accelerated equivalents (FluidAudio:
Parakeet TDT v3 + pyannote-Community-1). After TECH-P1/P2/P3 landed,
the Python pipeline still carried:

- `mp transcribe-stream`: a long-running subprocess the daemon spawned
  during recording to produce a chunked transcript while the meeting was
  live. Only invoked when `[transcription] backend = "pipeline"`.
- `mp transcribe`: offline MLX-Whisper / faster-whisper ASR, invoked
  from `mp run-all` when no daemon transcript was present.
- Channel-aware speaker labelling and Markdown rendering.
- Summarize + publish + Notion/Obsidian sinks (the actual outbound HTTP).

The default backend has been `fluidaudio` since 2026-05-16. With
FluidAudio writing `<stem>.json` in-process after recording stops, the
streaming sidecar and the offline ASR path were never invoked on a
normal user-driven recording. They existed only as a dogfood-period
fallback under `backend = "pipeline"`.

## Decision Drivers

- **Maintenance cost of two ASR paths.** Each surface (streaming sidecar,
  offline transcribe) is a separate code path with its own tests,
  failure modes, and dependency footprint (mlx-whisper, faster-whisper).
- **Disk + launch cost.** mlx-whisper + faster-whisper + numba + torch
  together weigh ~600 MB in the venv. The user never invokes them.
- **Behavioural ambiguity.** Two engines with subtly different sidecar
  shapes (`streaming: true` vs `streaming: false`, `backend: "mlx-stream"`
  vs `backend: "fluidaudio"`) made the orchestrator's finalize logic
  branch in ways that were easy to misread.
- **Daemon-stays-offline rule** (per project `CLAUDE.md`). Outbound HTTP
  belongs in the pipeline. Summarize (Anthropic) and publish (Notion)
  cannot move to Swift without overturning that rule.

## Options Considered

### Option A: Keep the Python ASR fallback indefinitely

Pros: a defensive fallback if FluidAudio regresses on a future macOS or
hardware variant.

Cons: every code touchpoint has to handle both providers; the Python
venv stays bloated; the fallback isn't actually exercised by the user.

### Option B: Eliminate the Python sidecar (transcription only)

Drop the streaming sidecar, the offline ASR path, the `[transcription]
backend` toggle, and all the supporting Python deps (mlx-whisper,
faster-whisper, sherpa-onnx already retired in P3). Keep the Python
pipeline binary because summarize and publish still need outbound HTTP.

Pros: single ASR provider; smaller venv; simpler orchestrator. FluidAudio
failures fail the job loudly instead of silently falling through.

Cons: a FluidAudio model regression has no fallback; users would have to
wait for an SDK update or run with degraded transcripts until fixed.

### Option C: Eliminate the entire Python pipeline binary

Port summarize + publish to Swift; ship a Python-free app bundle.

Pros: the cleanest "no Python distribution" outcome that the backlog's
acceptance criterion gestures at.

Cons: directly contradicts the daemon-stays-offline rule
(`CLAUDE.md`: "Don't call Anthropic / Notion APIs from the daemon.
Outbound HTTP belongs in the pipeline."). Adds significant Swift code
to talk to Anthropic + Notion + Obsidian. Multi-week port for no
end-user benefit.

## Decision

**Option B.** Eliminate the Python transcription sidecar (streaming
subprocess + offline ASR + backend toggle). Keep the Python pipeline
binary for summarize + publish.

## Consequences

### Changes

**Swift daemon:**
- `StreamingTranscriber.swift` deleted.
- `SinkDispatcher.swift` no longer spawns or stops a streaming subprocess.
  A FluidAudio failure now fails the pipeline job; there is no
  fallthrough to a Python ASR path.
- `TranscriptionService.swift` always returns a `FluidAudioRunner`.
  The `[transcription] backend` toggle is gone.
- `Config.swift` / `ConfigStore.swift` no longer model `transcription.backend`.
- `PreferencesView.swift` drops the engine-toggle UI.

**Python pipeline:**
- `mp/transcribe.py` deleted. `render_markdown` moved to `mp/markdown.py`.
- `mp/transcribe_stream.py` deleted.
- `mp/__main__.py` drops the `transcribe` and `transcribe-stream`
  subcommands.
- `mp/orchestrate.py` requires the FluidAudio sidecar; no offline ASR
  fallback. Empty-segments sidecars short-circuit to `skipped: no_speech`.
- `mp/config.py` drops the `Transcription` model fields; the section is
  retained as an empty `extra="ignore"` placeholder for legacy TOMLs.
- `mp/doctor.py` no longer probes ASR runtimes.
- `pyproject.toml` drops `mlx-whisper` and `faster-whisper`.

**Config:**
- `config.example.toml` no longer carries a `[transcription]` section.
- Older user configs continue to load: `extra="ignore"` swallows the
  abandoned fields silently.

### Trade-offs accepted

- **No transcription fallback.** A FluidAudio regression surfaces as a
  failed pipeline job. The user must wait for an SDK fix or use a
  third-party tool to transcribe by hand. This is acceptable for a
  single-user app where the operator can roll back to a known-good
  build.
- **Python distribution still ships.** Summarize + publish remain in
  Python, so the user's `~/.local/share/meeting-pipe/venv` continues to
  exist. The app bundle is not Python-free. The backlog's stated
  acceptance criterion of "app bundle no longer contains a Python
  distribution" is explicitly out of scope; pursuing it would require
  Option C and overturning the daemon-stays-offline rule.
- **`doctor` no longer probes Python ML.** The Python pipeline still
  exists, but the ASR / diarization probes are gone (nothing to probe).

### Out of scope (future work, if ever)

- Porting summarize + publish to Swift (Option C). Trigger condition:
  someone wants to ship a Python-free build (deferred per backlog).
- Restoring a fallback ASR path. Trigger condition: a FluidAudio
  regression that breaks the user's workflow for more than a day.

## Amendment: pluggable cloud providers (PROV1, 2026-07-11)

This ADR's "summarize stays in Python for outbound HTTP" framing and the README's "Anthropic Messages API directly, not Claude Code" rationale both predate headless `claude -p`. PROV1 formalizes a provider seam over the two summarize call shapes (the structured `SummaryClient.summarize` and the free-form `TextClient.complete` behind `engine.complete_text`) and adds two backends beside `anthropic` / `local` / `auto` / `apple_intelligence`:

- `claude_cli`: spawns Claude Code non-interactively (`claude -p --output-format json`, tools and MCP off), the prompt on stdin, validated through the same pydantic path. Zero marginal API cost on an existing Claude subscription, and no API key. The "the API surface is more deterministic than the interactive one" reasoning still holds for the default, so `anthropic` stays the default and `claude_cli` is opt-in.
- `openai`: an OpenAI-compatible chat-completions API over raw httpx (not the openai SDK), so the egress guard's httpx transport patch clamps it exactly like anthropic, with no SDK-specific plumbing.

The load-bearing constraint: a CLI provider egresses through a child process, OUTSIDE the in-process httpx egress guard, so `config.effective_backend` classes every CLI backend (`CLI_BACKENDS`) as cloud and forces local under regulated/NDA, and each CLI provider also refuses to spawn while the guard is armed (defense in depth, the SEC10 posture). `auto` keeps its anthropic-then-local ladder and never falls into a CLI provider. This does not overturn the daemon-stays-offline rule: all outbound work, including spawning `claude`, still happens in the Python pipeline, not the daemon.
