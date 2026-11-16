"""Europe/Paris helpers. Stored times are UTC Unix seconds; a "day" is a local calendar day."""
from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

PARIS = ZoneInfo("Europe/Paris")


def _midnight(d: date) -> int:
    return int(datetime.combine(d, time(0), tzinfo=PARIS).timestamp())


def day_bounds(day: str) -> tuple[int, int]:
    """Half-open UTC-seconds bounds of a local day: 23 h on spring-forward, 25 h on fall-back."""
    d = date.fromisoformat(day)
    return _midnight(d), _midnight(d + timedelta(days=1))


def local_day_of(ts: int) -> str:
    return datetime.fromtimestamp(ts, PARIS).date().isoformat()


def local_iso(ts: int) -> str:
    return datetime.fromtimestamp(ts, PARIS).isoformat(timespec="seconds")


def parse_local(s: str) -> int:
    """ISO-8601 -> UTC seconds. Naive values (and bare dates) are Paris local time; on a DST
    fold the first occurrence is used."""
    dt = datetime.fromisoformat(s.strip())
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=PARIS)
    return int(dt.astimezone(timezone.utc).timestamp())
