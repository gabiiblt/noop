// STUB: a tiny catalogue standing in for openGym's. Only the equipment word matters to plates/bar.
const EX = { bb: { id: 'bb', eq: 'barbell' }, ez: { id: 'ez', eq: 'ez barbell' }, tb: { id: 'tb', eq: 'trap bar' }, sm: { id: 'sm', eq: 'smith machine' }, db: { id: 'db', eq: 'dumbbell' } }
export const EXIDX = EX
export const exerciseOf = x => (x && typeof x === 'object' ? x : EX[x])
// Assistance is a property of the EXERCISE, as in openGym's catalogue: a generator marks the ids it wants assisted.
export const ASSISTED = new Set()
export const isAssisted = x => ASSISTED.has(x?.id)
export const isLoadedEq = () => true
export const isBodyweightEq = () => false
export const defaultIncrement = () => 2.5
