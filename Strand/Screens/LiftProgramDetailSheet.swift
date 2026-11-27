import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// What a tap on a routine opens: how it is built, and how it has gone. A title, a Start button, a chart of
// the sessions run from it, then each exercise with its rest and its set table. Edit and Start hand off to
// the caller once this sheet has closed, so two sheets never fight over the screen.

struct LiftProgramDetailSheet: View {
    let program: LiftProgramRow
    let onEdit: () -> Void
    let onStart: () -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var items: [LiftProgramItemRow] = []
    @State private var points: [Point] = []
    @State private var metric: Metric = .volume
    @State private var loaded = false

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    private enum Metric: CaseIterable {
        case volume, reps, duration
        var title: String {
            switch self {
            case .volume: return String(localized: "Volume")
            case .reps: return String(localized: "Reps")
            case .duration: return String(localized: "Duration")
            }
        }
    }

    /// One finished session of this routine, with the three things the chart can show.
    private struct Point: Identifiable {
        let id: String
        let startTs: Int
        let volumeKg: Double
        let reps: Int
        let minutes: Double
    }

    var body: some View {
        VStack(spacing: 0) {
            GymSheetBar(title: "Routine") {
                GymBarIcon(systemName: "xmark", label: "Close") { dismiss() }
            } trailing: {
                GymBarButton(title: "Edit") {
                    dismiss()
                    onEdit()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    header
                    startButton
                    chartCard
                    exercisesSection
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.bottom, NoopMetrics.sectionGap)
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 720)
        #endif
        .noopBackdrop(StrandPalette.gymAccent)
        .task { await load() }
    }

    // MARK: - Header + start

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(program.name)
                .font(StrandFont.title1)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = program.note, !note.isEmpty {
                Text(note)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if !items.isEmpty {
                Text("\(items.count) exercises")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.gymAccent)
            }
        }
    }

    private var startButton: some View {
        Button {
            dismiss()
            onStart()
        } label: {
            Label("Start routine", systemImage: "play.fill")
                .font(StrandFont.headline)
                .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight)
        }
        .noopGlassButton(prominent: true, tint: StrandPalette.gymAccent)
        .disabled(items.isEmpty)
        .opacity(items.isEmpty ? NoopButtonMetrics.disabledOpacity : 1)
    }

    // MARK: - Chart

    private var chartCard: some View {
        NoopGlassCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack(spacing: NoopMetrics.rowSpacing) {
                    ForEach(Metric.allCases, id: \.self) { option in
                        Button { metric = option } label: {
                            GymPill(title: option.title, selected: metric == option)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                if points.isEmpty {
                    Text("No data yet")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 96)
                } else {
                    bars
                }
            }
        }
    }

    private func value(_ point: Point) -> Double {
        switch metric {
        case .volume: return LiftFormat.display(fromKilograms: point.volumeKg, system: unitSystem)
        case .reps: return Double(point.reps)
        case .duration: return point.minutes
        }
    }

    private func label(_ v: Double) -> String {
        switch metric {
        case .volume: return "\(LiftFormat.trim(v.rounded())) \(unitSystem == .imperial ? "lb" : "kg")"
        case .reps: return LiftFormat.trim(v)
        case .duration: return "\(Int(v.rounded())) min"
        }
    }

    /// The last sessions as bars, newest on the right, the latest value named above its bar.
    private var bars: some View {
        let shown = Array(points.suffix(10))
        let top = max(shown.map(value).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(shown) { point in
                let v = value(point)
                let isLast = point.id == shown.last?.id
                VStack(spacing: 4) {
                    if isLast {
                        Text(label(v))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isLast ? StrandPalette.gymAccent : StrandPalette.gymAccent.opacity(0.4))
                        .frame(height: max(6, 96 * CGFloat(v / top)))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 124, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.last.map { "\(metric.title): \(label(value($0)))" } ?? "")
    }

    // MARK: - Exercises

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                Text("Exercises")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button("Edit routine") {
                    dismiss()
                    onEdit()
                }
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.gymAccent)
                .buttonStyle(.plain)
            }
            if items.isEmpty {
                Text("No exercises yet.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            ForEach(items, id: \.id) { item in
                exerciseBlock(item)
            }
        }
    }

    private func exerciseBlock(_ item: LiftProgramItemRow) -> some View {
        let rows = max(item.targetSets ?? 1, 1)
        let weight = item.targetWeightKg.map { LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: unitSystem)) } ?? "–"
        let reps = item.targetRepsLow.map { low in
            item.targetRepsHigh.map { $0 > low ? "\(low)–\($0)" : "\(low)" } ?? "\(low)"
        } ?? "–"
        return VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            HStack(spacing: NoopMetrics.gap) {
                GymExerciseThumb(catalogueId: item.catalogueId)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.exercise)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.gymAccent)
                        .lineLimit(2)
                    if let rest = item.restSec {
                        Text("Rest: \(LiftFormat.duration(rest))")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            GymSetHeader(unitSystem: unitSystem)
            ForEach(1...rows, id: \.self) { number in
                HStack(spacing: NoopMetrics.rowSpacing) {
                    GymSetBadge(index: number)
                    Text(weight).frame(maxWidth: .infinity)
                    Text(reps).frame(maxWidth: .infinity)
                }
                .font(StrandFont.rounded(17, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.vertical, 2)
                .background(number.isMultiple(of: 2) ? StrandPalette.surfaceRaised.opacity(0.5) : Color.clear,
                            in: RoundedRectangle(cornerRadius: NoopMetrics.radiusControl, style: .continuous))
            }
        }
        .padding(.vertical, NoopMetrics.rowSpacing)
    }

    // MARK: - Load

    private func load() async {
        guard !loaded else { return }
        loaded = true
        guard let store = await repo.storeHandle() else { return }
        items = (try? await store.liftProgramItems(programId: program.id)) ?? []
        let sessions = ((try? await store.liftSessions(deviceId: repo.deviceId, fromTs: 0, toTs: Int.max)) ?? [])
            .filter { $0.programId == program.id && $0.endTs != nil }
            .sorted { $0.startTs < $1.startTs }
        var out: [Point] = []
        for session in sessions.suffix(30) {
            let sets = (try? await store.liftSets(sessionId: session.id)) ?? []
            let work = sets.filter { !$0.isWarmup }
            out.append(Point(
                id: session.id,
                startTs: session.startTs,
                volumeKg: LiftMetrics.volumeLoadKg(sets) ?? 0,
                reps: work.reduce(0) { $0 + max($1.reps ?? 0, 0) },
                minutes: Double(max((session.endTs ?? session.startTs) - session.startTs, 0)) / 60))
        }
        points = out
    }
}
