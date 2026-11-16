import asyncio
import json
import sqlite3

import pytest

from mcp.server.mcpserver.exceptions import ToolError, UnexpectedToolError

from noop_selfhost.db import Store
from noop_selfhost.mcp_server import create_server
from noop_selfhost.registry import REGISTRY

TOOLS = {"get_hr_range", "get_rr_range", "get_sleep", "get_stress_timeline", "get_day_summary",
         "get_stream_range"}


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


def test_server_registers_exactly_six_tools(server):
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
