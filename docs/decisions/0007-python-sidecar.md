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
