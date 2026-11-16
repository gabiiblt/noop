import json
import uuid

import pytest
from fastapi.testclient import TestClient
from helpers import AUTH, SRC, hdr, nd, rec, win

from noop_selfhost.db import Store
from noop_selfhost.receiver import create_app
from noop_selfhost.registry import REGISTRY


@pytest.fixture
def store(tmp_path):
    return Store(str(tmp_path / "w.sqlite"))


@pytest.fixture
def client(store):
    return TestClient(create_app(store, "tok"))


def sleep_rec(s):
    return rec({"startTs": s}, {"endTs": s + 100, "userEdited": False})


def send(client, starts, a, b, part=1, parts=1, rid=None, dev="strap-local-id", src=SRC,
         stream="sleepSession", mk=sleep_rec, selector="startTs", batch_id=None):
    h = hdr(stream, len(starts), delivery="replace_window", endCursor=None, deviceId=dev, sourceId=src,
            window=win(selector, a, b, part, parts, rid))
    if batch_id:
        h["batchId"] = batch_id
    return client.post("/push", content=nd(h, *[mk(s) for s in starts]),
                       headers={**AUTH, "Content-Type": "application/x-ndjson"})


def starts(store, dev="strap-local-id", src=SRC):
    return [r[0] for r in store.conn.execute(
        "SELECT startTs FROM sleepSession WHERE _src=? AND _dev=? ORDER BY startTs", (src, dev))]


def test_single_part_window_deletes_absent_rows_inside_only(client, store):
    assert send(client, [100, 200, 300], 0, 1000).status_code == 200
    assert send(client, [5000], 5000, 6000).status_code == 200
    assert send(client, [200, 400], 0, 1000).status_code == 200
    assert starts(store) == [200, 400, 5000]


def test_empty_window_deletes_all_in_scope_only(client, store):
    send(client, [100, 200], 0, 1000)
    send(client, [100], 0, 1000, dev="other-strap")
    send(client, [5000], 5000, 6000)
    r = send(client, [], 0, 1000)
    assert r.status_code == 200 and r.json()["acceptedRows"] == 0
    assert starts(store) == [5000] and starts(store, dev="other-strap") == [100]


def test_window_scoped_per_source(client, store):
    other = "11111111-1111-4111-8111-111111111111"
    send(client, [100], 0, 1000, src=other)
    send(client, [], 0, 1000)
    assert starts(store, src=other) == [100]


def test_multipart_applies_only_when_complete_and_out_of_order_ok(client, store):
    send(client, [100, 200, 300], 0, 1000)
    rid = str(uuid.uuid4())
    assert send(client, [400, 500], 0, 1000, part=2, parts=2, rid=rid).status_code == 200
    assert starts(store) == [100, 200, 300]  # not applied yet
    assert send(client, [200, 300], 0, 1000, part=1, parts=2, rid=rid).status_code == 200
    assert starts(store) == [200, 300, 400, 500]  # 100 absent from the replacement -> deleted


def test_failed_apply_returns_error_not_ack_and_changes_nothing(client, store):
    send(client, [100], 0, 1000)
    rid = str(uuid.uuid4())
    assert send(client, [200, 300], 0, 1000, part=1, parts=2, rid=rid).status_code == 200
    r = send(client, [300], 0, 1000, part=2, parts=2, rid=rid)  # duplicate key across parts
    assert r.status_code == 400 and r.json()["code"] == "duplicate_key"
    assert starts(store) == [100]
    # the failed part was not staged: a corrected part 2 completes the generation
    assert send(client, [400], 0, 1000, part=2, parts=2, rid=rid).status_code == 200
    assert starts(store) == [200, 300, 400]


def test_new_replacement_supersedes_old_incomplete_and_late_part_409(client, store):
    a = str(uuid.uuid4())
    assert send(client, [100], 0, 1000, part=1, parts=2, rid=a).status_code == 200
    assert send(client, [700], 0, 800).status_code == 200  # other generation, different bounds
    late = send(client, [200], 0, 1000, part=2, parts=2, rid=a)
    assert late.status_code == 409 and late.json()["code"] == "superseded_generation"
    assert starts(store) == [700]


def test_conflicting_part_reuse_409(client, store):
    rid = str(uuid.uuid4())
    assert send(client, [100], 0, 1000, part=1, parts=2, rid=rid).status_code == 200
    same_part_new_batch = send(client, [150], 0, 1000, part=1, parts=2, rid=rid)
    assert same_part_new_batch.status_code == 409
    different_parts = send(client, [200], 0, 1000, part=2, parts=3, rid=rid)
    assert different_parts.status_code == 409
    different_bounds = send(client, [200], 0, 2000, part=2, parts=2, rid=rid)
    assert different_bounds.status_code == 409


def test_replacement_id_of_applied_generation_cannot_be_reused_409(client):
    rid = str(uuid.uuid4())
    assert send(client, [100], 0, 1000, rid=rid).status_code == 200
    assert send(client, [100], 0, 1000, rid=rid).status_code == 409


def test_retry_of_same_part_returns_same_ack(client, store):
    rid, bid = str(uuid.uuid4()), str(uuid.uuid4())
    a = send(client, [100], 0, 1000, rid=rid, batch_id=bid)
    b = send(client, [100], 0, 1000, rid=rid, batch_id=bid)
    assert a.status_code == b.status_code == 200 and a.json() == b.json()
    assert a.json()["endCursor"] is None


def test_arbitrary_old_subwindow_accepted_for_day_streams(client, store):
    mk = lambda d: rec({"day": d}, {"recovery": 55.0})  # noqa: E731
    r = send(client, ["2020-02-03"], "2020-01-01", "2020-04-01", stream="dailyMetric", mk=mk, selector="day")
    assert r.status_code == 200
    assert store.conn.execute("SELECT recovery FROM dailyMetric WHERE day='2020-02-03'").fetchone()[0] == 55.0


def test_workout_composite_key_delete_is_per_key(client, store):
    mk = lambda s: rec({"startTs": s[0], "sport": s[1]}, {"endTs": s[0] + 10, "source": "strap"})  # noqa: E731
    send(client, [(100, "run"), (100, "bike")], 0, 1000, stream="workout", mk=mk)
    send(client, [(100, "run")], 0, 1000, stream="workout", mk=mk)
    rows = store.conn.execute("SELECT sport FROM workout").fetchall()
    assert [r[0] for r in rows] == ["run"]


def test_no_blob_columns_outside_append_streams():
    for s in REGISTRY.values():
        if s.delivery != "append":
            assert not [c for c in s.all_data if c.type == "blob"], s.name


def test_staged_payload_is_json(client, store):
    rid = str(uuid.uuid4())
    send(client, [100], 0, 1000, part=1, parts=2, rid=rid)
    payload = store.conn.execute("SELECT payload FROM window_parts").fetchone()[0]
    assert json.loads(payload)[0][0] == {"startTs": 100}
