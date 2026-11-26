import { nextPrescription } from './lib/progression.js'
import fs from 'node:fs'

// ---- scenario builders -------------------------------------------------------------------------
const st = (rows, o = {}) => ({ // rows: [w, r, done?] ; time rows: [w, sec]
  sets: rows.map(x => o.time ? ({ w: x[0], sec: x[1], r: 0, done: x[2] !== false }) : ({ w: x[0], r: x[1], done: x[2] !== false })),
  ...(o.target ? { target: o.target } : {}), ...(o.planned ? { planned: o.planned } : {}), ...(o.excluded ? { excluded: true } : {}), ...(o.time ? { time: true } : {})
})
const rep = (w, rs, o) => st(rs.map(r => [w, r]), o)
const T = (sets, reps, weight, extra = {}) => ({ sets, reps, weight, ...extra })
const L = (extra = {}) => ({ policy: 'linear', sets: 3, reps: 5, weightKg: 60, incKg: 2.5, ...extra })
const D = (extra = {}) => ({ policy: 'double', sets: 3, reps: 12, repsMin: 8, weightKg: 40, incKg: 2.5, ...extra })
const R = (extra = {}) => ({ policy: 'triple', sets: 3, setsMax: 5, reps: 12, repsMin: 8, weightKg: 40, incKg: 2.5, ...extra })
const TM = (extra = {}) => ({ policy: 'time', mode: 'time', sets: 3, sec: 30, incKg: 5, ...extra })
const BW = (extra = {}) => ({ policy: 'linear', sets: 3, reps: 8, bodyweight: true, incKg: 2.5, ...extra })

const scenarios = []
const add = (name, cfg, sessions) => scenarios.push({ name, cfg, sessions })

// -- off / first
add('offKeepsTheTargets', { ...L(), policy: 'off' }, [rep(60, [5, 5, 5], { target: T(3, 5, 60) })])
add('firstLinear', L(), [])
add('firstDouble', D(), [])
add('firstTriple', R(), [])
add('policyOutsideTheModeIsOff', { ...L(), policy: 'time' }, [rep(60, [5, 5, 5], { target: T(3, 5, 60) })])
// -- linear
add('linearCleanSessionAddsAStep', L(), [rep(60, [5, 5, 5], { target: T(3, 5, 60) })])
add('linearOneMissHoldsWithThreeToGo', L(), [rep(60, [5, 5, 4], { target: T(3, 5, 60) })])
add('linearTwoMissesHold', L(), [rep(60, [5, 5, 4], { target: T(3, 5, 60) }), rep(60, [5, 4, 4], { target: T(3, 5, 60) })])
add('linearThreeMissesDeloadWithEpley', L(), [1, 2, 3].map(() => rep(60, [5, 4, 4], { target: T(3, 5, 60) })))
add('linearDeloadFactorFloor', L({ deloadFactor: 0.5 }), [1, 2, 3].map(() => rep(60, [5, 4, 4], { target: T(3, 5, 60) })))
add('linearInvalidDeloadFactorFallsBack', L({ deloadFactor: 0.99 }), [1, 2, 3].map(() => rep(60, [5, 4, 4], { target: T(3, 5, 60) })))
add('linearUndoneSetIsAMiss', L(), [st([[60, 5], [60, 5], [60, 5, false]], { target: T(3, 5, 60) })])
add('linearFewerSetsIsAMiss', L(), [rep(60, [5, 5], { target: T(3, 5, 60) })])
add('linearBonusSetDoesNotMoveThePlan', L(), [rep(60, [5, 5, 5, 3], { target: T(3, 5, 60) })])
add('linearWeightChangeEndsTheStallStreak', L(), [rep(60, [5, 4, 4], { target: T(3, 5, 60) }), rep(60, [5, 4, 4], { target: T(3, 5, 60) }), rep(57.5, [5, 4, 4], { target: T(3, 5, 57.5) })])
add('linearExcludedSessionIsNotABaseline', L(), [rep(60, [5, 5, 5], { target: T(3, 5, 60) }), rep(100, [1, 1, 1], { target: T(3, 5, 60), excluded: true })])
add('linearSessionWithoutTargetUsesThePlan', L(), [rep(60, [5, 5, 5])])
add('linearFinerStepOnTheGrid', L({ incKg: 1.25, weightKg: 61.25 }), [rep(61.25, [5, 5, 5], { target: T(3, 5, 61.25) })])
add('linearOffGridWeightJustAddsTheStep', L(), [rep(61.3, [5, 5, 5], { target: T(3, 5, 61.3) })])
add('linearNoWeightLoggedAsksForIt', L(), [rep(0, [5, 5, 5], { target: T(3, 5, 0) })])
add('linearNoWeightLoggedWithoutAPlanWeight', L({ weightKg: undefined }), [rep(0, [5, 5, 5], { target: T(3, 5, 0) })])
add('linearPlanChangedRestartsFromThePlan', L({ sets: 4, reps: 8, weightKg: 50 }), [rep(60, [5, 5, 5], { target: T(3, 5, 60), planned: { sets: 3, reps: 5, weight: 60 } })])
add('linearPlanWeightOnlyChangeIsNotAnEdit', L({ weightKg: 70 }), [rep(60, [5, 5, 5], { target: T(3, 5, 60), planned: { sets: 3, reps: 5, weight: 60 } })])
add('linearPerSideDeloadStaysEven', L({ side: true, reps: 10 }), [1, 2, 3].map(() => rep(40, [10, 8, 8], { target: T(3, 10, 40) })))
// -- double
add('doubleBottomOfTheRangeClimbsOneRep', D(), [rep(40, [8, 8, 8], { target: T(3, 8, 40) })])
add('doubleMidRangeKeepsClimbing', D(), [rep(40, [10, 10, 9], { target: T(3, 10, 40) })])
add('doubleTopOfTheRangeAddsWeightAndResets', D(), [rep(40, [12, 12, 12], { target: T(3, 12, 40) })])
add('doubleTargetMetBelowTheTopIsNotTheTop', D(), [rep(40, [9, 9, 9], { target: T(3, 9, 40) })])
add('doubleBeatingTheBestIsNotAStall', D(), [rep(40, [8, 8, 8], { target: T(3, 12, 40) }), rep(40, [9, 9, 8], { target: T(3, 12, 40) }), rep(40, [10, 9, 9], { target: T(3, 12, 40) })])
add('doubleThreeFlatSessionsDeloadWithEpley', D(), [1, 2, 3].map(() => rep(40, [10, 9, 8], { target: T(3, 12, 40) })))
add('doublePerSideStepsByTwo', D({ side: true, reps: 12, repsMin: 8 }), [rep(20, [8, 8, 8], { target: T(3, 12, 20) })])
add('doubleNarrowRange', D({ reps: 10, repsMin: 9 }), [rep(40, [9, 9, 9], { target: T(3, 10, 40) })])
add('doubleRangeCollapsedIsRepaired', D({ reps: 8, repsMin: 8 }), [rep(40, [8, 8, 8], { target: T(3, 8, 40) })])
add('doublePlanChangedAimsInsideTheNewRange', D(), [rep(40, [10, 10, 10], { target: T(3, 10, 40), planned: { sets: 3, reps: 10, repsMin: 8, weight: 40 } })])
// -- triple
add('tripleBaseSetsClimbTogether', R(), [rep(40, [8, 8, 8], { target: T(3, 8, 40, { rowReps: [8, 8, 8] }) })])
add('tripleBaseAtTheTopAddsASet', R(), [rep(40, [12, 12, 12], { target: T(3, 12, 40, { rowReps: [12, 12, 12] }) })])
add('tripleAddedSetClimbsAlone', R(), [rep(40, [12, 12, 12, 8], { target: T(4, 12, 40, { rowReps: [12, 12, 12, 8] }) })])
add('tripleAddedSetAtTheTopAddsAnother', R(), [rep(40, [12, 12, 12, 12], { target: T(4, 12, 40, { rowReps: [12, 12, 12, 12] }) })])
add('tripleCeilingAddsWeightAndStartsOver', R(), [rep(40, [12, 12, 12, 12, 12], { target: T(5, 12, 40, { rowReps: [12, 12, 12, 12, 12] }) })])
add('tripleMissedWithMoreRepsIsNotAStall', R(), [rep(40, [8, 8, 8], { target: T(3, 8, 40, { rowReps: [9, 9, 9] }) })])
add('tripleMissedHoldsTheSameRows', R(), [rep(40, [9, 9, 8], { target: T(3, 9, 40, { rowReps: [9, 9, 9] }) }), rep(40, [9, 8, 8], { target: T(3, 9, 40, { rowReps: [9, 9, 9] }) })])
add('tripleThreeStallsDeload', R(), [1, 2, 3].map(() => rep(40, [9, 8, 8], { target: T(3, 9, 40, { rowReps: [9, 9, 9] }) })))
add('tripleWithoutSetsMaxIsDoubleWithPerSetAims', R({ setsMax: undefined }), [rep(40, [12, 12, 12], { target: T(3, 12, 40, { rowReps: [12, 12, 12] }) })])
add('tripleSessionFromBeforeTripleReadsAsFlat', R(), [rep(40, [10, 10, 10], { target: T(3, 10, 40) })])
add('triplePlanChangedStartsTheCycleAgain', R({ reps: 10, repsMin: 6 }), [rep(40, [12, 12, 12], { target: T(3, 12, 40, { rowReps: [12, 12, 12] }), planned: { sets: 3, reps: 12, repsMin: 8, setsMax: 5, weight: 40 } })])
// -- time
add('timeHeldEveryHoldAddsSeconds', TM(), [st([[0, 30], [0, 30], [0, 32]], { time: true, target: { mode: 'time', sets: 3, sec: 30 } })])
add('timeShortHoldsAgain', TM(), [st([[0, 30], [0, 25], [0, 30]], { time: true, target: { mode: 'time', sets: 3, sec: 30 } })])
add('timeThreeShortSessionsDeload', TM(), [1, 2, 3].map(() => st([[0, 30], [0, 25], [0, 20]], { time: true, target: { mode: 'time', sets: 3, sec: 30 } })))
add('timePerSideNeedsBothSides', TM({ side: true, sets: 2 }), [st([[0, 30], [0, 30]], { time: true, target: { mode: 'time', sets: 2, sec: 30, side: true } })])
add('timePerSideBothSidesHeldAddsSeconds', TM({ side: true, sets: 2 }), [st([[0, 30], [0, 30], [0, 30], [0, 31]], { time: true, target: { mode: 'time', sets: 2, sec: 30, side: true } })])
// -- bodyweight
add('bodyweightCleanClimbsOneRep', BW(), [rep(0, [8, 8, 8], { target: T(3, 8, 0) })])
add('bodyweightMissHolds', BW(), [rep(0, [8, 8, 6], { target: T(3, 8, 0) })])
add('bodyweightPerSideClimbsByTwo', BW({ side: true }), [rep(0, [8, 8, 8], { target: T(3, 8, 0) })])
add('bodyweightCeilingAddsASet', BW({ repsMax: 12 }), [rep(0, [12, 12, 12], { target: T(3, 12, 0), planned: { sets: 3, reps: 8 } })])
add('bodyweightCeilingKeepsTheAddedSet', BW({ repsMax: 12 }), [rep(0, [8, 8, 8, 8], { target: T(4, 8, 0), planned: { sets: 3, reps: 8 } })])
add('bodyweightOutOfSetsAsksForLoad', BW({ repsMax: 12, sets: 6 }), [rep(0, [12, 12, 12, 12, 12, 12], { target: T(6, 12, 0), planned: { sets: 6, reps: 8 } })])

// ---- run the real engine ------------------------------------------------------------------------
const toState = sc => {
  const cfg = { id: 'x', mode: sc.cfg.mode, prog: sc.cfg.policy, sets: sc.cfg.sets, reps: sc.cfg.reps, repsMin: sc.cfg.repsMin, setsMax: sc.cfg.setsMax,
    sec: sc.cfg.sec, weight: sc.cfg.weightKg, inc: sc.cfg.incKg, side: sc.cfg.side || undefined, bodyweight: sc.cfg.bodyweight || undefined,
    repsMax: sc.cfg.repsMax, deloadFactor: sc.cfg.deloadFactor }
  Object.keys(cfg).forEach(k => cfg[k] === undefined && delete cfg[k])
  const S = { unit: 'kg', workouts: sc.sessions.map((s, i) => ({ d: `2026-01-${String(i + 1).padStart(2, '0')}`, entries: [{
    id: 'x', ...(s.target ? { target: s.target } : {}), ...(s.planned ? { planned: s.planned } : {}), ...(s.excluded ? { noProg: true } : {}),
    sets: s.sets }] })) }
  return { S, cfg }
}
const ID = [
  [/^Nothing logged yet/, 'baseline'], [/^Plan changed/, 'planChanged'], [/^Held every set for the full time/, 'timeUp'],
  [/^Short \{0\} sessions in a row/, 'timeDeload'], [/^Came up short last time\. Same target again\./, 'timeHold'],
  [/^Bodyweight: same target again/, 'bodyweightHold'], [/^\{0\} reps in every set! Add a set and go back/, 'bodyweightAddSet'],
  [/^\{0\} sets of \{1\}\. Time to add weight/, 'bodyweightMaxSets'], [/^Bodyweight: every rep last time/, 'bodyweightUp'],
  [/^No weight logged last time/, 'noWeightLogged'], [/^Stuck for \{0\} sessions\. Deload to \{1\} \{2\} and start again at/, 'tripleDeload'],
  [/^Short of the target, but more reps/, 'tripleHoldBeatenReps'], [/^Missed reps last time\. Same sets and reps again/, 'tripleHoldMissed'],
  [/^Same weight, aim for \{0\} reps in every set\./, 'tripleAimEverySet'], [/^Same weight, aim for \{0\} reps on the last set\./, 'tripleAimLastSet'],
  [/^\{0\} reps in every set! Add a set at/, 'tripleAddSet'], [/^Top of the range on all/, 'tripleUp'],
  [/^Top of the rep range in every set\./, 'doubleUp'], [/^Stuck for \{0\} sessions\. Hold/, 'doubleDeloadEpleyHold'],
  [/^Stuck for \{0\} sessions\. Epley deload/, 'doubleDeloadEpley'], [/^Stuck for \{0\} sessions\. Deload to \{1\} \{2\}\./, 'doubleDeload'],
  [/^Same weight, aim for \{0\} reps this time\./, 'doubleHold'], [/^Every rep last time\./, 'linearUp'],
  [/^Missed reps \{0\} sessions running/, 'linearDeload'], [/^Missed reps\. Reset to/, 'linearDeloadOnce'],
  [/^Missed reps last time\. Same weight again/, 'linearHold'],
]
const whyOf = w => {
  if (!w) return null
  const hit = ID.find(([re]) => re.test(w[0]))
  if (!hit) throw new Error('unmapped template: ' + w[0])
  return { id: hit[1], args: w.slice(1).filter(a => typeof a === 'number') }
}

// ---- emit Swift ---------------------------------------------------------------------------------
const num = v => (Number.isInteger(v) ? String(v) + (v === Math.trunc(v) ? '' : '') : String(v))
const dbl = v => (Number.isInteger(v) ? v + '.0' : String(v))
const optInt = v => (v == null ? 'nil' : String(v))
const optDbl = v => (v == null ? 'nil' : dbl(v))
const target = t => t ? `LiftProgressionTarget(sets: ${optInt(t.sets)}, reps: ${optInt(t.reps)}, repsMin: ${optInt(t.repsMin)}, sec: ${optInt(t.sec)}, weightKg: ${optDbl(t.weight)}, setsMax: ${optInt(t.setsMax)}, rowReps: ${t.rowReps ? '[' + t.rowReps.join(', ') + ']' : 'nil'}, perSide: ${!!t.side})` : 'nil'
const plan = p => p ? `LiftProgressionPlan(sets: ${p.sets}, reps: ${optInt(p.reps)}, repsMin: ${optInt(p.repsMin)}, sec: ${optInt(p.sec)}, setsMax: ${optInt(p.setsMax)}, weightKg: ${optDbl(p.weight)})` : 'nil'
const sessSwift = (s, mode) => `LiftProgressionSession(mode: .${mode}, sets: [${s.sets.map(x => `LiftProgressionSet(weightKg: ${dbl(x.w)}, reps: ${x.r}, seconds: ${x.sec || 0}, done: ${x.done})`).join(', ')}], target: ${target(s.target)}, planned: ${plan(s.planned)}, excluded: ${!!s.excluded})`
const cfgSwift = c => `LiftProgressionConfig(policy: .${c.policy}, mode: .${c.mode || 'reps'}, sets: ${c.sets}, reps: ${optInt(c.reps)}, repsMin: ${optInt(c.repsMin)}, setsMax: ${optInt(c.setsMax)}, sec: ${optInt(c.sec)}, weightKg: ${optDbl(c.weightKg)}, incKg: ${dbl(c.incKg)}, perSide: ${!!c.side}, bodyweight: ${!!c.bodyweight}, repsMax: ${optInt(c.repsMax)}, deloadFactor: ${optDbl(c.deloadFactor)})`

const tests = scenarios.map(sc => {
  const { S, cfg } = toState(sc)
  const out = nextPrescription(S, cfg, {})
  const why = whyOf(out.why)
  const mode = sc.cfg.mode || 'reps'
  const exp = `kind: .${out.kind}, weight: ${optDbl(out.weight)}, reps: ${optInt(out.reps)}, sets: ${optInt(out.sets)}, sec: ${optInt(out.sec)}, rowReps: ${out.rowReps ? '[' + out.rowReps.join(', ') + ']' : 'nil'}, why: ${why ? JSON.stringify(why.id) : 'nil'}, args: [${(why ? why.args : []).map(dbl).join(', ')}], target1RM: ${optDbl(out.target1RM)}, factor: ${optDbl(out.deloadFactor)}`
  return `    func test_${sc.name}() {
        check(${cfgSwift(sc.cfg)},
              [${sc.sessions.map(s => '\n               ' + sessSwift(s, mode)).join(',')}${sc.sessions.length ? '\n              ' : ''}],
              ${exp})
    }`
})
const header = `import XCTest
@testable import StrandAnalytics

// GENERATED by running openGym's own \`frontend/src/lib/progression.js\` (Duarte Santos, MIT authorization to
// Gabriel Bolatoglu; see ATTRIBUTION.md) over each scenario below under Node, then writing what it returned
// as the expected literals. The Swift port (\`LiftProgression\`) must agree on the kind, every number the
// rule sets and the reason (id and arguments). Rules and branches openGym has that the port leaves out
// (Greyskull, steady, undulating, density, ladder, owned dumbbells, assistance machines, back-off sets,
// pyramids) are stubbed inert in the oracle, so these scenarios never touch them.
//
// To regenerate: Tools/lift_progression_oracle (see its README).
final class LiftProgressionOracleTests: XCTestCase {

    private func check(_ cfg: LiftProgressionConfig, _ sessions: [LiftProgressionSession],
                       kind: LiftProgressionKind, weight: Double?, reps: Int?, sets: Int?, sec: Int?,
                       rowReps: [Int]?, why: String?, args: [Double], target1RM: Double?, factor: Double?,
                       file: StaticString = #filePath, line: UInt = #line) {
        let out = LiftProgression.nextPrescription(config: cfg, sessions: sessions)
        XCTAssertEqual(out.kind, kind, "kind", file: file, line: line)
        XCTAssertEqual(out.weightKg, weight, "weight", file: file, line: line)
        XCTAssertEqual(out.reps, reps, "reps", file: file, line: line)
        XCTAssertEqual(out.sets, sets, "sets", file: file, line: line)
        XCTAssertEqual(out.sec, sec, "sec", file: file, line: line)
        XCTAssertEqual(out.rowReps, rowReps, "rowReps", file: file, line: line)
        XCTAssertEqual(out.why?.id, why, "why", file: file, line: line)
        XCTAssertEqual(out.why?.args ?? [], args, "why args", file: file, line: line)
        XCTAssertEqual(out.target1RM, target1RM, "target1RM", file: file, line: line)
        XCTAssertEqual(out.deloadFactor, factor, "deloadFactor", file: file, line: line)
    }

`
fs.writeFileSync('LiftProgressionOracleTests.swift', header + tests.join('\n\n') + '\n}\n')
console.log(scenarios.length, 'scenarios')
for (const sc of scenarios) { const { S, cfg } = toState(sc); const o = nextPrescription(S, cfg, {}); console.log(sc.name.padEnd(48), o.kind, o.weight ?? '', o.reps ?? '', o.sets ?? '', o.sec ?? '', JSON.stringify(o.rowReps ?? ''), whyOf(o.why)?.id ?? '') }
