"""Which R-R beats count when several copies exist.

The phone can hold the same heartbeats more than once: a WHOOP 5/MG reports them on several transport
channels (the app scores one), and the same beats reach the server under more than one `sourceId` after an
app reinstall. Counting copies adds zero-difference pairs and drags RMSSD down, which reads as false stress.

This is a deliberately conservative APPROXIMATION of the app's read policy (Packages/WhoopStore
`Reads.rrIntervals`, `Whoop5RRReadPolicy`), which also consults the device registry that the server does not
have. Rules, per device and per hour:
  1. identical beats (device, ts, rrMs, seq, channel) from different sources collapse to one;
  2. if any beat in the hour carries a transport channel, keep one channel only: the lowest scorable
     WHOOP 5 channel (5, 7); else the WHOOP 4 history channel 8; else the lowest present; untagged
     (legacy) beats in such an hour are dropped as duplicates;
  3. an hour with no tagged beat keeps everything;
  4. output ordered by ts, device, ord, seq. Equal beats in one second (distinct seq) all survive.
"""
from __future__ import annotations

SCORABLE_WHOOP5_CHANNELS = (5, 7)
WHOOP4_HISTORY_CHANNEL = 8


def apply_read_policy(rows: list[dict]) -> list[dict]:
    seen: set[tuple] = set()
    unique = []
    for r in rows:
        key = (r["dev"], r["ts"], r["rrMs"], r["seq"], r["srcChannel"])
        if key not in seen:
            seen.add(key)
            unique.append(r)
    by_hour: dict[tuple, list[dict]] = {}
    for r in unique:
        by_hour.setdefault((r["dev"], r["ts"] // 3600), []).append(r)
    out: list[dict] = []
    for rs in by_hour.values():
        tagged = {r["srcChannel"] for r in rs if r["srcChannel"] is not None}
        if not tagged:
            out.extend(rs)
            continue
        scorable = [c for c in tagged if c in SCORABLE_WHOOP5_CHANNELS]
        if scorable:
            chosen = min(scorable)
        elif WHOOP4_HISTORY_CHANNEL in tagged:
            chosen = WHOOP4_HISTORY_CHANNEL
        else:
            chosen = min(tagged)
        out.extend(r for r in rs if r["srcChannel"] == chosen)
    out.sort(key=lambda r: (r["ts"], r["dev"], r["ord"] if r["ord"] is not None else 0, r["seq"]))
    return out
