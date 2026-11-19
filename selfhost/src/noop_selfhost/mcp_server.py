"""Read-only MCP server over the receiver's SQLite file (official `mcp` SDK, v2 `MCPServer`).

Eight tools, no free-form SQL, no write path: every call opens the database `mode=ro` (the optional
phone wake sends a silent notification through Apple and writes nothing).
Times in/out are Europe/Paris; naive ISO inputs are Paris local time."""
from __future__ import annotations

import argparse
import asyncio
import re
import sqlite3
import sys
import time

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings

from . import queries as q
from .apns import ApnsClient, ApnsConfig, ApnsError
from .db import Store
from .tz import day_bounds, parse_local

INSTRUCTIONS = (
    "Personal WHOOP/NOOP data exported from the owner's phone. Read-only. All times are Europe/Paris. "
    "Data arrives with delay (the phone uploads when iOS allows), so an empty or short recent range may "
    "mean 'not synced yet', not 'nothing happened'. Call get_sync_status first to know how fresh the data "
    "is; if it is stale and a phone wake is available, request_phone_sync asks the phone to upload now. "
    "get_stress_timeline is a HEURISTIC, not medical."
)
WAKE_MIN_GAP_S = 30          # iOS budgets background wakes; hammering them gets the app throttled
WAKE_MAX_WAIT_S = 120
WAKE_POLL_S = 2.0
WAKE_QUIET_S = 8             # an upload is done once no batch has arrived for this long


def _ts(value: str, what: str) -> int:
    try:
        return parse_local(value)
    except ValueError:
        # ToolError = deliberate, model-visible error (a plain ValueError is treated as a crash
        # and its text is hidden from the agent by the SDK).
        raise ToolError(f"{what}: expected an ISO-8601 time or date like 2026-06-10T14:30 or "
                        f"2026-06-10, got {value!r}") from None


def create_server(db_path: str, apns: ApnsClient | None = None, clock=time.time,
                  sleep=asyncio.sleep) -> MCPServer:
    server = MCPServer("noop-selfhost", instructions=INSTRUCTIONS)
    wake_state = {"last_sent": None}

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

    @server.tool()
    def get_sync_status() -> dict:
        """How fresh the server's copy is: when the phone last uploaded, the newest heart rate, sleep and
        daily score, and per stream the newest data and last delivery. Call this before interpreting a
        range so an empty or short result can be explained ('not uploaded since 14:05') rather than guessed."""
        return run(q.sync_status, int(clock()), apns is not None)

    @server.tool()
    async def request_phone_sync(wait_seconds: int = 45) -> dict:
        """Wake the owner's iPhone with a silent notification so it uploads what it has now, then wait up
        to wait_seconds (0-120) for the upload to finish and return the fresh sync status. iOS decides
        whether to wake the app (rate-limited, never after a force-quit), so no new data is a possible
        outcome; the phone also only has what the strap has already synced to it."""
        if apns is None:
            raise ToolError("Phone wake is not configured on this server (noop-mcp needs --apns-key, "
                            "--apns-key-id and --apns-team-id).")
        if not 0 <= wait_seconds <= WAKE_MAX_WAIT_S:
            raise ToolError(f"wait_seconds must be between 0 and {WAKE_MAX_WAIT_S}")
        conn = connect()
        try:
            device = q.wake_device(conn)
        finally:
            conn.close()
        if device is None:
            raise ToolError("The phone has not registered for wakes yet: open NOOP on the iPhone once "
                            "(Self-hosted Export enabled, app built with push notifications).")
        now = clock()
        last = wake_state["last_sent"]
        if last is not None and now - last < WAKE_MIN_GAP_S:
            raise ToolError(f"A wake was sent {int(now - last)} s ago; wait {int(WAKE_MIN_GAP_S - (now - last))} s "
                            "and call get_sync_status instead of waking again.")
        sent_at = int(now)
        wake_state["last_sent"] = now
        try:
            env = await apns.wake(device["deviceToken"], device["topic"], device["environment"])
        except ApnsError as e:
            raise ToolError(str(e)) from None
        except Exception as e:  # network trouble reaching Apple: say so, never crash the session
            raise ToolError(f"Could not reach Apple's push service ({type(e).__name__}).") from None

        def newest_arrival():
            c = connect()
            try:
                return q.last_arrival(c)
            finally:
                c.close()

        answered = False
        deadline = clock() + wait_seconds
        while clock() < deadline:
            await sleep(WAKE_POLL_S)
            latest = newest_arrival()
            if latest is not None and latest >= sent_at:
                answered = True
                if clock() - latest >= WAKE_QUIET_S:
                    break
        status = run(q.sync_status, int(clock()), True)
        return {"wake_sent": True, "apns_environment": env, "waited_seconds": int(clock() - now),
                "phone_uploaded": answered,
                "note": ("The phone uploaded after the wake." if answered else
                         "No upload arrived in time. iOS may delay or skip the wake (low power mode, force-quit "
                         "app, no network/VPN); try get_sync_status again in a minute."),
                "status": status}

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
    ap.add_argument("--apns-key", metavar="PATH", help="APNs auth key (.p8) to wake the phone (optional)")
    ap.add_argument("--apns-key-id", metavar="ID", help="the key's 10-character id")
    ap.add_argument("--apns-team-id", metavar="ID", help="your Apple developer team id")
    ap.add_argument("--allow-host", metavar="HOST:PORT", action="append", default=[],
                    help="with --http: also accept this exact Host header (a relay or tailscale serve "
                         "address); repeatable")
    a = ap.parse_args(argv)
    if a.allow_host and not a.http:
        sys.exit("noop-mcp: --allow-host only applies with --http")
    apns_args = (a.apns_key, a.apns_key_id, a.apns_team_id)
    apns = None
    if any(apns_args):
        if not all(apns_args):
            sys.exit("noop-mcp: --apns-key, --apns-key-id and --apns-team-id go together")
        try:
            apns = ApnsClient(ApnsConfig.load(*apns_args))
        except (OSError, ValueError, PermissionError) as e:
            sys.exit(f"noop-mcp: {e}")
    server = create_server(a.db, apns)
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
