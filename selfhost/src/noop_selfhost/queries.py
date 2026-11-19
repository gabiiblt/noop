"""Read-only query layer behind the MCP tools. Pure functions over a read-only sqlite3 connection
(row_factory=sqlite3.Row). Inputs/outputs are UTC seconds internally; every returned time is
Europe/Paris ISO-8601. Stream and column names always come from the registry, never from input."""
from __future__ import annotations

import sqlite3
import time

from .registry import REGISTRY
from .rr_policy import apply_read_policy
from .sleep import parse_stages, pick_sleep, wake_day
from .stress import (
    MIN_BASELINE_WINDOWS, STILL_MOTION_MAX, WINDOW_S, compute_stress_timeline, gravity_motion,
    personal_baseline,
)
from .tz import day_bounds, local_day_of, local_iso

MAX_ROWS = 5000
FUTURE_SLACK_S = 86400
BASELINE_DAYS = 14
MAX_STRESS_RANGE_S = 7 * 86400
MAX_TEXT = 2000
RR_FETCH_CAP = 8 * MAX_ROWS
BASELINE_SAMPLES = 400  # 5-minute windows read for the personal baseline (plenty for a median/MAD)
DISCLAIMER = ("Heuristic estimate from heart-rate variability, heart rate and motion; "
              "not medical advice or a diagnosis.")


def _cap(now: int | None) -> int:
    return (int(time.time()) if now is None else now) + FUTURE_SLACK_S


def _t(ts: int) -> str:
    return local_iso(ts)


def _q(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def hr_range(conn: sqlite3.Connection, start: int, end: int, bucket_s: int | None = None,
             now: int | None = None) -> dict:
    cap = _cap(now)
    base = {"start": _t(start), "end": _t(end), "bucket_s": bucket_s}
    if bucket_s is not None:
        if not 1 <= bucket_s <= 86400:
            raise ValueError("bucket must be between 1 s and 24 h")
        rows = conn.execute(
            "SELECT (ts/?)*? AS b, MIN(bpm) lo, MAX(bpm) hi, AVG(bpm) av, COUNT(*) n FROM hrSample "
            "WHERE ts>=? AND ts<? AND ts<=? GROUP BY b ORDER BY b LIMIT ?",
            (bucket_s, bucket_s, start, end, cap, MAX_ROWS + 1)).fetchall()
        points = [{"time": _t(r["b"]), "bpm_min": r["lo"], "bpm_max": r["hi"],
                   "bpm_avg": round(r["av"], 1), "n": r["n"]} for r in rows[:MAX_ROWS]]
    else:
        rows = conn.execute(
            "SELECT ts, AVG(bpm) bpm FROM hrSample WHERE ts>=? AND ts<? AND ts<=? GROUP BY ts ORDER BY ts LIMIT ?",
            (start, end, cap, MAX_ROWS + 1)).fetchall()
        points = [{"time": _t(r["ts"]), "ts": r["ts"], "bpm": r["bpm"]} for r in rows[:MAX_ROWS]]
    out = {**base, "count": len(points), "truncated": len(rows) > MAX_ROWS, "points": points}
    if not points:
        out["note"] = "No data in this range (the phone may not have synced yet)."
    return out


_RR_COLS = 'ts, rrMs, seq, ord, srcChannel, "_dev" AS dev, "_src" AS src'


def _rr_rows(conn, a: int, b: int, cap: int, limit: int) -> list[dict]:
    return apply_read_policy([dict(r) for r in conn.execute(
        f"SELECT {_RR_COLS} FROM rrInterval WHERE ts>=? AND ts<? AND ts<=? "
        "AND (tsSuspect IS NULL OR tsSuspect=0) ORDER BY ts, seq, rowid LIMIT ?", (a, b, cap, limit))])


def rr_range(conn: sqlite3.Connection, start: int, end: int, now: int | None = None) -> dict:
    cap = _cap(now)
    raw = conn.execute(
        f"SELECT {_RR_COLS} FROM rrInterval WHERE ts>=? AND ts<? AND ts<=? "
        "AND (tsSuspect IS NULL OR tsSuspect=0) ORDER BY ts, seq, rowid LIMIT ?",
        (start, end, cap, RR_FETCH_CAP + 1)).fetchall()
    kept = apply_read_policy([dict(r) for r in raw[:RR_FETCH_CAP]])
    points = [{"time": _t(r["ts"]), "ts": r["ts"], "rr_ms": r["rrMs"], "seq": r["seq"]} for r in kept[:MAX_ROWS]]
    out = {"start": _t(start), "end": _t(end), "count": len(points),
           "truncated": len(raw) > RR_FETCH_CAP or len(kept) > MAX_ROWS, "points": points}
    if not points:
        out["note"] = "No R-R data in this range."
    return out


def _session_out(r: dict) -> dict:
    st = parse_stages(r.get("stagesJSON"), r["startTs"], r["endTs"])
    eff = r.get("efficiency")
    return {
        "source": r["source"], "start": _t(r["startTs"]), "end": _t(r["endTs"]),
        "duration_min": round((r["endTs"] - r["startTs"]) / 60, 1),
        "efficiency_pct": None if eff is None else round(eff * 100 if eff <= 1.5 else eff, 1),
        "resting_hr": r.get("restingHr"), "avg_hrv": r.get("avgHrv"), "user_edited": bool(r.get("userEdited")),
        "minutes": st["minutes"],
        "segments": [{"start": _t(s["start"]), "end": _t(s["end"]), "stage": s["stage"]} for s in st["segments"]],
    }


def sleep_for(conn: sqlite3.Connection, day: str, now: int | None = None) -> dict:
    a, b = day_bounds(day)
    rows = conn.execute(
        'SELECT "_dev" AS deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited '
        "FROM sleepSession WHERE endTs>=? AND endTs<? ORDER BY startTs", (a - 43200, b + 43200)).fetchall()
    kept = [r for r in pick_sleep([dict(r) for r in rows]) if wake_day(r) == day]
    out = {"day": day, "sessions": [_session_out(r) for r in kept]}
    if not kept:
        out["note"] = "No sleep session recorded for this wake day (not synced yet?)."
    return out


def _history_rr(conn, a: int, b: int, cap: int):
    return [(r["ts"], r["rrMs"]) for r in _rr_rows(conn, a, b, cap, -1)]


def _hr_pairs(conn, a: int, b: int, cap: int):
    return [(r["ts"], r["bpm"]) for r in conn.execute(
        "SELECT ts, AVG(bpm) bpm FROM hrSample WHERE ts>=? AND ts<? AND ts<=? GROUP BY ts ORDER BY ts", (a, b, cap))]


def _motion(conn, a: int, b: int, cap: int):
    return gravity_motion([(r["ts"], r["x"], r["y"], r["z"]) for r in conn.execute(
        "SELECT ts, x, y, z FROM gravitySample WHERE ts>=? AND ts<? AND ts<=? ORDER BY ts", (a, b, cap))])


def _sample(buckets: list[int], limit: int) -> list[int]:
    """Evenly spaced, deterministic subset (all of them when there are few)."""
    if len(buckets) <= limit:
        return list(buckets)
    step = len(buckets) / limit
    return [buckets[int(i * step)] for i in range(limit)]


def _baseline(conn, start: int, cap: int):
    """Personal baseline from at most BASELINE_SAMPLES still, waking 5-minute windows of the previous
    BASELINE_DAYS days. Windows are sampled (a median/MAD does not need all ~4,000), and each is read
    with small time-indexed queries, so the cost does not grow with how much data the phone has sent."""
    lo = start - BASELINE_DAYS * 86400
    sleeps = [(r["startTs"], r["endTs"]) for r in conn.execute(
        "SELECT startTs, endTs FROM sleepSession WHERE endTs>=? AND startTs<?", (lo, start))]
    buckets = [r[0] for r in conn.execute(
        "SELECT ts/? AS b FROM rrInterval WHERE ts>=? AND ts<? AND ts<=? GROUP BY b ORDER BY b",
        (WINDOW_S, lo, start, cap))]
    hist = []
    for b in _sample(buckets, BASELINE_SAMPLES):
        a, e = b * WINDOW_S, (b + 1) * WINDOW_S
        if any(s < e and a < en for s, en in sleeps):
            continue
        for w in compute_stress_timeline(_history_rr(conn, a, e, cap), _hr_pairs(conn, a, e, cap),
                                         _motion(conn, a, e, cap), None):
            if (w.start_ts == a and w.rmssd is not None and w.mean_hr is not None and w.motion is not None
                    and w.motion <= STILL_MOTION_MAX):
                hist.append((w.rmssd, w.mean_hr))
    return personal_baseline(hist), len(hist)


def stress_timeline(conn: sqlite3.Connection, start: int, end: int, now: int | None = None) -> dict:
    if end - start > MAX_STRESS_RANGE_S:
        raise ValueError("range too long: get_stress_timeline accepts at most 7 days per call")
    cap = _cap(now)
    base, used = _baseline(conn, start, cap)
    wins = compute_stress_timeline(_history_rr(conn, start, end, cap), _hr_pairs(conn, start, end, cap),
                                   _motion(conn, start, end, cap), base)
    out = {
        "heuristic": True, "disclaimer": DISCLAIMER, "window_s": WINDOW_S,
        "baseline": None if base is None else {"median_rmssd_ms": round(base.median, 1),
                                               "mad_ms": round(base.mad, 1), "rest_hr": round(base.rest_hr, 1),
                                               "windows_used": used},
        "windows": [{**w.to_dict(), "start": _t(w.start_ts), "end": _t(w.end_ts)} for w in wins],
    }
    notes = []
    if base is None:
        notes.append(f"No personal baseline yet: needs at least {MIN_BASELINE_WINDOWS} still, waking 5-minute "
                     f"windows in the previous {BASELINE_DAYS} days; labels are 'unknown'.")
    if not wins:
        notes.append("No heart data in this range.")
    if notes:
        out["note"] = " ".join(notes)
    return out


def _daily(conn: sqlite3.Connection, day: str) -> dict | None:
    cols = [c.name for c in REGISTRY["dailyMetric"].all_data]
    rows = conn.execute(f'SELECT "_dev" AS dev, {", ".join(_q(c) for c in cols)} FROM dailyMetric WHERE day=?',
                        (day,)).fetchall()
    if not rows:
        return None
    imported = [r for r in rows if not str(r["dev"]).endswith("-noop")]
    r = (imported or rows)[0]
    return {**{c: r[c] for c in cols}, "source": "imported" if imported else "computed"}


def day_summary(conn: sqlite3.Connection, day: str, now: int | None = None) -> dict:
    a, b = day_bounds(day)
    cap = _cap(now)
    hrs = conn.execute(
        "SELECT COUNT(*) n, MIN(bpm) lo, MAX(bpm) hi, AVG(bpm) av FROM "
        "(SELECT ts, AVG(bpm) bpm FROM hrSample WHERE ts>=? AND ts<? AND ts<=? GROUP BY ts)", (a, b, cap)).fetchone()
    hours = (b - a) / 3600
    sleeps = sleep_for(conn, day)["sessions"]
    daily = _daily(conn, day)
    workouts = [{"sport": r["sport"], "start": _t(r["startTs"]), "end": _t(r["endTs"]), "source": r["source"],
                 "duration_s": r["durationS"], "energy_kcal": r["energyKcal"], "avg_hr": r["avgHr"],
                 "max_hr": r["maxHr"], "strain": r["strain"], "distance_m": r["distanceM"]}
                for r in conn.execute(
                    "SELECT sport, startTs, endTs, source, durationS, energyKcal, avgHr, maxHr, strain, distanceM "
                    "FROM workout WHERE startTs>=? AND startTs<? ORDER BY startTs", (a, b))]
    out = {
        "day": day, "hours_in_day": int(hours) if hours == int(hours) else hours,
        "has_data": bool(hrs["n"] or daily or sleeps or workouts),
        "heart_rate": {"samples": hrs["n"], "min": hrs["lo"], "max": hrs["hi"],
                       "avg": None if hrs["av"] is None else round(hrs["av"], 1)},
        "daily": daily, "sleep": sleeps, "workouts": workouts,
    }
    st = stress_timeline(conn, a, b, now)
    counts: dict[str, int] = {}
    for w in st["windows"]:
        counts[w["label"]] = counts.get(w["label"], 0) + 1
    top = sorted((w for w in st["windows"] if w["label"] == "stressed"), key=lambda w: -(w["score"] or 0))[:5]
    out["stress"] = {"heuristic": True, "disclaimer": DISCLAIMER, "counts": counts, "top_windows": top,
                     "baseline_available": st["baseline"] is not None}
    if not out["has_data"]:
        out["note"] = "No data for this day (the phone may not have synced yet)."
    return out


def stream_range(conn: sqlite3.Connection, stream: str, start: int, end: int, limit: int = 200,
                 offset: int = 0, now: int | None = None) -> dict:
    s = REGISTRY.get(stream)
    if s is None:
        raise ValueError(f"unknown stream: {stream!r}")
    limit = max(1, min(int(limit), MAX_ROWS))
    offset = max(0, int(offset))
    cap = _cap(now)
    key_names = [c.name for c in s.key]
    cols = [c for c in s.key] + list(s.all_data)
    select = ", ".join(f'length({_q(c.name)}) AS {_q(c.name)}' if c.type == "blob" else _q(c.name) for c in cols)
    where, params, note = "", [], None
    if s.delivery == "append":
        where, params = "WHERE ts>=? AND ts<? AND ts<=?", [start, end, cap]
    elif s.selector == "day":
        where, params = "WHERE day>=? AND day<=?", [local_day_of(start), local_day_of(max(start, end - 1))]
    elif s.selector in ("startTs", "ts"):
        col = _q(s.selector)
        where, params = f"WHERE {col}>=? AND {col}<? AND {col}<=?", [start, end, cap]
    else:
        note = "snapshot stream: the whole table is returned; the time range does not apply."
    total = conn.execute(f"SELECT COUNT(*) FROM {_q(s.name)} {where}", params).fetchone()[0]
    order = ", ".join(_q(n) for n in key_names)
    rows = conn.execute(f'SELECT "_dev" AS _device, {select} FROM {_q(s.name)} {where} ORDER BY {order} '
                        f"LIMIT ? OFFSET ?", [*params, limit, offset]).fetchall()
    out_rows = []
    for r in rows:
        row = {"device": r["_device"]}
        for c in cols:
            v = r[c.name]
            if c.type == "blob" and v is not None:
                v = {"bytes": v}
            elif isinstance(v, str) and len(v) > MAX_TEXT:
                v = v[:MAX_TEXT] + f"…[truncated {len(v) - MAX_TEXT} chars]"
            row[c.name] = v
        t = row.get("ts", row.get("startTs"))
        if isinstance(t, int):
            row["time"] = _t(t)
        out_rows.append(row)
    out = {"stream": stream, "delivery": s.delivery, "count": len(out_rows), "total_in_range": total,
           "offset": offset, "limit": limit, "rows": out_rows}
    if note:
        out["note"] = note
    return out


FRESH_HR_S = 20 * 60  # newest heart rate younger than this reads as "fresh" (the strap sends ~1 Hz while worn)


def _ago(ts: int | None, now: int) -> dict | None:
    if ts is None:
        return None
    return {"time": _t(ts), "minutes_ago": max(0, (now - ts) // 60)}


def _table_exists(conn: sqlite3.Connection, name: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def last_arrival(conn: sqlite3.Connection) -> int | None:
    """Receiver clock of the most recent accepted batch (None before the first one, or on an old database)."""
    if not _table_exists(conn, "arrivals"):
        return None
    return conn.execute("SELECT MAX(lastReceivedAt) FROM arrivals").fetchone()[0]


def wake_device(conn: sqlite3.Connection) -> dict | None:
    if not _table_exists(conn, "wake_device"):
        return None
    r = conn.execute("SELECT deviceToken, environment, topic, updatedAt FROM wake_device WHERE id=1").fetchone()
    return None if r is None else dict(r)


def sync_status(conn: sqlite3.Connection, now: int | None = None, wake_configured: bool = False) -> dict:
    """How fresh the server's copy is: when the phone last delivered, and the newest data per stream.

    Two clocks on purpose: `last_received` is when the phone uploaded (receiver clock), `latest_data` is
    the newest timestamp inside the data. Fresh data uploaded late and old data uploaded now look the same
    in one clock and different in the other."""
    now = int(time.time()) if now is None else now
    cap = now + FUTURE_SLACK_S
    arrivals = {}
    if _table_exists(conn, "arrivals"):
        for r in conn.execute("SELECT stream, MAX(lastReceivedAt) at, SUM(batches) b, SUM(rows) n "
                              "FROM arrivals GROUP BY stream"):
            arrivals[r["stream"]] = r
    streams = []
    for s in REGISTRY.values():
        latest = None
        if s.selector is not None:
            sel = _q(s.selector)
            if s.selector == "day":
                latest = conn.execute(f"SELECT MAX({sel}) FROM {_q(s.name)}").fetchone()[0]
            else:
                ts = conn.execute(f"SELECT MAX({sel}) FROM {_q(s.name)} WHERE {sel}<=?", (cap,)).fetchone()[0]
                latest = None if ts is None else _t(ts)
        a = arrivals.get(s.name)
        if latest is None and a is None:
            continue
        streams.append({"stream": s.name, "latest_data": latest,
                        "last_received": None if a is None else _t(a["at"]),
                        "minutes_since_received": None if a is None else max(0, (now - a["at"]) // 60),
                        "batches_received": None if a is None else a["b"],
                        "rows_received": None if a is None else a["n"]})
    hr_ts = conn.execute("SELECT MAX(ts) FROM hrSample WHERE ts<=?", (cap,)).fetchone()[0]
    sleep_end = conn.execute("SELECT MAX(endTs) FROM sleepSession WHERE endTs<=?", (cap,)).fetchone()[0]
    scored = conn.execute("SELECT day, recovery, strain FROM dailyMetric WHERE recovery IS NOT NULL "
                          "OR strain IS NOT NULL ORDER BY day DESC LIMIT 1").fetchone()
    up = last_arrival(conn)
    dev = wake_device(conn)
    out = {
        "now": _t(now),
        "last_upload": _ago(up, now),
        "latest_heart_rate": _ago(hr_ts, now),
        "latest_sleep_end": _ago(sleep_end, now),
        "latest_daily_scores": None if scored is None else dict(scored),
        "streams": streams,
        "phone_wake": {"available": wake_configured and dev is not None,
                       "server_configured": wake_configured,
                       "phone_registered": dev is not None,
                       "registered": None if dev is None else _t(dev["updatedAt"])},
    }
    if hr_ts is None:
        out["verdict"] = "empty"
        out["advice"] = "No heart-rate data has reached the server yet."
    elif now - hr_ts <= FRESH_HR_S:
        out["verdict"] = "fresh"
        out["advice"] = "Data is current to within a few minutes."
    else:
        out["verdict"] = "stale"
        out["advice"] = (f"The newest heart rate is {(now - hr_ts) // 60} minutes old: the phone has not "
                         "uploaded since, or the strap has not synced to the phone. "
                         + ("Call request_phone_sync to wake the phone and wait for fresh data."
                            if out["phone_wake"]["available"] else
                            "Say how old the data is rather than guessing what happened since."))
    if scored is None:
        out["scores_note"] = ("No daily recovery/strain score yet. NOOP computes them on the phone and needs "
                              "several nights of data to calibrate after a fresh install.")
    return out
