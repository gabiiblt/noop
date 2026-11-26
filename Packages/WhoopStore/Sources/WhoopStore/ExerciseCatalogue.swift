import Foundation
import GRDB

// MARK: - The bundled exercise catalogue (read-only)
//
// 5,600-odd exercises shipped inside the app as one SQLite file, built by
// `Tools/exercise_catalogue/build_catalogue.py` from openGym's catalogue (text, muscles, French
// translation, MIT authorization) and free-exercise-db's public-domain stills. See ATTRIBUTION.md.
//
// WHY A SEPARATE, READ-ONLY FILE. The catalogue is public reference data, not the user's data: it is
// never written, never backed up and never exported. Keeping it out of the user's store means a catalogue
// update is a file swap, not a migration, and the user's database stays small. Reads go through SQLite
// rather than a decoded JSON array so a search touches a few rows instead of holding thousands in memory.
//
// IDS ARE PERMANENT. A logged set and a program line keep `catalogueId`, so an id is never reused or
// renumbered (openGym's own rule, carried over). Names may be improved between releases; ids may not move.

/// One exercise from the bundled catalogue. Muscles are already `LiftMuscle` tokens.
public struct CatalogueExercise: Identifiable, Equatable, Sendable {
    public let id: String
    public let nameEn: String
    public let nameFr: String?
    public let bodyPart: String?
    /// openGym's equipment word ("dumbbell", "leverage machine"...). Display names live in the app.
    public let equipment: String?
    public let category: String?
    public let primaryMuscle: LiftMuscle?
    public let secondaryMuscles: [LiftMuscle]
    /// Logged as seconds held rather than reps (plank, wall sit).
    public let hold: Bool
    /// Done over a distance (carry, sled), logged as metres.
    public let trackDistance: Bool
    public let descriptionEn: String?
    public let descriptionFr: String?
    public let instructionsEn: [String]
    public let instructionsFr: [String]?
    /// File name under `ExerciseImages/`, or nil when no public-domain still matched this exercise.
    public let image: String?

    /// The name to show: French when asked for and translated, English otherwise, with a capital
    /// first letter (the catalogue stores names in lower case).
    public func name(french: Bool) -> String {
        let raw = (french ? nameFr : nil) ?? nameEn
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    public func instructions(french: Bool) -> [String] {
        (french ? instructionsFr : nil) ?? instructionsEn
    }

    public func description(french: Bool) -> String? {
        (french ? descriptionFr : nil) ?? descriptionEn
    }
}

/// Read-only access to the bundled catalogue directory (`ExerciseCatalogue.sqlite` + `ExerciseImages/`).
public final class ExerciseCatalogue: @unchecked Sendable {
    /// The highest catalogue schema this reader understands (`meta.schemaVersion`).
    public static let supportedSchemaVersion = 1
    public static let databaseFileName = "ExerciseCatalogue.sqlite"
    public static let imagesFolderName = "ExerciseImages"

    public enum CatalogueError: Error, Equatable {
        case missing(String)
        case unsupportedSchema(Int)
    }

    public let directory: URL
    public let count: Int
    private let queue: DatabaseQueue

    /// Opens the catalogue folder read-only. Throws when the file is absent or newer than this reader.
    public init(directory: URL) throws {
        self.directory = directory
        let file = directory.appendingPathComponent(Self.databaseFileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CatalogueError.missing(file.path)
        }
        var config = Configuration()
        config.readonly = true
        config.label = "ExerciseCatalogue"
        queue = try DatabaseQueue(path: file.path, configuration: config)
        let (version, total) = try queue.read { db -> (Int, Int) in
            let v = try String.fetchOne(db, sql: "SELECT v FROM meta WHERE k = 'schemaVersion'").flatMap(Int.init) ?? 0
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM exercise") ?? 0
            return (v, n)
        }
        guard version <= Self.supportedSchemaVersion else { throw CatalogueError.unsupportedSchema(version) }
        count = total
    }

    /// The still for an exercise, or nil when it has none.
    public func imageURL(for exercise: CatalogueExercise) -> URL? {
        guard let name = exercise.image else { return nil }
        return directory.appendingPathComponent(Self.imagesFolderName).appendingPathComponent(name)
    }

    public func exercise(id: String) throws -> CatalogueExercise? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM exercise WHERE id = ?", arguments: [id]).map(Self.decode)
        }
    }

    /// Several exercises by id, in the order asked, skipping unknown ids.
    public func exercises(ids: [String]) throws -> [CatalogueExercise] {
        guard !ids.isEmpty else { return [] }
        let found = try queue.read { db -> [String: CatalogueExercise] in
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM exercise WHERE id IN (\(marks))",
                                        arguments: StatementArguments(ids))
            return Dictionary(uniqueKeysWithValues: rows.map(Self.decode).map { ($0.id, $0) })
        }
        return ids.compactMap { found[$0] }
    }

    /// Search by name (English or French, accents and case ignored), optionally narrowed to a primary
    /// muscle and an equipment word. Every word of the query must appear. Results put names starting
    /// with the query first, then gym staples (barbell, dumbbell, cable, machines) before bands and
    /// props, then exercises with a picture, then shorter names (the plain lift before its variations).
    public func search(_ query: String, muscle: LiftMuscle? = nil, equipment: String? = nil,
                       limit: Int = 80) throws -> [CatalogueExercise] {
        let words = Self.fold(query).split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible?] = []
        for w in words.prefix(8) {
            clauses.append("searchKey LIKE ? ESCAPE '\\'")
            args.append("%" + Self.escapeLike(w) + "%")
        }
        if let muscle {
            clauses.append("primaryMuscle = ?")
            args.append(muscle.rawValue)
        }
        if let equipment {
            clauses.append("equipment = ?")
            args.append(equipment)
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let prefix = words.isEmpty ? "%" : Self.escapeLike(words.joined(separator: " ")) + "%"
        let sql = """
            SELECT * FROM exercise \(whereSQL)
            ORDER BY CASE WHEN searchKey LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END,
                     CASE equipment WHEN 'barbell' THEN 0 WHEN 'dumbbell' THEN 1 WHEN 'cable' THEN 2
                                    WHEN 'leverage machine' THEN 3 WHEN 'smith machine' THEN 4
                                    WHEN 'body weight' THEN 5 WHEN 'sled machine' THEN 6 ELSE 9 END,
                     image IS NULL, length(nameEn), nameEn
            LIMIT ?
            """
        args.append(prefix)
        args.append(max(1, min(limit, 500)))
        return try queue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.decode)
        }
    }

    /// The equipment words present, most common first (for the filter chips).
    public func equipmentValues() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT equipment FROM exercise WHERE equipment IS NOT NULL
                GROUP BY equipment ORDER BY COUNT(*) DESC, equipment
                """)
        }
    }

    /// Lower case with accents removed, the same folding the build applies to `searchKey`.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func decode(_ row: Row) -> CatalogueExercise {
        func list(_ json: String?) -> [String]? {
            guard let json, let data = json.data(using: .utf8),
                  let value = try? JSONDecoder().decode([String].self, from: data) else { return nil }
            return value
        }
        let secondaries: String = row["secondaryMuscles"] ?? ""
        return CatalogueExercise(
            id: row["id"],
            nameEn: row["nameEn"],
            nameFr: row["nameFr"],
            bodyPart: row["bodyPart"],
            equipment: row["equipment"],
            category: row["category"],
            primaryMuscle: (row["primaryMuscle"] as String?).flatMap(LiftMuscle.init(rawValue:)),
            secondaryMuscles: secondaries.split(separator: ",").compactMap { LiftMuscle(rawValue: String($0)) },
            hold: (row["hold"] as Int? ?? 0) != 0,
            trackDistance: (row["trackDistance"] as Int? ?? 0) != 0,
            descriptionEn: row["descriptionEn"],
            descriptionFr: row["descriptionFr"],
            instructionsEn: list(row["instructionsEn"]) ?? [],
            instructionsFr: list(row["instructionsFr"]),
            image: row["image"])
    }
}
