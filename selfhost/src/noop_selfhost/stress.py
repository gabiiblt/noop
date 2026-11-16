"""Stress timeline HEURISTIC (not medical).

Per 5-minute window: RMSSD from cleaned R-R intervals compared with the owner's own baseline,
combined with elevated heart rate and low motion. Thresholds are documented defaults, not
calibrated against ground truth; treat the output as a hint about when to look, nothing more.

R-R cleaning is a port of Packages/StrandAnalytics/.../HRVAnalyzer.swift (range filter, Malik-style
20 % ectopic rejection over a +/-2 beat local median, successive differences never taken across a
removed beat), so the server and the app clean beats the same way.
"""
from __future__ import annotations

import math
import statistics
from dataclasses import dataclass
from typing import Iterable, Literal

RR_MIN_MS, RR_MAX_MS = 300, 2000
ECTOPIC_THRESHOLD = 0.20
ECTOPIC_RADIUS = 2

WINDOW_S = 300
MIN_BEATS = 30          # clean beats needed before a window gets an RMSSD
HR_DELTA = 10           # bpm above personal resting HR that counts as "elevated"
K_MAD = 1.0             # RMSSD must sit this many robust SDs below the personal median
MAD_FLOOR = 2.0         # ms; avoids dividing by a near-zero spread
STILL_MOTION_MAX = 0.05  # mean |delta gravity| per sample (g); above this the wrist is moving
MIN_BASELINE_WINDOWS = 20
MAX_GRAVITY_GAP_S = 5

Label = Literal["calm", "elevated", "stressed", "unknown"]


def _median(xs: list[float]) -> float:
    return statistics.median(xs)


def clean_rr(rr: Iterable[float]) -> tuple[list[float], list[bool]]:
    """Return (clean NN series, contiguous flags). contiguous[i] is True when nn[i] and nn[i-1] were
    adjacent beats in the original series (nothing dropped between them); index 0 is always False."""
    ranged = [(i, float(v)) for i, v in enumerate(rr) if RR_MIN_MS <= v <= RR_MAX_MS]
    vals = [v for _, v in ranged]
    if len(vals) <= ECTOPIC_RADIUS:
        kept = ranged
    else:
        kept = []
        for k, (i, v) in enumerate(ranged):
            lo, hi = max(0, k - ECTOPIC_RADIUS), min(len(vals) - 1, k + ECTOPIC_RADIUS)
            nb = [vals[j] for j in range(lo, hi + 1) if j != k]
            if len(nb) < 2:
                kept.append((i, v))
                continue
            med = _median(nb)
            if med <= 0 or abs(v - med) / med <= ECTOPIC_THRESHOLD:
                kept.append((i, v))
    nn = [v for _, v in kept]
    contiguous = [False] + [kept[k][0] - kept[k - 1][0] == 1 for k in range(1, len(kept))]
    return nn, contiguous


def rmssd(rr_ms: Iterable[float]) -> float | None:
    nn, contiguous = clean_rr(list(rr_ms))
    diffs = [nn[i] - nn[i - 1] for i in range(1, len(nn)) if contiguous[i]]
    if not diffs:
        return None
    return math.sqrt(sum(d * d for d in diffs) / len(diffs))


@dataclass(frozen=True)
class Baseline:
    median: float   # personal median RMSSD (ms)
    mad: float      # median absolute deviation of RMSSD (ms)
    rest_hr: float  # personal resting HR (bpm)


def personal_baseline(history: list[tuple[float, float]]) -> Baseline | None:
    """`history` = (rmssd, mean_hr) of comparable waking windows (e.g. trailing ~14 days)."""
    if len(history) < MIN_BASELINE_WINDOWS:
        return None
    rm = [r for r, _ in history]
    med = _median(rm)
    mad = _median([abs(r - med) for r in rm])
    hrs = sorted(h for _, h in history)
    rest = hrs[max(0, math.ceil(0.10 * len(hrs)) - 1)]  # nearest-rank 10th percentile
    return Baseline(med, mad, rest)


def gravity_motion(samples: list[tuple[int, float, float, float]]) -> list[tuple[int, float]]:
    """L2 distance between consecutive 1 Hz gravity vectors (the app's own stillness proxy)."""
    out = []
    for (t0, x0, y0, z0), (t1, x1, y1, z1) in zip(samples, samples[1:]):
        if 0 < t1 - t0 <= MAX_GRAVITY_GAP_S:
            out.append((t1, math.dist((x0, y0, z0), (x1, y1, z1))))
    return out


@dataclass(frozen=True)
class StressWindow:
    start_ts: int
    end_ts: int
    rmssd: float | None
    mean_hr: float | None
    motion: float | None
    score: int | None
    label: Label
    reason: str

    def to_dict(self) -> dict:
        return {"start_ts": self.start_ts, "end_ts": self.end_ts,
                "rmssd_ms": None if self.rmssd is None else round(self.rmssd, 1),
                "mean_hr": None if self.mean_hr is None else round(self.mean_hr, 1),
                "motion": None if self.motion is None else round(self.motion, 4),
                "score": self.score, "label": self.label, "reason": self.reason}


def _mean(xs: list[float]) -> float | None:
    return sum(xs) / len(xs) if xs else None


def compute_stress_timeline(rr: list[tuple[int, int]], hr: list[tuple[int, int]],
                            motion: list[tuple[int, float]], baseline: Baseline | None) -> list[StressWindow]:
    rr_by: dict[int, list[int]] = {}
    hr_by: dict[int, list[float]] = {}
    mo_by: dict[int, list[float]] = {}
    for ts, v in sorted(rr, key=lambda p: p[0]):
        rr_by.setdefault(ts // WINDOW_S, []).append(v)
    for ts, v in hr:
        hr_by.setdefault(ts // WINDOW_S, []).append(v)
    for ts, v in motion:
        mo_by.setdefault(ts // WINDOW_S, []).append(v)

    out: list[StressWindow] = []
    for w in sorted(set(rr_by) | set(hr_by)):
        start = w * WINDOW_S
        nn, _ = clean_rr(rr_by.get(w, []))
        r = rmssd(rr_by[w]) if len(nn) >= MIN_BEATS and w in rr_by else None
        mean_hr = _mean(hr_by.get(w, []))
        if mean_hr is None and nn:
            mean_hr = 60000 / (sum(nn) / len(nn))
        mo = _mean(mo_by.get(w, []))
        score: int | None = None
        if r is None:
            label, reason = "unknown", "too_few_beats"
        elif baseline is None:
            label, reason = "unknown", "no_baseline"
        else:
            z = (baseline.median - r) / (1.4826 * max(baseline.mad, MAD_FLOOR))
            score = round(50 + 50 * max(-3.0, min(3.0, z)) / 3)
            if z < K_MAD:
                label, reason = "calm", "rmssd_within_baseline"
            else:
                fails = []
                if mean_hr is None or mean_hr < baseline.rest_hr + HR_DELTA:
                    fails.append("hr_not_elevated")
                if mo is None:
                    fails.append("motion_unknown")
                elif mo > STILL_MOTION_MAX:
                    fails.append("moving")
                if fails:
                    label, reason = "elevated", "rmssd_low; " + ",".join(fails)
                else:
                    label, reason = "stressed", "rmssd_low+hr_elevated+still"
        out.append(StressWindow(start, start + WINDOW_S, r, mean_hr, mo, score, label, reason))
    return out
