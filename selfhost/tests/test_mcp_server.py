import asyncio
import json
import sqlite3

import pytest

from mcp.server.mcpserver.exceptions import ToolError, UnexpectedToolError

from noop_selfhost.db import Store
from noop_selfhost.mcp_server import create_server
from noop_selfhost.registry import REGISTRY

TOOLS = {"get_hr_range", "get_rr_range", "get_sleep", "get_stress_timeline", "get_day_summary",
         "get_sync_status", "request_phone_sync", "get_lift_sessions", "get_exercise_progress",
         "get_stream_range", "get_progression_rules", "get_gyms", "get_programs"}


@pytest.fixture
def server(tmp_path):
    p = str(tmp_path / "m.sqlite")
    s = Store(p)
    s.upsert_rows(REGISTRY["hrSample"], "src", "strap",
                  [({"ts": 1_700_000_000 + i}, {"bpm": 60 + i}) for i in range(5)], "1.0")
    return create_server(p)


def call(server, name, args):
    res = asyncio.run(server.call_tool(name, args))
    return res


def test_server_registers_exactly_thirteen_tools(server):
    assert {t.name for t in asyncio.run(server.list_tools())} == TOOLS


def test_hr_tool_returns_json_with_paris_times(server):
    res = call(server, "get_hr_range", {"start": "2023-11-14T23:13:00", "end": "2023-11-14T23:14:00"})
    assert not res.is_error
    body = json.loads(res.content[0].text)
    assert body["count"] == 5 and body["points"][0]["time"].endswith("+01:00")


def expect_tool_error(server, name, args, match):
    """A deliberate, model-visible ToolError (not a hidden UnexpectedToolError crash)."""
    with pytest.raises(ToolError, match=match) as e:
        call(server, name, args)
    assert not isinstance(e.value, UnexpectedToolError)


def test_unknown_stream_is_a_tool_error_not_a_crash(server):
    expect_tool_error(server, "get_stream_range",
                      {"stream": "coachMessage", "start": "2023-01-01", "end": "2023-01-02"}, "unknown stream")


def test_bad_time_input_is_a_tool_error(server):
    expect_tool_error(server, "get_hr_range", {"start": "yesterday-ish", "end": "now"}, "ISO-8601")


def test_bad_day_input_is_a_tool_error(server):
    expect_tool_error(server, "get_sleep", {"day": "2026-13-45"}, "YYYY-MM-DD")


def test_get_sleep_and_day_summary_work_on_empty_day(server):
    s = json.loads(call(server, "get_sleep", {"day": "2023-11-14"}).content[0].text)
    assert s["sessions"] == [] and "note" in s
    d = json.loads(call(server, "get_day_summary", {"day": "2023-11-14"}).content[0].text)
    assert d["day"] == "2023-11-14" and d["heart_rate"]["samples"] == 5


def test_server_db_is_read_only(server):
    conn = server.noop_connect()
    with pytest.raises(sqlite3.OperationalError):
        conn.execute("DELETE FROM hrSample")
    with pytest.raises(sqlite3.OperationalError):
        conn.execute("INSERT INTO meta VALUES ('x','y')")


def test_no_tool_accepts_free_form_sql(server):
    for t in asyncio.run(server.list_tools()):
        props = " ".join(t.input_schema.get("properties", {}))
        assert "sql" not in props.lower() and "query" not in props.lower()


# --- Host-header allow-list for the HTTP transport -------------------------------------------------
# The SDK's DNS-rebinding guard only admits 127.0.0.1/localhost Host headers when bound to loopback, so a
# relay (a Docker bridge address) or `tailscale serve` (the tailnet name) got 421. `--allow-host` adds exact
# host:port values while keeping the guard on.

from starlette.testclient import TestClient

from noop_selfhost.mcp_server import http_security, main

INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "t", "version": "1"}}}
HDRS = {"content-type": "application/json", "accept": "application/json, text/event-stream"}


def post_init(server, host_header, extra=()):
    app = server.streamable_http_app(transport_security=http_security(list(extra)))
    with TestClient(app, base_url="http://127.0.0.1:8788") as c:
        return c.post("/mcp", json=INIT, headers={**HDRS, "host": host_header})


def test_loopback_host_is_accepted_by_default(server):
    assert post_init(server, "127.0.0.1:8788").status_code == 200


def test_foreign_host_is_still_refused_by_default(server):
    assert post_init(server, "172.21.0.1:8789").status_code == 421


def test_allowed_host_is_accepted(server):
    assert post_init(server, "172.21.0.1:8789", ["172.21.0.1:8789"]).status_code == 200


def test_allow_host_is_exact_not_a_prefix(server):
    assert post_init(server, "172.21.0.1:9999", ["172.21.0.1:8789"]).status_code == 421


def test_guard_stays_on_when_hosts_are_added():
    s = http_security(["server.example.ts.net:8443"])
    assert s.enable_dns_rebinding_protection
    assert "127.0.0.1:*" in s.allowed_hosts and "server.example.ts.net:8443" in s.allowed_hosts


@pytest.mark.parametrize("bad", ["172.21.0.1", "*:8789", "host:*", ":8789", "a b:1", "h:0", "h:70000"])
def test_allow_host_rejects_malformed_values(bad):
    with pytest.raises(ValueError):
        http_security([bad])


def test_allow_host_requires_http(tmp_path):
    with pytest.raises(SystemExit):
        main(["--db", str(tmp_path / "x.sqlite"), "--allow-host", "172.21.0.1:8789"])
