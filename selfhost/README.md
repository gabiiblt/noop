# selfhost: receiver and read-only MCP server for your NOOP data

A personal, private pipeline. The NOOP iPhone app (this fork) pushes your data one way, over your
Tailscale network, to a receiver on your own server. A read-only MCP server then lets your AI agents
ask questions about it ("how was my stress during yesterday's lecture?").

```
iPhone NOOP ──HTTPS (tailnet only)──▶ receiver ──▶ selfhost.sqlite ◀── noop-mcp (read-only) ◀── agents
```

Nothing goes to any cloud or third party. The receiver listens on loopback only and is published to the
tailnet by `tailscale serve`; every request needs your bearer token.

## What is here

| Path | What |
|---|---|
| `src/noop_selfhost/receiver.py`, `batch.py`, `db.py` | The receiver: `docs/PUSH_PROTOCOL.md` v1 plus the fork extension `1.100`. Idempotent, deduplicated, atomic window replacement. |
| `src/noop_selfhost/mcp_server.py`, `queries.py`, `stress.py`, `sleep.py`, `tz.py` | The read-only MCP server and its logic. Europe/Paris time. |
| `src/noop_selfhost/registry.py` | The single list of exported streams. Mirrored by `Packages/SelfHostPush` (parity checked by `Fixtures/registry.json`). |
| `src/noop_selfhost/simulator.py` | Replays a copy of your real `whoop.sqlite` against the receiver, to test the server before the app. |
| `PROTOCOL_EXT.md` | What `1.100` adds on top of the upstream protocol. |
| `deploy/` | systemd unit, `tailscale serve` steps, MCP config example, backup script. **Start with `deploy/README.md`.** |
| `tests/` | 150+ pytest tests (`python -m pytest`). |

The iPhone side lives in `Packages/SelfHostPush` (engine) and `StrandiOS/Push/` (settings screen, background
task, lifecycle triggers). It is off until you enable it and enter an `https://` address and a token.

## The MCP tools

All times are Europe/Paris. A "day" is a local calendar day (23 or 25 hours on daylight-saving days).
Data arrives with a delay (iOS only lets the app upload now and then), so an empty recent range can mean
"not synced yet".

| Tool | Returns |
|---|---|
| `get_hr_range(start, end, bucket_minutes?)` | Heart rate, raw or bucketed min/avg/max. |
| `get_rr_range(start, end)` | Beat-to-beat intervals. Duplicate copies (several transport channels, or the same beats re-sent under a second source) are collapsed with a conservative approximation of the app's read policy (`rr_policy.py`); equal consecutive beats are kept. |
| `get_sleep(day)` | Sleep sessions for the wake day: start/end, efficiency, stage minutes and segments. |
| `get_stress_timeline(start, end)` | The stress **heuristic** per 5-minute window (see below). |
| `get_day_summary(day)` | Heart-rate stats, daily scores, sleep, workouts, stress-label counts. |
| `get_stream_range(stream, start, end, limit?, offset?)` | Rows of any other exported stream (steps, SpO2, temperature, respiration, sleep states, ...). Fixed whitelist, no SQL, capped; binary waveforms are reported as byte counts only. |

The AI-coach conversations are never exported, and the MCP server never exposes them.

## The stress timeline is a heuristic, not medical

For each 5-minute window it compares your RMSSD (a heart-rate-variability measure computed from the
cleaned beat-to-beat intervals, with the same filtering as the app's `HRVAnalyzer`) with **your own**
baseline (median and spread over up to 400 comparable windows of the previous 14 days), and requires an
elevated heart rate and a still wrist before it says `stressed`:

- `calm`: RMSSD within your usual range.
- `elevated`: RMSSD low, but heart rate not elevated, or you were moving, or motion is unknown.
- `stressed`: RMSSD low **and** heart rate at least 10 bpm over your resting rate **and** still.
- `unknown`: too few beats in the window, or no baseline yet (needs about a week of data).

The thresholds are documented defaults in `stress.py`, **not calibrated** against ground truth. Use it to
decide when to look, never to diagnose anything. Tune the constants against your own days if you rely on it.

## Run the tests

```bash
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest
```

## Measured performance

On a synthetic 15-day database (1.5 M beat intervals, 1.3 M heart-rate and 1.3 M gravity rows, 231 MB):
`get_hr_range` (1 day, 5-minute buckets) 0.03 s, `get_day_summary` 1.5 s, `get_stress_timeline` (1 day) 2.2 s
(ranges over 7 days are refused for the stress timeline).
The receiver creates a time index on each large table at start-up (about 2 s for that size).
