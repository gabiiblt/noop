# Lift progression oracle

`Packages/StrandAnalytics/Tests/StrandAnalyticsTests/LiftProgressionOracleTests.swift` is generated: each
scenario in `gen.mjs` is run through openGym's own `progression.js` under Node, and what it returns is written
out as the expected literals for the Swift port (`LiftProgression`). A Swift change is checked against the
original, not against a re-reading of it.

```bash
Tools/lift_progression_oracle/fetch.sh /path/to/opengym   # copies the 3 openGym files + the inert stubs into lib/
cd Tools/lift_progression_oracle && node gen.mjs           # prints a summary, writes LiftProgressionOracleTests.swift
mv LiftProgressionOracleTests.swift ../../Packages/StrandAnalytics/Tests/StrandAnalyticsTests/
```

`lib/` and the generated file's output stay out of review noise: `lib/` is git-ignored. `stubs/` replaces the
openGym modules outside the ported scope (owned dumbbells, pyramids, back-off sets, ladders, assistance
machines, per-gym splits) with inert versions, so a scenario can never reach a rule the port omits.
`history.js` there copies `modeOf`, `repStep`, `isPerSide` and the entry helpers from openGym's history.js.

Add a scenario by calling `add(name, cfg, sessions)` in `gen.mjs`; the test name is `test_<name>`.
