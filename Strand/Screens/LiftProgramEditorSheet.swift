import SwiftUI
import StrandDesign
import WhoopStore

// Build or edit a routine: a name and an ordered list of exercise lines carrying the TARGETS —
// working sets, reps, weight, rest and the user's own technique note.
//
// Lines are edited as local drafts and written in one go on Save, through
// `replaceLiftProgramItems`, which swaps the whole list transactionally. Editing a program never
// rewrites history: a session snapshots the program's NAME when it runs, so renaming "Upper A" or
// deleting it entirely leaves every past session reading exactly as it did.

struct LiftProgramEditorSheet: View {
    /// The program being edited, or nil to create a new one.
    let program: LiftProgramRow?
    /// Called after a successful save or delete, so the caller can reload.
    let onSaved: () async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var note: String = ""
    /// The exercise lines, in display order. `ord` is assigned from the array index on save, so
    /// reordering is just moving an element.
    @State private var items: [LiftProgramItemRow] = []
    @State private var loaded = false
    @State private var saving = false

    /// The line being added or edited (nil = that sheet is closed).
    @State private var editingItem: ItemEditTarget?
    @State private var confirmingDelete = false

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var picking = false
    /// "Create" was tapped in the picker: the custom exercise editor opens once the picker is gone.
    @State private var wantsCustom = false
    /// Lines whose note field is open, whether or not it has text yet.
    @State private var noteOpen: Set<String> = []

    @FocusState private var focused: Field?
    private enum Field: Hashable {
        case name, note
        case itemNote(String)
        case weight(String, Int)
        case reps(String, Int)
    }

    private var isNew: Bool { program == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        VStack(spacing: 0) {
            GymSheetBar(title: isNew ? "New routine" : "Edit routine") {
                GymBarButton(title: "Cancel") { dismiss() }
            } trailing: {
                GymBarButton(title: isNew ? "Save" : "Update", prominent: true, enabled: canSave) {
                    Task { await save() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    titleField
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        exerciseBlock(item, index: index)
                    }
                    Button { picking = true } label: {
                        Label("Add exercise", systemImage: "plus")
                            .font(StrandFont.headline)
                            .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight)
                    }
                    .noopGlassButton(prominent: true, tint: StrandPalette.gymAccent)
                    if !isNew { deleteSection }
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.bottom, NoopMetrics.sectionGap)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        // A fixed frame, for the reason the other editor sheets document: a macOS sheet hosting a
        // ScrollView needs a definite height or every row collapses to the top.
        .frame(width: 520, height: 720)
        #endif
        .noopBackdrop(StrandPalette.gymAccent)
        .keyboardDoneToolbar($focused)
        .task { await loadIfNeeded() }
        .sheet(item: $editingItem) { target in
            LiftProgramItemSheet(item: target.item) { saved in
                apply(saved, replacing: target.item)
            }
        }
        .sheet(isPresented: $picking, onDismiss: {
            if wantsCustom {
                wantsCustom = false
                editingItem = ItemEditTarget(id: "new", item: nil)
            }
        }) {
            LiftExercisePickerSheet(onPick: { picked in addLine(picked) },
                                    onCreate: { wantsCustom = true })
        }
    }

    // MARK: - Title

    private var titleField: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            HStack(spacing: NoopMetrics.rowSpacing) {
                TextField("Routine title", text: $name)
                    .textFieldStyle(.plain)
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .focused($focused, equals: .name)
                if !name.isEmpty {
                    Button { name = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear title")
                }
            }
            Divider().overlay(StrandPalette.hairline)
            TextField("Note (optional)", text: $note)
                // Capped at what the hub can actually show (two caption lines). A field
                // that silently discards the end is worse than one that stops.
                .onChange(of: note) { new in
                    if new.count > WhoopStore.maxProgramNoteLength {
                        note = String(new.prefix(WhoopStore.maxProgramNoteLength))
                    }
                }
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .focused($focused, equals: .note)
        }
    }

    // MARK: - Exercise blocks

    private func exerciseBlock(_ item: LiftProgramItemRow, index: Int) -> some View {
        let rows = max(item.targetSets ?? 1, 1)
        let linked = item.supersetGroup != nil
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(spacing: NoopMetrics.gap) {
                GymExerciseThumb(catalogueId: item.catalogueId)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.exercise)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.gymAccent)
                        .lineLimit(2)
                    if linked {
                        Label("Superset", systemImage: "link")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                lineMenu(item, index: index)
            }

            HStack(spacing: NoopMetrics.rowSpacing) {
                restMenu(item)
                Button {
                    if noteOpen.contains(item.id) { noteOpen.remove(item.id) } else { noteOpen.insert(item.id) }
                } label: {
                    GymPill(title: String(localized: "Note"), systemImage: "note.text",
                            selected: noteOpen.contains(item.id) || !(item.note ?? "").isEmpty)
                }
                .buttonStyle(.plain)
            }

            if noteOpen.contains(item.id) || !(item.note ?? "").isEmpty {
                TextField("Technique note", text: noteBinding(item.id), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(NoopMetrics.gap)
                    .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: NoopMetrics.radiusControl, style: .continuous))
                    .focused($focused, equals: .itemNote(item.id))
            }

            GymSetHeader(unitSystem: unitSystem)
            // A line's targets are the same for each set, so every row shows the same pair and an
            // edit to one is an edit to all: the rows cannot disagree with what is stored.
            ForEach(1...rows, id: \.self) { number in
                HStack(spacing: NoopMetrics.rowSpacing) {
                    GymSetBadge(index: number)
                    GymNumberCell(placeholder: "–",
                                  value: item.targetWeightKg.map { LiftFormat.display(fromKilograms: $0, system: unitSystem) },
                                  focus: $focused, field: .weight(item.id, number)) { value in
                        update(item.id) {
                            $0.targetWeightKg = value.map { LiftFormat.kilograms(fromDisplay: $0, system: unitSystem) }
                        }
                    }
                    GymNumberCell(placeholder: "–",
                                  value: item.targetRepsLow.map(Double.init),
                                  focus: $focused, field: .reps(item.id, number)) { value in
                        update(item.id) {
                            let reps = value.map { Int($0.rounded()) }
                            $0.targetRepsLow = reps
                            // A rep range collapses to the single number typed.
                            if $0.targetRepsHigh != nil { $0.targetRepsHigh = reps }
                        }
                    }
                }
            }

            HStack(spacing: NoopMetrics.rowSpacing) {
                Button {
                    update(item.id) { $0.targetSets = rows + 1 }
                } label: {
                    Label("Add set", systemImage: "plus")
                        .font(StrandFont.subhead)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(StrandPalette.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textPrimary)
                if rows > 1 {
                    Button {
                        update(item.id) { $0.targetSets = rows - 1 }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(StrandPalette.surfaceRaised, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityLabel("Remove set")
                }
            }
        }
        .padding(.vertical, NoopMetrics.rowSpacing)
    }

    private func lineMenu(_ item: LiftProgramItemRow, index: Int) -> some View {
        Menu {
            Button { editingItem = ItemEditTarget(id: item.id, item: item) } label: {
                Label("Edit details", systemImage: "slider.horizontal.3")
            }
            if index < items.count - 1 {
                let linked = LiftSuperset.isLinkedToNext(items, index)
                Button { items = LiftSuperset.toggledLink(items, at: index) } label: {
                    Label(linked ? "Unlink superset" : "Superset with the next exercise",
                          systemImage: linked ? "link" : "link.badge.plus")
                }
            }
            if index > 0 {
                Button { move(from: index, by: -1) } label: { Label("Move up", systemImage: "chevron.up") }
            }
            if index < items.count - 1 {
                Button { move(from: index, by: 1) } label: { Label("Move down", systemImage: "chevron.down") }
            }
            Button(role: .destructive) {
                items.removeAll { $0.id == item.id }
                items = LiftSuperset.normalized(items)
            } label: {
                Label("Remove exercise", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Exercise options")
    }

    private func restMenu(_ item: LiftProgramItemRow) -> some View {
        Menu {
            ForEach(GymRestPresets.seconds, id: \.self) { seconds in
                Button {
                    update(item.id) { $0.restSec = seconds }
                } label: {
                    Text(seconds.map { LiftFormat.duration($0) } ?? String(localized: "No rest timer"))
                }
            }
        } label: {
            GymPill(title: item.restSec.map { LiftFormat.duration($0) } ?? String(localized: "Rest: off"),
                    systemImage: "timer", selected: item.restSec != nil)
        }
        .accessibilityLabel("Rest timer")
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            Label("Delete routine", systemImage: "trash")
                .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight)
        }
        .noopGlassButton()
        .confirmationDialog("Delete this routine?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteProgram() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Sessions you already logged from it are kept.")
        }
    }

    // MARK: - Helpers

    /// Change one line in place, by id.
    private func update(_ id: String, _ mutate: (inout LiftProgramItemRow) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    private func noteBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { items.first { $0.id == id }?.note ?? "" },
            set: { new in update(id) { $0.note = new.isEmpty ? nil : new } }
        )
    }

    /// A line for an exercise picked from the picker: three working sets, no weight until the user says.
    private func addLine(_ picked: LiftPickedExercise) {
        items.append(LiftProgramItemRow(
            id: UUID().uuidString, deviceId: repo.deviceId, programId: program?.id ?? "",
            ord: items.count, exercise: picked.name, targetSets: 3, targetRepsLow: nil,
            targetRepsHigh: nil, targetRpe: nil, targetWeightKg: nil, restSec: nil, note: nil,
            catalogueId: picked.catalogueId))
    }

    private func move(from index: Int, by offset: Int) {
        let target = index + offset
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target)
        // A move can split a superset: each consecutive run stays one, a line left alone is no group.
        items = LiftSuperset.normalized(items)
    }

    /// Insert a new line, or replace an edited one in place so its position is kept.
    private func apply(_ saved: LiftProgramItemRow, replacing old: LiftProgramItemRow?) {
        guard let old, let index = items.firstIndex(where: { $0.id == old.id }) else {
            items.append(saved)
            return
        }
        items[index] = saved
    }

    // MARK: - Load / save

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let program else { return }
        name = program.name
        note = program.note ?? ""
        guard let store = await repo.storeHandle() else { return }
        items = (try? await store.liftProgramItems(programId: program.id)) ?? []
    }

    private func save() async {
        guard canSave, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        let now = Int(Date().timeIntervalSince1970)
        let id = program?.id ?? UUID().uuidString
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        // A copy of the program being edited, not a rebuild: rebuilding dropped every column added since (the rotation's
        // place and rest days) each time a program was saved.
        var row = program ?? LiftProgramRow(id: id, deviceId: repo.deviceId, name: "", note: nil,
                                            createdAt: now, updatedAt: now, archived: false)
        row.deviceId = repo.deviceId
        row.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        row.note = trimmedNote.isEmpty ? nil : trimmedNote
        row.updatedAt = now
        _ = try? await store.upsertLiftPrograms([row])

        // `ord` is the array index: reordering the list is all it takes to reorder the program.
        // A copy of each line with its place changed, not a rebuild: rebuilding field by field dropped every
        // column added since (the catalogue link, the progression rule) each time a program was saved.
        let ordered = LiftSuperset.normalized(items).enumerated().map { index, item -> LiftProgramItemRow in
            var line = item
            line.deviceId = repo.deviceId
            line.programId = id
            line.ord = index
            return line
        }
        _ = try? await store.replaceLiftProgramItems(programId: id, items: ordered)

        await onSaved()
        dismiss()
    }

    private func deleteProgram() async {
        guard let program, let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteLiftProgram(id: program.id)
        await onSaved()
        dismiss()
    }
}

/// What the line editor is editing — a wrapper so "new line" has an identity to present on.
private struct ItemEditTarget: Identifiable {
    let id: String
    let item: LiftProgramItemRow?
}
