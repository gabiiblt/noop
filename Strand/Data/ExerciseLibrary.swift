import Foundation
import CoreGraphics
import ImageIO
import WhoopStore

/// The bundled exercise catalogue as the app uses it: one shared, read-only instance, the language to show
/// it in, and the display names of its equipment words.
///
/// The catalogue folder ships in the iOS bundle only (`StrandiOS/Resources/ExerciseCatalogue`, see
/// `project.yml`). Where it is absent, as in the macOS build, `shared` is nil and every view that uses
/// it hides its catalogue parts instead of failing.
enum ExerciseLibrary {
    /// Opened once, on first use. Read-only, so it is safe to share across tasks.
    static let shared: ExerciseCatalogue? = {
        guard let directory = Bundle.main.url(forResource: "ExerciseCatalogue", withExtension: nil) else {
            return nil
        }
        return try? ExerciseCatalogue(directory: directory)
    }()

    /// French names and steps when the app itself runs in French (the catalogue carries English and French).
    static var french: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("fr")
    }

    static func name(_ exercise: CatalogueExercise) -> String {
        exercise.name(french: french)
    }

    static func imageURL(_ exercise: CatalogueExercise) -> URL? {
        shared?.imageURL(for: exercise)
    }

    /// "Chest · Dumbbell": the primary muscle and the equipment, whichever are known.
    static func subtitle(_ exercise: CatalogueExercise) -> String {
        [exercise.primaryMuscle?.displayName, equipmentName(exercise.equipment)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The display name of one of the catalogue's equipment words. The common ones are translated; the
    /// rarer ones (clubbell, macebell...) show the catalogue's own word, capitalised.
    static func equipmentName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "body weight": return String(localized: "Body weight")
        case "dumbbell": return String(localized: "Dumbbell")
        case "barbell", "olympic barbell": return String(localized: "Barbell")
        case "cable": return String(localized: "Cable")
        case "leverage machine": return String(localized: "Machine")
        case "smith machine": return String(localized: "Smith machine")
        case "sled machine": return String(localized: "Sled machine")
        case "band", "resistance band": return String(localized: "Band")
        case "kettlebell": return String(localized: "Kettlebell")
        case "weighted": return String(localized: "Weighted")
        case "ez barbell": return String(localized: "EZ bar")
        case "trap bar": return String(localized: "Trap bar")
        case "assisted": return String(localized: "Assisted")
        case "stability ball": return String(localized: "Stability ball")
        case "medicine ball": return String(localized: "Medicine ball")
        case "suspension trainer": return String(localized: "Suspension trainer")
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

/// Downsampled exercise stills, decoded off the main thread and kept in a small memory cache.
///
/// The stills are at most 360 px, but a list row draws them at 44-56 pt: decoding a thumbnail at the size
/// it is drawn (`kCGImageSourceThumbnailMaxPixelSize`) keeps a scrolling list to a few hundred kilobytes
/// instead of full bitmaps, and NSCache gives the memory back under pressure.
final class ExerciseImageCache: @unchecked Sendable {
    static let shared = ExerciseImageCache()

    private let cache = NSCache<NSString, CGImage>()

    private init() {
        cache.countLimit = 150
    }

    func image(at url: URL, maxPixel: Int) -> CGImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
