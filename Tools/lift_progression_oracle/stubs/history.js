// STUBS standing in for openGym modules outside the ported scope. modeOf/repStep/isPerSide/isBw/
// entryExcluded/entryRoutineId are copied verbatim from history.js; the rest are inert.
export function modeOf(cfg) {
  const m = cfg && cfg.mode
  if (m === 'reps' || m === 'time' || m === 'cardio' || m === 'distance') return m
  return 'reps'
}
export const isBw = cfg => !!(cfg && cfg.bodyweight)
export const isPerSide = cfg => !!(cfg && cfg.side)
export const repStep = cfg => (isPerSide(cfg) ? 2 : 1)
export const rerampWarmups = () => {}
export function entryExcluded(w, entry) { return w?.excludeFromProgression === true || entry?.noProg === true }
export function entryRoutineId(w, en) {
  if (en?.rid) return en.rid
  if ((w?.entries || []).some(e => e && e.rid)) return null
  return [].concat(w?.routineIds ?? [])[0] ?? w?.routineId ?? null
}
export const lastAcrossRoutines = () => true
// ---- extra STUBS for the recovery oracle (recovery.js, onerm.js, effort.js) ----
export const workoutAt = w => Number(w?.start)
export const entriesForExercise = () => []
export const metricRowsForEntry = () => []
export const EFFORT = {}
export const effortOf = () => 'rir'
