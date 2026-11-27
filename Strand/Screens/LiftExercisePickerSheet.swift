import SwiftUI
import StrandDesign
import WhoopStore

// The "Add exercise" list of the routine editor: a search box, equipment and muscle filters, the exercises the
// user already uses, then the bundled library with a still for each. A tap adds the exercise to the routine.

/// What the picker hands back: a name, and the library exercise it stands for when there is one.
struct LiftPickedExercise {
    let name: String
    let catalogueId: String?
}

struct LiftExercisePickerSheet: View {
    let onPick: (LiftPickedExercise) -> Void
    /// "Create" was tapped: the caller opens its custom exercise editor.
    let onCreate: () -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var muscle: LiftMuscle?
    @State private var equipment: String?
    @State private var equipmentOptions: [String] = []
    @State private var results: [CatalogueExercise] = []
    @State private var vocabulary: [LiftExerciseRow] = []
    @State private var detail: CatalogueExercise?
    @FocusState private var searchFocused: Bool

    private var searchKey: String { "\(query)|\(muscle?.rawValue ?? "")|\(equipment ?? "")" }

    /// The user's own exercises matching the box, shown above the library while nothing narrows the library.
    private var recent: [LiftExerciseRow] {
        guard muscle == nil, equipment == nil else { return [] }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool = typed.isEmpty ? vocabulary : vocabulary.filter { $0.name.lowercased().contains(typed) }
        return Array(pool.prefix(typed.isEmpty ? 8 : 20))
    }

    var body: some View {
        VStack(spacing: 0) {
            GymSheetBar(title: "Add exercise") {
                GymBarButton(title: "Cancel") { dismiss() }
            } trailing: {
                GymBarButton(title: "Create") {
                    onCreate()
                    dismiss()
                }
            }
            searchField
                .padding(.horizontal, NoopMetrics.screenPadding)
            filterRow
                .padding(.vertical, NoopMetrics.rowSpacing)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !recent.isEmpty {
                        sectionLabel("Recent exercises")
                        ForEach(recent, id: \.id) { row in
                            Button { choose(name: row.name, catalogueId: row.catalogueId) } label: {
                                rowLabel(name: row.name, catalogueId: row.catalogueId,
                                         subtitle: LiftMuscleSummary.line(primary: row.primaryMuscle,
                                                                          secondaries: row.secondaryMuscles),
                                         info: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if ExerciseLibrary.shared != nil {
                        sectionLabel("All exercises")
                        ForEach(results) { entry in
                            Button {
                                choose(name: ExerciseLibrary.name(entry), catalogueId: entry.id, entry: entry)
                            } label: {
                                rowLabel(name: ExerciseLibrary.name(entry), catalogueId: entry.id,
                                         subtitle: ExerciseLibrary.subtitle(entry), info: entry)
                            }
                            .buttonStyle(.plain)
                        }
                        if results.isEmpty {
                            Text("No exercise matches. Create your own with the button above.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .padding(NoopMetrics.screenPadding)
                        }
                    } else if recent.isEmpty {
                        Text("No exercise yet. Create your own with the button above.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(NoopMetrics.screenPadding)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 720)
        #endif
        .noopBackdrop(StrandPalette.gymAccent)
        .sheet(item: $detail) { entry in
            NavigationStack {
                ExerciseDetailView(name: ExerciseLibrary.name(entry), catalogue: entry)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { detail = nil }
                        }
                    }
            }
        }
        .task {
            equipmentOptions = (try? ExerciseLibrary.shared?.equipmentValues()) ?? []
            if let store = await repo.storeHandle() {
                vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []
            }
        }
        .task(id: searchKey) { await search() }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: NoopMetrics.rowSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(StrandPalette.textTertiary)
            TextField("Search exercises", text: $query)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .focused($searchFocused)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(StrandPalette.surfaceRaised, in: Capsule())
    }

    private var filterRow: some View {
        HStack(spacing: NoopMetrics.rowSpacing) {
            Menu {
                Button("All equipment") { equipment = nil }
                ForEach(equipmentOptions, id: \.self) { option in
                    Button(ExerciseLibrary.equipmentName(option) ?? option) { equipment = option }
                }
            } label: {
                GymPill(title: ExerciseLibrary.equipmentName(equipment) ?? String(localized: "All equipment"),
                        selected: equipment != nil)
            }
            Menu {
                Button("All muscles") { muscle = nil }
                ForEach(LiftMuscle.Region.allCases, id: \.self) { region in
                    Section(region.displayName) {
                        ForEach(LiftMuscle.inRegion(region), id: \.self) { m in
                            Button(m.displayName) { muscle = m }
                        }
                    }
                }
            } label: {
                GymPill(title: muscle?.displayName ?? String(localized: "All muscles"), selected: muscle != nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NoopMetrics.screenPadding)
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.top, NoopMetrics.gap)
            .padding(.bottom, 4)
    }

    private func rowLabel(name: String, catalogueId: String?, subtitle: String, info: CatalogueExercise?) -> some View {
        HStack(spacing: NoopMetrics.gap) {
            GymExerciseThumb(catalogueId: catalogueId, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let info {
                Button { detail = info } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Exercise details")
            }
        }
        .padding(.horizontal, NoopMetrics.screenPadding)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func choose(name: String, catalogueId: String?, entry: CatalogueExercise? = nil) {
        onPick(LiftPickedExercise(name: name, catalogueId: catalogueId))
        // Remembered with its muscles so the next picker offers it back, as the line editor does.
        let known = vocabulary
        let device = repo.deviceId
        let row = vocabulary.first { $0.name == name }
        Task {
            guard let store = await repo.storeHandle() else { return }
            try? await LiftExerciseVocabulary.remember(
                name,
                primary: entry?.primaryMuscle ?? row?.primaryMuscle,
                secondaries: entry?.secondaryMuscles ?? row?.secondaryMuscles ?? [],
                known: known, deviceId: device, in: store,
                catalogueId: catalogueId, equipment: entry?.equipment ?? row?.equipment)
        }
        dismiss()
    }

    private func search() async {
        guard let catalogue = ExerciseLibrary.shared else { return }
        // Debounced, so typing does not run a query per keystroke.
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        let text = query, m = muscle, e = equipment
        results = await Task.detached(priority: .userInitiated) {
            (try? catalogue.search(text, muscle: m, equipment: e, limit: 150)) ?? []
        }.value
    }
}
