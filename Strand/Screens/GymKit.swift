import SwiftUI
import StrandDesign
import WhoopStore

// The pieces the gym sheets share, so the program detail, the program editor and the exercise picker read as
// one app: a glass top bar, round exercise stills, the set table, and a number cell that edits in place.
//
// Everything here is built from design tokens and the house glass helpers (`noopGlass*`), so it follows the
// Liquid Glass fallbacks on its own: glass on iOS 26, material on older iOS, a solid surface on macOS.

// MARK: - Top bar

/// The bar at the top of a gym sheet: an action on the leading edge, the title in the middle, an action on the
/// trailing edge. Glass buttons float over the backdrop, as in the system sheets of iOS 26.
struct GymSheetBar<Leading: View, Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // Keeps the title clear of the buttons whichever side is wider.
                .padding(.horizontal, 96)
            HStack(spacing: NoopMetrics.rowSpacing) {
                leading()
                Spacer(minLength: 0)
                trailing()
            }
        }
        .padding(.horizontal, NoopMetrics.screenPadding)
        .padding(.top, NoopMetrics.gap)
        .padding(.bottom, NoopMetrics.rowSpacing)
    }
}

/// A word on a glass capsule: Cancel, Create, Update. `prominent` is the one action that commits the sheet.
struct GymBarButton: View {
    let title: LocalizedStringKey
    var prominent = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(StrandFont.body)
                .lineLimit(1)
        }
        .noopGlassButton(prominent: prominent, tint: prominent ? StrandPalette.effortColor : nil)
        .disabled(!enabled)
        .opacity(enabled ? 1 : NoopButtonMetrics.disabledOpacity)
    }
}

/// A round glass icon button, 44 pt like every touch target.
struct GymBarIcon: View {
    let systemName: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: NoopMetrics.glassIconButtonSize, height: NoopMetrics.glassIconButtonSize)
                .noopGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Exercise still

/// The round still of an exercise, resolved from its catalogue id (or a URL already in hand).
struct GymExerciseThumb: View {
    var catalogueId: String?
    var url: URL?
    var size: CGFloat = 46

    @State private var resolved: URL?

    var body: some View {
        ExerciseImageView(url: url ?? resolved, maxPixel: Int(size * 3), cornerRadius: size / 2)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(StrandPalette.hairline, lineWidth: 0.5))
            .task(id: catalogueId) {
                guard url == nil, let id = catalogueId, let catalogue = ExerciseLibrary.shared else {
                    resolved = nil
                    return
                }
                resolved = await Task.detached(priority: .userInitiated) {
                    (try? catalogue.exercise(id: id)).flatMap { catalogue.imageURL(for: $0) }
                }.value
            }
    }
}

// MARK: - Pills

/// A rounded pill, the shape of a filter or a one-tap setting (rest, note, volume / reps / duration).
struct GymPill: View {
    let title: String
    var systemImage: String?
    var selected = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
            }
            Text(title).font(StrandFont.subhead).lineLimit(1)
        }
        .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(selected ? StrandPalette.effortColor.opacity(0.28) : StrandPalette.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(selected ? StrandPalette.effortColor.opacity(0.6) : Color.clear, lineWidth: 1))
        .contentShape(Capsule())
    }
}

// MARK: - Number cell

/// A numeric cell that edits in place. It keeps what is being typed ("62." on its way to "62.5") instead of
/// re-formatting under the cursor, and follows the value again when it changes from elsewhere.
struct GymNumberCell<F: Hashable>: View {
    let placeholder: String
    /// The value in display units, nil when there is none.
    let value: Double?
    let focus: FocusState<F?>.Binding
    let field: F
    let onChange: (Double?) -> Void

    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(StrandFont.rounded(18, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            .focused(focus, equals: field)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(focus.wrappedValue == field ? StrandPalette.effortColor : StrandPalette.hairline,
                            lineWidth: focus.wrappedValue == field ? 1.5 : 0.5)
            )
            .onAppear { text = Self.format(value) }
            .onChange(of: text) { new in
                // Only a cell being typed in reports; filling it from the value must not write the value back.
                if focus.wrappedValue == field { onChange(LiftFormat.number(new)) }
            }
            .onChange(of: value) { new in
                // A cell being typed in is the source of the change, so it is left alone.
                if focus.wrappedValue != field { text = Self.format(new) }
            }
    }

    private static func format(_ value: Double?) -> String {
        value.map { LiftFormat.trim($0) } ?? ""
    }
}

// MARK: - Set table

/// The numbered set rows of a program line: SET, weight and reps. A line's targets are the same for each of its
/// sets, so the rows show one pair of values and an edit to any of them is an edit to all.
struct GymSetHeader: View {
    let unitSystem: UnitSystem

    var body: some View {
        HStack(spacing: NoopMetrics.rowSpacing) {
            Text("Set").textCase(.uppercase).frame(width: 44)
            Text(verbatim: unitSystem == .imperial ? "LB" : "KG").frame(maxWidth: .infinity)
            Text("Reps").textCase(.uppercase).frame(maxWidth: .infinity)
        }
        .font(StrandFont.overline)
        .foregroundStyle(StrandPalette.textTertiary)
    }
}

/// The number badge on the leading edge of a set row.
struct GymSetBadge: View {
    let index: Int

    var body: some View {
        Text("\(index)")
            .font(StrandFont.rounded(17, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: 44, height: 44)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Rest

/// The rest choices a line offers, in seconds. Nil is no rest timer.
enum GymRestPresets {
    static let seconds: [Int?] = [nil, 30, 45, 60, 90, 105, 120, 150, 180, 240, 300]
}
