import gzip
import os
import stat

import pytest
from fastapi.testclient import TestClient
from helpers import AUTH, H64, SRC, hdr, hr_batch, nd, rec

from noop_selfhost.db import Store
from noop_selfhost.receiver import create_app, load_token, parse_listen
from noop_selfhost.registry import EXT, V1


@pytest.fixture
def store(tmp_path):
    return Store(str(tmp_path / "r.sqlite"))


@pytest.fixture
def client(store):
    return TestClient(create_app(store, "tok"))


def post(client, body, headers=None, **kw):
    h = {**AUTH, "Content-Type": "application/x-ndjson"}
    h.update(headers or {})
    return client.post("/push", content=body, headers=h, **kw)


def test_requires_bearer_401(client):
    assert client.get("/push").status_code == 401
    assert client.get("/push", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.post("/push", content=hr_batch()).status_code == 401
    r = client.get("/push", headers={"Authorization": "Bearer nope"})
    assert r.json()["type"] == "error" and r.json()["code"] == "unauthorized"


def test_capabilities_selects_first_supported_version(client):
    r = client.get("/push", headers={**AUTH, "NOOP-Push-Accept-Version": "1.100,1.0"})
    assert r.status_code == 200 and r.json()["protocolVersion"] == EXT
    r = client.get("/push", headers={**AUTH, "NOOP-Push-Accept-Version": "1.0"})
    assert r.json()["protocolVersion"] == V1
    r = client.get("/push", headers={**AUTH, "NOOP-Push-Accept-Version": "2.0, 1.0"})
    assert r.json()["protocolVersion"] == V1


def test_capabilities_no_common_version_406(client):
    assert client.get("/push", headers={**AUTH, "NOOP-Push-Accept-Version": "2.0"}).status_code == 406
    assert client.get("/push", headers=AUTH).status_code == 406


def test_capabilities_document_shape(client, store):
    j = client.get("/push", headers={**AUTH, "NOOP-Push-Accept-Version": "1.0"}).json()
    assert j["type"] == "capabilities" and j["receiverStateId"] == store.receiver_state_id()
    assert len(j["streams"]) == 12 and len(set(j["streams"])) == 12


def test_capabilities_streams_subset_follows_config(store):
    c = TestClient(create_app(store, "tok", enabled_streams={"hrSample", "stepSample"}))
    v1 = c.get("/push", headers={**AUTH, "NOOP-Push-Accept-Version": "1.0"}).json()["streams"]
    ext = c.get("/push", headers={**AUTH, "NOOP-Push-Accept-Version": "1.100"}).json()["streams"]
    assert v1 == ["hrSample"] and sorted(ext) == ["hrSample", "stepSample"]


def test_append_ack_matches_request_exactly(client, store):
    body = hr_batch()
    r = post(client, body)
    assert r.status_code == 200
    h = hdr()  # shape reference only
    ack = r.json()
    assert ack["status"] == "accepted" and ack["acceptedRows"] == 2
    assert ack["stream"] == "hrSample" and ack["deviceId"] == "strap-local-id"
    assert ack["endCursor"] == {"rowId": 10, "keySha256": H64}
    assert ack["protocolVersion"] == V1 and "batchId" in ack
    assert store.conn.execute("SELECT COUNT(*) FROM hrSample").fetchone()[0] == 2
    assert h["stream"] == "hrSample"


def test_retry_same_batch_returns_same_ack_no_duplicates(client, store):
    body = hr_batch(batch_id="e835f32f-60e7-4c93-90a0-51eb6830119a")
    a1, a2 = post(client, body), post(client, body)
    assert a1.status_code == a2.status_code == 200 and a1.json() == a2.json()
    assert store.conn.execute("SELECT COUNT(*) FROM hrSample").fetchone()[0] == 2


def test_gzip_and_identity_are_the_same_batch(client):
    body = hr_batch(batch_id="e835f32f-60e7-4c93-90a0-51eb6830119a")
    a1 = post(client, gzip.compress(body), {"Content-Encoding": "gzip"})
    a2 = post(client, body)
    assert a1.status_code == a2.status_code == 200 and a1.json() == a2.json()


def test_same_batch_id_different_bytes_409(client, store):
    bid = "e835f32f-60e7-4c93-90a0-51eb6830119a"
    assert post(client, hr_batch(batch_id=bid, bpm0=60)).status_code == 200
    r = post(client, hr_batch(batch_id=bid, bpm0=99))
    assert r.status_code == 409 and r.json()["code"] == "batch_id_conflict"
    assert store.conn.execute("SELECT MAX(bpm) FROM hrSample").fetchone()[0] == 61


def test_rr_equal_beats_both_stored(client, store):
    body = nd(hdr("rrInterval", 2),
              rec({"ts": 5, "rrMs": 800, "seq": 0}, {}), rec({"ts": 5, "rrMs": 800, "seq": 1}, {}))
    assert post(client, body).status_code == 200
    assert store.conn.execute("SELECT COUNT(*) FROM rrInterval").fetchone()[0] == 2


def test_two_sources_same_device_do_not_overwrite(client, store):
    other = "11111111-1111-4111-8111-111111111111"
    post(client, hr_batch(bpm0=60))
    post(client, hr_batch(bpm0=90, source=other))
    assert store.conn.execute("SELECT COUNT(*) FROM hrSample").fetchone()[0] == 4


def test_ext_stream_rejected_under_version_1_0_422(client):
    body = nd(hdr("stepSample", 1), rec({"ts": 1}, {"counter": 5}))
    r = post(client, body)
    assert r.status_code == 422 and r.json()["code"] == "unsupported_stream"


def test_ext_stream_accepted_under_ext(client, store):
    body = nd(hdr("stepSample", 1, protocolVersion=EXT), rec({"ts": 1}, {"counter": 5}))
    assert post(client, body).status_code == 200
    assert store.conn.execute("SELECT counter FROM stepSample").fetchone()[0] == 5


def test_declined_stream_rejected_422(store):
    c = TestClient(create_app(store, "tok", enabled_streams={"battery"}))
    assert post(c, hr_batch()).status_code == 422
    assert store.conn.execute("SELECT COUNT(*) FROM hrSample").fetchone()[0] == 0


def test_oversized_content_length_413(client):
    assert post(client, b"x" * (4_194_304 + 65_536 + 1)).status_code == 413


def test_error_body_is_bounded_machine_readable(client):
    r = post(client, b"not json\n")
    assert r.status_code == 400
    assert set(r.json()) == {"type", "protocolVersion", "code"} and r.json()["type"] == "error"


def test_rejected_batch_stores_nothing_and_no_ledger(client, store):
    bad = nd(hdr(n=2), rec({"ts": 1}, {"bpm": 60}), rec({"ts": 2}, {"bpm": "x"}))
    assert post(client, bad).status_code == 422
    assert store.conn.execute("SELECT COUNT(*) FROM hrSample").fetchone()[0] == 0
    assert store.conn.execute("SELECT COUNT(*) FROM ledger").fetchone()[0] == 0


def test_listen_must_be_loopback():
    assert parse_listen("127.0.0.1:8787") == ("127.0.0.1", 8787)
    assert parse_listen("[::1]:8787") == ("::1", 8787)
    for bad in ("0.0.0.0:8787", "192.168.1.5:8787", "server:8787", "8787"):
        with pytest.raises(ValueError):
            parse_listen(bad)


def test_token_file_must_be_private(tmp_path):
    p = tmp_path / "tok"
    p.write_text("secret\n")
    os.chmod(p, 0o644)
    with pytest.raises(PermissionError):
        load_token(str(p))
    os.chmod(p, stat.S_IRUSR | stat.S_IWUSR)
    assert load_token(str(p)) == "secret"
    p.write_text("\n")
    with pytest.raises(ValueError):
        load_token(str(p))


def test_source_constant_used():
    assert SRC
