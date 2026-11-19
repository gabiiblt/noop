"""Sync status (freshness), the phone's wake-token registration and the APNs silent wake."""
import asyncio
import json
import os

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient
from helpers import AUTH, hdr, hr_batch, nd, rec, win

from mcp.server.mcpserver.exceptions import ToolError

from noop_selfhost import queries as q
from noop_selfhost.apns import ApnsClient, ApnsConfig, ApnsError, HOSTS, PAYLOAD
from noop_selfhost.db import Store
from noop_selfhost.mcp_server import create_server
from noop_selfhost.receiver import create_app
from noop_selfhost.registry import REGISTRY

TOKEN_HEX = "a1" * 32
NOW = 1_800_000_000


@pytest.fixture
def store(tmp_path):
    return Store(str(tmp_path / "s.sqlite"))


@pytest.fixture
def client(store):
    return TestClient(create_app(store, "tok"))


def post_batch(client, body):
    return client.post("/push", content=body, headers={**AUTH, "Content-Type": "application/x-ndjson"})


def ro(store):
    return Store.connect_ro(store.path)


# --- arrivals --------------------------------------------------------------------------------------------

def test_append_batch_records_an_arrival_once(client, store):
    body = hr_batch(n=3)
    assert post_batch(client, body).status_code == 200
    assert post_batch(client, body).status_code == 200  # replay: same ack, not a second arrival
    r = store.conn.execute("SELECT stream, batches, rows FROM arrivals").fetchall()
    assert r == [("hrSample", 1, 3)]


def test_window_part_records_an_arrival(client, store):
    h = hdr(stream="dailyMetric", n=1, delivery="replace_window", endCursor=None,
            window=win("day", "2026-11-17", "2026-11-18"))
    body = nd(h, rec({"day": "2026-11-17"}, {"recovery": 55.0}))
    assert post_batch(client, body).status_code == 200
    assert store.conn.execute("SELECT stream, rows FROM arrivals").fetchall() == [("dailyMetric", 1)]


# --- wake-token registration -----------------------------------------------------------------------------

def reg(client, **over):
    doc = {"deviceToken": TOKEN_HEX, "environment": "development", "topic": "com.gabiwhoop.noop", **over}
    return client.post("/push/wake-token", json=doc, headers=AUTH)


def test_wake_token_requires_bearer(client):
    assert client.post("/push/wake-token", json={}).status_code == 401


def test_wake_token_is_stored_and_replaced(client, store):
    assert reg(client).json() == {"type": "wakeToken", "status": "stored"}
    assert reg(client, deviceToken="b2" * 32, environment="production").status_code == 200
    d = q.wake_device(ro(store))
    assert d["deviceToken"] == "b2" * 32 and d["environment"] == "production" and d["topic"] == "com.gabiwhoop.noop"


@pytest.mark.parametrize("over,code", [
    ({"deviceToken": "xyz"}, "invalid_device_token"),
    ({"deviceToken": "A1" * 32}, "invalid_device_token"),
    ({"deviceToken": "a1" * 8}, "invalid_device_token"),
    ({"environment": "staging"}, "invalid_environment"),
    ({"topic": "com.x/../y"}, "invalid_topic"),
    ({"topic": ""}, "invalid_topic"),
])
def test_wake_token_rejects_malformed_values(client, store, over, code):
    r = reg(client, **over)
    assert r.status_code == 422 and r.json()["code"] == code
    assert q.wake_device(ro(store)) is None


def test_wake_token_rejects_non_json_and_oversized(client):
    assert client.post("/push/wake-token", content=b"nope", headers=AUTH).status_code == 400
    assert client.post("/push/wake-token", content=b"[1]", headers=AUTH).status_code == 400
    assert client.post("/push/wake-token", content=b"x" * 5000, headers=AUTH).status_code == 413


# --- sync status -----------------------------------------------------------------------------------------

def test_status_on_empty_database(store):
    s = q.sync_status(ro(store), now=NOW)
    assert s["verdict"] == "empty" and s["last_upload"] is None and s["streams"] == []
    assert s["phone_wake"] == {"available": False, "server_configured": False, "phone_registered": False,
                               "registered": None}
    assert "calibrate" in s["scores_note"]


def test_status_fresh_and_stale(store):
    store.upsert_rows(REGISTRY["hrSample"], "s", "strap", [({"ts": NOW - 300}, {"bpm": 60})], "1.0")
    store._note_arrival(store.conn, "hrSample", "strap", 1, now=NOW - 240)
    fresh = q.sync_status(ro(store), now=NOW)
    assert fresh["verdict"] == "fresh"
    assert fresh["latest_heart_rate"]["minutes_ago"] == 5 and fresh["last_upload"]["minutes_ago"] == 4
    hr = next(x for x in fresh["streams"] if x["stream"] == "hrSample")
    assert hr["rows_received"] == 1 and hr["minutes_since_received"] == 4
    stale = q.sync_status(ro(store), now=NOW + 3600, wake_configured=True)
    assert stale["verdict"] == "stale" and "65 minutes old" in stale["advice"]
    assert "request_phone_sync" not in stale["advice"]  # no phone registered yet: do not offer it
    store.set_wake_device(TOKEN_HEX, "development", "com.x.noop", now=NOW)
    woke = q.sync_status(ro(store), now=NOW + 3600, wake_configured=True)
    assert woke["phone_wake"]["available"] and "request_phone_sync" in woke["advice"]
    assert TOKEN_HEX not in json.dumps(woke)  # the device token is never shown to an agent


def test_status_reports_newest_scored_day(store):
    store.upsert_rows(REGISTRY["dailyMetric"], "s", "strap-noop",
                      [({"day": "2026-11-17"}, {"recovery": None}), ({"day": "2026-11-18"}, {"strain": 9.5})], "1.0")
    s = q.sync_status(ro(store), now=NOW)
    assert s["latest_daily_scores"] == {"day": "2026-11-18", "recovery": None, "strain": 9.5}
    assert "scores_note" not in s


def test_status_works_on_a_database_from_before_arrivals(tmp_path):
    import sqlite3
    p = str(tmp_path / "old.sqlite")
    Store(p).conn.execute("DROP TABLE arrivals")
    c = Store.connect_ro(p)
    assert q.last_arrival(c) is None and q.sync_status(c, now=NOW)["last_upload"] is None
    c.close()
    c2 = sqlite3.connect(p)
    c2.execute("DROP TABLE wake_device")
    c2.close()
    assert q.wake_device(Store.connect_ro(p)) is None


# --- APNs ------------------------------------------------------------------------------------------------

@pytest.fixture
def keypair():
    k = ec.generate_private_key(ec.SECP256R1())
    pem = k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                          serialization.NoEncryption()).decode()
    return pem, k.public_key()


def cfg(pem):
    return ApnsConfig(pem, "ABC123DEFG", "TEAM123456")


def test_jwt_is_es256_with_kid_and_is_cached(keypair):
    pem, pub = keypair
    c = ApnsClient(cfg(pem))
    t1 = c.bearer(now=1000)
    assert c.bearer(now=1000 + 60) == t1  # reused well inside its lifetime
    assert jwt.get_unverified_header(t1) == {"alg": "ES256", "kid": "ABC123DEFG", "typ": "JWT"}
    assert jwt.decode(t1, pub, algorithms=["ES256"]) == {"iss": "TEAM123456", "iat": 1000}
    assert c.bearer(now=1000 + 3001) != t1  # refreshed after 50 min


def recorder(responses):
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        status, body = responses.pop(0)
        return httpx.Response(status, json=body)
    return seen, httpx.MockTransport(handler)


def test_wake_sends_a_silent_background_push(keypair):
    seen, transport = recorder([(200, {})])
    env = asyncio.run(ApnsClient(cfg(keypair[0]), transport).wake(TOKEN_HEX, "com.x.noop", "development"))
    assert env == "development"
    r = seen[0]
    assert str(r.url) == f"{HOSTS['development']}/3/device/{TOKEN_HEX}"
    assert r.headers["apns-push-type"] == "background" and r.headers["apns-priority"] == "5"
    assert r.headers["apns-topic"] == "com.x.noop" and r.headers["authorization"].startswith("bearer ")
    assert json.loads(r.content) == PAYLOAD == {"aps": {"content-available": 1}, "noop": "sync"}


def test_bad_device_token_retries_the_other_environment_once(keypair):
    seen, transport = recorder([(400, {"reason": "BadDeviceToken"}), (200, {})])
    env = asyncio.run(ApnsClient(cfg(keypair[0]), transport).wake(TOKEN_HEX, "com.x.noop", "development"))
    assert env == "production" and [str(r.url).split("/3/")[0] for r in seen] == [HOSTS["development"],
                                                                                    HOSTS["production"]]


def test_other_refusals_raise_without_retry(keypair):
    seen, transport = recorder([(403, {"reason": "InvalidProviderToken"})])
    with pytest.raises(ApnsError) as e:
        asyncio.run(ApnsClient(cfg(keypair[0]), transport).wake(TOKEN_HEX, "com.x.noop", "production"))
    assert e.value.reason == "InvalidProviderToken" and len(seen) == 1


def test_config_load_checks_permissions_and_ids(tmp_path, keypair):
    p = tmp_path / "AuthKey.p8"
    p.write_text(keypair[0])
    os.chmod(p, 0o644)
    with pytest.raises(PermissionError):
        ApnsConfig.load(str(p), "ABC123DEFG", "TEAM123456")
    os.chmod(p, 0o640)
    assert ApnsConfig.load(str(p), "ABC123DEFG", "TEAM123456").key_id == "ABC123DEFG"
    with pytest.raises(ValueError):
        ApnsConfig.load(str(p), "abc", "TEAM123456")
    p.write_text("not a key")
    with pytest.raises(ValueError):
        ApnsConfig.load(str(p), "ABC123DEFG", "TEAM123456")


# --- MCP tools -------------------------------------------------------------------------------------------

class FakeApns:
    def __init__(self, fail=None):
        self.calls, self.fail = [], fail

    async def wake(self, token, topic, env):
        self.calls.append((token, topic, env))
        if self.fail:
            raise self.fail
        return env


class Clock:
    def __init__(self, t):
        self.t = t

    def __call__(self):
        return self.t


def tool(server, name, args=None):
    res = asyncio.run(server.call_tool(name, args or {}))
    return json.loads(res.content[0].text)


def test_get_sync_status_tool(store):
    store.upsert_rows(REGISTRY["hrSample"], "s", "strap", [({"ts": NOW - 60}, {"bpm": 60})], "1.0")
    s = tool(create_server(store.path, clock=Clock(NOW)), "get_sync_status")
    assert s["verdict"] == "fresh" and s["phone_wake"]["server_configured"] is False


def test_request_phone_sync_without_apns_is_a_tool_error(store):
    with pytest.raises(ToolError, match="not configured"):
        tool(create_server(store.path), "request_phone_sync")


def test_request_phone_sync_needs_a_registered_phone(store):
    with pytest.raises(ToolError, match="not registered"):
        tool(create_server(store.path, FakeApns()), "request_phone_sync")


def test_request_phone_sync_waits_for_the_upload(store):
    store.set_wake_device(TOKEN_HEX, "development", "com.x.noop", now=NOW - 100)
    clock, apns = Clock(NOW), FakeApns()

    async def sleep(s):
        clock.t += s
        if clock.t == NOW + 4:  # the phone uploads 4 s after the wake
            store.upsert_rows(REGISTRY["hrSample"], "s", "strap", [({"ts": NOW}, {"bpm": 61})], "1.0")
            store._note_arrival(store.conn, "hrSample", "strap", 1, now=int(clock.t))

    out = tool(create_server(store.path, apns, clock=clock, sleep=sleep), "request_phone_sync", {"wait_seconds": 60})
    assert apns.calls == [(TOKEN_HEX, "com.x.noop", "development")]
    assert out["phone_uploaded"] is True and out["status"]["verdict"] == "fresh"
    assert 4 + 8 <= out["waited_seconds"] < 60  # stopped once uploads went quiet, well before the timeout


def test_request_phone_sync_reports_no_answer_and_rate_limits(store):
    store.set_wake_device(TOKEN_HEX, "development", "com.x.noop", now=NOW)
    clock = Clock(NOW)

    async def sleep(s):
        clock.t += s

    server = create_server(store.path, FakeApns(), clock=clock, sleep=sleep)
    out = tool(server, "request_phone_sync", {"wait_seconds": 10})
    assert out["phone_uploaded"] is False and out["waited_seconds"] == 10
    with pytest.raises(ToolError, match="ago"):
        tool(server, "request_phone_sync", {"wait_seconds": 0})
    clock.t += 30
    assert tool(server, "request_phone_sync", {"wait_seconds": 0})["wake_sent"] is True


def test_request_phone_sync_surfaces_apple_refusals(store):
    store.set_wake_device(TOKEN_HEX, "development", "com.x.noop", now=NOW)
    server = create_server(store.path, FakeApns(fail=ApnsError(403, "InvalidProviderToken")), clock=Clock(NOW))
    with pytest.raises(ToolError, match="InvalidProviderToken"):
        tool(server, "request_phone_sync")
    with pytest.raises(ToolError, match="between 0 and 120"):
        tool(create_server(store.path, FakeApns(), clock=Clock(NOW + 999)), "request_phone_sync", {"wait_seconds": 500})
