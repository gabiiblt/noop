# Lift oracles (progression, plates)

Two generated test files, checked against openGym's own code: `LiftProgressionOracleTests.swift` (from `gen.mjs`)
and `LiftPlatesOracleTests.swift` (from `gen_plates.mjs`: plate stacks, row loads, plate deltas, bars, owned weights).
`LiftProgressionOracleTests.swift` is generated: each
scenario in `gen.mjs` is run through openGym's own `progression.js` under Node, and what it returns is written
out as the expected literals for the Swift port (`LiftProgression`). A Swift change is checked against the
original, not against a re-reading of it.

```bash
Tools/lift_progression_oracle/fetch.sh /path/to/opengym   # copies the 6 openGym files + the inert stubs into lib/
cd Tools/lift_progression_oracle && node gen.mjs && node gen_plates.mjs   # write the two generated test files here
mv Lift*OracleTests.swift ../../Packages/StrandAnalytics/Tests/StrandAnalyticsTests/
```

`lib/` and the generated file's output stay out of review noise: `lib/` is git-ignored. `stubs/` replaces the
openGym modules outside the ported scope (pyramids, back-off sets, ladders, per-gym splits) with inert
versions, and `exercises.js` with a five-exercise catalogue (only the equipment word matters to plates), so a scenario can never reach a rule the port omits.
`history.js` there copies `modeOf`, `repStep`, `isPerSide` and the entry helpers from openGym's history.js.

Add a scenario by calling `add(name, cfg, sessions)` in `gen.mjs`; the test name is `test_<name>`.
