# Fork extension to the push protocol (version `1.100`)

Personal, fork-only extension to [`docs/PUSH_PROTOCOL.md`](../docs/PUSH_PROTOCOL.md). Upstream's
document is not modified. Everything not stated here is exactly protocol v1.

## Negotiation

The sender offers `NOOP-Push-Accept-Version: 1.100,1.0`. The receiver selects the first version it
supports. Minor `100` is reserved for this fork so it cannot collide with a future upstream `1.x`.
A stream or member of this extension is never sent under `1.0`; a receiver rejects it with `422`.

## What the extension adds

1. **More streams** (registry `phase: ext`): append `stepSample`, `ppgHrSample`,
   `sleepStateSample`, `appleStepHour`, `v18AuxSample`, `ppgWaveformSample`, `ecgWaveformSample`;
   replace-window `appleDaily`, `metricSeries`, `scoreInputProvenance`, `liveSession`; snapshot
   `ouraRaw`, `labMarker`, `liftExercise`, `liftProgram`, `liftProgramItem`, `liftSession`, `liftSet`.
2. **Extra optional members on v1 streams:** `dailyMetric.avgSdnn`, `.skinTempC`, `.sleepHrOnly`.
3. **Blob members** (`samples`, `fields`, `record`) are JSON strings holding standard base64.
4. **`snapshot` delivery**: whole-table replacement for a small id-keyed table, scoped by
   `(sourceId, deviceId, stream)`. Header `window` is `{"replacementId","selector":"all","part","parts"}`;
   the same part/staging/atomic-apply/supersede rules as `replace_window` apply, and absent keys are
   deleted for that scope.
5. **Full-history baseline:** on a fresh destination the sender replays all history of every
   replace-window stream as consecutive half-open windows (e.g. 90 days each), then continues with
   the rolling 14-day window. A receiver accepts any non-empty half-open window.

## Never exported

`coachMessage`, `device`, `cursors`, `rawBatch`, local `synced` columns, and the retired
`rawImuSample`.
