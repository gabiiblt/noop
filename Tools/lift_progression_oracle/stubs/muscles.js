// STUB: the muscle model reduced to what recovery.js reads. An entry carries its own weights per slug
// ({ chest: 1, triceps: 0.4 }): primary 1, secondary 0.4 (openGym's SECONDARY).
export const MUSCLES = [
  'trapezius', 'front-delts', 'side-delts', 'rear-delts', 'chest', 'lats', 'upper-back', 'serratus',
  'biceps', 'triceps', 'forearm', 'abs', 'obliques', 'lower-back',
  'gluteal', 'quadriceps', 'hamstring', 'adductors', 'hip-flexors', 'calves', 'tibialis',
]
export const musclesOf = ex => ex?.weights || {}
