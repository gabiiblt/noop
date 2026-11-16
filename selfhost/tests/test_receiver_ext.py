import base64
import uuid

import pytest
from fastapi.testclient import TestClient
from helpers import AUTH, hdr, nd, rec, win

from noop_selfhost.db import Store
from noop_selfhost.receiver import create_app
from noop_selfhost.registry import EXT


@pytest.fixture
def store(tmp_path):
    return Store(str(tmp_path / "e.sqlite"))


@pytest.fixture
def client(store):
    return TestClient(create_app(store, "tok"))


def post(client, body):
    return client.post("/push", content=body, headers={**AUTH, "Content-Type": "application/x-ndjson"})


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def test_ppg_waveform_blob_byte_identical_after_roundtrip(client, store):
    raw = bytes([(i * 37) % 256 for i in range(48)])
    body = nd(hdr("ppgWaveformSample", 1, protocolVersion=EXT),
              rec({"ts": 1}, {"samples": b64(raw), "burstIndex": 3, "baseCode": 7}))
    assert post(client, body).status_code == 200
    row = store.conn.execute("SELECT samples, burstIndex, baseCode FROM ppgWaveformSample").fetchone()
    assert row == (raw, 3, 7)


def test_ecg_record_1572_bytes_roundtrip_and_sequence_in_key(client, store):
    raw = bytes([i % 251 for i in range(1572)])
    body = nd(hdr("ecgWaveformSample", 2, protocolVersion=EXT),
              rec({"ts": 5, "sequence": 1}, {"record": b64(raw)}),
              rec({"ts": 5, "sequence": 2}, {"record": b64(raw[::-1])}))
    assert post(client, body).status_code == 200
    rows = store.conn.execute("SELECT sequence, record FROM ecgWaveformSample ORDER BY sequence").fetchall()
    assert rows == [(1, raw), (2, raw[::-1])]


def snap(client, ids, part=1, parts=1, rid=None, dev="strap-local-id", stream="liftSet", mk=None):
    mk = mk or (lambda i: rec({"id": i}, {"exercise": "squat", "reps": 5}))
    h = hdr(stream, len(ids), protocolVersion=EXT, delivery="snapshot", endCursor=None, deviceId=dev,
            window={"replacementId": rid or str(uuid.uuid4()), "selector": "all", "part": part, "parts": parts})
    return post(client, nd(h, *[mk(i) for i in ids]))


def ids(store, dev="strap-local-id"):
    return [r[0] for r in store.conn.execute("SELECT id FROM liftSet WHERE _dev=? ORDER BY id", (dev,))]


def test_lift_snapshot_replaces_whole_table_for_scope(client, store):
    assert snap(client, ["a", "b", "c"]).status_code == 200
    assert snap(client, ["x"], dev="other").status_code == 200
    assert snap(client, ["b", "d"]).status_code == 200
    assert ids(store) == ["b", "d"] and ids(store, "other") == ["x"]


def test_empty_snapshot_deletes_everything_in_scope(client, store):
    snap(client, ["a", "b"])
    r = snap(client, [])
    assert r.status_code == 200 and r.json()["acceptedRows"] == 0 and ids(store) == []


def test_multipart_snapshot_applies_on_completion(client, store):
    snap(client, ["old"])
    rid = str(uuid.uuid4())
    snap(client, ["a"], part=2, parts=2, rid=rid)
    assert ids(store) == ["old"]
    snap(client, ["b"], part=1, parts=2, rid=rid)
    assert ids(store) == ["a", "b"]


def test_snapshot_rejected_under_v1(client):
    h = hdr("liftSet", 0, delivery="snapshot", endCursor=None,
            window={"replacementId": str(uuid.uuid4()), "selector": "all", "part": 1, "parts": 1})
    assert post(client, nd(h)).status_code == 422


def day_mk(d, v):
    return rec({"day": d}, {"recovery": v})


def window(client, days, a, b, v=50.0, **kw):
    h = hdr("dailyMetric", len(days), protocolVersion=EXT, delivery="replace_window", endCursor=None,
            window=win("day", a, b, **kw))
    return post(client, nd(h, *[day_mk(d, v) for d in days]))


def test_full_history_chunked_windows_baseline_then_rolling_window(client, store):
    chunks = [("2025-01-01", "2025-04-01", ["2025-01-05", "2025-03-30"]),
              ("2025-04-01", "2025-07-01", ["2025-04-01", "2025-06-30"]),
              ("2025-07-01", "2025-10-01", ["2025-07-15"])]
    for a, b, days in chunks:
        assert window(client, days, a, b).status_code == 200
    assert store.conn.execute("SELECT COUNT(*) FROM dailyMetric").fetchone()[0] == 5
    # rolling 14-day window over the newest days replaces only itself
    assert window(client, ["2025-09-25"], "2025-09-20", "2025-10-04", v=80.0).status_code == 200
    days = [r[0] for r in store.conn.execute("SELECT day FROM dailyMetric ORDER BY day")]
    assert days == ["2025-01-05", "2025-03-30", "2025-04-01", "2025-06-30", "2025-07-15", "2025-09-25"]


def test_ext_member_on_v1_stream_is_stored_under_ext(client, store):
    h = hdr("dailyMetric", 1, protocolVersion=EXT, delivery="replace_window", endCursor=None,
            window=win("day", "2025-01-01", "2025-02-01"))
    body = nd(h, rec({"day": "2025-01-02"}, {"recovery": 60.0, "avgSdnn": 71.5, "skinTempC": 33.2,
                                             "sleepHrOnly": True}))
    assert post(client, body).status_code == 200
    row = store.conn.execute("SELECT avgSdnn, skinTempC, sleepHrOnly FROM dailyMetric").fetchone()
    assert row == (71.5, 33.2, 1)


def test_capability_narrowing_never_stores_declined_ext_stream(store):
    c = TestClient(create_app(store, "tok", enabled_streams={"hrSample"}))
    body = nd(hdr("ppgWaveformSample", 1, protocolVersion=EXT), rec({"ts": 1}, {"samples": b64(b"\x00" * 48)}))
    assert post(c, body).status_code == 422
    assert store.conn.execute("SELECT COUNT(*) FROM ppgWaveformSample").fetchone()[0] == 0
