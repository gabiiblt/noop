"""Read-only MCP server over the receiver's SQLite file (official `mcp` SDK, v2 `MCPServer`).

Six tools, no free-form SQL, no write path: every call opens the database `mode=ro`.
Times in/out are Europe/Paris; naive ISO inputs are Paris local time."""
from __future__ import annotations

import argparse
import re
import sqlite3
import sys

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings

from . import queries as q
from .db import Store
from .tz import day_bounds, parse_local

INSTRUCTIONS = (
    "Personal WHOOP/NOOP data exported from the owner's phone. Read-only. All times are Europe/Paris. "
    "Data arrives with delay (the phone uploads when iOS allows), so an empty or short recent range may "
    "mean 'not synced yet', not 'nothing happened'. get_stress_timeline is a HEURISTIC, not medical."
)


def _ts(value: str, what: str) -> int:
    try:
        return parse_local(value)
    except ValueError:
        # ToolError = deliberate, model-visible error (a plain ValueError is treated as a crash
        # and its text is hidden from the agent by the SDK).
        raise ToolError(f"{what}: expected an ISO-8601 time or date like 2026-06-10T14:30 or "
                        f"2026-06-10, got {value!r}") from None


def create_server(db_path: str) -> MCPServer:
    server = MCPServer("noop-selfhost", instructions=INSTRUCTIONS)

    def connect() -> sqlite3.Connection:
        return Store.connect_ro(db_path)

    server.noop_connect = connect  # type: ignore[attr-defined]  (used by tests)

    def run(fn, *args, **kw):
        conn = connect()
        try:
            return fn(conn, *args, **kw)
        except ValueError as e:  # bad stream name / bucket size: tell the agent why
            raise ToolError(str(e)) from None
        finally:
            conn.close()

    def valid_day(value: str) -> str:
        try:
            day_bounds(value)
        except ValueError:
            raise ToolError(f"day: expected YYYY-MM-DD, got {value!r}") from None
        return value

    @server.tool()
    def get_hr_range(start: str, end: str, bucket_minutes: int | None = None) -> dict:
        """Heart rate between start (inclusive) and end (exclusive). Optional bucket_minutes aggregates
        into min/avg/max buckets; without it raw 1 Hz samples are returned (capped at 5000)."""
        return run(q.hr_range, _ts(start, "start"), _ts(end, "end"),
                   None if bucket_minutes is None else bucket_minutes * 60)

    @server.tool()
    def get_rr_range(start: str, end: str) -> dict:
        """Beat-to-beat R-R intervals (ms) between start and end (capped at 5000); equal consecutive
        beats are kept (seq distinguishes them); rows flagged as having a suspect timestamp are excluded."""
        return run(q.rr_range, _ts(start, "start"), _ts(end, "end"))

    @server.tool()
    def get_sleep(day: str) -> dict:
        """Sleep sessions for a local wake day (YYYY-MM-DD): start/end, efficiency, stage minutes and
        segments. A night belongs to the day it ended on. Prefers imported data, falls back to the
        on-device computed session."""
        return run(q.sleep_for, valid_day(day))

    @server.tool()
    def get_stress_timeline(start: str, end: str) -> dict:
        """HEURISTIC stress estimate per 5-minute window: RMSSD against the owner's personal baseline
        (previous 14 days), heart rate above resting, and low motion. Not medical. Labels: calm,
        elevated, stressed, unknown (too few beats or no baseline yet)."""
        return run(q.stress_timeline, _ts(start, "start"), _ts(end, "end"))

    @server.tool()
    def get_day_summary(day: str) -> dict:
        """One local day (YYYY-MM-DD, 23/25 h on DST days): heart-rate stats, daily scores, sleep,
        workouts and a stress-label count (heuristic)."""
        return run(q.day_summary, valid_day(day))

    @server.tool()
    def get_stream_range(stream: str, start: str, end: str, limit: int = 200, offset: int = 0) -> dict:
        """Rows from one exported stream (fixed whitelist; e.g. stepSample, spo2Sample, skinTempSample,
        respSample, sleepStateSample, ppgHrSample, workout, metricSeries). Paginated, capped at 5000.
        Binary waveforms are reported as byte counts only."""
        return run(q.stream_range, stream, _ts(start, "start"), _ts(end, "end"), limit, offset)

    return server


LOOPBACK_HOSTS = ["127.0.0.1:*", "localhost:*", "[::1]:*"]
LOOPBACK_ORIGINS = ["http://127.0.0.1:*", "http://localhost:*", "http://[::1]:*"]
_HOST_PORT = re.compile(r"^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):([0-9]{1,5})$")


def http_security(allow_hosts: list[str]) -> TransportSecuritySettings:
    """DNS-rebinding guard for the HTTP transport: loopback plus exact extra `host:port` values.

    The SDK only admits 127.0.0.1/localhost Host headers when bound to loopback, which refuses (421) a
    request relayed from a Docker bridge address or published by `tailscale serve` under the tailnet name.
    Each extra value must be an exact host:port (no wildcard), and the guard itself stays on."""
    extra = []
    for value in allow_hosts:
        m = _HOST_PORT.match(value)
        if not m or not 1 <= int(m.group(2)) <= 65535:
            raise ValueError(f"--allow-host expects an exact host:port such as 172.21.0.1:8789, got {value!r}")
        extra.append(value)
    return TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=LOOPBACK_HOSTS + extra,
        allowed_origins=LOOPBACK_ORIGINS,
    )


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="noop-mcp")
    ap.add_argument("--db", required=True)
    ap.add_argument("--http", metavar="HOST:PORT", help="serve Streamable HTTP on loopback instead of stdio")
    ap.add_argument("--allow-host", metavar="HOST:PORT", action="append", default=[],
                    help="with --http: also accept this exact Host header (a relay or tailscale serve "
                         "address); repeatable")
    a = ap.parse_args(argv)
    if a.allow_host and not a.http:
        sys.exit("noop-mcp: --allow-host only applies with --http")
    server = create_server(a.db)
    if a.http:
        from .receiver import parse_listen
        try:
            host, port = parse_listen(a.http)
            security = http_security(a.allow_host)
        except ValueError as e:
            sys.exit(f"noop-mcp: {e}")
        server.run("streamable-http", host=host, port=port, transport_security=security)
    else:
        server.run("stdio")


if __name__ == "__main__":
    main()
