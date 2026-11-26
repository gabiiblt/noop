# Lift oracles (progression, plates, recovery, balance)

Four generated test files, checked against openGym's own code: `LiftProgressionOracleTests.swift` (from `gen.mjs`)
`LiftPlatesOracleTests.swift` (from `gen_plates.mjs`: plate stacks, row loads, plate deltas, bars, owned weights)
`LiftRecoveryOracleTests.swift` (from `gen_recovery.mjs`: fatigue and retained strength per muscle over 87 histories)
and `LiftBalanceOracleTests.swift` (from `gen_balance.mjs`: the three strength-balance tables over 76 histories). `gen_balance.mjs`
also writes `LiftBalanceTemplates.swift`, the tables as Swift data, straight from openGym's file: it goes to
`Packages/StrandAnalytics/Sources/StrandAnalytics/`, not to the tests.
`LiftProgressionOracleTests.swift` is generated: each
scenario in `gen.mjs` is run through openGym's own `progression.js` under Node, and what it returns is written
out as the expected literals for the Swift port (`LiftProgression`). A Swift change is checked against the
original, not against a re-reading of it.

```bash
Tools/lift_progression_oracle/fetch.sh /path/to/opengym   # copies the 11 openGym files + the inert stubs into lib/
cd Tools/lift_progression_oracle && node gen.mjs && node gen_plates.mjs && node gen_recovery.mjs && node gen_balance.mjs   # write the generated files here
mv Lift*OracleTests.swift ../../Packages/StrandAnalytics/Tests/StrandAnalyticsTests/
mv LiftBalanceTemplates.swift ../../Packages/StrandAnalytics/Sources/StrandAnalytics/
```

`lib/` and the generated file's output stay out of review noise: `lib/` is git-ignored. `stubs/` replaces the
openGym modules outside the ported scope (pyramids, back-off sets, ladders, per-gym splits) with inert
versions, and `exercises.js` with a five-exercise catalogue (only the equipment word matters to plates), so a scenario can never reach a rule the port omits.
`history.js` there copies `modeOf`, `repStep`, `isPerSide` and the entry helpers from openGym's history.js.

Add a scenario by calling `add(name, cfg, sessions)` in `gen.mjs`; the test name is `test_<name>`.
