import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// The building blocks the exercise library shows its catalogue with: a still loaded off the main thread,
// one catalogue row, and the short list of catalogue matches the exercise pickers offer under what is
// typed. The catalogue is iOS-only (see `ExerciseLibrary`); without it these views draw nothing.

/// An exercise still, or a neutral placeholder while it loads or when the exercise has none.
struct ExerciseImageView: View {
    let url: URL?
    /// Decode size in pixels: about three times the drawn size in points, for a sharp Retina still.
    var maxPixel: Int = 180
    var cornerRadius: CGFloat = 10

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            StrandPalette.surfaceInset
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            let pixels = maxPixel
            image = await Task.detached(priority: .userInitiated) {
                ExerciseImageCache.shared.image(at: url, maxPixel: pixels)
            }.value
        }
    }
}

/// One catalogue exercise as a list row: still, name, primary muscle and equipment.
struct CatalogueExerciseRowLabel: View {
    let exercise: CatalogueExercise
    var thumbnail: CGFloat = 44

    var body: some View {
        HStack(spacing: NoopMetrics.rowSpacing) {
            ExerciseImageView(url: ExerciseLibrary.imageURL(exercise), maxPixel: Int(thumbnail * 3))
                .frame(width: thumbnail, height: thumbnail)
            VStack(alignment: .leading, spacing: 2) {
                Text(ExerciseLibrary.name(exercise))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(ExerciseLibrary.subtitle(exercise))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The catalogue exercises matching what has been typed in a picker, for picking with their muscles,
/// equipment and picture. Searches after a short pause, off the main thread.
struct CatalogueExerciseSuggestions: View {
    let query: String
    var limit: Int = 6
    let onPick: (CatalogueExercise) -> Void

    @State private var results: [CatalogueExercise] = []

    var body: some View {
        Group {
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("From the exercise library").strandOverline()
                    ForEach(results) { exercise in
                        Button { onPick(exercise) } label: {
                            CatalogueExerciseRowLabel(exercise: exercise, thumbnail: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2, let catalogue = ExerciseLibrary.shared else {
                results = []
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let max = limit
            let found = await Task.detached(priority: .userInitiated) {
                (try? catalogue.search(text, limit: max)) ?? []
            }.value
            if !Task.isCancelled { results = found }
        }
    }
}

/// The marks a set earned (`LiftRecords`), as one small trophy chip.
struct LiftRecordBadge: View {
    let kinds: [LiftRecordKind]

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(kinds.map(\.displayName).joined(separator: " · "))
                .font(StrandFont.caption)
                .lineLimit(1)
        }
        .foregroundStyle(StrandPalette.statusWarning)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(StrandPalette.statusWarning.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "Personal record: \(kinds.map(\.displayName).joined(separator: ", "))")))
    }
}

extension LiftRecordKind {
    /// What the record is of, in a word.
    var displayName: String {
        switch self {
        case .weight: return String(localized: "Heaviest")
        case .reps: return String(localized: "Most reps")
        case .e1rm: return String(localized: "Best 1RM")
        case .volume: return String(localized: "Best set")
        }
    }
}
