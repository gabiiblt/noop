import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// The exercise library: the bundled catalogue to browse by name, muscle and equipment, and one exercise
// read back in full with its picture, its steps and everything you have logged of it.
//
// Lists stay light on purpose: rows are lazy, a search runs off the main thread after a short pause, and
// every still is decoded at the size it is drawn (`ExerciseImageCache`).

struct ExerciseLibraryView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var muscle: LiftMuscle?
    @State private var equipment: String?
    @State private var equipmentOptions: [String] = []
    @State private var results: [CatalogueExercise] = []
    @State private var searched = false

    private var searchKey: String { "\(query)|\(muscle?.rawValue ?? "")|\(equipment ?? "")" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    searchField
                    muscleChips
                    equipmentChip
                    if searched && results.isEmpty {
                        ComingSoon(what: "No exercise matches. Try fewer words or another muscle.",
                                   symbol: "magnifyingglass")
                    }
                    ForEach(results) { exercise in
                        NavigationLink {
                            ExerciseDetailView(name: ExerciseLibrary.name(exercise), catalogue: exercise)
                        } label: {
                            NoopCard(padding: 10) {
                                CatalogueExerciseRowLabel(exercise: exercise, thumbnail: 56)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Exercise text from openGym and ExerciseDB, pictures from free-exercise-db (public domain). See Attribution.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, NoopMetrics.gap)
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.vertical, NoopMetrics.gap)
            }
            .noopBackdrop(StrandPalette.effortColor)
            .navigationTitle(Text("Exercise library"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: searchKey) { await search() }
            .task { equipmentOptions = (try? ExerciseLibrary.shared?.equipmentValues()) ?? [] }
        }
    }

    private var searchField: some View {
        NoopCard(padding: 12) {
            HStack(spacing: NoopMetrics.rowSpacing) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                TextField("Search exercises", text: $query)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear search"))
                }
            }
        }
    }

    private var muscleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "All muscles"), selected: muscle == nil) { muscle = nil }
                ForEach(LiftMuscle.ordered, id: \.self) { m in
                    chip(m.displayName, selected: muscle == m) { muscle = (muscle == m) ? nil : m }
                }
            }
        }
    }

    private var equipmentChip: some View {
        Menu {
            Button(String(localized: "All equipment")) { equipment = nil }
            ForEach(equipmentOptions, id: \.self) { option in
                Button(ExerciseLibrary.equipmentName(option) ?? option) { equipment = option }
            }
        } label: {
            chipLabel(ExerciseLibrary.equipmentName(equipment) ?? String(localized: "All equipment"),
                      selected: equipment != nil, systemImage: "line.3.horizontal.decrease")
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, selected: selected, systemImage: nil) }
            .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, selected: Bool, systemImage: String?) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            }
            Text(title).font(StrandFont.caption)
        }
        .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? StrandPalette.accent.opacity(0.18) : StrandPalette.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(selected ? StrandPalette.accent : StrandPalette.hairline, lineWidth: 1))
    }

    private func search() async {
        guard let catalogue = ExerciseLibrary.shared else { results = []; searched = true; return }
        // Typing fires a new task per keystroke; the pause lets the last one win without a search per letter.
        try? await Task.sleep(nanoseconds: 180_000_000)
        if Task.isCancelled { return }
        let text = query, m = muscle, e = equipment
        let found = await Task.detached(priority: .userInitiated) {
            (try? catalogue.search(text, muscle: m, equipment: e, limit: 150)) ?? []
        }.value
        if Task.isCancelled { return }
        results = found
        searched = true
    }
}

/// One exercise: its picture, muscles, equipment and steps when it comes from the catalogue, and what you
/// have logged of it (records, the estimated-1RM curve, recent sessions). Works for a typed exercise too,
/// which simply has no catalogue part.
struct ExerciseDetailView: View {
    let name: String
    let catalogue: CatalogueExercise?

    @EnvironmentObject var repo: Repository
    @State private var history: WhoopStore.LiftExerciseHistory?

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    private var working: [LiftSetRow] {
        (history?.sets ?? []).filter { !$0.isWarmup && LiftMetrics.isPerformed(reps: $0.reps) }
    }
    private var points: [LiftProgress.Point] {
        LiftProgress.series(history?.sets ?? [], sessionStart: history?.sessionStart ?? [:])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                header
                statsSection
                if points.filter({ $0.bestEstimatedOneRepMaxKg != nil }).count >= 2 { progressSection }
                if !points.isEmpty { recentSection }
                if let catalogue, !catalogue.instructions(french: ExerciseLibrary.french).isEmpty {
                    stepsSection(catalogue)
                }
            }
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.vertical, NoopMetrics.gap)
        }
        .noopBackdrop(StrandPalette.effortColor)
        .navigationTitle(Text(verbatim: name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if let catalogue, let url = ExerciseLibrary.imageURL(catalogue) {
                ExerciseImageView(url: url, maxPixel: 720, cornerRadius: NoopMetrics.cardRadius)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            }
            Text(name)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let catalogue {
                Text(LiftMuscleSummary.line(primary: catalogue.primaryMuscle, secondaries: catalogue.secondaryMuscles))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let gear = ExerciseLibrary.equipmentName(catalogue.equipment) {
                    StatePill(LocalizedStringKey(gear), tone: .neutral, showsDot: false)
                }
                if let about = catalogue.description(french: ExerciseLibrary.french), !about.isEmpty {
                    Text(about)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Your figures

    private var statsSection: some View {
        let base = LiftRecordBaseline.from(history: working)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Your records", overline: "Personal")
            if history == nil {
                ComingSoon(what: "Reading your history…", symbol: "dumbbell")
            } else if working.isEmpty {
                NoopCard {
                    Text("You haven't logged this exercise yet. Its records and progress appear here after your first session.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.rowSpacing)],
                          alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                    tile(String(localized: "Best estimated 1RM"),
                         base.e1rmKg > 0 ? LiftFormat.weight(base.e1rmKg, system: unitSystem) : "—",
                         String(localized: "Epley, sets of 12 reps or fewer"))
                    tile(String(localized: "Heaviest"),
                         base.weightKg > 0 ? LiftFormat.weight(base.weightKg, system: unitSystem) : "—",
                         String(localized: "any rep count"))
                    tile(String(localized: "Best set"),
                         base.volumeKg > 0 ? LiftFormat.weight(base.volumeKg, system: unitSystem) : "—",
                         String(localized: "weight × reps, one set"))
                    tile(String(localized: "Sessions"),
                         "\(points.count)",
                         String(localized: "\(working.count) working sets in all"))
                }
            }
        }
    }

    private func tile(_ label: String, _ value: String, _ caption: String) -> some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).strandOverline()
                Text(value)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        let curve = points.filter { $0.bestEstimatedOneRepMaxKg != nil }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Progress", overline: "Estimated 1RM per session")
            NoopCard {
                Chart(curve, id: \.sessionId) { p in
                    let date = Date(timeIntervalSince1970: TimeInterval(p.startTs))
                    let value = LiftFormat.display(fromKilograms: p.bestEstimatedOneRepMaxKg ?? 0, system: unitSystem)
                    LineMark(x: .value("Date", date), y: .value("1RM", value))
                        .foregroundStyle(StrandPalette.effortColor)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", date), y: .value("1RM", value))
                        .foregroundStyle(StrandPalette.effortColor)
                        .symbolSize(24)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 180)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recent sessions", overline: "History")
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(points.reversed().prefix(8)), id: \.sessionId) { p in
                        HStack(spacing: NoopMetrics.rowSpacing) {
                            Text(Date(timeIntervalSince1970: TimeInterval(p.startTs)).formatted(date: .abbreviated, time: .omitted))
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer(minLength: 0)
                            Text(String(localized: "\(p.workingSets) sets · \(p.reps) reps"))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Text(LiftFormat.weight(p.topWeightKg, system: unitSystem))
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                }
            }
        }
    }

    // MARK: How to

    private func stepsSection(_ catalogue: CatalogueExercise) -> some View {
        let steps = catalogue.instructions(french: ExerciseLibrary.french)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("How to do it", overline: "Steps")
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.rowSpacing) {
                            Text("\(index + 1)")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.effortColor)
                                .frame(width: 18, alignment: .leading)
                            Text(step)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Load

    private func load() async {
        guard let store = await repo.storeHandle() else {
            history = WhoopStore.LiftExerciseHistory(sets: [], sessionStart: [:])
            return
        }
        history = (try? await store.liftExerciseHistory(deviceId: repo.deviceId, exercise: name,
                                                        catalogueId: catalogue?.id))
            ?? WhoopStore.LiftExerciseHistory(sets: [], sessionStart: [:])
    }
}
