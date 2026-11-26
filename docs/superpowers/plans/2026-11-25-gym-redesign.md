# Training redesign and app-wide polish: plan

Status: proposal, nothing implemented. Written after reading `gabiiblt/openGym` (a copy of
`DuarteSantos8/openGym`, see licensing below) and NOOP's current Lift Log.

## Goals

1. Redesign the app with a clean, "unslop" look, **keeping every metric currently on screen**.
2. Make the app fast and light: no stutter, a low and stable memory footprint.
3. Rebuild the training side: better design, detailed stats per workout, exercise images, an exercise database.
4. Every new piece of stored data is exported by the self-hosted push and readable through the MCP server.

## What openGym teaches us

openGym is a React 19 + Capacitor app with a plain Node API and one JSON document per profile. It is not a library
to embed. Under the MIT grant below its code can be ported, and its pure functions (with their tests) give us
reference values.

Behaviour worth reproducing (ported to Swift):

- A catalogue of 5,600+ exercises with permanent ids (never reused or deleted: workouts and routines store the id), body part,
  equipment, target and secondary muscles, instructions, a `hold` flag (timed holds), a `track: distance` flag
  (carries, sleds), `needs` (bench, pull-up bar) and a `machineKind` so an equipment profile can hide what you cannot do.
- Set shapes: straight, warm-up, drop set (main set plus drops), rest-pause and cluster (the row's reps are the total,
  bursts are a breakdown), to-failure flag, per-side (L/R) reps, timed, distance and cardio modes, RIR or RPE per set.
- Session flow: pre-filled weights from last time, rest timer, live PR detection, live volume, supersets, a backup
  exercise swapped in when a machine is taken, plate math per gym (each gym keeps its own plates, bars, dumbbells).
- Progression rules explained to the user (linear, double progression, triple progression, deload on stall).
- Stats: estimated 1RM curve per exercise, muscle map by volume / recovery / untrained, a year heatmap, volume totals,
  lifts as a percentage of body weight, edit any past session.
- An MCP server (read tools + `log_workout`) computed by the same pure functions as the UI.

## Licensing (decisive)

Decisions of 2026-11-25: the maintainer of NOOP holds a written authorization from Duarte Santos (author of openGym), dated
2026-11-25, version 3, naming **Gabriel Bolatoglu** and the app "Noop". It supersedes versions 1 and 2. Its terms:

- An MIT licence on openGym's **source code and the images, icons and other graphics Duarte Santos authored**, commercial
  use included, on top of the public AGPL-3.0, and files may be handed to an AI assistant to carry out the integration.
- An extension to **third-party elements** in the repository (Gym visual media, MuscleMap geometry, catalogue text and
  translations, free-exercise-db data) **"only to the extent I have the right to transmit them, with no warranty from me"**,
  with Gabriel respecting those third parties' licences and assuming their use.

The PDF stays with the maintainer and is **not** committed.

| Asset | Status for NOOP (PolyForm Noncommercial 1.0.0) |
|---|---|
| openGym source code and graphics Duarte Santos authored | **Reusable under the MIT grant** (copy, modify, merge, sublicense). Keep Duarte Santos's copyright and the MIT notice with every ported file or substantial portion, recorded in `ATTRIBUTION.md`. In practice: port logic to Swift (progression, 1RM, volume, set model, plate math). |
| 13,109 media files from Gym visual | **Still excluded.** Version 3 can only pass on what Duarte may transmit, and Gym visual's own notice says the media may be used only inside the openGym app, that other uses need a licence from gymvisual.com, and that they may not be fed to any AI system. His extension therefore does not give us rights he does not hold. Options if these animations are wanted: buy a licence from gymvisual.com. Nothing from `catalogue/media` is copied, read or processed. |
| MuscleMap body geometry (Melih Colpan) | MIT. Mention it in `ATTRIBUTION.md` when used (version 3 asks for it, and the MIT terms require it anyway). |
| Catalogue text and translations (5,632 French entries among 22 languages) | **Usable** to the extent Duarte can transmit them; his contributor licence agreement lets him relicense community contributions. The 1,323 `textSource: exercisedb` entries also need the ExerciseDB MIT notice. We accept the residual risk stated in the grant (no warranty). |
| `yuhonas/free-exercise-db` | Unlicense (public domain): 876 exercises, two JPG stills each (about 105 MB raw). Image provenance is declared by that repository, not verified by us. |

**Images and database (decided):** exercise text, muscles, equipment and translations come from the openGym catalogue;
**images come only from free-exercise-db**, matched to catalogue entries by name with a manual review. Entries with no image
show a muscle illustration instead. Custom exercises can carry the user's own photo.

## Where NOOP stands today

Lift Log exists (about 2,900 lines): tables `liftExercise`, `liftProgram`, `liftProgramItem`, `liftSession`, `liftSet`,
all already exported by the push; Hevy CSV, Liftosaur and program (xlsx/csv) importers. Gaps against the goals:

- `liftSet` stores only weight, reps, RPE, warm-up, start/end, rest, note. No set type, drops, clusters, failure, side,
  mode (time/distance), RIR, heart rate per set, superset, exercise id, equipment, media.
- `liftExercise` has a name and muscles only: no catalogue id, equipment, instructions, image. NOOP ships no catalogue.
- The muscle vocabulary is a closed set of 13 tokens, a stored-data contract. The catalogue's finer muscles
  (front delts, rear delts, traps...) must map onto it, or the vocabulary is extended deliberately and migrated.
- No per-workout detail screen with real analytics; no records or 1RM history stored.

## Data model changes and what must follow them into the push

Every field below needs, in the same change: a GRDB migration + test (iPhone only, see phase 7),
`Packages/SelfHostPush/.../StreamSpec.swift`, `selfhost/src/noop_selfhost/registry.py`, the parity fixture
`Parity/registry.json`, a protocol extension bump documented in `selfhost/PROTOCOL_EXT.md`, and receiver tests.

| Table | New columns / tables |
|---|---|
| `liftSet` | `setType` (straight/dropset/restpause/cluster), `dropsJSON`, `clustersJSON`, `failure`, `side` (L/R/both), `mode` (reps/time/distance/cardio), `durationS`, `distanceM`, `rir`, `hrAvg`, `hrMax`, `supersetGroup`, `exerciseId`, `loadKind` (external/bodyweight/assisted), `isPR` |
| `liftSession` | `bodyweightKg`, `volumeKg`, `prCount`, `avgHr`, `maxHr`, `kcalEst`, `gymId`, `deload`, `mediaCount` |
| `liftExercise` | `catalogueId`, `equipment`, `bodyPart`, `mechanic`, `hold`, `trackDistance`, `custom`, `mediaRef` |
| `liftProgramItem` | `exerciseId`, `supersetGroup`, `setType`, `backupExerciseId`, `progressionRule` |
| `liftProgram` | `weekday` / rotation slot, `progressionRule`, `deloadEvery` |
| new `liftRecord` | per exercise and rep range: best weight, best volume set, estimated 1RM, date (derived but stored so the MCP can answer without recomputation) |
| new `liftGym` | gym name, plates, bars, dumbbell range, machine stacks |
| catalogue | read-only, **shipped in the app bundle**, never exported (it is public data); exports carry only `catalogueId` |

New MCP tools (read-only): `get_workouts` (list), `get_workout` (set by set), `get_exercise_history`,
`get_records`, `get_muscle_volume`, plus `get_sync_status` already covers freshness. They reuse the Swift/Python
twin of the volume and 1RM formulas, checked by an oracle test (Swift output pasted as the Python expected values).

## Phases

Ordering rationale: training is the largest self-contained area and the best pilot of the new design language, so it goes
before the app-wide pass. Performance is measured first so we optimise real hot spots, not guesses.

0. **Decisions.** Done: images and exercise database from free-exercise-db; **iPhone only** (Android is not touched, now or
   in this plan); openGym code reusable under the MIT grant. Still open: the keep-list of metrics (built in phase 2).
   Catalogue text and translations are usable under authorization v3.
1. **Performance baseline.** Instruments (Time Profiler, Allocations, Hitches) on a device with a realistic database;
   MetricKit is already wired. Set budgets: cold launch, steady memory, no dropped frames while scrolling Today, Trends and
   the exercise list. Fix measured hot spots only (candidates: the multi-minute re-score pass, large single-file views that
   already break the type checker, unbounded in-memory series, full-size images). One concern per PR.
2. **Metric inventory.** A checklist of every metric and control on every screen, generated from the code, so the redesign
   cannot silently drop one. Each redesigned screen is ticked against it.
3. **Training data foundation.** Migrations, the catalogue import (openGym text and translations, images from free-exercise-db matched by name, mapped to NOOP muscles, ids permanent),
   the media pipeline (downsample to WebP, lazy load, disk cache, size measured against the sideload IPA limit), tests.
4. **Training UI.** Exercise library (search, muscle filter, equipment filter, image), session screen (set types, rest timer,
   supersets, PR detection), workout detail with real stats (volume, sets, reps, PRs, 1RM, muscle split, heart-rate zones,
   duration, rest), history with edit, progress per exercise, records.
5. **Self-host push and MCP** for everything added in 3 and 4 (kept in step with each PR, not left to the end).
6. **App-wide "unslop" pass**, screen by screen, tokens only (design system is law), checked against the inventory.
7. ~~Android parity~~ **Out of scope** (decision 2026-11-25). Consequence: new tables are iOS-only, so a `.noopbak` backup
   moved between iPhone and Android may carry data the other side ignores or rejects. Keep the backup whitelist change
   explicit and tested, and never restore across platforms without checking.

## Training features to port from openGym (all requested, 2026-11-26)

Each item is a port of openGym's code under the MIT authorization, with its origin noted in the file and
reference values from openGym's own functions run under vitest. Every stored field joins the push and the MCP.

Done: catalogue (text, French, muscles, equipment, images from free-exercise-db), personal records per set,
progress per exercise, set model (drop set, rest-pause, failure, RIR, side, time, distance) in the store and push,
and its logging UI in the live session (`LiftSetDetailSheet`, opened from the ellipsis on each set row; the value
is `LiftSetExtras`, held for a set not yet performed, kept across a relaunch, written to `liftSet` on Save).
Not yet on Android, which has no v49 set model; the Swift side leads until the Room twin lands.

To do:
2. Progression rules per program or exercise: linear, double, triple progression, time, with the reason shown
   for each target, and an automatic deload after a stall.
   Done: the pure engine (`LiftProgression`, StrandAnalytics), 56 scenarios checked against openGym's own
   `progression.js` (`Tools/lift_progression_oracle`); v50 storage (rule on `liftProgramItem`, the target and plan
   stamp on each `liftSet`), push on both sides, MCP (`get_progression_rules`, targets on `get_lift_sessions`);
   the adapter (`LiftProgressionStore`); the rule picker on a program line; the session starting from the rule's
   target, stamping its sets, and showing the reason under the exercise. A line with a rule is not rewritten
   from the heaviest set after a session.
   Not done: a rule for timed holds (a program line has no seconds field), bodyweight climbs (no flag on a line),
   Greyskull, steady, undulating, density, ladder, owned dumbbells, assistance machines. A tap to apply or
   ignore a suggestion, and showing the rule in the program's line summary.
3. Plate calculator per gym: plates, bars, dumbbells and machine stacks per gym, and the plates to load.
   Done: the plate maths (`LiftPlates`, 464 stacks and 528 loads checked against openGym's own `plates.js`, `bar.js`
   and `dumbbells.js`), v51 storage (`liftGym`, `liftSession.gymId`), push on both sides, MCP (`get_gyms`, a session
   names its gym), the gyms sheet (add, edit, delete, choose the one in use), the plate calculator, and the plate
   line under each set of a session (bar-loaded and sled exercises picked from the library).
   Not done: editing a machine's weight stack (stored, no screen), using owned dumbbells and stacks in progression
   (the engine takes no `owned` grid yet), a per-exercise choice of how it is loaded (only library exercises have
   an equipment word), and a unit-aware warm-up ramp.
4. Supersets, and a backup exercise that swaps in when a machine is taken (keeps the slot's sets and reps).
   Done: v52 storage (`supersetGroup` and `backupsJSON` on a program line; `supersetGroup` and `swappedFrom` on each
   set), push on both sides, MCP (`get_programs`, sets name their superset and swap); the engine runs a superset as a
   round (one set of each in turn, no rest inside the round, the longest member's rest after it, an out-of-order
   start goes to the other member's same set); a backup takes a line's place while nothing is recorded for it (sets,
   reps and rest stay, the weight and the progression rule go, the replaced exercise goes to the front of the
   backups, nothing is written back to the program line); linking lines in the program editor, backups in the line
   editor, the superset label and swap menu in the session.
   Not done: swapping a line that already has sets logged (openGym inserts the replacement beside it after a
   confirmation), a swap to any exercise rather than a listed backup, a backup with its own plan, a superset's own
   rest and circuit mode, moving a member inside a running superset.
5. Body map: volume per muscle, muscles still recovering, muscles left untrained (MuscleMap geometry, MIT).
   Done: the recovery model (`LiftRecovery`, openGym's `recovery.js`: per-muscle half-lives, RIR estimated from the
   90-day best, acute:chronic gain, saturation, retained strength) checked against openGym's own code over 87
   histories; the adapter and shading (`LiftMuscleMap`: weekly sets, fatigue, retained strength, last trained, never
   trained); the body outlines (MuscleMap, MIT, converted by `Tools/body_geometry/convert.py`, read by `SVGPathData`);
   the screen (front and back, three modes, tap a muscle, lists of what is recovering, left alone, never trained).
   Not done: sport outside the gym and cardio as stimulus (openGym's `activities`), per-side sets, bodyweight load in
   the RIR estimate, serratus, hip flexors and shins (NOOP has no such muscle: drawn, never shaded), a muscle
   target per person.
6. Strength balance ratios between lifts, and lifts as a percentage of body weight.
   Done: the engine and the three tables (Poliquin, Thibaudeau, ATG) ported from openGym (`LiftBalance`,
   `LiftBalanceTemplates`, generated from openGym's file) and checked against openGym's own `computeBalance` over 76
   histories; the adapter (`LiftBalanceStore`: sets with a catalogue link, body weight from the profile, sex for the
   female targets); the screen (a table picker, each lift's reading, status, target, and what is missing: a weigh-in, or
   the anchor). Stated on screen: reference ratios, never a norm.
   Not done: choosing a different exercise for a role (the engine supports overrides, no picker), a per-side lift, pounds
   histories (NOOP stores kilograms), and a trend over time.
7. A fuller rest timer, and a rotation of sessions (A, B, C) as an alternative to weekdays.

New stored data from these (gyms, progression rules, supersets, backups, rotation) gets its own tables or
columns, a migration with tests, registry entries on both push sides, and MCP read tools.

## Verification

- Swift packages: `swift test` for pure logic. Python: `pytest` in `selfhost/`. Oracle tests for every ported formula: run
  openGym's own pure functions under Node to produce expected values, and paste them as the Swift test literals.
- App targets cannot be compiled in the cloud environment: open PRs so `app-build.yml` compiles `Strand` and `NOOPiOS` and
  runs `StrandTests`, and build locally with `xcodebuild` before merging.
- Device checks (not CI-able): scrolling smoothness, memory in Instruments, a real session end to end, and that the session
  reaches the server (`get_stream_range` on `liftSession` / `liftSet`).

## Risks

- Muscle vocabulary change is a stored-data contract change: needs a migration, and breaks parity with the Android app.
- Image weight versus sideloaded IPA size.
- Breaking the `.noopbak` backup whitelist and the Hevy/program importers when tables change.
- Redesign scope creep: mitigated by the metric inventory and one-screen-per-PR.
- Image source provenance. openGym code may be ported under the MIT grant; its media and unconfirmed catalogue text may not.
