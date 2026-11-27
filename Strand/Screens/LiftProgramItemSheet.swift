import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// Edit ONE exercise line of a program: which exercise, and the targets for it.
//
// NOOP SHIPS NO EXERCISE CATALOGUE — deliberately. The user types whatever they call the movement
// and it is remembered in `liftExercise` with the muscle group they gave it, then offered back next
// time. A shipped mapping of common exercises to muscles would be both a permanent maintenance
// burden and a correctness claim NOOP has no business making about someone else's technique.
//
// Classification is therefore a one-time, few-second action per exercise: pick the primary muscle
// (a direct set) and any secondaries (indirect, counted at half). It is asked once, on first use,
// and remembered thereafter. Leaving it unset is allowed — an unclassified exercise still counts
// toward volume and session load, it simply claims no muscle it was never assigned.

struct LiftProgramItemSheet: View {
    /// The line being edited, or nil to add a new one.
    let item: LiftProgramItemRow?
    /// Handed the finished line. The parent owns ordering and persistence.
    let onSave: (LiftProgramItemRow) -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var exercise: String = ""
    @State private var primary: LiftMuscle?
    @State private var secondaries: Set<LiftMuscle> = []

    @State private var setsText: String = ""
    @State private var repsText: String = ""
    @State private var weightText: String = ""
    @State private var restText: String = ""
    @State private var maxRpeText: String = ""
    @State private var note: String = ""
    /// The progression rule driving this line's next target, or nil for none, with its settings as typed.
    @State private var progression: LiftProgressionPolicy?
    @State private var repsHighText: String = ""
    @State private var setsMaxText: String = ""
    @State private var stepText: String = ""
    @State private var deloadText: String = ""
    /// Exercises that can take this line's place when its machine is taken, and the name being typed.
    @State private var backups: [String] = []
    @State private var backupText: String = ""

    /// The user's own exercise vocabulary, for suggestions and for adopting a known classification.
    @State private var vocabulary: [LiftExerciseRow] = []
    @State private var loaded = false
    /// The vocabulary entry the user is about to forget (nil = no confirmation showing).
    @State private var forgetting: LiftExerciseRow?
    /// Set when the vocabulary is full, so the refusal is explained rather than silent.
    @State private var vocabularyFullLimit: Int?
    /// The library exercise the name was picked from, until the name is edited away from it.
    @State private var picked: CatalogueExercise?

    /// The app's existing metric/imperial preference — the Lift Log never adds a second weight unit
    /// setting of its own, so the plan is typed in the same unit the session records in.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var weightLabel: LocalizedStringKey {
        unitSystem == .imperial ? "Weight (lb)" : "Weight (kg)"
    }

    @FocusState private var focused: Field?
    private enum Field: Hashable { case exercise, sets, reps, weight, rest, maxRpe, note, repsHigh, setsMax, step, deload, backup }

    private var trimmedExercise: String {
        exercise.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The ceiling as typed, when it is one: 1 to 10. A blank field is no ceiling.
    private var maxRpe: Double? {
        LiftFormat.number(maxRpeText).flatMap { (1...10).contains($0) ? $0 : nil }
    }
    private var maxRpeInvalid: Bool {
        !maxRpeText.trimmingCharacters(in: .whitespaces).isEmpty && maxRpe == nil
    }
    private var canSave: Bool { !trimmedExercise.isEmpty && !maxRpeInvalid && !deloadInvalid }

    /// The deload factor as typed, when it is one: 50 to 95 percent. A blank field takes the default (90).
    private var deloadPercent: Double? {
        LiftFormat.number(deloadText).flatMap { (50...95).contains($0) ? $0 : nil }
    }
    private var deloadInvalid: Bool {
        !deloadText.trimmingCharacters(in: .whitespaces).isEmpty && deloadPercent == nil
    }

    private var suggestions: [LiftExerciseRow] {
        LiftExerciseVocabulary.suggestions(vocabulary, matching: exercise)
    }

    var body: some View {
        ScreenScaffold(
            title: item == nil ? "Add exercise" : "Edit exercise",
            subtitle: "Type any name you like. NOOP remembers it, with the muscles you give it."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                exerciseSection
                LiftMusclePicker(primary: $primary, secondaries: $secondaries)
                targetsSection
                progressionSection
                backupsSection
                noteSection
                footer
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 720)
        #endif
        .noopBackdrop(StrandPalette.gymAccent)
        .keyboardDoneToolbar($focused)
        .dismissesKeyboardOnTap($focused)
        .task { await loadIfNeeded() }
        // Typing a different name after a library pick un-links it: the link is to that exact name.
        .onChange(of: exercise) { _ in
            if let picked, exercise.trimmingCharacters(in: .whitespacesAndNewlines) != ExerciseLibrary.name(picked) {
                self.picked = nil
            }
        }
        .confirmationDialog(
            forgetting.map { Text(String(localized: "Forget \($0.name)?")) } ?? Text(""),
            isPresented: Binding(get: { forgetting != nil },
                                 set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) { Task { await forget() } }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("It stops being offered here. Sessions you already logged with it are kept exactly as they are.")
        }
        .alert("You've saved the most exercises NOOP remembers",
               isPresented: Binding(get: { vocabularyFullLimit != nil },
                                    set: { if !$0 { vocabularyFullLimit = nil } })) {
            Button("OK", role: .cancel) { vocabularyFullLimit = nil }
        } message: {
            Text("Forget one you no longer use and this one will save. Your logged sessions are never affected.")
        }
    }

    /// Forget an exercise. The logged sets keep their own copy of the name and muscles, so this
    /// removes it from the picker WITHOUT touching a single recorded session.
    private func forget() async {
        guard let row = forgetting, let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteLiftExercise(id: row.id)
        vocabulary.removeAll { $0.id == row.id }
        forgetting = nil
    }

    // MARK: - Exercise name + suggestions

    private var exerciseSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Exercise", overline: "Movement")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    TextField("Incline dumbbell press", text: $exercise)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .focused($focused, equals: .exercise)

                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Used before").strandOverline()
                            ForEach(suggestions, id: \.id) { row in
                                HStack(spacing: 8) {
                                    Button {
                                        adopt(row)
                                    } label: {
                                        LiftExerciseSuggestionLabel(row: row)
                                    }
                                    .buttonStyle(.plain)

                                    // A typo becomes a permanent picker entry otherwise. Forgetting a
                                    // name is safe by construction: every logged set SNAPSHOTS its
                                    // exercise name and classification, so history is untouched.
                                    Button(role: .destructive) {
                                        forgetting = row
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Forget this exercise")
                                }
                            }
                        }
                    }
                    if picked == nil {
                        CatalogueExerciseSuggestions(query: exercise) { adoptCatalogue($0) }
                    } else if let picked {
                        CatalogueExerciseRowLabel(exercise: picked, thumbnail: 40)
                    }
                }
            }
        }
    }

    // MARK: - Targets

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Targets", overline: "What you're aiming for")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: NoopMetrics.gap) {
                        field("Working sets") {
                            numberInput("4", text: $setsText, field: .sets)
                        }
                        field("Reps") {
                            numberInput("8", text: $repsText, field: .reps)
                        }
                    }
                    HStack(spacing: NoopMetrics.gap) {
                        field(weightLabel) {
                            numberInput("60", text: $weightText, field: .weight)
                        }
                        field("Rest (seconds)") {
                            numberInput("120", text: $restText, field: .rest)
                        }
                    }
                    // Max RPE is a CEILING, not effort planned in advance (Utku, 15 Sep 2026): the
                    // hardest a set should feel, so a lifter knows where to hold back. It is shown grey in
                    // the session and, like every other grey number, a set left unrated saves it
                    // (Utku, 16 Sep 2026; RULES 34) — typing a rating always wins.
                    HStack(spacing: NoopMetrics.gap) {
                        field("Max RPE (1–10)") {
                            numberInput("8", text: $maxRpeText, field: .maxRpe)
                        }
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                    if maxRpeInvalid {
                        Text("Max RPE must be between 1 and 10.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                    }
                    Text("Max RPE is a ceiling: the hardest a set should feel, where 10 means nothing left. It shows grey during the session, and a set you leave unrated saves it as its rating.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Every target is optional — this is the plan, not the record. What you actually lift is entered set by set during the session.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Progression

    /// The rule that sets this line's next target from what you did last time. Off by default: a line with no
    /// rule behaves exactly as it always has.
    private var progressionSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Progression", overline: "Next target")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Progression", selection: $progression) {
                        Text("None").tag(LiftProgressionPolicy?.none)
                        ForEach(LiftProgressionStore.pickable, id: \.self) { rule in
                            Text(LiftProgressionCopy.name(rule)).tag(LiftProgressionPolicy?.some(rule))
                        }
                    }
                    .pickerStyle(.menu)
                    Text(LiftProgressionCopy.summary(progression ?? .off))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let rule = progression {
                        if rule != .linear {
                            HStack(spacing: NoopMetrics.gap) {
                                field("Top of the range (reps)") {
                                    numberInput("12", text: $repsHighText, field: .repsHigh)
                                }
                                if rule == .triple {
                                    field("Most sets") {
                                        numberInput("5", text: $setsMaxText, field: .setsMax)
                                    }
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                                }
                            }
                            Text("Without a top, the range is the 2 reps below your reps.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: NoopMetrics.gap) {
                            field(stepLabel) {
                                numberInput("2.5", text: $stepText, field: .step)
                            }
                            field("Deload to (% of the weight)") {
                                numberInput("90", text: $deloadText, field: .deload)
                            }
                        }
                        if deloadInvalid {
                            Text("The deload must be between 50 and 95 percent.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusWarning)
                        }
                        Text("A line with a rule is not rewritten after a session: its target comes from your history, with the reason shown in the session.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Backups

    /// What can take this line's place when its machine is taken: the plan already says what to do instead.
    private var backupsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Backups", overline: "If the machine is taken")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(backups, id: \.self) { name in
                        HStack {
                            Text(name)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Button {
                                backups.removeAll { $0 == name }
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(StrandPalette.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Remove"))
                        }
                    }
                    if backups.count < LiftSuperset.maxBackups {
                        HStack(spacing: 8) {
                            TextField("Another exercise", text: $backupText)
                                .textFieldStyle(.plain)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .focused($focused, equals: .backup)
                                .onSubmit(addBackup)
                            Button("Add", action: addBackup)
                                .buttonStyle(.plain)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.accent)
                                .disabled(backupText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        ForEach(backupSuggestions, id: \.id) { row in
                            Button(row.name) { backupText = row.name; addBackup() }
                                .buttonStyle(.plain)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
                    Text("In a session, one tap swaps a backup in for this exercise. The sets, reps and rest stay; the weight does not, because it was for the other one.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Exercises you already use that match what is being typed, so a backup is usually one tap.
    private var backupSuggestions: [LiftExerciseRow] {
        guard !backupText.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Array(LiftExerciseVocabulary.suggestions(vocabulary, matching: backupText)
            .filter { $0.name != trimmedExercise && !backups.contains($0.name) }.prefix(4))
    }

    private func addBackup() {
        backups = LiftSuperset.cleanBackups(backups + [backupText], excluding: trimmedExercise)
        backupText = ""
    }

    private var stepLabel: LocalizedStringKey {
        unitSystem == .imperial ? "Weight step (lb)" : "Weight step (kg)"
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Technique note", overline: "In your words")
            NoopCard {
                TextField("Slow eccentric, pause at the bottom", text: $note, axis: .vertical)
                    // A cue read between sets, and it renders directly above the set rows — every
                    // line pushes them down the screen.
                    .onChange(of: note) { new in
                        if new.count > WhoopStore.maxExerciseNoteLength {
                            note = String(new.prefix(WhoopStore.maxExerciseNoteLength))
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1...4)
                    .focused($focused, equals: .note)
            }
        }
    }

    // MARK: - Footer

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
                .accessibilityLabel("Save exercise")
        }
    }

    // MARK: - Field helpers (the house form idiom)

    private func field<Content: View>(_ label: LocalizedStringKey,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: LocalizedStringKey,
                             text: Binding<String>,
                             field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            .focused($focused, equals: field)
    }

    // MARK: - Behaviour

    /// Take a known exercise from the vocabulary, including the classification it already carries —
    /// so a movement is classified once and never asked about again.
    private func adopt(_ row: LiftExerciseRow) {
        exercise = row.name
        primary = row.primaryMuscle
        secondaries = Set(row.secondaryMuscles)
        picked = nil
        focused = nil
    }

    /// Take a library exercise: its name in the app's language, its muscles, and the link to its entry.
    private func adoptCatalogue(_ entry: CatalogueExercise) {
        exercise = ExerciseLibrary.name(entry)
        primary = entry.primaryMuscle
        secondaries = Set(entry.secondaryMuscles)
        picked = entry
        focused = nil
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let item {
            exercise = item.exercise
            setsText = item.targetSets.map(String.init) ?? ""
            repsText = item.targetRepsLow.map(String.init) ?? ""
            weightText = item.targetWeightKg.map {
                LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: unitSystem))
            } ?? ""
            restText = item.restSec.map(String.init) ?? ""
            maxRpeText = item.targetRpe.map { LiftFormat.trim($0) } ?? ""
            note = item.note ?? ""
            progression = LiftProgressionStore.policy(of: item)
            repsHighText = item.targetRepsHigh.map(String.init) ?? ""
            setsMaxText = item.targetSetsMax.map(String.init) ?? ""
            stepText = item.incrementKg.map { LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: unitSystem)) } ?? ""
            deloadText = item.deloadFactor.map { LiftFormat.trim($0 * 100) } ?? ""
            backups = item.backups
        }
        guard let store = await repo.storeHandle() else { return }
        vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []
        // An existing line adopts whatever classification its exercise already carries, so editing a
        // line shows the muscles the exercise is known by rather than an empty picker.
        if let item, let known = vocabulary.first(where: { $0.name == item.exercise }) {
            primary = known.primaryMuscle
            secondaries = Set(known.secondaryMuscles)
        }
    }

    /// The top of the rep range, only for a rule that works through one and only when it is above the bottom.
    private var rangeTop: Int? {
        guard let rule = progression, rule != .linear,
              let top = Int(repsHighText.trimmingCharacters(in: .whitespaces)),
              let low = Int(repsText.trimmingCharacters(in: .whitespaces)), top > low else { return nil }
        return top
    }

    /// Triple progression's ceiling, only when it is above the line's sets.
    private var setsMaxValue: Int? {
        guard let most = Int(setsMaxText.trimmingCharacters(in: .whitespaces)),
              let sets = Int(setsText.trimmingCharacters(in: .whitespaces)), most > sets else { return nil }
        return most
    }

    /// The weight step in kilograms, when one was typed.
    private var stepKg: Double? {
        LiftFormat.number(stepText).flatMap { $0 > 0 ? LiftFormat.kilograms(fromDisplay: $0, system: unitSystem) : nil }
    }

    private func save() async {
        guard canSave else { return }
        let name = trimmedExercise

        // Remember the exercise (and its classification) in the vocabulary, so it is offered back
        // next time.
        if let store = await repo.storeHandle() {
            do {
                try await LiftExerciseVocabulary.remember(
                    name, primary: primary,
                    secondaries: LiftExerciseVocabulary.ordered(secondaries, excluding: primary),
                    known: vocabulary, deviceId: repo.deviceId, in: store,
                    catalogueId: picked?.id, equipment: picked?.equipment)
            } catch let full as WhoopStore.LiftExerciseVocabularyFull {
                // Refused rather than silently dropped: the user typed a name and deserves to know
                // it was not remembered.
                vocabularyFullLimit = full.limit
                return
            } catch {
                return
            }
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(LiftProgramItemRow(
            id: item?.id ?? UUID().uuidString,
            deviceId: repo.deviceId,
            // Assigned properly by the parent on save; a placeholder here would be a second source
            // of truth for ordering.
            programId: item?.programId ?? "",
            ord: item?.ord ?? 0,
            exercise: name,
            targetSets: Int(setsText.trimmingCharacters(in: .whitespaces)),
            // ONE rep count, unless a double or triple rule needs a range: then the top of the range is
            // `targetRepsHigh` (only when it is above the bottom); otherwise it stays nil.
            targetRepsLow: Int(repsText.trimmingCharacters(in: .whitespaces)),
            targetRepsHigh: rangeTop,
            targetRpe: maxRpe,
            targetWeightKg: LiftFormat.number(weightText).map {
                LiftFormat.kilograms(fromDisplay: $0, system: unitSystem)
            },
            restSec: Int(restText.trimmingCharacters(in: .whitespaces)),
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            // A library pick links the line; an edited line keeps the link it had while the name is unchanged.
            catalogueId: picked?.id ?? (name == item?.exercise ? item?.catalogueId : nil),
            progression: progression?.rawValue,
            targetSetsMax: progression == .triple ? setsMaxValue : nil,
            incrementKg: progression == nil ? nil : stepKg,
            deloadFactor: progression == nil ? nil : deloadPercent.map { $0 / 100 },
            // A line keeps the superset it is in: that is set by linking lines in the program, not here.
            supersetGroup: item?.supersetGroup,
            backups: LiftSuperset.cleanBackups(backups + (backupText.isEmpty ? [] : [backupText]), excluding: name)
        ))
        dismiss()
    }
}
