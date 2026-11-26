import Foundation

// GENERATED from openGym's `frontend/src/lib/structuralBalanceTemplates.js` (Duarte Santos, MIT authorization to Gabriel
// Bolatoglu; see ATTRIBUTION.md) by Tools/lift_progression_oracle/gen_balance.mjs. Do not edit by hand.
//
// The ratio tables themselves are Poliquin's, Thibaudeau's and ATG's, as transcribed by openGym from
// https://anticulturista.substack.com/p/30-equilibrio-estructural-tu-proximo. They are reference ratios from coaching
// literature, not norms for any person. Exercise ids are the bundled catalogue's (openGym's).

extension LiftBalanceTemplate {
    static let all: [LiftBalanceTemplate] = [
        LiftBalanceTemplate(id: "poliquin", label: "Poliquin", roles: [
            LiftBalanceRole(id: "narrowBench", label: "Close-grip bench press (anchor)", mode: .loadRatio, exerciseIds: ["0030", "1719"], anchorRoleId: nil, targetPct: 100, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "inclineBench", label: "Incline bench press", mode: .loadRatio, exerciseIds: ["0047"], anchorRoleId: "narrowBench", targetPct: 91, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "dips", label: "Dips (bodyweight + load)", mode: .loadRatio, exerciseIds: ["0251"], anchorRoleId: "narrowBench", targetPct: 117, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "supinePullups", label: "Supine pull-ups (bodyweight + load)", mode: .loadRatio, exerciseIds: ["0652", "0841"], anchorRoleId: "narrowBench", targetPct: 87, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "barbellCurl", label: "Standing barbell curl", mode: .loadRatio, exerciseIds: ["0031"], anchorRoleId: "narrowBench", targetPct: 40, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "highBarSquat", label: "High-bar back squat (anchor)", mode: .loadRatio, exerciseIds: ["1436", "0043"], anchorRoleId: nil, targetPct: 100, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "frontSquat", label: "Front squat", mode: .loadRatio, exerciseIds: ["0042"], anchorRoleId: "highBarSquat", targetPct: 85, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "deadlift", label: "Deadlift", mode: .loadRatio, exerciseIds: ["0032"], anchorRoleId: "highBarSquat", targetPct: 125, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "powerClean", label: "Power clean", mode: .loadRatio, exerciseIds: ["0648"], anchorRoleId: "highBarSquat", targetPct: 61, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
        ]),
        LiftBalanceTemplate(id: "thibaudeauPowerlifting", label: "Thibaudeau (Powerlifting)", roles: [
            LiftBalanceRole(id: "squat", label: "Squat (anchor)", mode: .loadRatio, exerciseIds: ["0043", "1436"], anchorRoleId: nil, targetPct: 100, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "bench", label: "Bench press", mode: .loadRatio, exerciseIds: ["0025"], anchorRoleId: "squat", targetPct: 75, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "deadlift", label: "Deadlift", mode: .loadRatio, exerciseIds: ["0032"], anchorRoleId: "squat", targetPct: 120, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "militaryPress", label: "Military press", mode: .loadRatio, exerciseIds: ["0091", "1456", "1457", "0086"], anchorRoleId: "squat", targetPct: 45, targetPctFemale: nil, reps: nil, repsTarget: nil, repsTargetFemale: nil),
        ]),
        LiftBalanceTemplate(id: "atg", label: "ATG", roles: [
            LiftBalanceRole(id: "romanianDeadlift", label: "Romanian deadlift (12 reps)", mode: .bodyweightRatio, exerciseIds: ["0085"], anchorRoleId: nil, targetPct: 100, targetPctFemale: 80, reps: 12, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "goodMorning", label: "Seated good morning (10 reps)", mode: .bodyweightRatio, exerciseIds: ["0090"], anchorRoleId: nil, targetPct: 66, targetPctFemale: 40, reps: 10, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "stepUp", label: "Poliquin step-up (15 reps)", mode: .bodyweightRatio, exerciseIds: ["0114", "0431"], anchorRoleId: nil, targetPct: 50, targetPctFemale: 40, reps: 15, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "nordicCurl", label: "Nordic curl (1 rep)", mode: .repCount, exerciseIds: ["3193"], anchorRoleId: nil, targetPct: nil, targetPctFemale: nil, reps: nil, repsTarget: 1, repsTargetFemale: nil),
            LiftBalanceRole(id: "pullups", label: "Pull-ups (10 reps, bodyweight)", mode: .repCount, exerciseIds: ["0652"], anchorRoleId: nil, targetPct: nil, targetPctFemale: nil, reps: nil, repsTarget: 10, repsTargetFemale: 1),
            LiftBalanceRole(id: "atgDips", label: "Dips (10 reps, bodyweight)", mode: .repCount, exerciseIds: ["0251"], anchorRoleId: nil, targetPct: nil, targetPctFemale: nil, reps: nil, repsTarget: 10, repsTargetFemale: nil),
            LiftBalanceRole(id: "inclineDbPress", label: "Incline DB press (each hand, 8 reps)", mode: .bodyweightRatio, exerciseIds: ["0314", "3545"], anchorRoleId: nil, targetPct: 40, targetPctFemale: 20, reps: 8, repsTarget: nil, repsTargetFemale: nil),
            LiftBalanceRole(id: "dbShoulderPress", label: "DB shoulder press (each hand, 8 reps)", mode: .bodyweightRatio, exerciseIds: ["0405", "0404", "0361", "0360"], anchorRoleId: nil, targetPct: 33, targetPctFemale: 15, reps: 8, repsTarget: nil, repsTargetFemale: nil),
        ]),
    ]
}
