# Self-hosted WHOOP data pipeline + MCP — design

Status: **draft for approval** (no code written yet). Personal, private use under the repo's
PolyForm Noncommercial license. Date: 2026-11-16.

## 1. Intent

The owner wears a WHOOP strap and uses NOOP (iOS, built from source with a paid Apple Developer
account) instead of the WHOOP app. They want the strap data to reach their own Ubuntu server
(over Tailscale only) so their AI agents can read it through a read-only MCP server.

First use case: a nightly "midnight debrief". An agent pulls the day's data, cross-references the
owner's class timetable (handled elsewhere) and says things like "your HRV dropped during this
lecture". Delayed delivery is fine; real time is not needed.

## 2. Goals / non-goals / anti-goals

Goals
- Incremental, idempotent, retrying export from the iPhone to the server, with catch-up after iOS
  suspension.
- A receiver that dedupes and stores everything it is sent, in its own SQLite.
- A read-only MCP server: `get_hr_range`, `get_rr_range`, `get_sleep`, `get_stress_timeline`,
  `get_day_summary`; timezone Europe/Paris.
- Fork diff as small as possible so upstream (`ryanbr/noop`) merges stay trivial.

Non-goals
- Real-time streaming; two-way sync; restoring data from the server into the app.
- Any server component inside the app's responsibility (the app only exports).
- Calendar handling; medical interpretation.

Anti-goals (would be a failure even if it "works")
- Any cloud / third party / public exposure of health data.
- An uploader that can delay or break strap sync, scoring or the UI.
- A silently lossy export (stranded backfill rows, dropped duplicate RR beats).

## 3. Constraints

- `docs/SCOPE.md` + `AGENTS.md` allow exactly one export path: a **default-off Experimental**
  client, one-way, to a user-owned HTTP(S) endpoint, never reading data back, independent of strap
  sync, no receiver in this repository's app code. Wire format: `docs/PUSH_PROTOCOL.md` v1.
- The protocol rejects cleartext hostnames, so the endpoint is HTTPS:
  `https://server.tailfb9ed9.ts.net` (Tailscale MagicDNS + `tailscale serve`, tailnet-only).
- iOS suspends the app; progress must resume across relaunches.
- Linux sandbox cannot compile the Apple targets; Swift is verified on the owner's Mac.
- Repo rules: migrations are never edited (we add none), design tokens for UI, English for
  repo-facing text, one concern per change.

## 4. Approaches considered

A. **Implement `PUSH_PROTOCOL.md` v1 in Swift (chosen).** Spec already exists, Android client is a
   reference, rowid cursors fix the backfill problem, mergeable/upstreamable.
B. Own JSON batches with a "last uploaded ts per table" cursor (the owner's first sketch).
   Rejected: a forward-only `ts` highwater permanently strands older rows inserted by a later
   offload (the repo's own migration v5 comment describes this exact bug), and it would diverge
   from upstream.
C. File-based export (e.g. `noop_sync.txt` / backups synced by Syncthing). Rejected: not
   incremental, no background trigger, loses most streams.

The owner delegated server technology: **Python** (FastAPI/uvicorn receiver, official `mcp`
SDK) for speed to build and reliability; one language, one DB file.

## 5. Architecture

```
iPhone NOOPiOS ──HTTPS (Tailscale)──▶ tailscale serve :443 ──▶ 127.0.0.1:8787 receiver
                                                                   │ writes
                                                                   ▼
                                                         selfhost.sqlite (WAL)
                                                                   ▲ read-only (mode=ro)
                                                   MCP server (stdio; optional 127.0.0.1 HTTP)
```

### 5.1 iOS client (the only change inside the app)

- New folder `StrandiOS/Push/` (new files never conflict on merge). Pure logic (NDJSON encoding,
  key fingerprints, batching, cursor logic) in a platform-neutral file so it can be unit-tested.
- Explicit SQL projections per stream (no `SELECT *`), reading the main DB through its own
  read-only GRDB connection.
- Streams (v1): append `hrSample, rrInterval, event, battery, spo2Sample, skinTempSample,
  respSample, gravitySample`; replace-window `dailyMetric, sleepSession, workout, journal`.
  Cursor = SQLite insertion `rowid` + `keySha256` verification, per the protocol.
- Progress state (cursors, daily hashes, `sourceId`, receiver state id) lives in a **separate small
  state file** next to the DB, not in the main database: no migration, no upstream version clash.
  *(My call.)*
- Settings: endpoint URL, bearer token (Keychain), enable toggle (default off), "Test connection".
  Minimal hook into the existing settings screen.
- Triggers: after a successful offload, scene `.active`, and a new BGTask `<bundle>.push`
  (identifier added to `BGTaskSchedulerPermittedIdentifiers`, registered in `StrandiOSApp.init`).
  Runs as an independent task; any failure is swallowed into a status line, never touching sync.
- Retries: backoff on transport/408/429/5xx with a finite attempt budget; resumes on next trigger.
- Build mode: **Xcode from source** under the owner's paid Developer account (own bundle-id prefix
  and App Group). No 7-day expiry, HealthKit/App Group provisioned. *(Owner asked for the most
  practical option; this is it.)*

### 5.2 Receiver (`selfhost/receiver/`, outside the app code)

- Conforms to `PUSH_PROTOCOL.md` v1: `GET` capabilities (`receiverStateId` persisted), `POST` NDJSON
  batches (gzip or identity), strict acknowledgement, `batchId` idempotency with decoded-bytes
  hash, `409` on conflicting reuse, `413/422/401` per spec, bounded decompression.
- Storage: tables keyed by `(sourceId, deviceId, stream, primary key)`; append = upsert;
  `replace_window` = stage parts, then atomic upsert + delete-in-window; superseded generations → 409.
- Auth: constant-time bearer comparison; token from a `chmod 600` file.
- Binds **127.0.0.1 only**; exposed to the tailnet via
  `tailscale serve --bg --https=443 http://127.0.0.1:8787` (never Funnel). No payload logging.
- `systemd` unit with restart-on-failure; nightly `sqlite3 .backup`.

### 5.3 MCP server (`selfhost/mcp/`)

- Read-only: opens the DB `file:…?mode=ro`; no write tools. Transport stdio by default (agents on
  the same machine); optional Streamable HTTP on 127.0.0.1. *(My call.)*
- All times stored as UTC seconds; every tool takes/returns Europe/Paris local time (DST days are
  23/25 h; "day" = local calendar day).
- Tools: `get_hr_range(start,end,resolution?)`, `get_rr_range(start,end)`, `get_sleep(day|range)`
  (handles both `stagesJSON` shapes — segment array and minutes dict — plus `sleepStateJSON`),
  `get_stress_timeline(start,end)`, `get_day_summary(day)`.
- **`get_stress_timeline` is a heuristic, not medical.** Per ~5-minute window: RMSSD from RR
  (same range/ectopic filtering as the app's `HRVAnalyzer`, minimum beat count) compared to a
  personal baseline (median/MAD over the trailing ~14 days of comparable waking windows), combined
  with HR above personal resting HR and low motion (gravity/steps) to exclude exercise. Output
  carries the inputs, a 0–100 score and a `heuristic: true` + disclaimer field. Thresholds are
  tunable constants with documented defaults.

## 6. Decisions made on the owner's behalf (please check)

1. v1 registry first, exactly as specified. **Phase 2 (optional, separate change):** local
   extension negotiated as protocol `1.1` for `stepSample`, `ppgHrSample`, `sleepStateSample`,
   `metricSeries`. Raw PPG/ECG/IMU waveforms are excluded (huge, not useful for the debrief).
   The owner said "send everything"; this is the closest compliant reading — confirm or widen.
2. Both sleep identities (`deviceId` and `deviceId-noop`) are exported; the MCP layer prefers the
   imported/strap source and falls back to the computed one.
3. Progress state in a separate file, not a migration.
4. Receiver/MCP live in `selfhost/` in the same fork (new directory = no merge conflicts), not in
   the upstream-facing app code.

## 7. Testing and verification

- Receiver: pytest conformance suite built from the protocol's examples (idempotent retry, conflict,
  gzip bomb, replace-window atomicity, auth, capability negotiation). Runs on Linux.
- Stress heuristic + timezone/DST logic: pytest with synthetic RR/HR series (must track varying
  inputs, not one matching night).
- Swift pure logic: XCTest for NDJSON/fingerprint/cursor logic, to be run by the owner on macOS
  (`xcodegen generate`, `xcodebuild … test`). The iOS target compile is **not** verifiable here and
  will be reported as such.
- End-to-end on a real iPhone + strap by the owner; BLE/background behaviour cannot be
  CI- or Linux-tested.

## 8. Left to the builder

Exact file/module names, batching constants within protocol limits, backoff parameters, the exact
settings-screen hook, stress-heuristic default thresholds (documented and test-pinned), MCP output
schemas.
