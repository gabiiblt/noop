import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// Gyms: the plates, bars, dumbbells and machine stacks of each place a person trains.
//
// A home rack with one pair of each size loads very differently from a big gym, and a plate calculator that
// assumes the wrong one is worse than none. So each gym keeps its own inventory, in its own unit (a 45 lb plate is
// a 45 lb plate), and a session remembers which gym it was done at. A gym that lists no plates has the standard set
// for its unit, which is what NOOP assumed before gyms existed.
//
// The plate maths is ported from openGym (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md) and checked against openGym's own code.

struct LiftGymsSheet: View {
    /// Called after a gym is added, changed, deleted or chosen, so the screen behind can reload.
    var onChanged: () async -> Void = {}

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    /// The gym a new session is done at. Kept as a preference: choosing a gym is not a change to the gym.
    @AppStorage(LiftGymsSheet.activeKey) private var activeGymId = ""
    static let activeKey = "noop.lift.activeGymId"

    @State private var gyms: [LiftGymRow] = []
    @State private var loaded = false
    @State private var editing: EditTarget?
    @State private var calculating: LiftGymRow?
    @State private var deleting: LiftGymRow?

    struct EditTarget: Identifiable {
        let gym: LiftGymRow?
        var id: String { gym?.id ?? "new" }
    }

    var body: some View {
        ScreenScaffold(title: "Gyms",
                       subtitle: "Plates, bars and dumbbells for each place you train. A session remembers which gym it was done at.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if loaded && gyms.isEmpty { emptyCard }
                ForEach(gyms, id: \.id) { gymCard($0) }
                NoopButton("Add a gym", systemImage: "plus", kind: .secondary) {
                    editing = EditTarget(gym: nil)
                }
                .disabled(gyms.count >= WhoopStore.maxGyms)
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 720)
        #endif
        .background(StrandPalette.surfaceBase)
        .task { await load() }
        .sheet(item: $editing) { target in
            LiftGymEditSheet(gym: target.gym) { saved in
                if activeGymId.isEmpty { activeGymId = saved.id }
                await load()
                await onChanged()
            }
        }
        .sheet(item: $calculating) { gym in
            LiftPlateCalculatorSheet(gym: gym)
        }
        .confirmationDialog(
            deleting.map { Text(String(localized: "Delete \($0.name)?")) } ?? Text(""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Sessions done at this gym are kept exactly as they are.")
        }
    }

    // MARK: - Cards

    private var emptyCard: some View {
        NoopCard {
            Text("No gym yet. Until you add one, plate lines are not shown. A gym that lists no plates uses the standard set for its unit.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gymCard(_ gym: LiftGymRow) -> some View {
        let isActive = effectiveActiveId == gym.id
        return NoopCard(tint: isActive ? StrandPalette.effortColor : nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text(gym.name)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(gym.unit)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(LiftGymCopy.summary(gym))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: NoopMetrics.gap) {
                    if isActive {
                        Label("In use", systemImage: "checkmark.circle.fill")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.statusPositive)
                    } else {
                        Button("Use this gym") { activeGymId = gym.id; Task { await onChanged() } }
                            .buttonStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    Spacer(minLength: 0)
                    Button("Calculator") { calculating = gym }
                        .buttonStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.accent)
                    Button("Edit") { editing = EditTarget(gym: gym) }
                        .buttonStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.accent)
                    Button { deleting = gym } label: {
                        Image(systemName: "trash").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Delete this gym"))
                }
            }
        }
    }

    /// The gym in use: the chosen one if it still exists, else the one used most recently.
    private var effectiveActiveId: String? {
        gyms.contains { $0.id == activeGymId } ? activeGymId : gyms.first?.id
    }

    // MARK: - Behaviour

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        gyms = (try? await store.liftGyms(deviceId: repo.deviceId)) ?? []
        loaded = true
    }

    private func delete() async {
        guard let gym = deleting, let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteLiftGym(id: gym.id)
        if activeGymId == gym.id { activeGymId = "" }
        deleting = nil
        await load()
        await onChanged()
    }
}

// MARK: - Edit one gym

struct LiftGymEditSheet: View {
    /// The gym being edited, or nil to add one.
    let gym: LiftGymRow?
    let onSaved: (LiftGymRow) async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var unit: LiftPlateUnit = .kg
    /// Off: the standard set for the unit. On: the pairs below.
    @State private var ownPlates = false
    @State private var pairs: [Double: Int] = [:]
    @State private var barText: [String: String] = [:]
    @State private var dumbbellText = ""
    @State private var loaded = false

    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, bar(String), dumbbells }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The most pairs of one size the stepper offers.
    private static let maxPairs = 12

    var body: some View {
        ScreenScaffold(title: gym == nil ? "Add a gym" : "Edit gym",
                       subtitle: "What you can load here. Leave the plates on the standard set if you have not counted them.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                nameCard
                platesCard
                barsCard
                dumbbellsCard
                footer
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 720)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        .dismissesKeyboardOnTap($focused)
        .onAppear(perform: load)
    }

    // MARK: - Sections

    private var nameCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text("Name").strandOverline()
                TextField("Home, Big gym", text: $name)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .focused($focused, equals: .name)
                    .onChange(of: name) { new in
                        if new.count > WhoopStore.maxGymNameLength { name = String(new.prefix(WhoopStore.maxGymNameLength)) }
                    }
                Text("Unit").strandOverline()
                Picker("Unit", selection: $unit) {
                    Text("kg").tag(LiftPlateUnit.kg)
                    Text("lb").tag(LiftPlateUnit.lb)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: unit) { _ in
                    // An inventory is in the gym's own unit: switching it starts the plates and bars again
                    // rather than relabelling 20 kg plates as 20 lb ones.
                    pairs = Dictionary(uniqueKeysWithValues: LiftPlates.defaultInventory(unit).map { ($0.size, $0.pairs) })
                    barText = [:]
                }
            }
        }
    }

    private var platesCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text("Plates").strandOverline()
                Toggle("I counted my plates", isOn: $ownPlates)
                    .tint(StrandPalette.accent)
                    .onChange(of: ownPlates) { on in
                        if on && pairs.isEmpty {
                            pairs = Dictionary(uniqueKeysWithValues: LiftPlates.defaultInventory(unit).map { ($0.size, $0.pairs) })
                        }
                    }
                if ownPlates {
                    ForEach(LiftPlates.sizes(unit), id: \.self) { size in
                        Stepper(value: pairsBinding(size), in: 0...Self.maxPairs) {
                            HStack {
                                Text("\(LiftFormat.trim(size)) \(LiftGymCopy.unitLabel(unit))")
                                    .font(StrandFont.bodyNumber)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text("\(pairs[size] ?? 0) pairs")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                } else {
                    Text("The standard set: six pairs of each usual size, the way a big gym racks them.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var barsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text("Bars").strandOverline()
                ForEach(LiftPlates.barTypes, id: \.self) { type in
                    HStack {
                        Text(LiftGymCopy.barName(type))
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        TextField(LiftFormat.trim(LiftPlates.defaultBar(type, unit: unit) ?? 0),
                                  text: Binding(get: { barText[type] ?? "" }, set: { barText[type] = $0 }))
                            .textFieldStyle(.plain)
                            .font(StrandFont.bodyNumber)
                            .multilineTextAlignment(.trailing)
                            .numericKeyboard()
                            .focused($focused, equals: .bar(type))
                            .frame(width: 70)
                        Text(LiftGymCopy.unitLabel(unit))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Text("Leave a bar blank to use its usual weight. A short bar, or a Smith machine that counterbalances its carriage, goes here.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dumbbellsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text("Dumbbells").strandOverline()
                TextField("5, 7.5, 10, 12.5, 15", text: $dumbbellText)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .focused($focused, equals: .dumbbells)
                Text("The weights you own, separated by commas. Leave it empty if you have not listed them.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button("Save") { Task { await save() } }
                .buttonStyle(.noopPrimary)
                .frame(maxWidth: 160)
                .disabled(!canSave)
                .opacity(canSave ? 1 : NoopButtonMetrics.disabledOpacity)
        }
    }

    // MARK: - Behaviour

    private func pairsBinding(_ size: Double) -> Binding<Int> {
        Binding(get: { pairs[size] ?? 0 }, set: { pairs[size] = $0 })
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let gym else { return }
        name = gym.name
        unit = LiftGymLoading.unit(of: gym)
        ownPlates = !gym.plates.isEmpty
        pairs = Dictionary(uniqueKeysWithValues: gym.plates.map { ($0.size, $0.pairs) })
        barText = gym.bars.mapValues { LiftFormat.trim($0) }
        dumbbellText = gym.dumbbells.map { LiftFormat.trim($0) }.joined(separator: ", ")
    }

    private func save() async {
        guard canSave, let store = await repo.storeHandle() else { return }
        let plates = ownPlates ? pairs.map { LiftGymPlate(size: $0.key, pairs: $0.value) } : []
        var bars: [String: Double] = [:]
        for (type, text) in barText { if let v = LiftFormat.number(text), v > 0 { bars[type] = v } }
        let dumbbells = dumbbellText.split(whereSeparator: { ",;".contains($0) }).compactMap { LiftFormat.number(String($0)) }
        let row = LiftGymRow(
            id: gym?.id ?? UUID().uuidString, deviceId: repo.deviceId,
            name: name, unit: unit.rawValue, plates: plates, bars: bars, dumbbells: dumbbells,
            // A machine's stack is kept as it was: this sheet does not edit it yet.
            stacks: gym?.stacks ?? [:],
            createdAt: gym?.createdAt ?? Int(Date().timeIntervalSince1970), lastUsedTs: gym?.lastUsedTs)
        _ = try? await store.upsertLiftGyms([row])
        await onSaved(row)
        dismiss()
    }
}

// MARK: - The calculator

/// What goes on the bar for a weight, at one gym. For the lifter standing at the rack with a number in their head.
struct LiftPlateCalculatorSheet: View {
    let gym: LiftGymRow

    @Environment(\.dismiss) private var dismiss
    @State private var equipment = "barbell"
    @State private var weightText = ""
    @FocusState private var focused: CalculatorField?
    private enum CalculatorField: Hashable { case weight }

    private var unit: LiftPlateUnit { LiftGymLoading.unit(of: gym) }
    private var weight: Double? { LiftFormat.number(weightText) }
    private var result: LiftGymLoad? {
        weight.flatMap { LiftGymLoading.load(gym: gym, equipment: equipment, weight: $0) }
    }
    private var equipmentChoices: [String] { LiftPlates.barTypes + ["sled machine"] }

    var body: some View {
        ScreenScaffold(title: "Plate calculator", subtitle: gym.name) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                        Text("Loaded on").strandOverline()
                        Picker("Loaded on", selection: $equipment) {
                            ForEach(equipmentChoices, id: \.self) { Text(LiftGymCopy.barName($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Text("Total weight (\(LiftGymCopy.unitLabel(unit)))").strandOverline()
                        TextField("100", text: $weightText)
                            .textFieldStyle(.plain)
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .numericKeyboard()
                            .focused($focused, equals: .weight)
                    }
                }
                resultCard
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 480, height: 560)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        .dismissesKeyboardOnTap($focused)
    }

    @ViewBuilder private var resultCard: some View {
        if let result {
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LiftGymCopy.line(result))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if result.base > 0 {
                        Text("Bar \(LiftFormat.trim(result.base)) \(LiftGymCopy.unitLabel(unit))")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    if result.load.missing > 0 {
                        Text("This gym makes \(LiftFormat.trim(result.achievable)) \(LiftGymCopy.unitLabel(unit)) at most near that weight.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if weight != nil {
            NoopCard {
                Text("Nothing to load for that weight.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}
