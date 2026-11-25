# Performance baseline (phase 1 of the training redesign plan)

Goal: measure before optimising. Nothing in this file changes the app. The output is a table of numbers from a real
iPhone, which tells us which screens to fix and what "fast" means for the rest of the work.

## What the code already tells us (candidates, not conclusions)

Static scan of the iOS target, no measurement yet:

- `LiveState` publishes 65 properties and is observed through `@EnvironmentObject` / `@ObservedObject` in about 73 places.
  A change to any one `@Published` value invalidates every observing view. Heart rate arrives about once a second, so a
  large observer such as `TodayView` (about 6,000 lines) or `LiquidTodayView` (about 3,200) may re-evaluate its whole body
  every second. This is the first thing to confirm or rule out.
- Existing mitigations to keep: the strap log publish is coalesced (`publishCoalesceSeconds`), buffers are capped
  (`maxLogLines` 5,000, `maxSleepReadoutSamples` 2,000, `maxBatterySamples` 400), and `FrameRouter` already avoids
  `objectWillChange` for some frames.
- 29 `TimelineView` and 7 `Timer.publish` uses: each is a recurring redraw to account for.
- `ForEach` appears 189 times against 33 `LazyVStack`: long lists inside a plain `VStack` build every row up front.
- Very large single files (`BLEManager` 7,677 lines, `TodayView` 5,998, `IntelligenceEngine` 3,604, `Repository` 3,540):
  hard to reason about, and known to stress the type checker.
- No `os_signpost` and no `_printChanges` anywhere, and no scoring or screen-load timings recorded.

## Budgets to hold ourselves to (adjust after the first measurement)

| Measure | Target |
|---|---|
| Cold launch to an interactive Today | under 2 s on the test iPhone |
| Steady memory after 10 minutes of normal use | stable, no growth between minute 5 and minute 10 |
| Peak memory | under 250 MB |
| Scrolling (Today, Trends, Sleep, exercise list) | no hitch over 16 ms on a 60 Hz display, none over 8 ms on ProMotion |
| Idle CPU with the app open and the strap streaming | under 5 % average |
| `SwiftUI` body re-evaluations of Today per second while heart rate streams | at most 1, and only for views showing heart rate |

## How to capture (Xcode, iPhone connected by cable, Release-like build)

1. Scheme `NOOPiOS`, destination your iPhone. Edit Scheme, Run, Build Configuration **Release** (Debug builds are slower and
   distort every number). Product, **Profile** (Cmd-I).
2. Use a database with real history (your own phone), the strap connected and worn, and Low Power Mode off.
3. For each scenario below, record 60 to 90 seconds with the named template, then note the numbers.

| # | Scenario | Template | What to read |
|---|---|---|---|
| A | Kill the app, launch it, wait for Today to settle | **App Launch** | time to first frame, time to Today populated |
| B | Stay on Today for 2 minutes with the strap streaming, no touch | **SwiftUI** (View Body, View Properties) + **Time Profiler** | body re-evaluations per second per view, top 10 hot functions |
| C | Scroll Today, Trends, Sleep, Workouts end to end, twice | **Animation Hitches** | hitch count and worst hitch per screen |
| D | Use the app normally for 10 minutes, then leave it open | **Allocations** + **Leaks** | memory curve (flat or climbing), persistent allocation by type, leaks |
| E | Open Lift Log, start a session, log 3 sets, finish | **Time Profiler** + **Hitches** | time to open, hitches while logging, memory after closing |
| F | Background the app for 5 minutes with the strap connected, return | **Energy Log** or **Activity Monitor** | CPU while backgrounded, wake-ups |

## What to send back

For each scenario: the screenshot of the main track and the numbers (launch time, worst hitch, memory at start and end,
top 5 symbols by weight, the views with the most body evaluations in B). The `.trace` file itself is large; a screenshot of
the summary is enough, and I will ask for a deeper export only where a number looks wrong.

## After the baseline

Fix only what is measured, one concern per pull request, each with a before and after number from the same scenario.
Likely first suspects, in order: how `LiveState` is observed (split it, or have views read narrow slices), unbounded work in
list screens, and image decoding for the exercise library once it exists.
