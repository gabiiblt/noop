# Verification record: self-hosted pipeline

Status at hand-over. This lists what was actually run, what was only reviewed, and what **you** have to run.
Nothing below is claimed beyond what is stated.

## 1. Verified in the build environment (Linux, Python 3.13)

| Check | Result |
|---|---|
| `selfhost` test suite (`python -m pytest`) | **167 passed** (receiver, protocol, windows, extension, tz/DST, sleep, stress, queries, MCP, deploy files, simulator, registry fixture) |
| Real receiver process on loopback (`noop-receiver`) | capabilities OK; 401 without token; `0.0.0.0` listen refused; request bodies not logged |
| `noop-push-simulator` against it (2,000 HR rows + 1 sleep session), run twice | 2,000 / 1 rows, second run adds zero rows (idempotent) |
| `noop-mcp` over stdio, raw JSON-RPC | 6 tools listed; `get_sleep`, `get_hr_range`, `get_day_summary`, `get_stress_timeline` return correct data; bad input returns a model-visible tool error |
| Latency on a synthetic 15-day database (3.8 M rows, 231 MB) | `get_stress_timeline` 2.2 s, `get_day_summary` 1.5 s, `get_hr_range` 0.03 s (was 7.6 s / 6.6 s before the time indexes and baseline sampling) |
| Swift syntax (tree-sitter grammar) on every new/edited Swift file | no syntax errors. **This is a syntax check only, not a compile.** |

## 2. NOT verified (no Swift toolchain, no iPhone, no Tailscale in the build environment)

- **No Swift code has been compiled or run.** `Packages/SelfHostPush` (engine, transport, GRDB reader, their
  XCTest suites), `Strand/System/PushSettings.swift`, `StrandiOS/Push/*`, the edits to `AppModel`,
  `StrandiOSApp`, `RootTabView`, `project.yml`, and `StrandTests/PushGateTests.swift`.
  The Swift tests were desk-checked against the code by hand, which found and fixed real bugs, but a compiler
  will find more. Expect a few compile fixes on first build.
- systemd unit, `tailscale serve` + MagicDNS HTTPS, the `--http` MCP mode.
- Anything on a real iPhone: background behaviour, Keychain, BGProcessingTask, real data volumes.

## 3. What you run, in order

On your Mac (Xcode 26.x):

```bash
cd Packages/SelfHostPush && swift test            # engine/transport/progress/GRDB tests
cd ../.. && xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  test -only-testing:StrandTests/PushGateTests    # the gate: nothing runs without endpoint + token
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build                   # the iOS app compiles
```

Report compile errors back (the iOS and macOS targets both compile `Strand/System/PushSettings.swift`).
For a device build set your own `BUNDLE_ID_PREFIX` and `APP_GROUP_ID` (see `docs/BUILD.md`), signed with
your Apple Developer account.

On the server: follow `selfhost/deploy/README.md` (install, token, systemd, `tailscale serve`, curl check).
Optionally rehearse with `noop-push-simulator` and a copy of your `whoop.sqlite` before touching the phone.

On the iPhone: More, Self-hosted Export. Enter `https://server.tailfb9ed9.ts.net/push` and the token, tap
**Test connection** (this sends no health data), turn the switch on, tap **Upload now**, keep the app open
for the first backlog, then check on the server:

```bash
sqlite3 /var/lib/noop-selfhost/selfhost.sqlite "select count(*) from hrSample; select count(*) from sleepSession;"
```

Then leave the phone for a day and confirm catch-up happened without opening the app (uploads need iOS to
grant background time: after a strap sync, and a nightly processing task while idle and online).

## 3b. Independent review (whole branch) and what was done about it

A fresh reviewer read the whole branch. Two critical and seven important findings were fixed, each with a
test written first (Python tests were watched failing then passing; Swift tests are unrun, see section 2):

- **Critical:** a window/snapshot that flip-flopped (A, B, A, B) or whose acknowledgement was lost before the
  data reverted could leave the receiver silently out of date. Fixed with a per-stream delivery generation
  and an in-flight marker (`ProgressStore`), so a retry is byte-identical but every new delivery is distinct,
  and an unacknowledged delivery is re-sent even if the local data has since reverted.
- **Critical:** the background-time expiry handler did not end the assertion, and windows/snapshots ignored the
  deadline. Fixed: expiry cancels the task and ends the assertion; the engine checks the deadline and
  cancellation between parts.
- **Important:** Swift test literals that would not compile; the RR read policy and duplicate sources in the
  MCP (false "stressed" risk); triggers dropped during a run; `appleStepHour` (updated in place) now a window;
  device discovery for extension-only devices (e.g. mood entries); stress range capped at 7 days and long text
  truncated; backup instructions.

## 4. Known limits and decisions (also in the plan ledger)

- Delivery is catch-up, not real time (iOS suspends the app).
- The client sends uncompressed bodies (allowed by the protocol); the first backlog may be large if optical
  waveform capture is on. Compression can be added later.
- The stress heuristic's thresholds are uncalibrated defaults.
- The extension version `1.100` is fork-only; a stock upstream-protocol receiver still works with the 12 v1
  streams.
- The sleep and daily scores computed on the phone (`deviceId` ending `-noop`) are exported next to imported
  ones; the MCP server prefers imported data and falls back to the computed session.
