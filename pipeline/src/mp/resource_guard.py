"""LOCAL16: the machine's memory budget, in one place.

On-device processing is supposed to degrade by *refusing with a reason*, never
by taking the machine down. It has taken this Mac down twice: the 14B OOM-hung
it at long context (see `config.local_model`'s comment), and the 2026-07-29
`mp ask` incident ended in a hard reboot. Before this module the only RAM check
in the product was `mp doctor`: advisory, manual, and against TOTAL physical
RAM, so nothing on the actual run path ever looked at memory at all.

Three pieces, deliberately separable so a caller can take only what it needs:

1. **Sizing** (`estimate_model_gb`, `physical_ram_gb`) - promoted out of
   `doctor`, which is no longer the only reader.
2. **A pure tier policy** (`tier_for`, `assess`, `refusal_message`) - physical
   RAM to a maximum advisable model size and a context-token ceiling. Pure and
   table-driven so it is unit-testable without a machine, and mirrored in Swift
   (`daemon/Sources/MeetingPipe/LocalModelTier.swift`) because Preferences has
   to annotate the presets before any Python runs. Change one, change both.
3. **A free-RAM watchdog** (`sample_memory`, `MemoryWatchdog`) - the LOCAL13
   bench protocol, which lived as a shell snippet in a spike doc and never
   became product code. Sampling is injectable so the abort is testable, and
   `check()` is cheap enough to call once per batch inside a loop (it shells out
   to `vm_stat` at most every `min_interval_sec`).

The guard refuses only what it can *measure*. A model id whose parameter count
does not parse (any Custom preset) is never refused on size, because guessing
that a custom id is too big would break the one escape hatch a user has; the
watchdog is the backstop for that case. `MP_RAM_GUARD=0` disables both the
refusal and the watchdog for owner-dev bench runs.
"""
from __future__ import annotations

import logging
import os
import re
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal

from . import events

log = logging.getLogger("mp.resource_guard")

_GB = 1024 ** 3

#: Substring every memory refusal and abort message carries. Swift matches it
#: (`PipelineFailureSidecar.lowMemoryMarker`) to stamp the failure sidecar's
#: stage as `memory`, so the Library row says *why* it failed rather than
#: "Summarize and publish". Same shape as UX21's `not in the local HuggingFace
#: cache` marker: there is no shared constant across the language boundary, so
#: the phrase itself is the contract. Keep it in both messages below.
LOW_MEMORY_MARKER = "Not enough memory"

#: Owner-dev override for bench runs (LOCAL13 measures the boundary the guard
#: exists to keep runs away from, so it has to be able to cross it).
OVERRIDE_ENV = "MP_RAM_GUARD"

#: Default free-RAM floor, as a percentage of physical RAM. 10% is LOCAL13's
#: bench figure, measured against this Mac reading ~18% free while idle.
DEFAULT_FLOOR_PCT = 10.0


class ResourceGuardError(RuntimeError):
    """Base for the two fail-closed memory refusals."""


class ModelTooLargeError(ResourceGuardError):
    """The configured model does not fit this machine's tier. Raised before a
    server is spawned, so no multi-GB load is ever started."""


class LowMemoryError(ResourceGuardError):
    """Free memory crossed the floor mid-run. Raised from inside the owning
    loop so the run ends with a named reason instead of a swap storm."""


def guard_enabled() -> bool:
    """False only when `MP_RAM_GUARD` is explicitly off. Unset means on: a
    guard that is off by default protects nobody."""
    return os.environ.get(OVERRIDE_ENV, "1").strip().lower() not in {"0", "false", "no", "off"}


# ---------- sizing ---------------------------------------------------------


def estimate_model_gb(model_id: str) -> float | None:
    """Rough resident-memory / download estimate for a 4-bit MLX chat model,
    parsed from the parameter count in its repo id (`...-7B-...` -> 7B).
    ~0.62 GB per billion params covers 4-bit weights plus runtime overhead and
    matches the measured ~4.3 GB for the 7B. None when the size is unparseable.
    """
    m = re.search(r"(\d+(?:\.\d+)?)\s*[bB]\b", model_id)
    if not m:
        return None
    try:
        params_b = float(m.group(1))
    except ValueError:
        return None
    return round(params_b * 0.62, 1)


def physical_ram_bytes() -> int | None:
    """Total physical RAM in bytes. `sysctl hw.memsize` on macOS, os.sysconf fallback."""
    try:
        out = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "hw.memsize"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip().isdigit():
            return int(out.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        return int(os.sysconf("SC_PHYS_PAGES")) * int(os.sysconf("SC_PAGE_SIZE"))
    except (ValueError, OSError):
        return None


def physical_ram_gb() -> float | None:
    """Total physical RAM in GB. None when it cannot be read, which every caller
    treats as "do not judge" rather than as a refusal."""
    total = physical_ram_bytes()
    return round(total / _GB, 1) if total else None


# ---------- the pure tier policy -------------------------------------------


@dataclass(frozen=True)
class Tier:
    """One row of the policy: machines with at least `min_ram_gb` of physical
    RAM may run a model estimated at up to `max_model_gb`, and should keep a
    single request under `context_token_ceiling` tokens."""
    min_ram_gb: float
    max_model_gb: float
    context_token_ceiling: int


#: The policy, anchored on measurements rather than on a ratio:
#:
#: * 7B (~4.3 GB) is the default and is called memory-safe on 16 GB, so 16 GB
#:   has to admit it (and it lands at 86% of that tier's budget, which is
#:   honestly "little headroom", not "comfortable").
#: * 14B (~8.7 GB) "wants 24 GB+ RAM (can OOM on 16 GB)" per the shipped
#:   Preferences copy and LOCAL6, so 16 GB must refuse it and 24 GB must admit
#:   it at the top of its budget.
#: * AI2 measured the 14B on this 32 GB Mac: fine at 4K tokens, watchdog abort
#:   at 8K, OOM at 16K. That is what caps the context ceilings, and it is why
#:   the ceiling is a machine-level cap and not a promise: a model sitting at
#:   the top of its tier still needs the watchdog underneath it.
TIERS: tuple[Tier, ...] = (
    Tier(min_ram_gb=8, max_model_gb=2.5, context_token_ceiling=2_000),
    Tier(min_ram_gb=16, max_model_gb=5.0, context_token_ceiling=4_000),
    Tier(min_ram_gb=24, max_model_gb=9.0, context_token_ceiling=4_000),
    Tier(min_ram_gb=32, max_model_gb=9.0, context_token_ceiling=8_000),
    Tier(min_ram_gb=48, max_model_gb=20.0, context_token_ceiling=16_000),
)

#: Above this share of the tier's budget a model is admitted but annotated as
#: tight. The 7B on 16 GB and the 14B on 24-32 GB both land here, which is
#: exactly the population that has produced OOM reports.
TIGHT_FRACTION = 0.8

Fit = Literal["fits", "tight", "over", "unknown"]

#: The curated Preferences presets, so a refusal can name the alternative the
#: user is meant to pick. Mirrors `LocalModelPreset.all` in
#: `daemon/Sources/MeetingPipe/PreferencesWindow.swift`; sizes are not repeated
#: here, they come from `estimate_model_gb` like every other model's.
PRESETS: tuple[tuple[str, str], ...] = (
    ("Small (Qwen 3B-4bit)", "mlx-community/Qwen2.5-3B-Instruct-4bit"),
    ("Recommended (Qwen 7B-4bit)", "mlx-community/Qwen2.5-7B-Instruct-4bit"),
    ("Large (Qwen 14B-4bit)", "mlx-community/Qwen2.5-14B-Instruct-4bit"),
)


def tier_for(ram_gb: float) -> Tier:
    """The policy row for a machine with `ram_gb` of physical RAM. A machine
    below the first tier's floor still gets that tier: there is nothing smaller
    to offer it, and the watchdog covers what the table cannot."""
    chosen = TIERS[0]
    for tier in TIERS:
        if ram_gb >= tier.min_ram_gb:
            chosen = tier
    return chosen


def needs_ram_gb(model_gb: float) -> float | None:
    """The smallest tier that would admit a model of this size, as a RAM figure
    to quote back to the user ("needs about 24 GB"). None when no tier does."""
    for tier in TIERS:
        if model_gb <= tier.max_model_gb:
            return tier.min_ram_gb
    return None


@dataclass(frozen=True)
class Assessment:
    """What the policy says about one (model, machine) pair. Pure data, so the
    caller decides whether to refuse, annotate, or gray a picker row."""
    model_id: str
    model_gb: float | None
    ram_gb: float
    tier: Tier
    fit: Fit
    wants_ram_gb: float | None


def assess(model_id: str, ram_gb: float) -> Assessment:
    """Pure: score `model_id` against a machine with `ram_gb` of physical RAM.

    `fit == "unknown"` for an unparseable id (the Custom preset). Callers must
    treat that as permission to run, not as a refusal: the watchdog is what
    covers a model whose size nobody can compute.
    """
    tier = tier_for(ram_gb)
    model_gb = estimate_model_gb(model_id)
    if model_gb is None:
        return Assessment(model_id, None, ram_gb, tier, "unknown", None)
    if model_gb > tier.max_model_gb:
        return Assessment(model_id, model_gb, ram_gb, tier, "over", needs_ram_gb(model_gb))
    fit: Fit = "tight" if model_gb > tier.max_model_gb * TIGHT_FRACTION else "fits"
    return Assessment(model_id, model_gb, ram_gb, tier, fit, None)


def preset_label(model_id: str) -> str | None:
    """The Preferences label for a curated preset id, else None (Custom)."""
    for label, mid in PRESETS:
        if mid == model_id:
            return label
    return None


def largest_preset_within(ram_gb: float) -> str | None:
    """The biggest curated preset this machine can run, by label. The refusal
    names it so the user has somewhere to go, rather than only being told no."""
    best: str | None = None
    for label, mid in PRESETS:
        if assess(mid, ram_gb).fit in {"fits", "tight"}:
            best = label
    return best


def refusal_message(a: Assessment) -> str:
    """The user-facing refusal for an over-tier model. Same shape as the SEC13
    uncached-model refusal in `summarize_local._spawn`: what happened, on this
    machine, and the one thing to do about it. Carries `LOW_MEMORY_MARKER` so
    the daemon can stamp the failure sidecar's stage as memory.

    Deliberately does not mention `MP_RAM_GUARD`: this text becomes the Library
    row's failure reason, and "here is how to turn the safety off" is not advice
    to put in front of someone whose Mac has already been taken down twice.
    """
    name = preset_label(a.model_id) or a.model_id
    wants = f"about {a.wants_ram_gb:g} GB" if a.wants_ram_gb else "more RAM than any tier allows"
    alternative = largest_preset_within(a.ram_gb)
    remedy = (
        f"Pick {alternative} in Preferences > Pipeline."
        if alternative
        else "Use the Anthropic backend, or a smaller model id, in Preferences > Pipeline."
    )
    return (
        f"{LOW_MEMORY_MARKER} for this model: this Mac has {a.ram_gb:g} GB of RAM and "
        f"{name} needs {wants} (about {a.model_gb:g} GB resident, plus working memory). "
        f"{remedy}"
    )


def require_model_fits(model_id: str, *, ram_gb: float | None = None) -> None:
    """Refuse an over-tier model before anything heavy is loaded.

    Fails open in every case where it cannot tell: guard disabled, RAM
    unreadable, model size unparseable. Raises `ModelTooLargeError` otherwise.
    """
    if not guard_enabled():
        log.warning("%s=0: skipping the model-size refusal for %s", OVERRIDE_ENV, model_id)
        return
    ram = ram_gb if ram_gb is not None else physical_ram_gb()
    if ram is None:
        log.warning("could not read physical RAM; skipping the model-size check")
        return
    a = assess(model_id, ram)
    if a.fit != "over":
        return
    events.emit(
        "pipeline", "memory_guard_refused_model",
        model=model_id, model_gb=a.model_gb, ram_gb=a.ram_gb,
        max_model_gb=a.tier.max_model_gb,
    )
    raise ModelTooLargeError(refusal_message(a))


# ---------- the free-RAM watchdog ------------------------------------------


@dataclass(frozen=True)
class MemorySample:
    """One reading of how much memory is actually available right now."""
    free_bytes: int
    total_bytes: int

    @property
    def free_pct(self) -> float:
        return 100.0 * self.free_bytes / self.total_bytes if self.total_bytes else 0.0


#: The buckets `vm_stat` reports that are genuinely available to a new
#: allocation. LOCAL13's bench watchdog sums exactly these four, and the choice
#: matters: macOS keeps `Pages free` near zero by design (it caches
#: aggressively), so a floor measured against free alone would fire constantly
#: on a healthy machine and teach the user to ignore it.
_VM_STAT_FREE_BUCKETS = ("free", "inactive", "speculative", "purgeable")
_VM_STAT_LINE = re.compile(r"^Pages\s+([a-z ]+?):\s+(\d+)\.", re.MULTILINE)
_VM_STAT_PAGE_SIZE = re.compile(r"page size of (\d+) bytes")


def sample_memory() -> MemorySample | None:
    """Read available memory via `vm_stat`. None when it cannot be read, which
    every caller treats as "do not abort" - a guard that fires on its own
    failure to measure is worse than no guard.
    """
    total = physical_ram_bytes()
    if not total:
        return None
    try:
        out = subprocess.run(
            ["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return parse_vm_stat(out.stdout, total_bytes=total)


def parse_vm_stat(text: str, *, total_bytes: int) -> MemorySample | None:
    """Pure half of `sample_memory`, so the arithmetic is testable without a Mac."""
    page = _VM_STAT_PAGE_SIZE.search(text)
    if not page:
        return None
    page_bytes = int(page.group(1))
    free_pages = 0
    seen = False
    for name, count in _VM_STAT_LINE.findall(text):
        if name.strip() in _VM_STAT_FREE_BUCKETS:
            free_pages += int(count)
            seen = True
    if not seen:
        return None
    return MemorySample(free_bytes=free_pages * page_bytes, total_bytes=total_bytes)


class MemoryWatchdog:
    """Aborts the owning run when free memory crosses the floor.

    Built to be called from inside a loop: the local summarize path checks it
    before every request, and an embedding pass checks it between batches. The
    sampling is throttled (`min_interval_sec`) so a tight loop does not pay for
    a `vm_stat` per iteration, and both the sampler and the clock are injectable
    so the abort can be tested deterministically.

    It never kills anything itself. It raises, and the run unwinds through its
    normal failure path: the caller's process exits non-zero, the daemon writes
    the failure sidecar, and the Library row says memory. Killing the model
    server from here would race whoever owns it (the LOCAL11 lesson) and leave
    the run reporting a confusing connection error instead of the real cause.
    """

    def __init__(
        self,
        *,
        floor_pct: float = DEFAULT_FLOOR_PCT,
        sampler: Callable[[], MemorySample | None] = sample_memory,
        min_interval_sec: float = 2.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.floor_pct = floor_pct
        self._sampler = sampler
        self._min_interval_sec = min_interval_sec
        self._clock = clock
        self._last_sampled_at: float | None = None

    @property
    def enabled(self) -> bool:
        return self.floor_pct > 0 and guard_enabled()

    def check(self, *, stage: str) -> MemorySample | None:
        """Sample and raise `LowMemoryError` below the floor. Returns the sample
        it took, or None when it was disabled, throttled, or could not measure.
        """
        if not self.enabled:
            return None
        now = self._clock()
        if self._last_sampled_at is not None and now - self._last_sampled_at < self._min_interval_sec:
            return None
        self._last_sampled_at = now
        sample = self._sampler()
        if sample is None:
            return None
        if sample.free_pct >= self.floor_pct:
            return sample
        events.emit(
            "pipeline", "memory_guard_aborted",
            stage=stage, free_pct=round(sample.free_pct, 1), floor_pct=self.floor_pct,
        )
        raise LowMemoryError(
            f"{LOW_MEMORY_MARKER}: free RAM fell to {sample.free_pct:.0f}% during {stage} "
            f"(floor {self.floor_pct:g}%), so the run stopped before this Mac started "
            f"swapping. Close memory-heavy apps, or pick a smaller model preset in "
            f"Preferences > Pipeline, then run it again."
        )
