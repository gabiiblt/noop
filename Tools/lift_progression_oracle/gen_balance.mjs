import { computeBalance } from './lib/structuralBalance.js'
import { TEMPLATE_LIST, EVALUATION_MODES } from './lib/structuralBalanceTemplates.js'
import { EXIDX } from './lib/exercises.js'
import fs from 'node:fs'

// ---- the exercises the templates name (id -> name + equipment), plus the ones the scenarios add -------------------
const EX = {
  '0030': ['close grip bench press', 'barbell'], '1719': ['incline close grip bench press', 'barbell'], '0047': ['incline bench press', 'barbell'],
  '0251': ['chest dip', 'body weight'], '0652': ['pull-up', 'body weight'], '0841': ['weighted pull-up', 'weighted'], '0031': ['barbell curl', 'barbell'],
  '1436': ['high bar squat', 'barbell'], '0043': ['full squat', 'barbell'], '0042': ['front squat', 'barbell'], '0032': ['deadlift', 'barbell'],
  '0648': ['power clean', 'barbell'], '0025': ['bench press', 'barbell'], '0091': ['military press', 'barbell'], '1456': ['standing military press', 'barbell'],
  '1457': ['seated military press', 'barbell'], '0086': ['overhead press', 'barbell'], '0085': ['romanian deadlift', 'barbell'], '0090': ['seated good morning', 'barbell'],
  '0114': ['step up', 'barbell'], '0431': ['dumbbell step up', 'dumbbell'], '3193': ['glute-ham raise', 'body weight'], '0314': ['incline dumbbell press', 'dumbbell'],
  '3545': ['incline dumbbell bench press', 'dumbbell'], '0405': ['dumbbell shoulder press', 'dumbbell'], '0404': ['seated dumbbell shoulder press', 'dumbbell'],
  '0361': ['dumbbell press', 'dumbbell'], '0360': ['standing dumbbell press', 'dumbbell'],
  // not named by a template: assistance, belt movements and the bench dip the rule excludes
  'asspull': ['assisted pull-up', 'leverage machine'], 'wdip': ['weighted straight bar dip', 'weighted'], 'wbenchdip': ['weighted bench dip', 'weighted'],
  'wtricepdips': ['weighted tricep dips', 'weighted'], '1755': ['weighted tricep dips', 'weighted'], 'wcrunch': ['weighted crunch', 'weighted'],
  'bandcurl': ['assisted band leg curl', 'band'],
}
for (const [id, [n, eq]] of Object.entries(EX)) EXIDX[id] = { id, n, eq }

const BW_MODE = EVALUATION_MODES
const KG = 'kg'
// set: [w, r, flags]  flags: done=false -> u, warm -> w
const W = (day, entries, bw) => ({ d: `2026-01-${String(day).padStart(2, '0')}`, start: Date.UTC(2026, 0, day, 10) , ...(bw ? { bw } : {}), entries })
const E = (id, sets) => ({ id, sets: sets.map(([w, r, f = '']) => ({ w, r, done: !f.includes('u'), ...(f.includes('w') ? { warmup: true } : {}) })) })

const scenarios = []
const add = (name, S) => scenarios.push({ name, S: { unit: KG, ...S } })
const HISTORY = {
  powerlifter: [W(1, [E('0043', [[140, 5]]), E('0025', [[100, 5]]), E('0032', [[180, 3]])]), W(8, [E('0030', [[90, 5]]), E('0047', [[80, 5]]), E('0252', [[1, 1]])])],
}
add('noData', { workouts: [], bodyweight: [] })
add('thibaudeauFromSquat', { workouts: [W(1, [E('0043', [[140, 5], [100, 8, 'w']]), E('0025', [[100, 5]]), E('0032', [[170, 3]]), E('0091', [[60, 5]])])], bodyweight: [] })
add('poliquinAnchorsAndRatios', { workouts: [W(1, [E('0030', [[100, 5]]), E('0047', [[85, 5]]), E('0031', [[40, 8]]), E('1436', [[140, 5]]), E('0042', [[110, 5]]), E('0032', [[170, 5]]), E('0648', [[80, 3]])])], bodyweight: [{ d: '2026-01-01', w: 80 }] })
add('anchorMissingMeansNeedsAnchor', { workouts: [W(1, [E('0047', [[85, 5]]), E('0032', [[170, 5]])])], bodyweight: [] })
add('atgBodyweightRatios', { workouts: [W(1, [E('0085', [[85, 12]]), E('0090', [[50, 10]]), E('0114', [[45, 15]]), E('0314', [[28, 8]]), E('0405', [[20, 8]])])], bodyweight: [{ d: '2026-01-01', w: 80 }] })
add('atgNeedsABodyweight', { workouts: [W(1, [E('0085', [[85, 12]])])], bodyweight: [] })
add('atgFemaleTargets', { female: true, workouts: [W(1, [E('0085', [[70, 12]]), E('0090', [[36, 10]]), E('0314', [[18, 8]])])], bodyweight: [{ d: '2026-01-01', w: 65 }] })
add('shorterSetIsCarriedToTheRepTarget', { workouts: [W(1, [E('0085', [[100, 5]])])], bodyweight: [{ d: '2026-01-01', w: 80 }] })
add('repCountRoles', { workouts: [W(1, [E('0652', [[0, 8], [0, 11]]), E('0251', [[0, 10]]), E('3193', [[0, 1]])])], bodyweight: [] })
add('repCountIgnoresAssistance', { workouts: [W(1, [E('asspull', [[30, 12]])])], bodyweight: [{ d: '2026-01-01', w: 80 }], balanceOverrides: { 'atg:pullups': 'asspull' } })
add('chestDipsLoadTheLifter', { workouts: [W(1, [E('0030', [[100, 5]]), E('0251', [[20, 5]])])], bodyweight: [{ d: '2026-01-01', w: 80 }] })
add('dipsWithoutAWeighIn', { workouts: [W(1, [E('0030', [[100, 5]]), E('0251', [[20, 5]])])], bodyweight: [] })
add('aSessionStampedWithItsOwnBodyweight', { workouts: [W(1, [E('0030', [[100, 5]]), E('0251', [[20, 5]])], 90)], bodyweight: [{ d: '2026-01-01', w: 70 }] })
add('assistedPullUpSubtractsTheHelp', { workouts: [W(1, [E('0030', [[100, 5]]), E('asspull', [[20, 8]])])], bodyweight: [{ d: '2026-01-01', w: 80 }], balanceOverrides: { 'poliquin:supinePullups': 'asspull' } })
add('assistedWithNoHelpEnteredIsUnscored', { workouts: [W(1, [E('0030', [[100, 5]]), E('asspull', [[0, 8]])])], bodyweight: [{ d: '2026-01-01', w: 80 }], balanceOverrides: { 'poliquin:supinePullups': 'asspull' } })
add('aBeltDipIsOnTheLifter', { workouts: [W(1, [E('0030', [[100, 5]]), E('wdip', [[30, 5]])])], bodyweight: [{ d: '2026-01-01', w: 80 }], balanceOverrides: { 'poliquin:dips': 'wdip' } })
add('aBenchDipIsNotOnTheLifter', { workouts: [W(1, [E('0030', [[100, 5]]), E('wbenchdip', [[30, 5]])])], bodyweight: [{ d: '2026-01-01', w: 80 }], balanceOverrides: { 'poliquin:dips': 'wbenchdip' } })
add('theNamedBenchDipIdIsExcludedToo', { workouts: [W(1, [E('0030', [[100, 5]]), E('1755', [[30, 5]])])], bodyweight: [{ d: '2026-01-01', w: 80 }], balanceOverrides: { 'poliquin:dips': '1755' } })
add('overrideOfTheDefaultIsNotCustom', { workouts: [W(1, [E('0030', [[100, 5]]), E('1719', [[110, 5]])])], bodyweight: [], balanceOverrides: { 'poliquin:narrowBench': '0030' } })
add('overrideToAnotherExercise', { workouts: [W(1, [E('0030', [[100, 5]]), E('0025', [[120, 5]])])], bodyweight: [], balanceOverrides: { 'poliquin:narrowBench': '0025' } })
add('repsAboveTheCapAreNoOneRm', { workouts: [W(1, [E('0030', [[60, 20]])])], bodyweight: [] })
add('warmUpsAndUndoneSetsAreIgnored', { workouts: [W(1, [E('0030', [[120, 5, 'w'], [110, 5, 'u'], [100, 5]])])], bodyweight: [] })
add('theBestSetAcrossSessionsWins', { workouts: [W(1, [E('0030', [[100, 5]])]), W(8, [E('0030', [[105, 5]])]), W(15, [E('0030', [[95, 5]])])], bodyweight: [] })
add('aSingleIsItsOwnMax', { workouts: [W(1, [E('0030', [[130, 1]])])], bodyweight: [] })
add('borderlineBand', { workouts: [W(1, [E('0030', [[100, 5]]), E('0047', [[88, 5]]), E('0031', [[37, 5]])])], bodyweight: [] })
add('theLatestWeighInWins', { workouts: [W(1, [E('0085', [[85, 12]])])], bodyweight: [{ d: '2026-01-20', w: 90 }, { d: '2026-01-02', w: 70 }] })

function rng(seed) { return () => { seed |= 0; seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296 } }
const POOL = Object.keys(EX)
for (let k = 0; k < 50; k++) {
  const r = rng(7000 + k)
  const nw = 1 + Math.floor(r() * 6)
  const workouts = []
  for (let i = 0; i < nw; i++) {
    const ne = 1 + Math.floor(r() * 5)
    const entries = []
    for (let j = 0; j < ne; j++) {
      const id = POOL[Math.floor(r() * POOL.length)]
      const ns = 1 + Math.floor(r() * 4)
      const sets = []
      for (let q = 0; q < ns; q++) sets.push([Math.round((r() * 160) * 4) / 4, 1 + Math.floor(r() * 16), r() < 0.1 ? 'w' : r() < 0.1 ? 'u' : ''])
      entries.push(E(id, sets))
    }
    workouts.push(W(1 + i * 3, entries, r() < 0.2 ? 60 + Math.floor(r() * 40) : undefined))
  }
  const bodyweight = r() < 0.7 ? [{ d: '2026-01-01', w: 55 + Math.floor(r() * 50) }] : []
  const overrides = {}
  if (r() < 0.3) overrides['poliquin:dips'] = POOL[Math.floor(r() * POOL.length)]
  if (r() < 0.3) overrides['atg:pullups'] = POOL[Math.floor(r() * POOL.length)]
  add('random' + String(k).padStart(2, '0'), { workouts, bodyweight, female: r() < 0.4, balanceOverrides: overrides })
}

// ---- run the real engine ------------------------------------------------------------------------
const cases = scenarios.map(sc => {
  const S = { ...sc.S, body: sc.S.female ? 'female' : 'male' }
  const results = {}
  for (const t of TEMPLATE_LIST) results[t.id] = computeBalance(S, t)
  return { name: sc.name, female: !!sc.S.female, bodyweight: sc.S.bodyweight, overrides: sc.S.balanceOverrides || {},
    workouts: sc.S.workouts.map(w => ({ ts: w.start, d: w.d, bw: w.bw ?? null, entries: w.entries.map(e => ({ id: e.id, sets: e.sets.map(s => ({ w: s.w, r: s.r, done: s.done, warm: !!s.warmup })) })) })),
    results }
})
const exercises = Object.fromEntries(Object.entries(EX).map(([id, [n, eq]]) => [id, { name: n, equipment: eq }]))

// ---- the templates as Swift data ----------------------------------------------------------------
const q = s => JSON.stringify(s)
const optN = v => (v == null ? 'nil' : String(v))
const modeSwift = m => ({ [BW_MODE.LOAD_RATIO]: '.loadRatio', [BW_MODE.BODYWEIGHT_RATIO]: '.bodyweightRatio', [BW_MODE.REP_COUNT]: '.repCount' }[m])
const tplSwift = `import Foundation

// GENERATED from openGym's \`frontend/src/lib/structuralBalanceTemplates.js\` (Duarte Santos, MIT authorization to Gabriel
// Bolatoglu; see ATTRIBUTION.md) by Tools/lift_progression_oracle/gen_balance.mjs. Do not edit by hand.
//
// The ratio tables themselves are Poliquin's, Thibaudeau's and ATG's, as transcribed by openGym from
// https://anticulturista.substack.com/p/30-equilibrio-estructural-tu-proximo. They are reference ratios from coaching
// literature, not norms for any person. Exercise ids are the bundled catalogue's (openGym's).

extension LiftBalanceTemplate {
    static let all: [LiftBalanceTemplate] = [
${TEMPLATE_LIST.map(t => `        LiftBalanceTemplate(id: ${q(t.id)}, label: ${q(t.label)}, roles: [
${t.roles.map(r => `            LiftBalanceRole(id: ${q(r.id)}, label: ${q(r.label)}, mode: ${modeSwift(r.evaluationMode)}, exerciseIds: [${r.exerciseIds.map(q).join(', ')}], anchorRoleId: ${r.anchorRoleId ? q(r.anchorRoleId) : 'nil'}, targetPct: ${optN(r.targetPct)}, targetPctFemale: ${optN(r.targetPctFemale)}, reps: ${optN(r.reps)}, repsTarget: ${optN(r.repsTarget)}, repsTargetFemale: ${optN(r.repsTargetFemale)}),`).join('\n')}
        ]),`).join('\n')}
    ]
}
`
fs.writeFileSync('LiftBalanceTemplates.swift', tplSwift)

const nz = v => (v === undefined ? null : v)
const outCases = cases.map(c => ({ ...c, results: Object.fromEntries(Object.entries(c.results).map(([tid, rs]) => [tid, rs.map(r => ({
  roleId: r.roleId, configured: r.configuredExerciseId, targetPct: r.targetPct, isOverridden: r.isOverridden, mapped: r.mappedExerciseId,
  actualPct: nz(r.actualPct), status: r.status, needsBodyweight: r.needsBodyweight, needsAnchor: r.needsAnchor,
  est: nz(r.current?.estKg), repsKg: nz(r.current?.repsKg), reps: nz(r.current?.r), w: nz(r.current?.w), ts: nz(r.current?.t) }))])) }))
const swift = `import XCTest
@testable import StrandAnalytics

// GENERATED by running openGym's own \`frontend/src/lib/structuralBalance.js\` (Duarte Santos, MIT authorization to Gabriel
// Bolatoglu; see ATTRIBUTION.md) over each history below under Node, for all three ratio tables, then writing what
// \`computeBalance\` returned as the expected values. ${outCases.length} histories: ${outCases.length - 50} named and 50 seeded random ones covering
// anchors, bodyweight ratios, rep counts, assistance work, belt movements, the bench-dip exclusion, overrides,
// stamped body weights and female targets. JSON, not Swift literals, for the type checker's sake.
//
// To regenerate: Tools/lift_progression_oracle (see its README).
final class LiftBalanceOracleTests: XCTestCase {

    private struct Case: Decodable {
        struct SetJSON: Decodable { var w: Double; var r: Int; var done: Bool; var warm: Bool }
        struct EntryJSON: Decodable { var id: String; var sets: [SetJSON] }
        struct WorkoutJSON: Decodable { var ts: Double; var bw: Double?; var entries: [EntryJSON] }
        struct WeighIn: Decodable { var d: String; var w: Double }
        struct ResultJSON: Decodable {
            var roleId: String; var configured: String?; var targetPct: Double; var isOverridden: Bool; var mapped: String?
            var actualPct: Double?; var status: String; var needsBodyweight: Bool; var needsAnchor: Bool
            var est: Double?; var repsKg: Double?; var reps: Int?; var w: Double?; var ts: Double?
        }
        var name: String
        var female: Bool
        var bodyweight: [WeighIn]
        var overrides: [String: String]
        var workouts: [WorkoutJSON]
        var results: [String: [ResultJSON]]
    }

    private struct Exercise: Decodable { var name: String; var equipment: String }

    func testBalanceAgreesWithOpenGym() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(Self.casesJSON.utf8))
        let table = try JSONDecoder().decode([String: Exercise].self, from: Data(Self.exercisesJSON.utf8))
        let exercises = table.mapValues { LiftBalanceExercise(name: $0.name, equipment: $0.equipment) }
        XCTAssertEqual(cases.count, ${outCases.length})
        for c in cases {
            // The latest weigh-in (by date string), as openGym reads it.
            let latest = c.bodyweight.sorted { $0.d < $1.d }.last
            let sessions = c.workouts.enumerated().map { i, w in
                LiftBalanceSession(timestamp: w.ts, bodyweightKg: w.bw, entries: w.entries.map { e in
                    LiftBalanceEntry(exerciseId: e.id, sets: e.sets.map { LiftBalanceSet(weightKg: $0.w, reps: $0.r, done: $0.done, isWarmup: $0.warm) })
                })
            }
            let input = LiftBalanceInput(sessions: sessions, bodyweightKg: latest.flatMap { $0.w > 0 ? $0.w : nil }, female: c.female,
                                         overrides: c.overrides, exercises: exercises)
            for template in LiftBalanceTemplate.all {
                let got = LiftBalance.compute(template, input)
                let want = try XCTUnwrap(c.results[template.id], "\\(c.name) \\(template.id)")
                XCTAssertEqual(got.count, want.count, "\\(c.name) \\(template.id)")
                for (g, w) in zip(got, want) {
                    let label = "\\(c.name) \\(template.id) \\(w.roleId)"
                    XCTAssertEqual(g.roleId, w.roleId, label)
                    XCTAssertEqual(g.configuredExerciseId, w.configured, label)
                    XCTAssertEqual(g.targetPct, w.targetPct, accuracy: 1e-9, label)
                    XCTAssertEqual(g.isOverridden, w.isOverridden, label)
                    XCTAssertEqual(g.mappedExerciseId, w.mapped, label)
                    XCTAssertEqual(g.status.rawValue, w.status, label)
                    XCTAssertEqual(g.needsBodyweight, w.needsBodyweight, label)
                    XCTAssertEqual(g.needsAnchor, w.needsAnchor, label)
                    XCTAssertEqual(g.actualPct == nil, w.actualPct == nil, "actualPct presence \\(label)")
                    if let a = g.actualPct, let b = w.actualPct { XCTAssertEqual(a, b, accuracy: 1e-9, "actualPct \\(label)") }
                    XCTAssertEqual(g.current?.estKg == nil, w.est == nil, "estKg presence \\(label)")
                    if let a = g.current?.estKg, let b = w.est { XCTAssertEqual(a, b, accuracy: 1e-9, "estKg \\(label)") }
                    XCTAssertEqual(g.current?.repsKg == nil, w.repsKg == nil, "repsKg presence \\(label)")
                    if let a = g.current?.repsKg, let b = w.repsKg { XCTAssertEqual(a, b, accuracy: 1e-9, "repsKg \\(label)") }
                    XCTAssertEqual(g.current?.reps, w.reps, "reps \\(label)")
                    XCTAssertEqual(g.current?.weightKg ?? nil, w.w, "w \\(label)")
                }
            }
        }
    }

    private static let exercisesJSON = #"""
${JSON.stringify(exercises)}
"""#

    private static let casesJSON = #"""
${JSON.stringify(outCases)}
"""#
}
`
fs.writeFileSync('LiftBalanceOracleTests.swift', swift)
console.log(outCases.length, 'cases', Math.round(swift.length / 1024), 'KB')
const c = outCases[2]; console.log(JSON.stringify(c.results.poliquin.slice(0, 3)))
