"""Channel-aware speaker labelling for stereo recordings.

The daemon writes stereo WAVs (mic-L, system-R), so the entire Python
fallback path needs is a per-segment RMS comparison: whichever channel
was loudest during a transcript segment's window owns the segment.
Diarization on mono recordings is no longer attempted from Python;
FluidAudio (Swift-native) is the source of truth for embedding-based
diarization. The fallback gracefully degrades to USER_SPEAKER for the
mono case rather than re-introducing a per-recording embedding cluster.
"""
from __future__ import annotations

import math
from pathlib import Path
from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:
    # `roster` imports `cosine_similarity` from this module, so importing it at
    # runtime would close the cycle. The annotation only needs the name.
    from .roster import RosterStore

# The share of a cluster's speech that must be on the mic channel for it to count as a mic-side
# voice, in both the mic tier and the voiceprint tier's agreement check (DIAR11).
MIC_FRACTION_MIN = 0.6

# Speaker labels for the stereo channel-aware path. Stable strings so
# downstream Markdown renders consistently across recordings.
USER_SPEAKER = "speaker_user"
OTHER_SPEAKER = "speaker_other"


def is_stereo_recording(wav: Path) -> bool:
    """Cheap channel-count probe (reads only the WAV header)."""
    import soundfile as sf  # type: ignore
    try:
        return sf.info(str(wav)).channels == 2
    except Exception:  # noqa: BLE001
        return False


def assign_speakers_by_channel(
    transcript_segments: list[dict],
    wav: Path,
    *,
    dominance_ratio: float = 1.5,
    min_other_rms: float = 50.0,
) -> list[dict]:
    """Stamp speaker labels onto each transcript segment by comparing
    per-channel RMS over the segment's time window.

    Heuristic per segment:
      - L_rms > dominance_ratio * R_rms  → USER_SPEAKER
      - R_rms > dominance_ratio * L_rms  → OTHER_SPEAKER
      - both close                        → whichever is louder (overlap)

    `min_other_rms` guards the degenerate "system audio is silent the
    whole recording" case: when the right channel is below this floor,
    we collapse all segments to USER_SPEAKER rather than producing a
    silly "OTHER said one quiet word" attribution from background noise.
    PCM s16 RMS of pure silence is ~0; threshold 50 is well above noise
    floor and well below normal speech.

    The WAV passed here is the redacted artifact: under capture-first the
    daemon zero-fills the muted mic spans before the pipeline runs (ADR
    0016 / TECH-MIC5), and the kept full recording lives outside the
    pipeline's reach. So these int16 thresholds keep their gated-audio
    meaning and a muted speaker is never relabeled USER_SPEAKER from
    full-amplitude audio.
    """
    import numpy as np
    import soundfile as sf  # type: ignore

    # Stream the WAV instead of reading the whole clip plus two float32 copies
    # (~2 GB peak on a 3-hour stereo file, in the exact degraded fallback we
    # least want to also OOM). Reads stay int16 with a local float32 cast on
    # bounded slices, so every RMS value, and therefore `min_other_rms` and
    # `dominance_ratio`, keeps its int16-magnitude meaning. (TECH-PERF1)
    with sf.SoundFile(str(wav)) as f:
        if f.channels != 2:
            # Caller should have checked is_stereo_recording first; defend
            # against future config drift by collapsing to a single label.
            return [{**s, "speaker": USER_SPEAKER} for s in transcript_segments]
        sr = f.samplerate
        total_frames = f.frames

        # Decide once whether the right channel ever had real audio, scanning
        # it block-wise so we never hold more than one block in RAM. If not,
        # all segments go to USER_SPEAKER, much more useful than spurious OTHER
        # attributions on silence/noise. (float64 accumulation is a touch more
        # accurate than the old whole-channel float32 mean; the silence floor
        # has orders-of-magnitude margin, so it cannot flip the threshold.)
        sumsq_r = 0.0
        count_r = 0
        for block in f.blocks(blocksize=1 << 20, dtype="int16", always_2d=True):
            r = block[:, 1].astype(np.float64)
            sumsq_r += float(r @ r)
            count_r += r.shape[0]
        overall_r_rms = (sumsq_r / count_r) ** 0.5 if count_r else 0.0
        other_channel_present = overall_r_rms >= min_other_rms

        out: list[dict] = []
        for seg in transcript_segments:
            seg = dict(seg)
            if not other_channel_present:
                seg["speaker"] = USER_SPEAKER
                out.append(seg)
                continue
            start_i = max(0, int(float(seg.get("start", 0)) * sr))
            end_i = min(total_frames, int(float(seg.get("end", 0)) * sr))
            if end_i <= start_i:
                seg["speaker"] = USER_SPEAKER
                out.append(seg)
                continue
            # Read only this segment's window. int16 + a local float32 cast
            # leaves the per-segment RMS identical to the old whole-file slice.
            f.seek(start_i)
            chunk = f.read(frames=end_i - start_i, dtype="int16", always_2d=True)
            l_chunk = chunk[:, 0].astype(np.float32)
            r_chunk = chunk[:, 1].astype(np.float32)
            l_rms = float(np.sqrt(np.mean(l_chunk * l_chunk)))
            r_rms = float(np.sqrt(np.mean(r_chunk * r_chunk)))
            if l_rms > dominance_ratio * r_rms:
                seg["speaker"] = USER_SPEAKER
            elif r_rms > dominance_ratio * l_rms:
                seg["speaker"] = OTHER_SPEAKER
            else:
                seg["speaker"] = USER_SPEAKER if l_rms >= r_rms else OTHER_SPEAKER
            out.append(seg)
    return out


def _resolve_me(
    segments: list[dict],
    *,
    channel_me: str = USER_SPEAKER,
    mic_me: str | None = None,
    voiceprint_me: str | None = None,
    mic_fractions: dict[str, float] | None = None,
    min_fraction: float = MIC_FRACTION_MIN,
) -> tuple[str | None, str]:
    """Which diarization speaker id is the user, and which tier decided
    (`channel`, `mic`, `voiceprint` or `none`).

    Precedence: the channel-assigned mic speaker, else the mic-channel
    identification, else the voiceprint match. When the mic pick and the
    voiceprint both name a speaker and DISAGREE (DIAR11), the voiceprint wins if
    that speaker is itself mic-side (its `mic_fractions` entry clears
    `min_fraction`) and otherwise nobody is named: the mic pick never overrides a
    voiceprint that disagrees with it. A voiceprint match with no mic pick to
    disagree with is unchanged and not mic-checked (it also serves mono and the
    merged-cluster case); only the fold below insists on mic-side.

    None when no signal places the user among these speakers, which is the
    correct answer when the user sat silent. Naming "me" requires positive
    evidence: every tier here is a measurement of the user's own voice, so a
    meeting the user only listened to leaves the speakers unnamed rather than
    lending the owner's name to whoever talked most.
    """
    present = {s.get("speaker") for s in segments if s.get("speaker")}
    if channel_me in present:
        return channel_me, "channel"
    mic = mic_me if mic_me and mic_me in present else None
    vp = voiceprint_me if voiceprint_me and voiceprint_me in present else None
    if mic and vp and mic != vp:
        if mic_fractions is not None and mic_fractions.get(vp, 0.0) >= min_fraction:
            return vp, "voiceprint"
        return None, "none"
    if mic:
        return mic, "mic"
    if vp:
        return vp, "voiceprint"
    return None, "none"


def _resolve_me_id(
    segments: list[dict],
    *,
    channel_me: str = USER_SPEAKER,
    mic_me: str | None = None,
    voiceprint_me: str | None = None,
    mic_fractions: dict[str, float] | None = None,
) -> str | None:
    """`_resolve_me`'s speaker id alone."""
    return _resolve_me(
        segments, channel_me=channel_me, mic_me=mic_me, voiceprint_me=voiceprint_me,
        mic_fractions=mic_fractions,
    )[0]


def label_me_speaker(
    segments: list[dict],
    user_label: str,
    *,
    channel_me: str = USER_SPEAKER,
    mic_me: str | None = None,
    voiceprint_me: str | None = None,
) -> list[dict]:
    """Stamp the user's enrolled display name on their own speaker, so
    "me vs them" reads as a real name.

    Picks the "me" speaker by precedence:
      - the channel-assigned mic speaker (`speaker_user`) when present, the
        reliable stereo path since the mic channel is always the user; else
      - `mic_me`, the diarized speaker whose speech is predominantly on the mic
        channel (`identify_user_speaker`), physical evidence that the voice is
        the user's; else
      - `voiceprint_me`, the speaker matched to the persisted self-voiceprint
        (FEAT3-VOICEPRINT), which still resolves on mono and when a merged
        cluster leaves no clean mic winner.

    Returns a new segment list with the chosen speaker relabeled to
    `user_label`. No-op (segments copied unchanged) when `user_label` is empty
    or no signal identifies the user, the latter being what a meeting the user
    stayed silent through looks like. The name is enrolled once in config
    (`summarization.user_label`) and reused on every meeting.
    """
    label = user_label.strip()
    if not label or not segments:
        return [dict(s) for s in segments]

    me = _resolve_me_id(
        segments, channel_me=channel_me, mic_me=mic_me, voiceprint_me=voiceprint_me
    )
    if me is None or me == label:
        return [dict(s) for s in segments]
    return [
        {**s, "speaker": label} if s.get("speaker") == me else dict(s)
        for s in segments
    ]


def cosine_similarity(a: list[float], b: list[float]) -> float:
    """Cosine similarity of two equal-length vectors; 0.0 on length mismatch,
    empty input, or a zero vector."""
    if not a or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na < 1e-9 or nb < 1e-9:
        return 0.0
    return dot / (na * nb)


# Two-gate accept rule for the self-voiceprint, mirroring `roster.match`: the
# top similarity must clear MATCH_MIN and the runner-up must trail it by
# MATCH_MARGIN. Conservative on both counts, since an unresolved "me" costs one
# in-app naming while a wrong one puts the owner's name on a stranger. The
# margin is what stops two near-identical scores (0.506 vs 0.495 was seen in the
# real library) from deciding the owner's identity on a coin flip.
VOICEPRINT_MATCH_MIN = 0.5
VOICEPRINT_MATCH_MARGIN = 0.07


def match_voiceprint(
    speaker_embeddings: dict[str, list[float]],
    voiceprint: list[float] | None,
    *,
    min_similarity: float = VOICEPRINT_MATCH_MIN,
    margin: float = VOICEPRINT_MATCH_MARGIN,
) -> str | None:
    """Return the diarized speaker id whose embedding matches the persisted
    `voiceprint` under the two-gate rule, else None. The top similarity must
    clear `min_similarity`, and the gap to the runner-up speaker must clear
    `margin`; a lone candidate only faces the first gate. Ties break to the
    lowest speaker id for determinism."""
    if not voiceprint or not speaker_embeddings:
        return None
    scored = sorted(
        (
            (cosine_similarity(emb, voiceprint), spk)
            for spk, emb in speaker_embeddings.items()
        ),
        key=lambda t: (-t[0], t[1]),
    )
    top_sim, top_id = scored[0]
    if top_sim < min_similarity:
        return None
    runner_up = scored[1][0] if len(scored) > 1 else -1.0
    if top_sim - runner_up < margin:
        return None
    return top_id


# DIAR11: the mic-tier contest. The tier used to be `max(total_time, key=mic_fraction)`, which
# has no floor and no runner-up: a one-utterance cluster at fraction 1.0 beat the owner's main
# cluster at 0.85, and two local voices on one laptop mic both read near 1.0, so whichever was
# heard first was named the owner. In the 2026-11-13 field pack the owner's name sat on a cluster
# under cosine 0.5 to their voice in 26 of 107 stems, always a small one (0 to 53 s of speech).
#
# Speech time on the mic decides, among clusters that clear the fraction bar, and two bars guard
# the pick. MIN_MIC_SPEECH_SEC is the least mic-side speech that counts as evidence of a voice: a
# cluster under it is a cough, a clipped "yes", or a leaked word, and enrolling it would put a
# stranger's sample in the self-voiceprint. PROVISIONAL: the field wrong clusters held 0 to 53 s,
# so 15 s clears most of them on its own and the time ordering handles the rest; the value is
# meant to be revised from the owner-run `scripts/valid1_check.py --owner-cluster` replay.
# RUNNER_UP_SHARE is how much of the winner's mic time a second mic-side voice may have before
# the pick is a coin flip between two local voices (F096's hybrid call): at a quarter or more,
# decline, and let the voiceprint tier decide. Reaching the share is enough ("or more").
MIN_MIC_SPEECH_SEC = 15.0
RUNNER_UP_SHARE = 0.25


class MicTier(NamedTuple):
    """The mic channel's verdict on one meeting (DIAR11).

    `winner` is the owner cluster the mic tier picks, or None. `mic_time` and
    `total_time` are each speaker's speech seconds on the mic channel and overall,
    kept so the voiceprint tier and the fold can ask a cluster's mic fraction
    without a second pass over the WAV.
    """

    winner: str | None
    mic_time: dict[str, float]
    total_time: dict[str, float]
    # Set when `winner` is None only because a second mic-side voice reached `RUNNER_UP_SHARE`
    # of the leader's mic time (the leader clearing the floor): the leader first, then every
    # such contender. With no voiceprint to tell them apart, the owner decision of 2026-11-17
    # treats them as one over-split owner (see `orchestrate._me_signals` and the fold in
    # `resolve_speaker_labels`).
    split: tuple[str, ...] = ()

    def fraction(self, spk: str) -> float:
        total = self.total_time.get(spk, 0.0)
        return self.mic_time.get(spk, 0.0) / total if total > 0 else 0.0

    def owner_pick(self, voiceprint: list[float] | None) -> str | None:
        """The mic pick as the caller treats it: `winner`, or, with no voiceprint yet and the
        pick declined only on the runner-up share, the split's leader (an over-split owner, the
        owner's decision of 2026-11-17). The one home of that promotion, shared by
        `orchestrate._me_signals` and the `valid1_check --owner-cluster` replay."""
        if self.winner is None and voiceprint is None and self.split:
            return self.split[0]
        return self.winner


def pick_mic_speaker(
    mic_time: dict[str, float],
    total_time: dict[str, float],
    *,
    min_fraction: float = MIC_FRACTION_MIN,
    min_mic_seconds: float = MIN_MIC_SPEECH_SEC,
    runner_up_share: float = RUNNER_UP_SHARE,
) -> MicTier:
    """The mic-tier decision over per-speaker speech seconds (pure, DIAR11).

    Among speakers whose mic fraction clears `min_fraction`, the one with the most
    mic-channel speech wins (a tie goes to the higher fraction, then the lower id,
    never to whoever was heard first), provided it has `min_mic_seconds` of it.
    The pick is None when another speaker also clears the fraction bar with more
    than `runner_up_share` of the winner's mic time: two local voices, which the
    voiceprint tier has to tell apart, and `split` then names the leader and those
    contenders, which with no voiceprint at all are folded into one owner.
    """
    def fraction(spk: str) -> float:
        t = total_time.get(spk, 0.0)
        return mic_time.get(spk, 0.0) / t if t > 0 else 0.0

    by_mic = sorted(total_time, key=lambda k: (-mic_time.get(k, 0.0), -fraction(k), k))
    candidates = [k for k in by_mic if fraction(k) >= min_fraction]
    winner = candidates[0] if candidates else None
    split: tuple[str, ...] = ()
    if winner is not None:
        if mic_time.get(winner, 0.0) < min_mic_seconds:
            winner = None
        else:
            contenders = [
                k for k in candidates
                if k != winner and mic_time.get(k, 0.0) >= runner_up_share * mic_time[winner]
            ]
            if contenders:
                split = (winner, *contenders)
                winner = None
    return MicTier(winner, dict(mic_time), dict(total_time), split)


def analyze_mic_tier(
    segments: list[dict],
    wav: Path,
    *,
    min_fraction: float = MIC_FRACTION_MIN,
) -> MicTier | None:
    """Cross-tabulate each diarized speaker against the stereo mic/other verdict
    and run the mic-tier contest. None on mono or when the channels cannot tell the
    user's voice apart (the mic-only recording where the system channel is silent).

    Deliberately conservative, since a wrong enrollment poisons the voiceprint.
    """
    if not segments or not is_stereo_recording(wav):
        return None
    channel = assign_speakers_by_channel([dict(s) for s in segments], wav)
    if len(channel) != len(segments):
        return None
    mic_time: dict[str, float] = {}
    total_time: dict[str, float] = {}
    saw_other = False
    for orig, chan in zip(segments, channel):
        spk = orig.get("speaker")
        if not spk:
            continue
        dur = max(0.0, float(orig.get("end", 0)) - float(orig.get("start", 0)))
        total_time[spk] = total_time.get(spk, 0.0) + dur
        if chan.get("speaker") == USER_SPEAKER:
            mic_time[spk] = mic_time.get(spk, 0.0) + dur
        else:
            saw_other = True
    # assign_speakers_by_channel collapses every segment to USER_SPEAKER when the
    # system channel is silent (effectively mono-from-mic); we can't tell the
    # user's voice apart there, so decline to enroll.
    if not total_time or not saw_other:
        return None
    return pick_mic_speaker(mic_time, total_time, min_fraction=min_fraction)


def identify_user_speaker(
    segments: list[dict],
    wav: Path,
    *,
    min_fraction: float = MIC_FRACTION_MIN,
) -> str | None:
    """On a stereo recording, return which diarized speaker is the mic-channel
    user (the voiceprint-enrollment target), or None when mono / ambiguous.
    See `pick_mic_speaker` for the rule."""
    tier = analyze_mic_tier(segments, wav, min_fraction=min_fraction)
    return tier.winner if tier else None


def them_label(idx: int) -> str:
    """Stable unknown-voice cluster label: 0 -> THEM-A, 25 -> THEM-Z, 26 -> THEM-AA."""
    letters = ""
    n = idx
    while True:
        letters = chr(ord("A") + n % 26) + letters
        n = n // 26 - 1
        if n < 0:
            break
    return f"THEM-{letters}"


class OwnerChoice(NamedTuple):
    """How the owner cluster was chosen for one meeting (DIAR11), the numbers
    behind `pipeline`/`owner_cluster_chosen`. Carries no label, name or text:
    only which tier decided and the evidence it had, so a field pack can check the
    rule without embeddings. `None` fields mean the evidence did not exist (mono,
    no voiceprint, no runner-up).
    """

    tier: str                          # channel | mic | voiceprint | none
    mic_fraction: float | None         # the chosen cluster's mic-channel share of its speech
    mic_seconds: float | None          # its mic-channel speech seconds
    voiceprint_score: float | None     # its cosine to the self-voiceprint
    runner_up_fraction: float | None   # the best other cluster by mic time
    runner_up_seconds: float | None
    folded: int                        # owner-matching mic-side clusters given the owner's name
    flagged: int                       # owner-matching but system-side clusters left alone


class SpeakerLabelResolution(NamedTuple):
    """What `resolve_speaker_labels` worked out for one meeting.

    `mapping` is the diarization speaker id -> final label table the transcript is
    rewritten through. `near_misses` is keyed by the FINAL `THEM-x` label instead,
    because that is the label the app shows and the one a suggestion is offered
    against; it holds only the voices the roster declined to name and came close
    on (FEAT14). The similarity behind each one is deliberately left here: the app
    is offered a name to suggest, never a number to render as a confidence.
    """

    mapping: dict[str, str]
    near_misses: dict[str, str]
    owner: OwnerChoice | None = None
    # The raw diarization id named the owner, or None. Kept out of `OwnerChoice`, which is logged.
    owner_id: str | None = None


def resolve_speaker_labels(
    segments: list[dict],
    speaker_embeddings: dict[str, list[float]] | None,
    roster: RosterStore,
    *,
    user_label: str = "",
    channel_me: str = USER_SPEAKER,
    mic_me: str | None = None,
    voiceprint_me: str | None = None,
    mic_tier: MicTier | None = None,
    voiceprint: list[float] | None = None,
) -> SpeakerLabelResolution:
    """Map each diarization speaker id present in `segments` to its final label:
    the user's name ("me"), a matched roster name (`roster.match`), or a stable
    THEM-A/B cluster for an unknown voice. A speaker with no embedding keeps its
    raw id (it cannot be roster-matched, e.g. channel-fallback labels), except a
    no-voiceprint over-split owner's cluster (DIAR11, below), which is named from its mic time. The "me"
    speaker is never roster-matched. `roster` may be None (no roster).

    An identified user with an empty `user_label` is labelled `USER_SPEAKER` (UX83).
    When no signal identifies the user (`_resolve_me_id` returns None, the
    silent-owner case), no speaker is given `user_label`; every voice falls
    through to a roster match or a THEM-x cluster, which the user can name in
    the app.

    A cluster the roster declined but came close on is reported in `near_misses`
    (FEAT14) so the app can offer that person as a suggestion. It changes no
    label here: a near miss is still a `THEM-x` cluster on disk, and stays one
    until a human accepts the name.

    DIAR11: with the self-`voiceprint` and the meeting's `mic_tier` (the per-cluster
    mic fractions), a cluster the roster did not name that matches the voiceprint
    at the roster's same-person bar AND is mic-side is the owner over-split, and is
    given the owner's name too. One that matches but is system-side is a remote voice
    that sounds like the owner and is left alone, counted as flagged: it must never
    take the owner's name. A cluster the roster already names is never folded.

    With NO voiceprint (`voiceprint` is None) and a mic tier that declined only on the
    runner-up share, the mic-side clusters in `mic_tier.split` are folded into the leader
    the caller named (`mic_me`), which is how the print gets bootstrapped (owner decision
    2026-11-17). Accepted cost, audit F096: a second person on the owner's mic gets the
    owner's name until a print exists to tell them apart.
    `owner` reports the choice for the event log."""
    from .roster import MATCH_MIN as _SAME_PERSON_MIN  # lazy: roster imports this module

    mapping: dict[str, str] = {}
    fractions = (
        {spk: mic_tier.fraction(spk) for spk in mic_tier.total_time} if mic_tier else None
    )
    me, tier = _resolve_me(
        segments, channel_me=channel_me, mic_me=mic_me, voiceprint_me=voiceprint_me,
        mic_fractions=fractions,
    )
    # UX83: an identified owner with no name set takes the reserved `speaker_user`, the
    # label the channel fallback already gives the same person, never the diarizer's raw
    # id ("1"), which the app counted as a roster match and summaries listed as an
    # attendee. With nobody identified the label stays empty, as before. A non-empty
    # label also turns on DIAR11's two folds below, so an over-split owner folds into
    # `speaker_user` the way it folds into a set name.
    label = user_label.strip() or (USER_SPEAKER if me is not None else "")
    if me is not None and label:
        mapping[me] = label
    order: list[str] = []
    seen: set[str] = set()
    for s in segments:
        spk = s.get("speaker")
        if spk and spk != me and spk not in seen:
            seen.add(spk)
            order.append(spk)
    unknown_idx = 0
    near_misses: dict[str, str] = {}
    folded = flagged = 0
    # A mic pick and a voiceprint pick that disagreed left nobody named; folding the mic pick in
    # anyway would name somebody the rule just declined to.
    disagreed = me is None and bool(mic_me) and bool(voiceprint_me) and mic_me != voiceprint_me
    me_emb = speaker_embeddings.get(me) if (me and speaker_embeddings) else None
    for spk in order:
        emb = speaker_embeddings.get(spk) if speaker_embeddings else None
        scored = roster.match_detail(emb) if (roster is not None and emb) else None
        name = scored.name if scored else None
        if name and name != label:
            mapping[spk] = name
            continue
        if (
            label and voiceprint is None and me is not None and tier == "mic"
            and mic_tier is not None and mic_tier.split[:1] == (me,) and spk in mic_tier.split
        ):
            mapping[spk] = label
            folded += 1
            continue
        if emb is None:
            continue
        if (
            label and voiceprint and fractions is not None and not disagreed
            and cosine_similarity(emb, voiceprint) >= _SAME_PERSON_MIN
            # With an owner already named, the cluster must also sound like THAT cluster: a second
            # local voice that happens to score 0.66 to the voiceprint is not an over-split owner.
            and (me_emb is None or cosine_similarity(emb, me_emb) >= _SAME_PERSON_MIN)
        ):
            if fractions.get(spk, 0.0) >= MIC_FRACTION_MIN:
                mapping[spk] = label
                folded += 1
                continue
            flagged += 1
        them = them_label(unknown_idx)
        mapping[spk] = them
        unknown_idx += 1
        # Same guard the accept path applies: the owner is identified by their
        # own voiceprint, so suggesting their name for another voice would be
        # wrong in the one case the roster cannot arbitrate.
        if scored and scored.near_miss and scored.near_miss != label:
            near_misses[them] = scored.near_miss

    chosen_emb = speaker_embeddings.get(me) if (me and speaker_embeddings) else None
    runner = None
    if mic_tier is not None:
        # The best cluster other than the one named, by mic speech: what the
        # pick had to beat (or, when nobody was named, the contenders' leader).
        runner = min(
            (k for k in mic_tier.total_time if k != me),
            key=lambda k: (-mic_tier.mic_time.get(k, 0.0), k),
            default=None,
        )
    owner = OwnerChoice(
        tier=tier,
        mic_fraction=round(mic_tier.fraction(me), 3) if (mic_tier and me) else None,
        mic_seconds=round(mic_tier.mic_time.get(me, 0.0), 1) if (mic_tier and me) else None,
        voiceprint_score=(
            round(cosine_similarity(chosen_emb, voiceprint), 3)
            if (chosen_emb and voiceprint) else None
        ),
        runner_up_fraction=round(mic_tier.fraction(runner), 3) if (mic_tier and runner) else None,
        runner_up_seconds=round(mic_tier.mic_time.get(runner, 0.0), 1) if (mic_tier and runner) else None,
        folded=folded,
        flagged=flagged,
    )
    return SpeakerLabelResolution(mapping, near_misses, owner, me if label else None)


def apply_speaker_labels(segments: list[dict], mapping: dict[str, str]) -> list[dict]:
    """Return a new segment list with each speaker id replaced per `mapping`;
    ids absent from the mapping (and a segment with no speaker at all) are left
    unchanged."""
    out: list[dict] = []
    for s in segments:
        speaker = s.get("speaker")
        resolved = mapping.get(speaker, speaker) if isinstance(speaker, str) else speaker
        out.append({**s, "speaker": resolved})
    return out
