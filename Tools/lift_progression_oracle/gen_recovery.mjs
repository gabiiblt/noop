import { fatigueOf, strengthOf } from './lib/recovery.js'
import { ASSISTED } from './lib/exercises.js'
ASSISTED.add('dip').add('assistedpullup')
import fs from 'node:fs'

const DAY = 86400000, HOUR = 3600000, NOW = 1_800_000_000_000
// LiftMuscle case <-> openGym slug (the muscles both models have)
const MAP = [['chest','chest'],['frontDelts','front-delts'],['sideDelts','side-delts'],['rearDelts','rear-delts'],['triceps','triceps'],
  ['lats','lats'],['upperBack','upper-back'],['traps','trapezius'],['biceps','biceps'],['forearms','forearm'],['quads','quadriceps'],
  ['hamstrings','hamstring'],['glutes','gluteal'],['adductors','adductors'],['calves','calves'],['abs','abs'],['obliques','obliques'],['lowerBack','lower-back']]
const slugOf = Object.fromEntries(MAP.map(([m, s]) => [m, s]))
const BENCH = { chest: 1, frontDelts: 0.4, triceps: 0.4 }
const SQUAT = { quads: 1, glutes: 0.4, hamstrings: 0.4, lowerBack: 0.4 }
const ROW = { lats: 1, upperBack: 0.4, biceps: 0.4, rearDelts: 0.4 }
const CURL = { biceps: 1, forearms: 0.4 }

// set: { w, r, done=true, warm, rir, rpe, fail, drops:[[w,r]] }
const S = (w, r, o = {}) => ({ w, r, done: true, ...o })
const sets = (n, w, r, o) => Array.from({ length: n }, () => S(w, r, o))
const E = (ex, weights, ss, o = {}) => ({ ex, weights, sets: ss, ...o })
const W = (ago, entries) => ({ start: NOW - ago, entries })

const scenarios = []
const add = (name, workouts, now = NOW) => scenarios.push({ name, workouts, now })

add('noHistory', [])
add('oneBenchSessionYesterday', [W(DAY, [E('bench', BENCH, sets(8, 80, 8))])])
add('benchThreeDaysAgo', [W(3 * DAY, [E('bench', BENCH, sets(8, 80, 8))])])
add('benchTwoHoursAgo', [W(2 * HOUR, [E('bench', BENCH, sets(8, 80, 8))])])
add('legsYesterdayRecoverSlower', [W(DAY, [E('squat', SQUAT, sets(8, 100, 5))])])
add('sessionCapAtTwelveSets', [W(DAY, [E('bench', BENCH, sets(20, 60, 10))])])
add('warmUpsCountAtTheFloor', [W(DAY, [E('bench', BENCH, sets(8, 40, 10, { warm: true }))])])
add('loggedRirWinsOverTheEstimate', [W(10 * DAY, [E('bench', BENCH, sets(3, 100, 5))]), W(DAY, [E('bench', BENCH, [S(80, 8, { rir: 0 }), S(80, 8, { rir: 2 }), S(80, 8, { rir: 4 }), S(80, 8, { rir: 7 })])])])
add('rpeReadsAsTenMinusRpe', [W(DAY, [E('bench', BENCH, [S(80, 8, { rpe: 10 }), S(80, 8, { rpe: 8 }), S(80, 8, { rpe: 5 }), S(80, 8, { rpe: 2 })])])])
add('failureReadsAsRirZero', [W(DAY, [E('curl', CURL, sets(6, 20, 10, { fail: true }))])])
add('estimatedRirFromTheNinetyDayBest', [W(40 * DAY, [E('bench', BENCH, [S(100, 5), S(100, 5)])]), W(DAY, [E('bench', BENCH, sets(6, 70, 10))])])
add('estimatedRirNeedsAnAnchor', [W(DAY, [E('bench', BENCH, sets(6, 70, 10))])])
add('anchorOlderThanNinetyDaysIsForgotten', [W(100 * DAY, [E('bench', BENCH, [S(140, 3)])]), W(DAY, [E('bench', BENCH, sets(6, 70, 10))])], NOW)
add('repsAboveTheCapAnchorNothing', [W(40 * DAY, [E('bench', BENCH, sets(3, 100, 20))]), W(DAY, [E('bench', BENCH, sets(6, 70, 10))])])
add('singleRepIsTheMeasurement', [W(30 * DAY, [E('bench', BENCH, [S(120, 1)])]), W(DAY, [E('bench', BENCH, sets(6, 100, 3))])])
add('dropSetDropsCountAsExtraSets', [W(DAY, [E('curl', CURL, [S(20, 10, { drops: [[15, 8], [10, 8]] }), S(20, 10)])])])
add('undoneSetsAreIgnored', [W(DAY, [E('bench', BENCH, [S(80, 8), S(80, 8, { done: false }), S(80, 8, { done: false })])])])
add('assistedWorkNeverAnchors', [W(30 * DAY, [E('dip', BENCH, [S(10, 8)], { assisted: true })]), W(DAY, [E('dip', BENCH, sets(6, 10, 10), { assisted: true })])])
add('maintainedWeeklyVolumeScoresAboutOne', Array.from({ length: 5 }, (_, i) => W((i * 7 + 1) * DAY, [E('bench', BENCH, sets(8, 80, 8))])))
add('aDeloadScoresLess', [...Array.from({ length: 4 }, (_, i) => W(((i + 1) * 7 + 1) * DAY, [E('bench', BENCH, sets(10, 80, 8))])), W(DAY, [E('bench', BENCH, sets(3, 60, 8))])])
add('aFirstSessionAfterAGapScoresMore', [W(60 * DAY, [E('bench', BENCH, sets(8, 80, 8))]), W(DAY, [E('bench', BENCH, sets(8, 80, 8))])])
add('daysApartCompoundAndFade', [W(3 * DAY, [E('bench', BENCH, sets(8, 80, 8))]), W(2 * DAY, [E('bench', BENCH, sets(8, 80, 8))]), W(DAY, [E('bench', BENCH, sets(8, 80, 8))])])
add('olderThanThirtyDaysOnlyInformsAnchors', [W(35 * DAY, [E('bench', BENCH, sets(8, 80, 8))])])
add('twoSessionsAtTheSameInstant', [W(DAY, [E('bench', BENCH, sets(4, 80, 8))]), W(DAY, [E('row', ROW, sets(4, 70, 8))])])
add('aSessionAfterNowStillCounts', [{ start: NOW + 2 * HOUR, entries: [E('bench', BENCH, sets(8, 80, 8))] }])
add('mixedFullBody', [W(DAY, [E('squat', SQUAT, sets(5, 100, 5)), E('bench', BENCH, sets(5, 80, 5)), E('row', ROW, sets(5, 70, 8)), E('curl', CURL, sets(3, 20, 12))]), W(4 * DAY, [E('bench', BENCH, sets(4, 80, 6))])])
add('unratedFloatRepsAndZeroWeight', [W(DAY, [E('plank', { abs: 1 }, [S(0, 30), S(0, 45)])])])

// seeded random histories
function rng(seed) { return () => { seed |= 0; seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296 } }
const EXS = [['assistedpullup', ROW], ['bench', BENCH], ['squat', SQUAT], ['row', ROW], ['curl', CURL], ['press', { frontDelts: 1, triceps: 0.4, chest: 0.4 }], ['deadlift', { hamstrings: 1, glutes: 0.4, lowerBack: 0.4, lats: 0.4 }]]
for (let k = 0; k < 60; k++) {
  const r = rng(1000 + k)
  const nw = 1 + Math.floor(r() * 12)
  const ws = []
  for (let i = 0; i < nw; i++) {
    const ago = Math.floor(r() * 130 * DAY / HOUR) * HOUR
    const ne = 1 + Math.floor(r() * 3)
    const entries = []
    for (let j = 0; j < ne; j++) {
      const [ex, weights] = EXS[Math.floor(r() * EXS.length)]
      const ns = 1 + Math.floor(r() * 7)
      const ss = []
      for (let q = 0; q < ns; q++) {
        const o = {}
        const u = r()
        if (u < 0.12) o.warm = true
        else if (u < 0.3) o.rir = Math.floor(r() * 8 * 2) / 2
        else if (u < 0.38) o.rpe = 5 + Math.floor(r() * 5 * 2) / 2
        else if (u < 0.45) o.fail = true
        if (r() < 0.08) o.done = false
        if (r() < 0.08) o.drops = [[Math.round(30 + r() * 40), 5 + Math.floor(r() * 8)]]
        ss.push(S(Math.round((20 + r() * 120) * 4) / 4, 1 + Math.floor(r() * 16), o))
      }
      entries.push(E(ex, weights, ss, ex === 'assistedpullup' ? { assisted: true } : {}))
    }
    ws.push(W(ago, entries))
  }
  add('random' + String(k).padStart(2, '0'), ws, NOW + Math.floor(r() * 3) * 12 * HOUR)
}

// ---- run the real engine ---------------------------------------------------------------------
const toJs = ws => ws.map(w => ({ start: w.start, entries: w.entries.map(e => ({ id: e.ex, weights: Object.fromEntries(Object.entries(e.weights).map(([m, v]) => [slugOf[m], v])),
  ...(e.assisted ? { assisted: true } : {}), sets: e.sets.map(s => ({ w: s.w, r: s.r, done: s.done, ...(s.warm ? { warmup: true } : {}), ...(s.rir != null ? { rir: s.rir } : {}),
    ...(s.rpe != null ? { rpe: s.rpe } : {}), ...(s.fail ? { failure: true } : {}), ...(s.drops ? { type: 'dropset', drops: s.drops.map(([w, r]) => ({ w, r })) } : {}) })) })) }))
const mapSet = s => ({ w: s.w, r: s.r, done: s.done, warm: !!s.warm, rir: s.rir ?? null, rpe: s.rpe ?? null, fail: !!s.fail, drops: (s.drops || []).map(([w, r]) => ({ w, r })) })
const mapEntry = e => ({ ex: e.ex, weights: e.weights, assisted: !!e.assisted, sets: e.sets.map(mapSet) })
const cases = scenarios.map(sc => {
  const f = fatigueOf(toJs(sc.workouts), sc.now)
  const st = strengthOf(toJs(sc.workouts), sc.now)
  return { name: sc.name, now: sc.now, sessions: sc.workouts.map(w => ({ ts: w.start, entries: w.entries.map(mapEntry) })),
    fatigue: Object.fromEntries(MAP.map(([m, sl]) => [m, f[sl]])), strength: Object.fromEntries(MAP.map(([m, sl]) => [m, st[sl]])) }
})
const swift = `import XCTest
import WhoopStore
@testable import StrandAnalytics

// GENERATED by running openGym's own \`frontend/src/lib/recovery.js\` (Duarte Santos, MIT authorization to Gabriel
// Bolatoglu; see ATTRIBUTION.md) over each history below under Node, then writing what \`fatigueOf\` and \`strengthOf\`
// returned as the expected values. ${cases.length} histories: ${cases.length - 60} named scenarios and 60 seeded random ones, covering logged
// RIR, RPE, failure, the 90-day anchor, drops, the per-session cap, the acute:chronic gain, assistance work and
// future-dated sessions. The muscles the two models share are compared (abductors and neck have no openGym twin:
// abductors take the glutes' half-life, as openGym folds them into the glutes).
//
// The data is JSON rather than Swift literals: ${cases.length} histories as nested literals is more than the type checker can swallow.
// To regenerate: Tools/lift_progression_oracle (see its README).
final class LiftRecoveryOracleTests: XCTestCase {

    private struct Case: Decodable {
        struct Drop: Decodable { var w: Double; var r: Int }
        struct SetJSON: Decodable { var w: Double; var r: Int; var done: Bool; var warm: Bool; var rir: Double?; var rpe: Double?; var fail: Bool; var drops: [Drop] }
        struct EntryJSON: Decodable { var ex: String; var weights: [String: Double]; var assisted: Bool; var sets: [SetJSON] }
        struct SessionJSON: Decodable { var ts: Double; var entries: [EntryJSON] }
        var name: String
        var now: Double
        var sessions: [SessionJSON]
        var fatigue: [String: Double]
        var strength: [String: Double]

        var model: [LiftRecoverySession] {
            sessions.map { s in
                LiftRecoverySession(timestamp: s.ts, entries: s.entries.map { e in
                    LiftRecoveryEntry(exercise: e.ex,
                                      weights: Dictionary(uniqueKeysWithValues: e.weights.map { (LiftMuscle(rawValue: $0.key)!, $0.value) }),
                                      isAssisted: e.assisted,
                                      sets: e.sets.map { x in
                        LiftRecoverySet(weightKg: x.w, reps: x.r, done: x.done, isWarmup: x.warm, rir: x.rir, rpe: x.rpe,
                                        isFailure: x.fail, drops: x.drops.map { .init(weightKg: $0.w, reps: $0.r) })
                    })
                })
            }
        }
    }

    func testFatigueAndStrengthAgreeWithOpenGym() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(Self.json.utf8))
        XCTAssertEqual(cases.count, ${cases.length})
        for c in cases {
            let sessions = c.model
            let f = LiftRecovery.fatigue(sessions, now: c.now)
            let s = LiftRecovery.strength(sessions, now: c.now)
            for (muscle, expected) in c.fatigue { XCTAssertEqual(f[LiftMuscle(rawValue: muscle)!] ?? -1, expected, accuracy: 1e-9, "fatigue \\(c.name) \\(muscle)") }
            for (muscle, expected) in c.strength { XCTAssertEqual(s[LiftMuscle(rawValue: muscle)!] ?? -1, expected, accuracy: 1e-9, "strength \\(c.name) \\(muscle)") }
        }
    }

    private static let json = #"""
${JSON.stringify(cases)}
"""#
}
`
fs.writeFileSync('LiftRecoveryOracleTests.swift', swift)
console.log(cases.length, 'histories', Math.round(swift.length / 1024), 'KB')
