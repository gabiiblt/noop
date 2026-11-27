import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// Strength balance: how one lift stands against another in YOUR log, and against your body weight.
//
// Three published tables (Poliquin, Thibaudeau, ATG) give each lift a ratio: a percentage of an anchor lift's
// estimated one-rep max, a load for a number of reps as a percentage of body weight, or a rep count at body weight.
// A lift is Balanced when it reaches its ratio, Borderline within five points under it, Weak below that.
//
// THESE ARE REFERENCE RATIOS FROM COACHING LITERATURE, NEVER A NORM FOR ANYONE. A lifter whose anchor is weak scores
// every other lift as strong, and a lift below its ratio says which one trails the others in this log, not that
// anything is wrong. The screen says so.
//
// The maths and the tables are ported from openGym (Duarte Santos, MIT authorization to Gabriel Bolatoglu) and
// checked against openGym's own code; see ATTRIBUTION.md.

struct LiftBalanceSheet: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var tables: [(template: LiftBalanceTemplate, results: [LiftBalanceResult])] = []
    @State private var names: [String: String] = [:]
    @State private var loaded = false
    @State private var selectedId = "poliquin"

    private var selected: (template: LiftBalanceTemplate, results: [LiftBalanceResult])? {
        tables.first { $0.template.id == selectedId } ?? tables.first
    }

    var body: some View {
        ScreenScaffold(title: "Strength balance",
                       subtitle: "How your lifts compare with each other and with your body weight, against published reference ratios.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                tableCard
                if profile.weightKg <= 0 { weighInCard }
                if let selected {
                    ForEach(selected.results, id: \.roleId) { roleRow(selected.template, $0) }
                }
                noteCard
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 560, height: 800)
        #endif
        .noopBackdrop(StrandPalette.gymAccent)
        .task { await load() }
    }

    // MARK: - Pieces

    private var tableCard: some View {
        GymCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Picker("Table", selection: $selectedId) {
                    Text("Poliquin").tag("poliquin")
                    Text("Thibaudeau").tag("thibaudeauPowerlifting")
                    Text("ATG").tag("atg")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var caption: LocalizedStringKey {
        switch selectedId {
        case "thibaudeauPowerlifting": return "Squat, bench press, deadlift and military press against each other, with the squat as the anchor."
        case "atg": return "Lifts for a number of reps as a percentage of your body weight, and rep counts at body weight."
        default: return "Your lifts as a percentage of the close-grip bench press (upper body) or the high-bar squat (lower body)."
        }
    }

    private var weighInCard: some View {
        GymCard(tint: StrandPalette.statusWarning) {
            Text("Set your weight in your profile: lifts on your own body (dips, pull-ups) and the body-weight ratios need it.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roleRow(_ template: LiftBalanceTemplate, _ r: LiftBalanceResult) -> some View {
        let role = template.roles.first { $0.id == r.roleId }
        return GymCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(exerciseName(r.mappedExerciseId ?? r.configuredExerciseId))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(statusWord(r.status))
                        .font(StrandFont.caption)
                        .foregroundStyle(statusColor(r.status))
                }
                Text(detail(r, role))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if r.needsBodyweight {
                    Text("Needs a weigh-in: set your weight in your profile.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                }
                if r.needsAnchor, let anchor = role?.anchorRoleId.flatMap({ id in template.roles.first { $0.id == id } }) {
                    Text("Log \(exerciseName(anchor.exerciseIds.first)) to compare against.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                }
            }
        }
    }

    private var noteCard: some View {
        GymCard {
            Text("These ratios come from coaching literature and are not a norm for anyone. A weak anchor makes every other lift look strong, and a lift below its ratio only says which one trails the others in your log.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Words

    /// "117 %": a plain string, so a percent sign never sits inside a localised format.
    private func pct(_ value: Double) -> String { "\(LiftFormat.trim(value)) %" }

    private func detail(_ r: LiftBalanceResult, _ role: LiftBalanceRole?) -> String {
        let isReps = role?.mode == .repCount
        let target = isReps ? LiftFormat.trim(r.targetPct) : pct(r.targetPct)
        guard r.status != .noData, let actual = r.actualPct else {
            return isReps ? String(localized: "Target: \(target) reps") : String(localized: "Target: \(target)")
        }
        switch role?.mode {
        case .repCount:
            return String(localized: "\(r.current?.reps ?? 0) reps · target \(target)")
        case .bodyweightRatio:
            return String(localized: "\(pct(actual.rounded())) of body weight for \(role?.reps ?? 1) reps · target \(target)")
        default:
            return role?.anchorRoleId == nil
                ? String(localized: "Anchor lift")
                : String(localized: "\(pct(actual.rounded())) of the anchor · target \(target)")
        }
    }

    private func statusWord(_ s: LiftBalanceStatus) -> String {
        switch s {
        case .balanced: return String(localized: "Balanced")
        case .borderline: return String(localized: "Borderline")
        case .weak: return String(localized: "Weak")
        case .noData: return String(localized: "No data")
        }
    }

    private func statusColor(_ s: LiftBalanceStatus) -> Color {
        switch s {
        case .balanced: return StrandPalette.statusPositive
        case .borderline: return StrandPalette.statusWarning
        case .weak: return StrandPalette.statusCritical
        case .noData: return StrandPalette.textTertiary
        }
    }

    private func exerciseName(_ id: String?) -> String {
        guard let id else { return "—" }
        return names[id] ?? id
    }

    // MARK: - Data

    private func load() async {
        // The catalogue gives each table exercise its name (in the app's language) and its equipment word.
        var exercises: [String: LiftBalanceExercise] = [:]
        if let catalogue = ExerciseLibrary.shared,
           let found = try? catalogue.exercises(ids: LiftBalanceStore.tableExerciseIds) {
            for e in found {
                exercises[e.id] = LiftBalanceExercise(name: e.nameEn, equipment: e.equipment ?? "")
                names[e.id] = ExerciseLibrary.name(e)
            }
        }
        guard let store = await repo.storeHandle() else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let sets = (try? await store.liftSetsBefore(deviceId: repo.deviceId, startTs: stamp + 1)) ?? []
        let sessions = (try? await store.liftSessions(deviceId: repo.deviceId, fromTs: 0, toTs: Int.max)) ?? []
        let starts = Dictionary(sessions.map { ($0.id, $0.startTs) }, uniquingKeysWith: { first, _ in first })
        let input = LiftBalanceStore.input(sets: sets, sessionStarts: starts, bodyweightKg: profile.weightKg,
                                           female: profile.sex == "female", exercises: exercises)
        tables = LiftBalanceStore.results(input)
        loaded = true
    }
}
