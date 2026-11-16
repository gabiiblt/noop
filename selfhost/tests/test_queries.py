import json
from datetime import datetime, timezone

import pytest

from noop_selfhost import queries as q
from noop_selfhost.db import Store
from noop_selfhost.registry import REGISTRY
from noop_selfhost.tz import day_bounds, parse_local


def utc(*a) -> int:
    return int(datetime(*a, tzinfo=timezone.utc).timestamp())


NOW = utc(2026, 6, 10, 12)
SRC, DEV = "src-1", "strap"


@pytest.fixture
def store(tmp_path):
    return Store(str(tmp_path / "q.sqlite"))


@pytest.fixture
def conn(store):
    return Store.connect_ro(store.path)


def put(store, stream, rows, dev=DEV, version="1.100"):
    store.upsert_rows(REGISTRY[stream], SRC, dev, rows, version)


def put_hr(store, rows):
    put(store, "hrSample", [({"ts": t}, {"bpm": b}) for t, b in rows])


def test_hr_range_bucketing_and_paris_local_iso(store, conn):
    t0 = utc(2026, 6, 10, 10)
    put_hr(store, [(t0 + i * 60, 60 + i) for i in range(10)])
    out = q.hr_range(conn, t0, t0 + 600, 300, now=NOW)
    assert out["count"] == 2 and out["bucket_s"] == 300
    p = out["points"][0]
    assert p["time"] == "2026-06-10T12:00:00+02:00" and p["n"] == 5
    assert (p["bpm_min"], p["bpm_max"], p["bpm_avg"]) == (60, 64, 62.0)


def test_hr_range_raw_points(store, conn):
    put_hr(store, [(1_700_000_000, 61), (1_700_000_001, 62)])
    out = q.hr_range(conn, 1_700_000_000, 1_700_000_100, None, now=utc(2026, 1, 1))
    assert [p["bpm"] for p in out["points"]] == [61, 62] and out["truncated"] is False


def test_rr_range_keeps_equal_beats_and_excludes_ts_suspect(store, conn):
    t = utc(2026, 6, 10, 10)
    put(store, "rrInterval", [({"ts": t, "rrMs": 800, "seq": 0}, {}), ({"ts": t, "rrMs": 800, "seq": 1}, {}),
                              ({"ts": t + 1, "rrMs": 900, "seq": 0}, {"tsSuspect": 1})])
    out = q.rr_range(conn, t, t + 10, now=NOW)
    assert [p["rr_ms"] for p in out["points"]] == [800, 800]


def test_future_dated_rows_excluded(store, conn):
    put_hr(store, [(NOW + 3600, 70), (NOW + 10 * 86400, 99)])
    out = q.hr_range(conn, 0, NOW + 20 * 86400, None, now=NOW)
    assert [p["bpm"] for p in out["points"]] == [70]


def test_empty_db_returns_empty_with_reason_not_error(conn):
    assert q.hr_range(conn, 0, 10, None, now=NOW)["count"] == 0
    assert "no data" in q.hr_range(conn, 0, 10, None, now=NOW)["note"].lower()
    assert q.rr_range(conn, 0, 10, now=NOW)["points"] == []
    assert q.sleep_for(conn, "2026-06-10")["sessions"] == []
    s = q.stress_timeline(conn, 0, 600, now=NOW)
    assert s["windows"] == [] and s["heuristic"] is True
    d = q.day_summary(conn, "2026-06-10", now=NOW)
    assert d["has_data"] is False and "note" in d


def test_day_summary_on_dst_day_uses_23h_bounds(store, conn):
    a, b = day_bounds("2026-03-29")
    put_hr(store, [(a + 1800, 60), (b - 1800, 70), (b + 600, 99), (a - 600, 99)])
    d = q.day_summary(conn, "2026-03-29", now=utc(2026, 4, 1))
    assert d["hours_in_day"] == 23 and d["heart_rate"]["samples"] == 2
    assert (d["heart_rate"]["min"], d["heart_rate"]["max"]) == (60, 70)


def test_sleep_for_prefers_imported_parses_both_shapes_and_wake_day(store, conn):
    start, end = parse_local("2026-06-09 23:30"), parse_local("2026-06-10 07:00")
    put(store, "sleepSession", [({"startTs": start}, {"endTs": end, "userEdited": False, "efficiency": 0.9,
                                                      "stagesJSON": '{"light":200,"deep":80,"rem":90,"awake":20}'})])
    seg = json.dumps([{"start": start + 60, "end": start + 3660, "stage": "deep"}])
    put(store, "sleepSession", [({"startTs": start + 600}, {"endTs": end - 600, "userEdited": False,
                                                            "stagesJSON": seg})], dev="strap-noop")
    out = q.sleep_for(conn, "2026-06-10")
    assert len(out["sessions"]) == 1
    s = out["sessions"][0]
    assert s["source"] == "imported" and s["minutes"]["deep"] == 80.0 and s["efficiency_pct"] == 90.0
    assert s["start"].startswith("2026-06-09T23:30") and s["end"].startswith("2026-06-10T07:00")
    assert q.sleep_for(conn, "2026-06-09")["sessions"] == []  # attributed to the wake day only


def test_sleep_for_falls_back_to_computed_segments(store, conn):
    start, end = parse_local("2026-06-09 23:30"), parse_local("2026-06-10 07:00")
    seg = json.dumps([{"start": start, "end": start + 1800, "stage": "wake"},
                      {"start": start + 1800, "end": start + 5400, "stage": "light"}])
    put(store, "sleepSession", [({"startTs": start}, {"endTs": end, "userEdited": False, "stagesJSON": seg})],
        dev="strap-noop")
    s = q.sleep_for(conn, "2026-06-10")["sessions"][0]
    assert s["source"] == "computed" and s["minutes"] == {"awake": 30.0, "light": 60.0}
    assert s["segments"][0]["stage"] == "awake" and s["segments"][0]["start"].endswith("+02:00")


def seed_stress(store, hist_rmssd=(40, 60), test_rmssd=15, test_hr=80):
    """3 days of calm still history (>=20 windows), then one window to evaluate."""
    def window(start, target, bpm, still=True):
        a, t, i, rr = target / 2, float(start), 0, []
        while t < start + 300:
            v = int(800 + (a if i % 2 == 0 else -a))
            rr.append(({"ts": int(t), "rrMs": v, "seq": 0}, {}))
            t += v / 1000
            i += 1
        put(store, "rrInterval", rr)
        put_hr(store, [(start + s, bpm) for s in range(0, 300, 10)])
        put(store, "gravitySample", [({"ts": start + s}, {"x": 0.0, "y": 0.0, "z": 1.0 if s % 2 else 0.99})
                                     for s in range(300)], version="1.0")
    base = utc(2026, 6, 6, 10)
    for k in range(24):
        window(base + (k // 8) * 86400 + (k % 8) * 300, hist_rmssd[k % 2], 62)
    start = utc(2026, 6, 10, 10)
    window(start, test_rmssd, test_hr)
    return start


def test_stress_timeline_labels_heuristic_with_personal_baseline(store, conn):
    start = seed_stress(store)
    out = q.stress_timeline(conn, start, start + 300, now=NOW)
    assert out["heuristic"] is True and "not medical" in out["disclaimer"].lower()
    assert out["baseline"] is not None and 40 <= out["baseline"]["median_rmssd_ms"] <= 60
    w = out["windows"]
    assert len(w) == 1 and w[0]["label"] == "stressed" and w[0]["start"].endswith("+02:00")


def test_stress_without_history_is_unknown_with_note(store, conn):
    start = utc(2026, 6, 10, 10)
    seed = []
    a, t, i = 10.0, float(start), 0
    while t < start + 300:
        v = int(800 + (a if i % 2 == 0 else -a))
        seed.append(({"ts": int(t), "rrMs": v, "seq": 0}, {}))
        t += v / 1000
        i += 1
    put(store, "rrInterval", seed)
    out = q.stress_timeline(conn, start, start + 300, now=NOW)
    assert out["baseline"] is None and out["windows"][0]["label"] == "unknown"
    assert "baseline" in out["note"].lower()


def test_stream_range_rejects_unknown_stream_and_coach_messages(conn):
    for bad in ("nope", "coachMessage", "device", "ledger", "hrSample; DROP TABLE x"):
        with pytest.raises(ValueError):
            q.stream_range(conn, bad, 0, 10)


def test_stream_range_clamps_limit_and_paginates(store, conn):
    put(store, "stepSample", [({"ts": 1000 + i}, {"counter": i}) for i in range(30)])
    out = q.stream_range(conn, "stepSample", 0, 5000, limit=10**6, now=utc(2026, 1, 1))
    assert out["limit"] == q.MAX_ROWS and out["count"] == 30 and out["total_in_range"] == 30
    page = q.stream_range(conn, "stepSample", 0, 5000, limit=10, offset=25, now=utc(2026, 1, 1))
    assert [r["counter"] for r in page["rows"]] == [25, 26, 27, 28, 29]


def test_stream_range_never_returns_blob_inline(store, conn):
    put(store, "ppgWaveformSample", [({"ts": 1000}, {"samples": bytes(48), "burstIndex": 1})])
    row = q.stream_range(conn, "ppgWaveformSample", 0, 5000, now=utc(2026, 1, 1))["rows"][0]
    assert row["samples"] == {"bytes": 48} and row["burstIndex"] == 1


def test_stream_range_snapshot_stream_ignores_time_range(store, conn):
    put(store, "liftSet", [({"id": "a"}, {"exercise": "squat", "reps": 5})])
    out = q.stream_range(conn, "liftSet", 0, 1, now=NOW)
    assert out["count"] == 1 and "snapshot" in out["note"]


def test_day_summary_collects_daily_sleep_workout_and_stress_counts(store, conn):
    put_hr(store, [(utc(2026, 6, 10, 8) + i * 60, 60 + i % 20) for i in range(120)])
    put(store, "dailyMetric", [({"day": "2026-06-10"}, {"recovery": 61.0, "strain": 9.5})])
    put(store, "dailyMetric", [({"day": "2026-06-10"}, {"recovery": 40.0})], dev="strap-noop")
    put(store, "workout", [({"startTs": utc(2026, 6, 10, 9), "sport": "run"},
                            {"endTs": utc(2026, 6, 10, 9, 40), "source": "strap", "avgHr": 150})])
    d = q.day_summary(conn, "2026-06-10", now=NOW)
    assert d["has_data"] is True and d["hours_in_day"] == 24
    assert d["daily"]["recovery"] == 61.0 and d["daily"]["source"] == "imported"
    assert d["workouts"][0]["sport"] == "run" and d["workouts"][0]["start"].startswith("2026-06-10T11:00")
    assert set(d["stress"]) >= {"heuristic", "counts"}


def test_sample_buckets_is_evenly_spaced_deterministic_and_capped():
    b = list(range(1000, 1000 + 5000))
    out = q._sample(b, 400)
    assert len(out) <= 400 and out[0] == b[0] and out == sorted(out)
    assert out == q._sample(b, 400)
    assert q._sample(b[:24], 400) == b[:24]   # sparse data: every bucket is used
    assert q._sample([], 400) == []


def test_baseline_reads_a_bounded_number_of_windows(store, conn, monkeypatch):
    """A busy database must not make the baseline read every window of the last 14 days."""
    seen = []
    real = q.compute_stress_timeline

    def spy(rr, hr, motion, baseline):
        seen.append(len(rr))
        return real(rr, hr, motion, baseline)

    monkeypatch.setattr(q, "compute_stress_timeline", spy)
    base = utc(2026, 6, 1, 10)
    # 600 five-minute buckets with a handful of beats each (enough to be candidates, cheap to build)
    rows = [({"ts": base + w * 300 + i, "rrMs": 800 + (i % 3), "seq": 0}, {}) for w in range(600) for i in range(3)]
    put(store, "rrInterval", rows)
    q.stress_timeline(conn, utc(2026, 6, 10, 10), utc(2026, 6, 10, 10, 5), now=NOW)
    history_calls = [n for n in seen if n <= 3]
    assert 0 < len(history_calls) <= q.BASELINE_SAMPLES + 1


def test_stream_range_filters_a_ts_selector_window_stream_by_time(store, conn):
    put(store, "appleStepHour", [({"ts": 3600}, {"steps": 10}), ({"ts": 90_000}, {"steps": 20})])
    out = q.stream_range(conn, "appleStepHour", 0, 7200, now=utc(2026, 1, 1))
    assert [r["steps"] for r in out["rows"]] == [10] and out["total_in_range"] == 1


def test_stream_range_truncates_long_text_values(store, conn):
    put(store, "event", [({"ts": 10, "kind": "k"}, {"payloadJSON": "x" * 5000})])
    row = q.stream_range(conn, "event", 0, 100, now=utc(2026, 1, 1))["rows"][0]
    assert len(row["payloadJSON"]) < 2100 and "truncated 3000 chars" in row["payloadJSON"]


def test_stress_timeline_rejects_ranges_longer_than_seven_days(conn):
    with pytest.raises(ValueError, match="7 days"):
        q.stress_timeline(conn, 0, 8 * 86400, now=NOW)
    q.stress_timeline(conn, NOW - 7 * 86400, NOW, now=NOW)  # exactly the limit is fine


def test_rr_range_applies_the_read_policy_across_sources_and_channels(store, conn):
    t = utc(2026, 6, 10, 10)
    beats = [({"ts": t + i, "rrMs": 800 + i, "seq": 0}, {"srcChannel": 7, "ord": i}) for i in range(3)]
    store.upsert_rows(REGISTRY["rrInterval"], "src-A", "strap", beats, "1.0")
    # the same beats re-sent under a second sourceId (app reinstall) and on another transport channel
    store.upsert_rows(REGISTRY["rrInterval"], "src-B", "strap", beats, "1.0")
    chan5 = [({"ts": t + i, "rrMs": 800 + i, "seq": 0}, {"srcChannel": 5, "ord": i}) for i in range(3)]
    store.upsert_rows(REGISTRY["rrInterval"], "src-A", "strap", [(k | {"rrMs": k["rrMs"]}, d) for k, d in chan5], "1.0")
    out = q.rr_range(conn, t, t + 10, now=NOW)
    assert [p["rr_ms"] for p in out["points"]] == [800, 801, 802]
