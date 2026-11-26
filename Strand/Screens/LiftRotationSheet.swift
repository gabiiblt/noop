import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// The rotation: train "the next session in the cycle" instead of "Monday's session".
//
// Pick the programs that make up the cycle, put them in order, and say how many days off follow each one. What is up
// next then follows from what was trained last: the program after the last session of the rotation, due the day after
// it plus the rest days. No calendar to fall behind: skip a week and the same program is simply still next.
//
// The idea follows openGym's rotation (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see ATTRIBUTION.md).

struct LiftRotationSheet: View {
    /// Called after the rotation is changed, so the hub can reload.
    var onChanged: () async -> Void = {}

    @EnvironmentObject var repo: Repository

    @State private var programs: [LiftProgramRow] = []
    @State private var loaded = false

    private var steps: [LiftRotationStep] { LiftRotation.steps(programs) }
    private var outside: [LiftProgramRow] { programs.filter { !$0.archived && $0.rotationOrd == nil } }

    var body: some View {
        ScreenScaffold(title: "Rotation",
                       subtitle: "Train the next session in the cycle instead of a fixed weekday. What is up next follows from what you trained last.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if loaded && steps.isEmpty { emptyCard }
                ForEach(Array(steps.enumerated()), id: \.element.programId) { index, step in
                    stepCard(step, index: index)
                }
                if !outside.isEmpty { outsideSection }
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 720)
        #endif
        .background(StrandPalette.surfaceBase)
        .task { await load() }
    }

    // MARK: - Pieces

    private var emptyCard: some View {
        NoopCard {
            Text("No program is in the rotation yet. Add the programs below in the order you train them: push, pull, legs, for instance.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepCard(_ step: LiftRotationStep, index: Int) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1)")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(step.name)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Button { change { LiftRotation.moved($0, id: step.programId, by: -1) } } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                        .accessibilityLabel("Move up")
                    Button { change { LiftRotation.moved($0, id: step.programId, by: 1) } } label: { Image(systemName: "chevron.down") }
                        .disabled(index == steps.count - 1)
                        .accessibilityLabel("Move down")
                    Button { change { LiftRotation.removing($0, id: step.programId) } } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel("Remove from the rotation")
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textSecondary)
                Stepper(value: Binding(get: { step.restDaysAfter },
                                       set: { days in change { LiftRotation.settingRest($0, id: step.programId, days: days) } }),
                        in: 0...LiftProgramRow.maxRestDays) {
                    Text(restLabel(step.restDaysAfter))
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func restLabel(_ days: Int) -> String {
        days == 0 ? String(localized: "Next session the day after") : String(localized: "\(days) rest days after")
    }

    private var outsideSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Not in the rotation", overline: nil)
            ForEach(outside, id: \.id) { program in
                NoopCard {
                    HStack {
                        Text(program.name)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button("Add to the rotation") { change { LiftRotation.adding($0, id: program.id) } }
                            .buttonStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
            }
        }
    }

    // MARK: - Data

    /// Apply an edit and write only the programs it changed.
    private func change(_ edit: ([LiftProgramRow]) -> [LiftProgramRow]) {
        let before = programs
        let after = edit(before)
        let changed = after.filter { row in before.first { $0.id == row.id } != row }
        programs = after
        guard !changed.isEmpty else { return }
        Task {
            guard let store = await repo.storeHandle() else { return }
            _ = try? await store.upsertLiftPrograms(changed)
            await onChanged()
        }
    }

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        programs = (try? await store.liftPrograms(deviceId: repo.deviceId)) ?? []
        loaded = true
    }
}
