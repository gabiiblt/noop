// STUB of openGym's exercises.js: a small catalogue keyed by id (name + equipment word), with the REAL rules for
// bodyweight equipment and assistance copied from the original. Generators register the exercises they use.
export const EXIDX = {}
export const ASSISTED = new Set()
export const exerciseOf = x => (x && typeof x === 'object' ? x : EXIDX[x])
const BODYWEIGHT_EQ = new Set(['body weight', 'band', 'resistance band'])
export const isBodyweightEq = idOrEx => BODYWEIGHT_EQ.has(exerciseOf(idOrEx)?.eq)
const ASSISTED_EQ = 'leverage machine'
const assistedName = n => /\bassist(ed)?\b/i.test(String(n || ''))
const assistedShape = ex => (typeof ex?.assisted === 'boolean' ? ex.assisted : ex?.eq === ASSISTED_EQ && assistedName(ex?.n))
export function isAssisted(idOrEx) {
  if (!idOrEx) return false
  if (typeof idOrEx === 'string') return ASSISTED.has(idOrEx) || !!assistedShape(EXIDX[idOrEx])
  if (idOrEx.id && ASSISTED.has(idOrEx.id)) return true
  return !!assistedShape(EXIDX[idOrEx.id] || idOrEx)
}
export const isLoadedEq = () => true
export const defaultIncrement = () => 2.5
