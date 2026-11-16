"""Sleep helpers: parse both `stagesJSON` shapes the app writes and choose between sources."""
from __future__ import annotations

import json

from .tz import local_day_of

_STAGES = ("light", "deep", "rem", "awake")


def _num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def parse_stages(stages_json: str | None, start_ts: int, end_ts: int) -> dict:
    """Normalise to {"segments": [{start,end,stage}], "minutes": {stage: minutes}}.

    Two shapes exist: computed sessions store a segment array in epoch seconds (awake is
    "wake"); imported sessions store minutes per stage. Anything else yields empty results.
    """
    empty: dict = {"segments": [], "minutes": {}}
    if not stages_json:
        return empty
    try:
        obj = json.loads(stages_json)
    except ValueError:
        return empty
    if isinstance(obj, dict):
        if not obj or any(not _num(v) for v in obj.values()):
            return empty
        mins = {k: round(float(obj[k]), 1) for k in _STAGES if k in obj}
        return {"segments": [], "minutes": mins} if mins else empty
    if not isinstance(obj, list):
        return empty
    segs, totals = [], {}
    for s in obj:
        if not (isinstance(s, dict) and _num(s.get("start")) and _num(s.get("end"))
                and isinstance(s.get("stage"), str)):
            continue
        a, b = max(int(s["start"]), start_ts), min(int(s["end"]), end_ts)
        if b <= a:
            continue
        stage = "awake" if s["stage"].lower() == "wake" else s["stage"].lower()
        segs.append({"start": a, "end": b, "stage": stage})
        totals[stage] = totals.get(stage, 0) + (b - a)
    if not segs:
        return empty
    return {"segments": segs, "minutes": {k: round(v / 60, 1) for k, v in totals.items()}}


def wake_day(session: dict) -> str:
    """A night belongs to the local calendar day on which it ended."""
    return local_day_of(session["endTs"])


def _is_computed(row: dict) -> bool:
    return str(row["deviceId"]).endswith("-noop")


def pick_sleep(rows: list[dict]) -> list[dict]:
    """Prefer imported/strap sessions; keep an on-device computed session only if it does not
    overlap one already kept. Each returned row gains `source` ("imported"|"computed")."""
    kept = [dict(r, source="imported") for r in rows if not _is_computed(r)]
    for r in sorted((r for r in rows if _is_computed(r)), key=lambda r: r["startTs"]):
        if not any(r["startTs"] < k["endTs"] and k["startTs"] < r["endTs"] for k in kept):
            kept.append(dict(r, source="computed"))
    return sorted(kept, key=lambda r: r["startTs"])
