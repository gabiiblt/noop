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
to embed; it is a reference for **behaviour and data shape**.

Behaviour worth reproducing (re-implemented, not copied):

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

## Licensing constraints (decisive)

| Asset | Licence | Consequence for NOOP (PolyForm Noncommercial 1.0.0) |
|---|---|---|
| openGym code | AGPL-3.0, author Duarte Santos | **No code copied.** AGPL is incompatible with NOOP's licence. Ideas, behaviour and algorithms are free; implementation is clean-room. Permission from the author (his CLA lets him relicense) is the only way to reuse code. |
| 13,109 media files in `catalogue/media` | Gym visual, proprietary | **Cannot be used in NOOP.** The notice forbids reuse in independent apps, extraction, and any AI use. |
| Exercise text, 1,324 `textSource: exercisedb` entries | MIT (ExerciseDB v1 via hasaneyldrm) | Usable with the MIT notice. |
| Other exercise text, muscle-map data, translations | AGPL | Not usable. |
| MuscleMap body geometry | MIT | Usable with notice (only if we want a body map). |

**Image and database source:** `yuhonas/free-exercise-db` is Unlicense (public domain), 876 exercises, two JPG stills each
(about 105 MB raw), with name, level, mechanic, equipment, primary/secondary muscles and instructions. Its image provenance
is declared by the repository, not verified by us. Fallback for anything missing: user-supplied photos on custom exercises.
Decision needed before phase 3.

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

Every field below needs, in the same change: a GRDB migration + test, the Android Room twin (parity contract),
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

0. **Decisions** (no code): image/catalogue source, Android parity timing, the keep-list of metrics (below).
1. **Performance baseline.** Instruments (Time Profiler, Allocations, Hitches) on a device with a realistic database;
   MetricKit is already wired. Set budgets: cold launch, steady memory, no dropped frames while scrolling Today, Trends and
   the exercise list. Fix measured hot spots only (candidates: the multi-minute re-score pass, large single-file views that
   already break the type checker, unbounded in-memory series, full-size images). One concern per PR.
2. **Metric inventory.** A checklist of every metric and control on every screen, generated from the code, so the redesign
   cannot silently drop one. Each redesigned screen is ticked against it.
3. **Training data foundation.** Migrations, the catalogue import (free-exercise-db, mapped to NOOP muscles, ids permanent),
   the media pipeline (downsample to WebP, lazy load, disk cache, size measured against the sideload IPA limit), tests.
4. **Training UI.** Exercise library (search, muscle filter, equipment filter, image), session screen (set types, rest timer,
   supersets, PR detection), workout detail with real stats (volume, sets, reps, PRs, 1RM, muscle split, heart-rate zones,
   duration, rest), history with edit, progress per exercise, records.
5. **Self-host push and MCP** for everything added in 3 and 4 (kept in step with each PR, not left to the end).
6. **App-wide "unslop" pass**, screen by screen, tokens only (design system is law), checked against the inventory.
7. **Android parity** for data, push and logic (UI parity is feature-level).

## Verification

- Swift packages: `swift test` for pure logic. Python: `pytest` in `selfhost/`. Oracle tests for any shared formula.
- App targets cannot be compiled in the cloud environment: open PRs so `app-build.yml` compiles `Strand` and `NOOPiOS` and
  runs `StrandTests`, and build locally with `xcodebuild` before merging.
- Device checks (not CI-able): scrolling smoothness, memory in Instruments, a real session end to end, and that the session
  reaches the server (`get_stream_range` on `liftSession` / `liftSet`).

## Risks

- Muscle vocabulary change is a stored-data contract change: needs a migration and Android twin.
- Image weight versus sideloaded IPA size.
- Breaking the `.noopbak` backup whitelist and the Hevy/program importers when tables change.
- Redesign scope creep: mitigated by the metric inventory and one-screen-per-PR.
- Image source provenance and the AGPL boundary: stay clean-room; never paste openGym code or media.
