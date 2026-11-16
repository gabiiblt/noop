# Self-hosted WHOOP pipeline + MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export all of the owner's NOOP data one-way from the iPhone to a Tailscale-only receiver on their Ubuntu server, and expose it read-only to AI agents through an MCP server.

**Architecture:** A Python project `selfhost/` (receiver + MCP server sharing one stream registry and one SQLite file) and a Swift package `Packages/SelfHostPush` plus a thin iOS glue folder `StrandiOS/Push/`. The wire format is `docs/PUSH_PROTOCOL.md` v1 (phase A: 12 streams) plus a fork-only extension `1.100` (phase B: everything else, full-history baseline).

**Tech Stack:** Python 3.12, FastAPI + uvicorn, official `mcp` SDK (FastMCP), `sqlite3` (WAL), pytest; Swift 5.9 / iOS 17, GRDB `exact: "6.29.3"`, URLSession, CryptoKit, BGTaskScheduler.

**Spec:** `docs/superpowers/specs/2026-11-16-self-hosted-pipeline-design.md` (approved). Wire contract: `docs/PUSH_PROTOCOL.md`.

## Global Constraints

- Endpoint `https://server.tailfb9ed9.ts.net` via `tailscale serve --bg --https=443 http://127.0.0.1:8787`; never Funnel; receiver binds `127.0.0.1` only.
- Protocol versions: `1.0` (spec) and `1.100` (fork extension, reserved minor). Never emit an ext stream while claiming `1.0`.
- Per request: one device, one stream, at most 5,000 record lines and 4 MiB (4,194,304 bytes) decoded NDJSON; encoded wire cap 4 MiB + 64 KiB; decompress with a hard cap.
- Bearer token required on every route; constant-time compare; token file `chmod 600`; no payload logging.
- MCP server is read-only (`file:…?mode=ro`), stdio by default, no raw SQL, hard row cap, no blob inline, `coachMessage` never exported or exposed.
- All stored times are UTC Unix seconds; every MCP input/output is `Europe/Paris`; a "day" is a local calendar day (23/25 h on DST days).
- Stress output is always labelled `heuristic: true` and not medical.
- Client is default-off, endpoint-gated, one-way, independent of strap sync (`docs/SCOPE.md`). No new GRDB migration; progress state lives in a separate file.
- Swift: `swift-tools-version: 5.9`, iOS 17, design tokens only for UI, English for all repo-facing text, no edits to upstream's `docs/PUSH_PROTOCOL.md`.
- The Linux sandbox cannot compile Apple targets: Swift tasks end with commands the **owner runs on macOS**; report them as unverified here.

## Review Focus

1. A stored cursor whose row is missing or whose fingerprint differs (restore, `VACUUM`, DB replaced) must reset that stream and replay, never skip data. (Task 12)
2. Equal consecutive RR beats in the same second must both survive end to end (`seq` is in the key). (Tasks 3, 4)
3. A kill between "POST sent" and "ack received" must retry the byte-identical batch with the same `batchId`. (Task 14)
4. DST days (2026-03-29 = 23 h, 2026-10-25 = 25 h) and a night crossing Paris midnight must give correct day boundaries and sleep attribution. (Task 7)
5. Windows with too few beats, an empty database, or future-dated rows (`tsSuspect`, clock skew) must return empty/`null` results with a reason, never a fabricated score or an exception. (Tasks 8, 9)

---

## Phase A: Python receiver + MCP

### Task 1: Project scaffold, stream registry, extension spec

**Files:**
- Create: `selfhost/pyproject.toml`, `selfhost/src/noop_selfhost/__init__.py`, `selfhost/src/noop_selfhost/registry.py`, `selfhost/PROTOCOL_EXT.md`, `selfhost/tests/test_registry.py`

**Interfaces:**
- Produces: `Col(name:str, type:Literal["int","real","text","bool","blob_b64"], nullable:bool)`; `Stream(name:str, key:tuple[Col,...], data:tuple[Col,...], delivery:Literal["append","replace_window","snapshot"], selector:Literal["ts","day","startTs"]|None, phase:Literal["v1","ext"])`; `REGISTRY: dict[str, Stream]`; `V1="1.0"`, `EXT="1.100"`; `streams_for(version:str) -> list[Stream]` (v1 → the 12 spec streams; ext → all).

- [ ] **Step 1: Write failing tests** in `test_registry.py`: `test_v1_has_exactly_twelve_streams` (names from PUSH_PROTOCOL registry tables); `test_rr_key_includes_seq` (`[c.name for c in REGISTRY["rrInterval"].key] == ["ts","rrMs","seq"]`); `test_sleep_session_is_replace_window_on_startTs`; `test_ext_includes_waveforms_and_lift_tables`; `test_forbidden_streams_absent` (`coachMessage`, `device`, `cursors`, `rawBatch`, `rawImuSample` not in `REGISTRY`); `test_streams_for_v1_excludes_ext`.
- [ ] **Step 2: Run** `cd selfhost && python -m pytest tests/test_registry.py -v` → FAIL (module missing).
- [ ] **Step 3: Implement** the scaffold (deps: fastapi, uvicorn, httpx, mcp, pytest, tzdata; console scripts `noop-receiver`, `noop-mcp`) and `registry.py`. v1 columns come from the PUSH_PROTOCOL tables (including later-added columns such as `tsSuspect`, `dynAccel`, `aux1Raw`); ext columns from `Packages/WhoopStore/.../Database.swift` migrations v10–v48 for the tables listed in spec §5.4. Write `PROTOCOL_EXT.md`: version `1.100`, new streams, `snapshot` delivery, base64 blobs, full-history chunked replace-window baseline.
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `git add selfhost && git commit -m "feat(selfhost): scaffold and stream registry"`.

### Task 2: SQLite store and idempotency ledger

**Files:**
- Create: `selfhost/src/noop_selfhost/db.py`, `selfhost/tests/test_db.py`

**Interfaces:**
- Consumes: `REGISTRY`.
- Produces: `class Store(path:str)` (WAL, `busy_timeout`, tables generated from `REGISTRY` keyed `(sourceId, deviceId, <key cols>)`, a `ledger(sourceId, deviceId, batchId, bodySha256, ackJson)` table, a `meta` table); `Store.receiver_state_id() -> str` (UUID, created once); `Store.rotate_receiver_state_id() -> str` (clears ledger + staging); `Store.connect_ro(path:str) -> sqlite3.Connection` (`mode=ro`).

- [ ] **Step 1: Write failing tests:** `test_state_id_stable_across_reopen`; `test_rotate_changes_id_and_clears_ledger`; `test_tables_exist_for_every_registry_stream`; `test_ro_connection_rejects_writes` (`sqlite3.OperationalError`); `test_blob_column_roundtrips_bytes`.
- [ ] **Step 2: Run** `python -m pytest tests/test_db.py -v` → FAIL.
- [ ] **Step 3: Implement** `db.py`; `blob_b64` columns stored as BLOB.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(selfhost): sqlite store`.

### Task 3: NDJSON batch parsing and validation

**Files:**
- Create: `selfhost/src/noop_selfhost/batch.py`, `selfhost/tests/test_batch.py`

**Interfaces:**
- Consumes: `REGISTRY`, `streams_for`.
- Produces: `@dataclass Batch(header:dict, records:list[Record], sha256:str)`; `Record(key:dict, data:dict)`; `class ProtocolError(Exception)` with `.status:int`, `.code:str`; `parse_batch(body:bytes, content_encoding:str|None, version:str, allowed:set[str]) -> Batch`; constants `MAX_RECORDS=5000`, `MAX_DECODED=4_194_304`, `MAX_WIRE=4_194_304+65_536`.

- [ ] **Step 1: Write failing tests:** `test_parses_spec_hr_example`; `test_gzip_and_identity_have_same_sha256`; `test_gzip_bomb_rejected_413` (small wire, >4 MiB decoded → `ProtocolError.status == 413`, decompression stops at the cap); `test_wrong_record_count_400`; `test_duplicate_keys_in_batch_400`; `test_unknown_or_disallowed_stream_422`; `test_append_keys_must_be_ordered_and_above_start_cursor`; `test_two_equal_rr_beats_with_distinct_seq_accepted`; `test_blank_line_or_bom_400`.
- [ ] **Step 2: Run** `python -m pytest tests/test_batch.py -v` → FAIL.
- [ ] **Step 3: Implement** `parse_batch` with streaming decompression bounded by `MAX_DECODED`; SHA-256 over decoded bytes.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(selfhost): ndjson batch parser`.

### Task 4: Receiver app, auth, capabilities, append delivery

**Files:**
- Create: `selfhost/src/noop_selfhost/receiver.py`, `selfhost/tests/test_receiver_append.py`

**Interfaces:**
- Consumes: `Store`, `parse_batch`, `streams_for`.
- Produces: `create_app(store:Store, token:str, enabled_streams:set[str]|None=None) -> FastAPI` with `GET /push` (capabilities) and `POST /push` (batch); `Store.accept_append(batch:Batch) -> dict` (ack object per spec).

- [ ] **Step 1: Write failing tests** (FastAPI `TestClient`): `test_requires_bearer_401`; `test_capabilities_selects_first_supported_version` (`NOOP-Push-Accept-Version: 1.100,1.0` → `1.100`; `1.0` only → `1.0`; unsupported → 406); `test_capabilities_streams_subset_follows_config`; `test_append_ack_matches_request_exactly`; `test_retry_same_batch_returns_same_ack_no_duplicates`; `test_same_batch_id_different_bytes_409`; `test_rr_equal_beats_both_stored` (query `COUNT(*)==2`); `test_ext_stream_rejected_under_version_1_0_422`; `test_declined_stream_rejected_422`.
- [ ] **Step 2: Run** `python -m pytest tests/test_receiver_append.py -v` → FAIL.
- [ ] **Step 3: Implement** `create_app`; token compare with `hmac.compare_digest`; errors as `{"type":"error","protocolVersion":…,"code":…}`; upserts `ON CONFLICT … DO UPDATE`; the ack and ledger row commit in the same transaction.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(selfhost): receiver with append delivery`.

### Task 5: Replace-window delivery

**Files:**
- Modify: `selfhost/src/noop_selfhost/receiver.py`, `selfhost/src/noop_selfhost/db.py`
- Test: `selfhost/tests/test_receiver_window.py`

**Interfaces:**
- Produces: `Store.accept_window_part(batch:Batch) -> dict` (stages parts keyed by `replacementId`, applies atomically when all `parts` are present: upsert, then delete rows in `[startInclusive, endExclusive)` absent from the replacement).

- [ ] **Step 1: Write failing tests:** `test_single_part_window_deletes_absent_rows_inside_only`; `test_empty_window_deletes_all_in_scope`; `test_multipart_applies_only_when_complete_and_out_of_order_ok`; `test_ack_of_last_part_only_after_apply`; `test_new_replacement_supersedes_old_incomplete_and_late_part_409`; `test_conflicting_part_reuse_409`; `test_arbitrary_subwindow_accepted` (including windows older than 14 days).
- [ ] **Step 2: Run** `python -m pytest tests/test_receiver_window.py -v` → FAIL.
- [ ] **Step 3: Implement** staging tables and the single-transaction apply.
- [ ] **Step 4: Run** → PASS; also run the whole suite `python -m pytest -q`.
- [ ] **Step 5: Commit** `feat(selfhost): replace-window delivery`.

### Task 6: Extension behaviours (snapshot, blobs, narrowing)

**Files:**
- Modify: `selfhost/src/noop_selfhost/receiver.py`, `selfhost/src/noop_selfhost/batch.py`, `selfhost/PROTOCOL_EXT.md`
- Test: `selfhost/tests/test_receiver_ext.py`

**Interfaces:**
- Produces: `delivery="snapshot"` handled as a whole-table replace per `(sourceId, deviceId, stream)` (same part/atomicity rules as windows, window `selector:"all"`); `blob_b64` fields decoded on write.

- [ ] **Step 1: Write failing tests:** `test_ppg_waveform_blob_byte_identical_after_roundtrip` (48-byte blob via base64); `test_ecg_record_1572_bytes_roundtrip`; `test_lift_snapshot_replaces_whole_table`; `test_full_history_chunked_windows_baseline` (3 consecutive 90-day windows then a 14-day one, no data loss); `test_capability_narrowing_never_stores_declined_stream`.
- [ ] **Step 2: Run** `python -m pytest tests/test_receiver_ext.py -v` → FAIL.
- [ ] **Step 3: Implement** and document in `PROTOCOL_EXT.md`.
- [ ] **Step 4: Run** → PASS (full suite too).
- [ ] **Step 5: Commit** `feat(selfhost): full-coverage extension`.

### Task 7: Paris time and sleep parsing

**Files:**
- Create: `selfhost/src/noop_selfhost/tz.py`, `selfhost/src/noop_selfhost/sleep.py`, `selfhost/tests/test_tz_sleep.py`

**Interfaces:**
- Produces: `PARIS = ZoneInfo("Europe/Paris")`; `day_bounds(day:str) -> tuple[int,int]` (UTC seconds, half-open); `local_iso(ts:int) -> str`; `parse_local(s:str) -> int` (naive strings are Paris time); `parse_stages(stages_json:str|None, start_ts:int, end_ts:int) -> list[dict]|dict` returning segments `[{"start","end","stage"}]` for the array shape and `{"light","deep","rem","awake"}` minutes for the dict shape; `pick_sleep(rows:list[dict]) -> list[dict]` (prefers the plain `deviceId` source over `deviceId-noop` per night).

- [ ] **Step 1: Write failing tests:** `test_day_bounds_dst_spring_is_23h` (`2026-03-29`), `test_day_bounds_autumn_is_25h` (`2026-10-25`); `test_night_crossing_midnight_attributed_to_wake_day`; `test_parse_stages_array_and_minutes_dict`; `test_parse_stages_none_and_garbage_return_empty`; `test_pick_sleep_prefers_imported_falls_back_to_noop`.
- [ ] **Step 2: Run** `python -m pytest tests/test_tz_sleep.py -v` → FAIL.
- [ ] **Step 3: Implement.** Attribution rule: a sleep session belongs to the local day of its `endTs`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(selfhost): paris time and sleep parsing`.

### Task 8: Stress heuristic

**Files:**
- Create: `selfhost/src/noop_selfhost/stress.py`, `selfhost/tests/test_stress.py`

**Interfaces:**
- Produces: `rmssd(rr_ms:list[int]) -> float|None` (range + Malik ectopic filter with the constants of `Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift`, copied and cited); `@dataclass(frozen=True) Baseline(median:float, mad:float, rest_hr:float)`; `personal_baseline(history_windows:list[tuple[float,float]]) -> Baseline|None`; `@dataclass(frozen=True) StressWindow(start_ts:int, end_ts:int, rmssd:float|None, mean_hr:float|None, score:int|None, label:Literal["calm","elevated","stressed","unknown"], reason:str)`; `compute_stress_timeline(rr:list[tuple[int,int]], hr:list[tuple[int,int]], motion:list[tuple[int,float]], baseline:Baseline|None) -> list[StressWindow]`; constants `WINDOW_S=300`, `MIN_BEATS=30`, `HR_DELTA=10`, `K_MAD=1.0`.

- [ ] **Step 1: Write failing tests:** `test_rmssd_matches_oracle` (values computed once from `HRVAnalyzer` on a fixed series and pasted as literals); `test_tracks_varying_input` (synthetic windows with injected RMSSD 20/40/80 ms yield monotonically decreasing scores for decreasing RMSSD, not a single match); `test_stressed_requires_low_rmssd_and_high_hr_and_low_motion`; `test_exercise_is_not_stress` (high HR + high motion → not "stressed"); `test_too_few_beats_gives_unknown_score_none`; `test_no_baseline_gives_unknown`.
- [ ] **Step 2: Run** `python -m pytest tests/test_stress.py -v` → FAIL.
- [ ] **Step 3: Implement.** Stressed ⇔ `rmssd < median − K_MAD·1.4826·mad` and `mean_hr ≥ rest_hr + HR_DELTA` and motion below the still threshold; score 0–100 from the clamped z-score of RMSSD. The thresholds are documented defaults, pinned by the tests.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(selfhost): stress heuristic`.

### Task 9: Query layer and MCP server

**Files:**
- Create: `selfhost/src/noop_selfhost/queries.py`, `selfhost/src/noop_selfhost/mcp_server.py`, `selfhost/tests/test_queries.py`, `selfhost/tests/test_mcp_server.py`

**Interfaces:**
- Consumes: `Store.connect_ro`, `tz`, `sleep`, `stress`.
- Produces: pure functions on a `sqlite3.Connection`: `hr_range(conn,start:int,end:int,bucket_s:int|None)->list[dict]`, `rr_range(conn,start,end)->list[dict]`, `sleep_for(conn,day:str)->list[dict]`, `stress_timeline(conn,start,end)->dict` (`{"heuristic":True,"disclaimer":…,"windows":[…]}`), `day_summary(conn,day:str)->dict`, `stream_range(conn,stream:str,start:int,end:int,limit:int,offset:int)->dict`; `create_server(db_path:str) -> FastMCP` exposing tools `get_hr_range`, `get_rr_range`, `get_sleep`, `get_stress_timeline`, `get_day_summary`, `get_stream_range`; `MAX_ROWS=5000`; rows with `ts > now + 86400` excluded.

- [ ] **Step 1: Write failing tests:** `test_hr_range_bucketing_paris_local_iso`; `test_rr_range_keeps_equal_beats`; `test_day_summary_on_dst_day_uses_23h_bounds`; `test_empty_db_returns_empty_with_reason_not_error`; `test_future_dated_rows_excluded`; `test_stream_range_rejects_unknown_stream_and_clamps_limit`; `test_stream_range_never_returns_blob_inline` (waveform stream returns counts/summary only); `test_coach_message_not_queryable`; `test_server_registers_exactly_six_tools`; `test_server_db_is_read_only` (write attempt through its connection raises).
- [ ] **Step 2: Run** `python -m pytest tests/test_queries.py tests/test_mcp_server.py -v` → FAIL.
- [ ] **Step 3: Implement.** Stream names come from the registry whitelist, never string-interpolated from input without a membership check. stdio entry point `noop-mcp --db PATH`; optional `--http 127.0.0.1:PORT`.
- [ ] **Step 4: Run** → PASS; run the full suite.
- [ ] **Step 5: Commit** `feat(selfhost): read-only mcp server`.

### Task 10: Deployment files and push simulator

**Files:**
- Create: `selfhost/deploy/noop-receiver.service`, `selfhost/deploy/noop-mcp.example.json`, `selfhost/deploy/README.md`, `selfhost/tools/push_simulator.py`, `selfhost/tests/test_simulator.py`

**Interfaces:**
- Produces: `noop-receiver --db PATH --token-file PATH --listen 127.0.0.1:8787`; `push_simulator.py --db <whoop.sqlite copy> --endpoint URL --token-file PATH` replaying the owner's real DB (v1 streams) so the receiver is verifiable before the iPhone client exists.

- [ ] **Step 1: Write failing test** `test_simulator_pushes_fixture_db_and_receiver_matches_counts` (builds a tiny fixture `whoop.sqlite`, runs simulator against an in-process receiver, asserts row counts equal per stream and a second run adds zero rows).
- [ ] **Step 2: Run** `python -m pytest tests/test_simulator.py -v` → FAIL.
- [ ] **Step 3: Implement** the simulator and deploy files: systemd unit (`Restart=always`, `User=` non-root, `ProtectSystem=strict`, `ReadWritePaths=` data dir), token generation (`openssl rand -hex 32`, `chmod 600`), the exact `tailscale serve` command and a `curl` capability check against `https://server.tailfb9ed9.ts.net/push`, a nightly `sqlite3 … ".backup"` cron line, and MCP registration example for agents.
- [ ] **Step 4: Run** the full suite `python -m pytest -q` → PASS.
- [ ] **Step 5: Commit** `feat(selfhost): deployment files and push simulator`.

---

## Phase A (client): Swift package + iOS glue

> Run on macOS by the owner: `cd Packages/SelfHostPush && swift test`, then `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`. None of these can run in the Linux sandbox; the implementer says so in the commit/PR text.

### Task 11: Package, stream specs, NDJSON encoder, key fingerprint

**Files:**
- Create: `Packages/SelfHostPush/Package.swift`, `Packages/SelfHostPush/Sources/SelfHostPush/StreamSpec.swift`, `.../NDJSON.swift`, `.../Fingerprint.swift`, `Packages/SelfHostPush/Tests/SelfHostPushTests/EncodingTests.swift`

**Interfaces:**
- Produces: `public enum Delivery { case append, replaceWindow, snapshot }`; `public struct StreamSpec { name:String; table:String; keyColumns:[Column]; dataColumns:[Column]; delivery:Delivery; selector:Selector?; phase:Phase }` with `Column(name:String, kind:Kind)` (`Kind`: int, real, text, bool, blobB64); `public enum PushRegistry { static let v1:[StreamSpec]; static let ext:[StreamSpec] }`; `public struct Cursor: Codable, Equatable { rowId:Int64; keySha256:String }`; `public func keyFingerprint(stream:String, deviceId:String, key:[(String,JSONValue)]) -> String`; `public struct EncodedBatch { batchId:String; body:Data; recordCount:Int; endCursor:Cursor?; window:WindowSpec? }`; `public func encodeBatch(header:BatchHeader, records:[Record]) throws -> EncodedBatch` (LF-terminated lines, deterministic key order, no BOM).

- [ ] **Step 1: Write failing tests:** `testHrExampleMatchesProtocolBytes` (the PUSH_PROTOCOL `hrSample` example encodes to the exact lines); `testFingerprintMatchesAndroidVector` (hash of `"hrSample\nstrap-local-id\n{\"ts\":1723939201}"` computed independently and pasted); `testNullAndBoolEncoding`; `testBatchStopsBefore5000RecordsOr4MiB` (`splitBatches` helper); `testRegistryV1HasTwelveStreamsMatchingSpec`.
- [ ] **Step 2: Run** `swift test --filter EncodingTests` → FAIL (macOS).
- [ ] **Step 3: Implement.** Tools 5.9, platforms iOS 17 / macOS 13, GRDB `exact: "6.29.3"`; SHA-256 via CryptoKit.
- [ ] **Step 4: Run** → PASS (macOS).
- [ ] **Step 5: Commit** `feat(push): package, registry and encoder`.

### Task 12: Progress store and cursor verification

**Files:**
- Create: `.../ProgressStore.swift`, `Tests/.../ProgressTests.swift`

**Interfaces:**
- Consumes: `Cursor`, `keyFingerprint`.
- Produces: `public protocol RowSource { func deviceIds() throws -> [String]; func appendPage(_ s:StreamSpec, deviceId:String, afterRowId:Int64?, limit:Int) throws -> [SourceRow]; func row(_ s:StreamSpec, deviceId:String, rowId:Int64) throws -> SourceRow? }` (`SourceRow(rowId:Int64, key:[String:JSONValue], data:[String:JSONValue])`); `public final class ProgressStore { init(url:URL); sourceId:String; func namespace(endpoint:URL, version:String, receiverStateId:String) -> Namespace; func cursor(ns:Namespace, device:String, stream:String) -> Cursor?; func advance(...) ; func reset(...) }` stored in `push-progress.sqlite` beside the main DB (no migration of the main DB); `func verifiedCursor(_ c:Cursor?, source:RowSource, spec:StreamSpec, device:String) throws -> Cursor?` (returns `nil` and resets when the row is missing or the fingerprint differs).

- [ ] **Step 1: Write failing tests:** `testNewNamespaceWhenEndpointVersionOrReceiverStateChanges`; `testTokenRotationKeepsProgress`; `testMissingRowResetsCursorToNil`; `testFingerprintMismatchResetsCursorToNil`; `testValidCursorSurvivesReopen`.
- [ ] **Step 2: Run** `swift test --filter ProgressTests` → FAIL.
- [ ] **Step 3: Implement** with its own small GRDB `DatabaseQueue`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(push): progress store and cursor verification`.

### Task 13: Transport

**Files:**
- Create: `.../PushTransport.swift`, `Tests/.../TransportTests.swift`

**Interfaces:**
- Produces: `public struct PushEndpoint { url:URL; token:String }` (rejects non-HTTPS); `public final class PushTransport { init(session:URLSession) ; func capabilities(_ e:PushEndpoint, accept:[String]) async throws -> Capabilities; func post(_ e:PushEndpoint, batch:EncodedBatch, version:String) async throws -> Ack }`; `public enum PushError: Error { retryable(Cause), fatal(Cause) }`; gzip body with explicit `Content-Length`; redirects never followed and the token never forwarded; retry-once-without-gzip only on 415; ack validated field-by-field against the request.

- [ ] **Step 1: Write failing tests** (`URLProtocol` stub): `testCapabilitiesParsedAndVersionSelected`; `testHttpEndpointRejected`; `testRedirectNotFollowed`; `test415FallsBackToIdentityOnceWithSameBatchId`; `testMismatchedAckIsFatalNotAccepted`; `test408_429_5xxAreRetryable_otherFourXXFatal`; `testCapabilitiesOver16KiBRejected`.
- [ ] **Step 2: Run** `swift test --filter TransportTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(push): transport`.

### Task 14: Sync engine (phase A streams)

**Files:**
- Create: `.../PushEngine.swift`, `.../WindowSync.swift`, `Tests/.../EngineTests.swift`

**Interfaces:**
- Consumes: `RowSource`, `ProgressStore`, `PushTransport`, `PushRegistry`.
- Produces: `public enum PushTrigger { case offloadLanded, foreground, backgroundTask, manual }`; `public struct PushRunResult { sentRows:Int; pendingStreams:[String]; error:PushError? }`; `public final class PushEngine { init(source:RowSource, progress:ProgressStore, transport:PushTransport, endpoint:PushEndpoint, phase:Phase); func runOnce(_ t:PushTrigger, deadline:Date) async -> PushRunResult }`. Cheap streams first (`hrSample`, `rrInterval`, sleep), then the rest. Pending batch bytes persisted before POST. Replace-window: current local day + preceding 13 days, per-day hashes, smallest changed contiguous window, empty window for a deleted day.

- [ ] **Step 1: Write failing tests** (fake `RowSource`/transport): `testAppendAdvancesCursorOnlyAfterValidAck`; `testRetryAfterKillReusesIdenticalBatchIdAndBytes`; `testBackfilledOldTsRowsAreNotStranded` (a lower `ts` inserted later has a higher rowid and is sent); `testUnadvertisedStreamNeverReadOrSent`; `testUnchangedDaysSendNothing`; `testDeletedDayEmitsEmptyAuthoritativeWindow`; `testDeadlineStopsBetweenBatchesWithoutLosingProgress`; `testFailureOnOneStreamDoesNotBlockOthers`.
- [ ] **Step 2: Run** `swift test --filter EngineTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(push): sync engine`.

### Task 15: GRDB row source

**Files:**
- Create: `.../GRDBRowSource.swift`, `Tests/.../GRDBRowSourceTests.swift`
- Modify: `Packages/SelfHostPush/Package.swift` (test-only dependency on `../WhoopStore`)

**Interfaces:**
- Produces: `public final class GRDBRowSource: RowSource { public init(databasePath:String) throws }` (read-only `DatabaseQueue`, WAL-safe, explicit column projections from `StreamSpec`, never `SELECT *`; missing nullable columns emit `null`).

- [ ] **Step 1: Write failing tests** (schema created with `WhoopStore`'s migrator in a temp file): `testAppendPageOrderedByRowidAndLimited`; `testRRBeatsWithEqualTsRrMsDifferentSeqBothReturned`; `testRowLookupByRowid`; `testWritesAreRejected`; `testDeviceIdsIncludesNoopSuffixedSource`; `testFutureAddedColumnAbsentEmitsNull`.
- [ ] **Step 2: Run** `swift test --filter GRDBRowSourceTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(push): grdb row source`.

### Task 16: iOS glue (settings, scheduler, triggers)

**Files:**
- Create: `Strand/System/PushSettings.swift` (new file in the macOS+iOS shared tree so `StrandTests` can compile it; it imports only Foundation/Security, never `SelfHostPush`), `StrandiOS/Push/PushCoordinator.swift`, `StrandiOS/Push/PushBackgroundScheduler.swift`, `StrandiOS/Push/PushSettingsView.swift`, `StrandTests/PushGateTests.swift`
- Modify: `project.yml` (package `SelfHostPush`, NOOPiOS dependency, `BGTaskSchedulerPermittedIdentifiers` += `$(PRODUCT_BUNDLE_IDENTIFIER).push`), `StrandiOS/App/StrandiOSApp.swift` (register in `init` next to `ScheduledDebugExport.register()`; trigger in the `scenePhase == .active` block; assign `model.pushAfterOffload` beside `model.healthWriteBack`), `StrandiOS/App/RootTabView.swift` (`case pushExport` row + destination, mirroring `shortcutsExport`), `Strand/App/AppModel.swift` (declare and call `pushAfterOffload` wherever `healthWriteBack` is called)

**Interfaces:**
- Produces: `enum PushSettings { static var enabled:Bool; static var endpointString:String; static func token() -> String?; static func setToken(_:String) }` (UserDefaults keys `noop.push.enabled`, `noop.push.endpoint`; token in Keychain, same pattern as `Strand/Oura/OuraTokenStore.swift`); `final class PushCoordinator { static func shouldRun() -> Bool; func trigger(_ t:PushTrigger) }` (single-flight, runs detached from strap sync, `shouldRun()` false when disabled or endpoint empty); `enum PushBackgroundScheduler { static let taskIdentifier:String; static func register(run:@escaping () async -> Bool); static func updateSchedule(isEnabled:Bool) }` (pattern of `HealthWritebackBackgroundScheduler`; `BGProcessingTaskRequest` with network required).

- [ ] **Step 1: Write failing tests** in `PushGateTests`: `testNeverRunsWhenDisabled`; `testNeverRunsWithEmptyEndpoint`; `testRejectsHttpEndpoint`; `testTaskIdentifierMatchesPermittedIdentifier` (reads `Bundle.main` info like `BackgroundTaskIdentityTests`); `testTriggerIsNoOpWithoutToken`.
- [ ] **Step 2: Run** `xcodebuild -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/PushGateTests` → FAIL (macOS; shared logic must compile for both targets).
- [ ] **Step 3: Implement** the files and edits above. UI uses design tokens only; copy states that data goes only to the user's own endpoint; settings has endpoint field, token field, enable toggle (default off), "Test connection" (capabilities `GET` only), last-run status, "Upload now".
- [ ] **Step 4: Run** the macOS tests and then the NOOPiOS build command from the phase note → PASS/BUILD SUCCEEDED.
- [ ] **Step 5: Commit** `feat(push): iOS settings, scheduler and triggers`.

---

## Phase B: full coverage

### Task 17: Extension streams and full-history baseline (Swift)

**Files:**
- Modify: `Packages/SelfHostPush/Sources/SelfHostPush/StreamSpec.swift`, `.../PushEngine.swift`, `.../WindowSync.swift`, `.../PushTransport.swift`
- Test: `Packages/SelfHostPush/Tests/SelfHostPushTests/ExtensionTests.swift`

**Interfaces:**
- Consumes: Tasks 11–15. Produces: `PushRegistry.ext` complete per spec §5.4 (append: `stepSample`, `ppgHrSample`, `sleepStateSample`, `appleStepHour`, `v18AuxSample`, `ppgWaveformSample`, `ecgWaveformSample`; windows: `appleDaily`, `metricSeries`, `scoreInputProvenance`, `liveSession`, `ouraRaw`; snapshots: `labMarker`, `liftExercise`, `liftProgram`, `liftProgramItem`, `liftSession`, `liftSet`); `Accept-Version: 1.100,1.0`; `func baselineWindows(spec:StreamSpec, earliest:Int, now:Int, chunkDays:Int) -> [WindowSpec]`.

- [ ] **Step 1: Write failing tests:** `testExtRegistryExcludesCoachMessageDeviceCursorsRawBatch`; `testBlobColumnsEncodedAsBase64`; `testFullHistoryBaselineChunksCoverEverythingOnce`; `testBaselineThenRollingWindowOnly`; `testFallsBackToV1StreamsWhenReceiverSelects1_0`; `testWaveformStreamsDrainedAfterCheapStreams`; `testSnapshotUnchangedIsElided`.
- [ ] **Step 2: Run** `swift test --filter ExtensionTests` → FAIL (macOS).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` (whole package) → PASS.
- [ ] **Step 5: Commit** `feat(push): full-coverage extension`.

### Task 18: End-to-end verification and docs

**Files:**
- Create: `selfhost/README.md`, `docs/superpowers/specs/2026-11-16-self-hosted-pipeline-verification.md`

- [ ] **Step 1: Server side (Linux):** run `python -m pytest -q` in `selfhost/`; start `noop-receiver`, run `push_simulator.py` against a copy of a real `whoop.sqlite`; expected: per-stream counts equal, second run adds zero rows.
- [ ] **Step 2: Tailnet:** apply `tailscale serve`, then `curl -H "Authorization: Bearer $(cat token)" -H "NOOP-Push-Accept-Version: 1.100,1.0" https://server.tailfb9ed9.ts.net/push`; expected: `{"type":"capabilities",…}` and a 401 without the token.
- [ ] **Step 3: Device (owner):** build `NOOPiOS` from source, enable the push in More → settings, tap "Test connection" then "Upload now"; confirm rows appear; background a day and confirm catch-up; record results (what was run on hardware, what was not) in the verification document.
- [ ] **Step 4: MCP:** register `noop-mcp` with an agent; ask for yesterday's `get_day_summary` and `get_stress_timeline`; record outputs.
- [ ] **Step 5: Commit** `docs: selfhost readme and verification notes`.
