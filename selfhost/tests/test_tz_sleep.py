import json
from datetime import datetime, timezone

from noop_selfhost.sleep import parse_stages, pick_sleep, wake_day
from noop_selfhost.tz import day_bounds, local_day_of, local_iso, parse_local


def utc(*a) -> int:
    return int(datetime(*a, tzinfo=timezone.utc).timestamp())


def test_day_bounds_dst_spring_is_23h():
    a, b = day_bounds("2026-03-29")
    assert b - a == 23 * 3600 and a == utc(2026, 3, 28, 23)


def test_day_bounds_autumn_is_25h():
    a, b = day_bounds("2026-10-25")
    assert b - a == 25 * 3600 and a == utc(2026, 10, 24, 22)


def test_day_bounds_ordinary_day_24h_and_contiguous():
    a, b = day_bounds("2026-06-10")
    assert b - a == 86400 and day_bounds("2026-06-11")[0] == b


def test_local_iso_uses_paris_offset():
    assert local_iso(utc(2026, 3, 29, 1, 30)) == "2026-03-29T03:30:00+02:00"
    assert local_iso(utc(2026, 1, 15, 12)) == "2026-01-15T13:00:00+01:00"


def test_parse_local_naive_offset_and_date_only():
    expected = utc(2026, 3, 29, 6)  # 08:00 Paris (CEST)
    assert parse_local("2026-03-29 08:00") == expected
    assert parse_local("2026-03-29T08:00:00") == expected
    assert parse_local("2026-03-29T08:00:00+02:00") == expected
    assert parse_local("2026-03-29T06:00:00Z") == expected
    assert parse_local("2026-03-29") == day_bounds("2026-03-29")[0]


def test_local_day_of_crosses_midnight_in_paris_not_utc():
    assert local_day_of(utc(2026, 3, 28, 23, 30)) == "2026-03-29"
    assert local_day_of(utc(2026, 3, 28, 22, 30)) == "2026-03-28"


def test_night_crossing_midnight_attributed_to_wake_day():
    start = parse_local("2026-03-28 23:00")
    end = parse_local("2026-03-29 06:30")
    assert wake_day({"startTs": start, "endTs": end}) == "2026-03-29"


def test_parse_stages_array_clips_normalises_wake_and_totals():
    js = json.dumps([{"start": 90, "end": 600, "stage": "wake"},
                     {"start": 600, "end": 1800, "stage": "light"},
                     {"start": 1800, "end": 2400, "stage": "deep"},
                     {"start": 2400, "end": 9999, "stage": "rem"}])
    out = parse_stages(js, 100, 3000)
    assert out["segments"][0] == {"start": 100, "end": 600, "stage": "awake"}
    assert out["segments"][-1] == {"start": 2400, "end": 3000, "stage": "rem"}
    assert out["minutes"] == {"awake": 8.3, "light": 20.0, "deep": 10.0, "rem": 10.0}


def test_parse_stages_minutes_dict():
    out = parse_stages('{"light":210,"deep":80.5,"rem":95,"awake":25}', 0, 1)
    assert out == {"segments": [], "minutes": {"light": 210.0, "deep": 80.5, "rem": 95.0, "awake": 25.0}}


def test_parse_stages_none_and_garbage_return_empty():
    empty = {"segments": [], "minutes": {}}
    for bad in (None, "", "not json", "42", "[1,2]", '[{"start":"a","end":1,"stage":"x"}]', '{"light":"x"}'):
        assert parse_stages(bad, 0, 100) == empty, bad


def test_pick_sleep_prefers_imported_falls_back_to_noop():
    imported = {"deviceId": "strap", "startTs": 1000, "endTs": 30000}
    computed_dup = {"deviceId": "strap-noop", "startTs": 1500, "endTs": 29000}
    computed_other_night = {"deviceId": "strap-noop", "startTs": 100000, "endTs": 130000}
    out = pick_sleep([computed_dup, imported, computed_other_night])
    assert [(r["deviceId"], r["source"]) for r in out] == [("strap", "imported"), ("strap-noop", "computed")]
    assert [r["startTs"] for r in out] == [1000, 100000]


def test_pick_sleep_keeps_non_overlapping_computed_nap():
    imported = {"deviceId": "strap", "startTs": 0, "endTs": 1000}
    nap = {"deviceId": "strap-noop", "startTs": 5000, "endTs": 6000}
    assert [r["source"] for r in pick_sleep([imported, nap])] == ["imported", "computed"]


def test_pick_sleep_empty():
    assert pick_sleep([]) == []
