import SwiftUI
import StrandDesign
import WhoopStore

// What a set was, beyond weight, reps and RPE: its shape (straight, drop set, rest-pause), the drops or
// bursts that ride on it, failure, reps in reserve, the side it was done on, and a time or a distance.
//
// Opened from a set row in the live session. Editing here changes only that set; "Done" writes the
// whole value back through `LiftSessionController.setExtras`, which holds it for a set not yet
// performed and edits the record of one that was — so describing a set can never create one.
//
// The set model follows openGym's (Duarte Santos, MIT authorization to Gabriel Bolatoglu; see
// ATTRIBUTION.md).

struct LiftSetDetailSheet: View {
    let exercise: String
    let setIndex: Int
    let system: UnitSystem
    let onDone: (LiftSetExtras) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form: LiftSetExtrasForm

    init(exercise: String, setIndex: Int, extras: LiftSetExtras, system: UnitSystem,
         onDone: @escaping (LiftSetExtras) -> Void) {
        self.exercise = exercise
        self.setIndex = setIndex
        self.system = system
        self.onDone = onDone
        _form = State(initialValue: LiftSetExtrasForm(extras, system: system))
    }

    var body: some View {
        ScreenScaffold(title: "Set detail",
                       subtitle: "\(exercise) · set \(setIndex)") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                shapeCard
                if form.setType != .straight { partsCard }
                effortCard
                measuresCard
                footer
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 720)
        #endif
    }

    // MARK: - Shape

    private var shapeCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text("Type").strandOverline()
                Picker("Type", selection: Binding(
                    get: { form.setType },
                    set: { form.switchType(to: $0) })) {
                    Text("Straight").tag(LiftSetType.straight)
                    Text("Drop set").tag(LiftSetType.dropset)
                    Text("Rest-pause").tag(LiftSetType.restpause)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(shapeHint)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shapeHint: LocalizedStringKey {
        switch form.setType {
        case .straight:
            return "One block of reps at one weight."
        case .dropset:
            return "Lower the weight and keep going, with no rest. Each drop adds to the volume."
        case .restpause:
            return "Rest briefly and go again at the same weight. Reps is the total of every burst, so list each burst here."
        }
    }

    // MARK: - Drops and bursts

    private var partsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text(form.setType == .dropset ? "Drops" : "Bursts").strandOverline()
                ForEach($form.parts) { $part in
                    HStack(spacing: 8) {
                        if form.setType == .dropset {
                            field("Weight", unit: LiftFormat.weightUnit(system), text: $part.weightText)
                        } else {
                            field("Rest", unit: "s", text: $part.restText)
                        }
                        field("Reps", unit: nil, text: $part.repsText)
                        Button {
                            form.removePart(part.id)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Remove"))
                    }
                }
                Button {
                    form.addPart()
                } label: {
                    Label(form.setType == .dropset ? "Add a drop" : "Add a burst",
                          systemImage: "plus.circle")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .disabled(form.parts.count >= LiftSetExtras.maxParts)
                if let total = form.extras(system: system).restPauseTotal {
                    Text("Total \(total) reps")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    // MARK: - Effort

    private var effortCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text("Effort").strandOverline()
                Toggle("Taken to failure", isOn: $form.isFailure)
                    .tint(StrandPalette.accent)
                HStack {
                    Text("Reps in reserve")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    TextField("—", text: $form.rirText)
                        .textFieldStyle(.plain)
                        .font(StrandFont.bodyNumber)
                        .multilineTextAlignment(.trailing)
                        .numericKeyboard()
                        .frame(width: 64)
                }
            }
        }
    }

    // MARK: - Side, time, distance

    private var measuresCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text("Per side, time and distance").strandOverline()
                Picker("Side", selection: $form.side) {
                    Text("Both").tag(LiftSide?.none)
                    Text("Left").tag(LiftSide?.some(.left))
                    Text("Right").tag(LiftSide?.some(.right))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 8) {
                    field("Time", unit: "s", text: $form.durationText)
                    field("Distance", unit: "m", text: $form.distanceText)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Clear") { form = LiftSetExtrasForm() }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button("Done") {
                onDone(form.extras(system: system))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
        }
    }

    /// A labelled number field. The label doubles as the placeholder, so an empty field still says what it is.
    private func field(_ label: LocalizedStringKey, unit: String?, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
            if let unit {
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
