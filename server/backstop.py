"""Conservative server-side SpO2 backstop for the CNS-depression klaxon's
redundant alert channel (sub-project C).

This is a *backstop*, not a second opinion. It exists so that a silent
backend or on-device failure is still caught by an independent, deliberately
dumb evaluator -- the 2019-Dexcom-Follow-outage lesson that motivated the whole
redundant channel (server-redundant-alert-channel-design sec. 1, sec. 5). It
uses FIXED, absolute floors only, never the personalized baseline-relative
logic that lives on-device in ``CNSFusionEngine`` / ``CNSAlertTierMachine``.
Porting that life-safety Swift engine to Python is a correctness hazard the
design explicitly forbids (design sec. 5 "conservative backstop only",
sec. 7 non-goals).

Safety invariants (do not weaken):

* **Conservative.** It raises only on a *clearly sustained*, *gap-free* low
  SpO2 run. Brief dips, short windows, recoveries above the floor, and
  evidence separated by a data blackout never trigger it.
* **Gap guard (a rise guard AND a safety invariant).** Two low readings that
  bracket a data blackout must NOT satisfy the sustain window -- a rise must be
  earned by continuously observed evidence, never inferred across missing data.
  This mirrors the on-device ``CNSThresholds.sustainMaxGapSeconds`` gap guard.
* **Pure.** No DB, no network, no I/O, no globals, no wall-clock reads: the
  caller injects ``now``. Given the same inputs it always returns the same
  verdict, so it is exhaustively table-testable.

It intentionally does NOT re-implement the on-device quality gate (perfusion
index / SQI / artifact percentage). Artifact / no-contact / no-finger samples
are expected to be *absent* from the uploaded stream (the phone omits them
rather than uploading a coerced value); any resulting hole is a data gap, which
the gap guard already handles by breaking the run.
"""

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime


# --- Fixed, absolute backstop thresholds (never inline these literals) -------

# Absolute SpO2 hard floor, in percent. This is the parent klaxon design's
# terminal-episode floor: cns-depression-klaxon-design sec. 3 cites the PRODIGY
# trial's definition of a *terminal* respiratory-depression episode as
# "RR <= 5, SpO2 <= 85%, apnea > 30 s", and the on-device early-warning is
# deliberately set to fire *above* those terminal floors. The on-device SpO2
# onset is personalized -- ``min(88%, personal-nadir - N)`` -- so 88% is an
# early-warning value, not an absolute floor. The server backstop instead pins
# the fixed terminal floor (85%) so that it (a) needs no per-user baseline and
# (b) sits well below a normal CPAP/apnea-inclusive nightly nadir once the
# sustain requirement is applied: a single spot dip to 85% is ordinary in sleep
# apnea, but a *continuously observed* run below it for >= SUSTAIN_SECONDS is
# not, which is exactly what makes a fixed floor defensible for a backstop.
SPO2_FLOOR = 85.0

# How long SpO2 must stay continuously below SPO2_FLOOR to raise, in seconds.
# Design sec. 3 gives the early-warning sustain as "sustained >= ~60-90 s"; the
# backstop takes the conservative TOP of that range. The on-device rise sustain
# (``CNSThresholds.riseSustainSeconds``) is 60 s -- the backstop is deliberately
# slower and more conservative than the on-device path (design sec. 5).
SUSTAIN_SECONDS = 90.0

# Largest gap between two consecutive qualifying (below-floor) samples that
# still counts as one continuous run, in seconds. A gap strictly greater than
# this is a data blackout: it breaks the run so that two low readings bracketing
# missing data can never be laundered into a sustained low. Mirrors the
# on-device gap guard ``CNSThresholds.sustainMaxGapSeconds`` (5 s).
MAX_GAP_SECONDS = 5.0

# Channel identifier for SpO2 samples in the uploaded stream. Matches the AS11
# stream-sample channel label used elsewhere in the server; compared
# case-insensitively so an "SpO2"/"spo2" variant is still recognized.
SPO2_CHANNEL = "SPO2"


@dataclass(frozen=True)
class Sample:
    """One uploaded physiological sample.

    ``value`` for an SpO2 sample is a percent (0-100). Non-SpO2 channels are
    ignored by the backstop.
    """

    ts_utc: datetime
    channel: str
    value: float


@dataclass(frozen=True)
class BackstopVerdict:
    """Result of a backstop evaluation.

    ``raised`` is the ONLY field that gates an alert. The rest exist for the
    channel-health / observability surface (design sec. 3, "own failure is
    visible") and never affect the decision.
    """

    raised: bool
    reason: str
    # Span of the longest gap-free below-floor run observed, in seconds.
    sustained_seconds: float
    # Echo of the injected evaluation time (audit / channel-health only).
    evaluated_at: datetime


def _is_spo2(sample: Sample) -> bool:
    return sample.channel.strip().upper() == SPO2_CHANNEL


def evaluate(samples: Iterable[Sample], now: datetime) -> BackstopVerdict:
    """Return a conservative SpO2 backstop verdict for ``samples`` as of ``now``.

    ``verdict.raised`` is True iff the SpO2 channel stayed continuously below
    ``SPO2_FLOOR`` for at least ``SUSTAIN_SECONDS``, with no gap greater than
    ``MAX_GAP_SECONDS`` between consecutive below-floor samples. Any recovery to
    or above the floor, any run shorter than the sustain window, and any
    blackout inside a run all prevent a raise.

    ``now`` is injected so the function performs no wall-clock reads and stays
    deterministically testable. It is recorded on the verdict but NEVER changes
    the raise decision: the caller owns the recency of the window it passes in
    (mirroring the server's bounded stream-replay window), and detecting a
    stopped feed is the separate no-data / heartbeat monitor's job, not the
    backstop's.
    """
    ordered = sorted((s for s in samples if _is_spo2(s)), key=lambda s: s.ts_utc)

    longest = 0.0        # longest gap-free below-floor run span seen, seconds
    saw_low = False      # any below-floor SpO2 sample at all?
    run_start = None     # ts of the first below-floor sample in the current run
    prev_low_ts = None   # ts of the previous below-floor sample in the run

    for sample in ordered:
        if sample.value < SPO2_FLOOR:
            saw_low = True
            # run_start and prev_low_ts always move together (both None between
            # runs, both set within one). Folding the "first low sample" and
            # "blackout larger than the gap guard" cases into a single guard
            # keeps the None-safety provable instead of resting on that coupling:
            # when the guard is False, both are non-None for the arithmetic below.
            if (
                run_start is None
                or prev_low_ts is None
                or (sample.ts_utc - prev_low_ts).total_seconds() > MAX_GAP_SECONDS
            ):
                # First low sample, or the earlier evidence is separated by a
                # data blackout: start a fresh run here rather than bridging the
                # gap (two low readings must never be laundered across missing data).
                run_start = sample.ts_utc
            prev_low_ts = sample.ts_utc
            span = (sample.ts_utc - run_start).total_seconds()
            if span > longest:
                longest = span
        else:
            # Recovery to/above the floor: SpO2 did not "stay below", run ends.
            run_start = None
            prev_low_ts = None

    raised = longest >= SUSTAIN_SECONDS

    if raised:
        reason = (
            "sustained SpO2 below %.0f%% for %.0fs (>= %.0fs), gap-free"
            % (SPO2_FLOOR, longest, SUSTAIN_SECONDS)
        )
    elif not ordered:
        reason = "no SpO2 samples in window"
    elif not saw_low:
        reason = "SpO2 stayed at or above %.0f%% floor" % SPO2_FLOOR
    else:
        reason = (
            "longest gap-free low run %.0fs < required %.0fs"
            % (longest, SUSTAIN_SECONDS)
        )

    return BackstopVerdict(
        raised=raised,
        reason=reason,
        sustained_seconds=longest,
        evaluated_at=now,
    )
