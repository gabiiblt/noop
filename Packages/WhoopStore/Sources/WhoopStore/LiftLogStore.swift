import Foundation
import GRDB

// MARK: - v45 store: the in-app strength log (programs, sessions, sets)
//
// Mirrors the established LabMarkerStore / AppleStepHourStore idiom precisely: plain Codable row
// structs, raw `Row` fetch + manual decode, idempotent upserts keyed by the natural key, all GRDB
// work through the actor's `syncWrite` / `syncRead` helpers.
//
// The four tables are flat and deviceId-keyed, joined manually by id — this schema carries no
// foreign keys. A logged session also exists as an ordinary `workout` row; the two find each other
// through the workout table's natural key (deviceId, startTs, sport), which `liftSession` pins with
// a UNIQUE index.
//
// Nothing here computes or stores a load score. `workout.strain` remains the HR-measured number the
// analytics engine produces; volume is derived on read from the sets, where the arithmetic is
// visible (`LiftSetRow.volumeKg`).

// MARK: - Rows

/// One exercise in the user's own vocabulary. NOOP ships no catalogue: an exercise is whatever the
/// user typed, remembered here the first time it is used so it can be offered back with the muscle
/// group they gave it. Keeping the name→group mapping in one place is what makes a per-muscle-group
/// rollup mean the same thing from one session to the next.
public struct LiftExerciseRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Exactly as the user typed it. The natural key is (deviceId, name), so case and spacing are
    /// preserved rather than normalised — their vocabulary, shown back verbatim.
    public var name: String
    /// Canonical classification. Nil until the user has classified this exercise.
    public var primaryMuscle: LiftMuscle?
    /// Also-worked muscles, in the order the user listed them. Never contains `primaryMuscle`.
    public var secondaryMuscles: [LiftMuscle]
    /// Unix seconds.
    public var createdAt: Int
    /// Unix seconds; most-recently-used floats to the top of the picker. Nil until first used.
    public var lastUsedTs: Int?
    /// The bundled catalogue exercise this name stands for (v49), or nil for a name the user made up.
    public var catalogueId: String?
    /// The catalogue's equipment word, copied when the exercise was picked from the catalogue (v49).
    public var equipment: String?

    public init(
        id: String,
        deviceId: String,
        name: String,
        primaryMuscle: LiftMuscle?,
        secondaryMuscles: [LiftMuscle] = [],
        createdAt: Int,
        lastUsedTs: Int?,
        catalogueId: String? = nil,
        equipment: String? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = LiftMuscle.decodeList(
            LiftMuscle.encodeList(secondaryMuscles, excluding: primaryMuscle))
        self.createdAt = createdAt
        self.lastUsedTs = lastUsedTs
        self.catalogueId = catalogueId
        self.equipment = equipment
    }

    static func decode(_ row: Row) -> LiftExerciseRow {
        LiftExerciseRow(
            id: row["id"],
            deviceId: row["deviceId"],
            name: row["name"],
            primaryMuscle: LiftMuscle(rawValue: row["primaryMuscle"] ?? ""),
            secondaryMuscles: LiftMuscle.decodeList(row["secondaryMuscles"]),
            createdAt: row["createdAt"],
            lastUsedTs: row["lastUsedTs"],
            catalogueId: row["catalogueId"],
            equipment: row["equipment"]
        )
    }
}

/// A saved program — the reusable plan ("Upper A"), not a session run from it.
public struct LiftProgramRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var note: String?
    /// Unix seconds.
    public var createdAt: Int
    /// Unix seconds. Drives most-recently-touched-first ordering in the programs list.
    public var updatedAt: Int
    /// Hidden from the picker but kept, so old sessions still resolve their program.
    public var archived: Bool

    public init(
        id: String,
        deviceId: String,
        name: String,
        note: String?,
        createdAt: Int,
        updatedAt: Int,
        archived: Bool
    ) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
    }

    static func decode(_ row: Row) -> LiftProgramRow {
        LiftProgramRow(
            id: row["id"],
            deviceId: row["deviceId"],
            name: row["name"],
            note: row["note"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            archived: row["archived"]
        )
    }
}

/// One exercise line in a program: the TARGETS. What actually happened lives in `LiftSetRow`.
public struct LiftProgramItemRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var programId: String
    /// Position within the program, 0-based.
    public var ord: Int
    /// The exercise NAME. Its muscle classification lives in `liftExercise`, resolved by name —
    /// one owner, so a program line and the vocabulary can never disagree.
    public var exercise: String
    public var targetSets: Int?
    /// Rep range low end — the 8 of "8-10". Nil when the line has no rep target.
    public var targetRepsLow: Int?
    public var targetRepsHigh: Int?
    /// Max RPE on the user's own 1-10 scale: the ceiling the session shows grey, and what a set left
    /// unrated records as its rating.
    public var targetRpe: Double?
    /// Planned working weight in kilograms (v41). A program line plans a weight, not only reps.
    public var targetWeightKg: Double?
    /// Intended rest after each set, seconds.
    public var restSec: Int?
    /// The user's own technique cue, stored and shown back verbatim.
    public var note: String?
    /// The bundled catalogue exercise this line was picked from (v49), or nil for a typed name.
    public var catalogueId: String?
    // v50 — see `LiftPlanStamp` for what a session stamps from these.
    /// The rule that drives this line's next target: 'linear', 'double', 'triple' or 'time'. Nil is no rule,
    /// which is what every line written before v50 has, so it behaves exactly as it did.
    public var progression: String?
    /// Triple progression's ceiling on sets; nil reads as the line's own set count.
    public var targetSetsMax: Int?
    /// The load step in kilograms (seconds for a hold); nil takes the default.
    public var incrementKg: Double?
    /// How far a deload backs off, 0.5...0.95; nil takes the default 0.9.
    public var deloadFactor: Double?
    // v52 — see `LiftSuperset.swift`.
    /// Lines that share it are done as a round. Nil for a line on its own.
    public var supersetGroup: String?
    /// Exercises that can take this line's place for a session when its machine is taken, at most five.
    public var backups: [String]

    public init(
        id: String,
        deviceId: String,
        programId: String,
        ord: Int,
        exercise: String,
        targetSets: Int?,
        targetRepsLow: Int?,
        targetRepsHigh: Int?,
        targetRpe: Double?,
        targetWeightKg: Double?,
        restSec: Int?,
        note: String?,
        catalogueId: String? = nil,
        progression: String? = nil,
        targetSetsMax: Int? = nil,
        incrementKg: Double? = nil,
        deloadFactor: Double? = nil,
        supersetGroup: String? = nil,
        backups: [String] = []
    ) {
        self.id = id
        self.deviceId = deviceId
        self.programId = programId
        self.ord = ord
        self.exercise = exercise
        self.targetSets = targetSets
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.targetRpe = targetRpe
        self.targetWeightKg = targetWeightKg
        self.restSec = restSec
        self.note = note
        self.catalogueId = catalogueId
        self.progression = progression
        self.targetSetsMax = targetSetsMax
        self.incrementKg = incrementKg
        self.deloadFactor = deloadFactor
        self.supersetGroup = supersetGroup
        self.backups = LiftSuperset.cleanBackups(backups, excluding: exercise)
    }

    static func decode(_ row: Row) -> LiftProgramItemRow {
        LiftProgramItemRow(
            id: row["id"],
            deviceId: row["deviceId"],
            programId: row["programId"],
            ord: row["ord"],
            exercise: row["exercise"],
            targetSets: row["targetSets"],
            targetRepsLow: row["targetRepsLow"],
            targetRepsHigh: row["targetRepsHigh"],
            targetRpe: row["targetRpe"],
            targetWeightKg: row["targetWeightKg"],
            restSec: row["restSec"],
            note: row["note"],
            catalogueId: row["catalogueId"],
            progression: row["progression"],
            targetSetsMax: row["targetSetsMax"],
            incrementKg: row["incrementKg"],
            deloadFactor: row["deloadFactor"],
            supersetGroup: row["supersetGroup"],
            backups: LiftSuperset.decodeBackups(row["backupsJSON"])
        )
    }
}

/// One gym session. Pairs 1:1 with a `workout` row through (deviceId, startTs, sport).
public struct LiftSessionRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Unix seconds; the same instant as the paired `workout.startTs`.
    public var startTs: Int
    /// Nil while the session is still running.
    public var endTs: Int?
    /// The same string as the paired `workout.sport`.
    public var sport: String
    /// Nil for a freehand session with no program behind it.
    public var programId: String?
    /// The program's name AS IT WAS when the session ran, so a later rename never rewrites history.
    public var programName: String?
    /// Session RPE, 0-10 Borg CR10 (v41). A NUMBER, not a note: Foster's session load is sRPE x
    /// duration, so the rating has to be computable. Nil when the user skipped rating the session.
    public var sessionRpe: Double?
    public var note: String?
    /// The gym this session was done at (v51), or nil when none was chosen. Names nothing once the gym is deleted.
    public var gymId: String?

    public init(
        id: String,
        deviceId: String,
        startTs: Int,
        endTs: Int?,
        sport: String,
        programId: String?,
        programName: String?,
        sessionRpe: Double?,
        note: String?,
        gymId: String? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.startTs = startTs
        self.endTs = endTs
        self.sport = sport
        self.programId = programId
        self.programName = programName
        self.sessionRpe = sessionRpe
        self.note = note
        self.gymId = gymId
    }

    static func decode(_ row: Row) -> LiftSessionRow {
        LiftSessionRow(
            id: row["id"],
            deviceId: row["deviceId"],
            startTs: row["startTs"],
            endTs: row["endTs"],
            sport: row["sport"],
            programId: row["programId"],
            programName: row["programName"],
            sessionRpe: row["sessionRpe"],
            note: row["note"],
            gymId: row["gymId"]
        )
    }
}

/// One set. Stored as its own row rather than folded into the session, because per-exercise history
/// ("what did I lift for this last time") has to be answerable from an index.
public struct LiftSetRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var sessionId: String
    /// Order within the whole session, 0-based — reconstructs the order the sets were performed in.
    public var ord: Int
    /// Denormalised deliberately: a session stays readable after its program is edited or deleted.
    public var exercise: String
    /// The classification this set was counted under, snapshotted at log time.
    public var primaryMuscle: LiftMuscle?
    public var secondaryMuscles: [LiftMuscle]
    /// 1-based within this exercise, so "set 3 of 4" survives.
    public var setIndex: Int
    /// Kilograms. Display units convert at the edge; storage is always kg.
    public var weightKg: Double?
    public var reps: Int?
    /// RPE on the user's own 1-10 scale.
    public var rpe: Double?
    /// Warmup sets are recorded but excluded from volume.
    public var isWarmup: Bool
    public var startTs: Int?
    public var endTs: Int?
    /// Rest ACTUALLY taken after this set, seconds — not the target from the program.
    public var restSec: Int?
    public var note: String?
    // v49 — see `LiftSetDetail.swift` for the model.
    /// Straight, drop set or rest-pause.
    public var setType: LiftSetType
    /// A drop set's weight drops, or the bursts a rest-pause set's `reps` break down into.
    public var parts: [LiftSetPart]
    /// Taken to failure.
    public var isFailure: Bool
    /// Reps in reserve, the alternative to RPE some lifters rate with.
    public var rir: Double?
    /// Left or right for single-limb work logged per side; nil for both.
    public var side: LiftSide?
    /// Seconds, for a timed hold or a cardio interval.
    public var durationSec: Int?
    /// Metres, for a carry or a sled.
    public var distanceM: Double?
    /// The bundled catalogue exercise, when the exercise was picked from it.
    public var catalogueId: String?
    // v50 — the target this set was built from, stamped as it was (`LiftPlanStamp`).
    /// What THIS set was asked for in reps. Triple progression asks each set for its own number.
    public var targetReps: Int?
    /// The weight aimed at, kilograms.
    public var targetWeightKg: Double?
    /// The plan the session was built from, the same on every set of the exercise in the session.
    public var plan: LiftPlanStamp?
    // v52
    /// The superset group the set was done in, as it was. Nil for a set done on its own.
    public var supersetGroup: String?
    /// The exercise the line was PLANNED as, when a backup took its place that session. Nil otherwise.
    public var swappedFrom: String?

    public init(
        id: String,
        deviceId: String,
        sessionId: String,
        ord: Int,
        exercise: String,
        primaryMuscle: LiftMuscle?,
        secondaryMuscles: [LiftMuscle] = [],
        setIndex: Int,
        weightKg: Double?,
        reps: Int?,
        rpe: Double?,
        isWarmup: Bool,
        startTs: Int?,
        endTs: Int?,
        restSec: Int?,
        note: String?,
        setType: LiftSetType = .straight,
        parts: [LiftSetPart] = [],
        isFailure: Bool = false,
        rir: Double? = nil,
        side: LiftSide? = nil,
        durationSec: Int? = nil,
        distanceM: Double? = nil,
        catalogueId: String? = nil,
        targetReps: Int? = nil,
        targetWeightKg: Double? = nil,
        plan: LiftPlanStamp? = nil,
        supersetGroup: String? = nil,
        swappedFrom: String? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.ord = ord
        self.exercise = exercise
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = LiftMuscle.decodeList(
            LiftMuscle.encodeList(secondaryMuscles, excluding: primaryMuscle))
        self.setIndex = setIndex
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.startTs = startTs
        self.endTs = endTs
        self.restSec = restSec
        self.note = note
        self.setType = setType
        self.parts = setType == .straight ? [] : parts
        self.isFailure = isFailure
        self.rir = rir
        self.side = side
        self.durationSec = durationSec
        self.distanceM = distanceM
        self.catalogueId = catalogueId
        self.targetReps = targetReps
        self.targetWeightKg = targetWeightKg
        self.plan = plan
        self.supersetGroup = supersetGroup
        self.swappedFrom = swappedFrom
    }

    /// Volume for this set: weight x reps, in kilograms. Nil unless BOTH are present, and zero for a
    /// warmup — a transparent arithmetic figure, never a physiological claim. A drop set adds each drop's
    /// weight x reps on top (the drops are extra work); a rest-pause set does not (its `reps` is already
    /// the total of its bursts).
    public var volumeKg: Double? {
        guard !isWarmup, let weightKg, let reps else { return nil }
        return weightKg * Double(reps) + dropVolumeKg
    }

    /// Weight x reps of a drop set's drops; zero for every other set.
    public var dropVolumeKg: Double {
        guard setType == .dropset else { return 0 }
        return parts.reduce(0) { $0 + ($1.weightKg ?? 0) * Double(max(0, $1.reps)) }
    }

    static func decode(_ row: Row) -> LiftSetRow {
        LiftSetRow(
            id: row["id"],
            deviceId: row["deviceId"],
            sessionId: row["sessionId"],
            ord: row["ord"],
            exercise: row["exercise"],
            primaryMuscle: LiftMuscle(rawValue: row["primaryMuscle"] ?? ""),
            secondaryMuscles: LiftMuscle.decodeList(row["secondaryMuscles"]),
            setIndex: row["setIndex"],
            weightKg: row["weightKg"],
            reps: row["reps"],
            rpe: row["rpe"],
            isWarmup: row["isWarmup"],
            startTs: row["startTs"],
            endTs: row["endTs"],
            restSec: row["restSec"],
            note: row["note"],
            setType: LiftSetType(stored: row["setType"]),
            parts: LiftSetPart.decode(row["dropsJSON"]),
            isFailure: (row["isFailure"] as Int? ?? 0) != 0,
            rir: row["rir"],
            side: (row["side"] as String?).flatMap(LiftSide.init(rawValue:)),
            durationSec: row["durationSec"],
            distanceM: row["distanceM"],
            catalogueId: row["catalogueId"],
            targetReps: row["targetReps"],
            targetWeightKg: row["targetWeightKg"],
            plan: LiftPlanStamp.decode(row["planJSON"]),
            supersetGroup: row["supersetGroup"],
            swappedFrom: row["swappedFrom"]
        )
    }
}

extension LiftSetRow {
    private enum LegacyKeys: String, CodingKey {
        case id, deviceId, sessionId, ord, exercise, primaryMuscle, secondaryMuscles, setIndex, weightKg
        case reps, rpe, isWarmup, startTs, endTs, restSec, note
        case setType, parts, isFailure, rir, side, durationSec, distanceM, catalogueId
        case targetReps, targetWeightKg, plan, supersetGroup, swappedFrom
    }

    /// Decodes rows saved before v49 too (an in-progress session persisted by an older build has none
    /// of the newer keys), defaulting each missing one exactly as the memberwise initializer does.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LegacyKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            deviceId: try c.decode(String.self, forKey: .deviceId),
            sessionId: try c.decode(String.self, forKey: .sessionId),
            ord: try c.decode(Int.self, forKey: .ord),
            exercise: try c.decode(String.self, forKey: .exercise),
            primaryMuscle: try c.decodeIfPresent(LiftMuscle.self, forKey: .primaryMuscle),
            secondaryMuscles: try c.decodeIfPresent([LiftMuscle].self, forKey: .secondaryMuscles) ?? [],
            setIndex: try c.decode(Int.self, forKey: .setIndex),
            weightKg: try c.decodeIfPresent(Double.self, forKey: .weightKg),
            reps: try c.decodeIfPresent(Int.self, forKey: .reps),
            rpe: try c.decodeIfPresent(Double.self, forKey: .rpe),
            isWarmup: try c.decode(Bool.self, forKey: .isWarmup),
            startTs: try c.decodeIfPresent(Int.self, forKey: .startTs),
            endTs: try c.decodeIfPresent(Int.self, forKey: .endTs),
            restSec: try c.decodeIfPresent(Int.self, forKey: .restSec),
            note: try c.decodeIfPresent(String.self, forKey: .note),
            setType: try c.decodeIfPresent(LiftSetType.self, forKey: .setType) ?? .straight,
            parts: try c.decodeIfPresent([LiftSetPart].self, forKey: .parts) ?? [],
            isFailure: try c.decodeIfPresent(Bool.self, forKey: .isFailure) ?? false,
            rir: try c.decodeIfPresent(Double.self, forKey: .rir),
            side: try c.decodeIfPresent(LiftSide.self, forKey: .side),
            durationSec: try c.decodeIfPresent(Int.self, forKey: .durationSec),
            distanceM: try c.decodeIfPresent(Double.self, forKey: .distanceM),
            catalogueId: try c.decodeIfPresent(String.self, forKey: .catalogueId),
            targetReps: try c.decodeIfPresent(Int.self, forKey: .targetReps),
            targetWeightKg: try c.decodeIfPresent(Double.self, forKey: .targetWeightKg),
            plan: try c.decodeIfPresent(LiftPlanStamp.self, forKey: .plan),
            supersetGroup: try c.decodeIfPresent(String.self, forKey: .supersetGroup),
            swappedFrom: try c.decodeIfPresent(String.self, forKey: .swappedFrom))
    }
}

// MARK: - Store

extension WhoopStore {

    // MARK: Exercises (the user's own vocabulary)

    /// Remember exercises. Keyed on the natural key (deviceId, name), so recording the same name
    /// twice updates its classification and recency instead of duplicating it. A muscle field is
    /// only overwritten when the caller supplies one, so merely using an exercise never erases the
    /// classification the user set for it.
    /// How many exercises one device remembers.
    ///
    /// A cap exists because the vocabulary is typo-accumulating by design: every misspelling becomes
    /// a permanent picker entry ("Chest supported row3"). It is set high enough that no real
    /// training history reaches it — a broad lifter's whole vocabulary is well under a hundred — so
    /// hitting it means something has gone wrong, and the honest response is to say so rather than
    /// to silently drop what the user typed or to evict something they still use.
    ///
    /// An EXISTING name always updates, cap or no cap: only genuinely NEW names are refused.
    public static let maxRememberedExercises = 500

    /// How long a PROGRAM note may be.
    ///
    /// 120 because that is what can actually be SEEN: the hub renders it under the program name at
    /// `lineLimit(3)` in caption type, in a column narrowed by the Start button — roughly three
    /// lines on a phone. A longer note is not
    /// stored-and-shown, it is stored-and-silently-truncated, and typing into a field that quietly
    /// discards the end is worse than a field that stops.
    public static let maxProgramNoteLength = 120

    /// How long an EXERCISE (technique) note may be.
    ///
    /// 200, about four lines. Longer than a program note because it is a cue you read BETWEEN sets
    /// — "slow eccentric, pause at the bottom, don't let the elbows flare" — and shorter than
    /// unlimited because it renders directly above the set rows and every line pushes them down the
    /// screen. Both are a MAXIMUM, not a target — a one-line note is usually the better note.
    public static let maxExerciseNoteLength = 200

    /// Thrown when the vocabulary is full and the name is a new one.
    public struct LiftExerciseVocabularyFull: Error, Equatable {
        public let limit: Int
        public init(limit: Int) { self.limit = limit }
    }

    @discardableResult
    public func upsertLiftExercises(_ rows: [LiftExerciseRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                // Only a NEW name can push the vocabulary over: re-saving one that already exists is
                // an update and must always be allowed, or a user at the cap could no longer correct
                // the classification of an exercise they use every week.
                let known = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM liftExercise WHERE deviceId = ? AND name = ?
                    """, arguments: [r.deviceId, r.name]) ?? 0
                if known == 0 {
                    let total = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM liftExercise WHERE deviceId = ?
                        """, arguments: [r.deviceId]) ?? 0
                    if total >= WhoopStore.maxRememberedExercises {
                        throw LiftExerciseVocabularyFull(limit: WhoopStore.maxRememberedExercises)
                    }
                }
                try db.execute(sql: """
                    INSERT INTO liftExercise
                        (id, deviceId, name, primaryMuscle, secondaryMuscles, createdAt, lastUsedTs,
                         catalogueId, equipment)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, name) DO UPDATE SET
                        primaryMuscle = COALESCE(excluded.primaryMuscle, primaryMuscle),
                        secondaryMuscles = COALESCE(excluded.secondaryMuscles, secondaryMuscles),
                        lastUsedTs = MAX(COALESCE(excluded.lastUsedTs, 0), COALESCE(lastUsedTs, 0)),
                        catalogueId = COALESCE(excluded.catalogueId, catalogueId),
                        equipment = COALESCE(excluded.equipment, equipment)
                    """, arguments: [
                        r.id, r.deviceId, r.name,
                        r.primaryMuscle?.rawValue,
                        LiftMuscle.encodeList(r.secondaryMuscles, excluding: r.primaryMuscle),
                        r.createdAt, r.lastUsedTs,
                        r.catalogueId, r.equipment,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// The user's exercises, most recently used first and never-used ones after, alphabetical within
    /// each. This is the picker's list — built entirely from what they have typed.
    public func liftExercises(deviceId: String) async throws -> [LiftExerciseRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftExercise
                WHERE deviceId = ?
                ORDER BY COALESCE(lastUsedTs, 0) DESC, name ASC
                """, arguments: [deviceId]).map(LiftExerciseRow.decode)
        }
    }

    /// Forget one exercise from the vocabulary. Sets already logged under that name are untouched —
    /// they carry their own copy of the name and muscle group, so history never loses meaning.
    @discardableResult
    public func deleteLiftExercise(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftExercise WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: Programs

    /// Upsert programs by `id`. Returns rows written.
    @discardableResult
    public func upsertLiftPrograms(_ rows: [LiftProgramRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO liftProgram
                        (id, deviceId, name, note, createdAt, updatedAt, archived)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        note = excluded.note,
                        updatedAt = excluded.updatedAt,
                        archived = excluded.archived
                    """, arguments: [
                        r.id, r.deviceId, r.name, r.note, r.createdAt, r.updatedAt, r.archived,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// Programs for a device, most recently touched first. `includeArchived` defaults false so the
    /// picker shows only live programs.
    public func liftPrograms(deviceId: String, includeArchived: Bool = false) async throws -> [LiftProgramRow] {
        try syncRead { db in
            let sql = includeArchived
                ? """
                  SELECT * FROM liftProgram
                  WHERE deviceId = ?
                  ORDER BY updatedAt DESC
                  """
                : """
                  SELECT * FROM liftProgram
                  WHERE deviceId = ? AND archived = 0
                  ORDER BY updatedAt DESC
                  """
            return try Row.fetchAll(db, sql: sql, arguments: [deviceId]).map(LiftProgramRow.decode)
        }
    }

    /// Delete a program and its item lines. Sessions already run from it are NOT touched — they
    /// carry their own `programName` snapshot, so history survives the program's deletion.
    /// Returns true if a program row was removed.
    @discardableResult
    public func deleteLiftProgram(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftProgramItem WHERE programId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM liftProgram WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: Program items

    /// Replace a program's item lines wholesale. The editor hands back the whole list, and deleting
    /// then reinserting inside one transaction avoids reconciling removals and reorders row by row.
    @discardableResult
    public func replaceLiftProgramItems(programId: String, items: [LiftProgramItemRow]) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftProgramItem WHERE programId = ?", arguments: [programId])
            var n = 0
            for r in items {
                try db.execute(sql: """
                    INSERT INTO liftProgramItem
                        (id, deviceId, programId, ord, exercise, targetSets,
                         targetRepsLow, targetRepsHigh, targetRpe, targetWeightKg, restSec, note, catalogueId,
                         progression, targetSetsMax, incrementKg, deloadFactor, supersetGroup, backupsJSON)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        r.id, r.deviceId, r.programId, r.ord, r.exercise, r.targetSets,
                        r.targetRepsLow, r.targetRepsHigh, r.targetRpe, r.targetWeightKg,
                        r.restSec, r.note, r.catalogueId,
                        r.progression, r.targetSetsMax, r.incrementKg, r.deloadFactor,
                        r.supersetGroup, LiftSuperset.encodeBackups(r.backups),
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// A program's exercise lines in program order.
    public func liftProgramItems(programId: String) async throws -> [LiftProgramItemRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftProgramItem
                WHERE programId = ?
                ORDER BY ord ASC
                """, arguments: [programId]).map(LiftProgramItemRow.decode)
        }
    }

    // MARK: Sessions

    /// Upsert sessions. Keyed on the NATURAL key (deviceId, startTs, sport) rather than the `id` PK,
    /// so re-saving the same session updates it in place even if the caller minted a fresh id — the
    /// labMarker rule, and what keeps this row paired 1:1 with its `workout` row.
    @discardableResult
    public func upsertLiftSessions(_ rows: [LiftSessionRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO liftSession
                        (id, deviceId, startTs, endTs, sport, programId, programName,
                         sessionRpe, note, gymId)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        endTs = excluded.endTs,
                        programId = excluded.programId,
                        programName = excluded.programName,
                        sessionRpe = excluded.sessionRpe,
                        note = excluded.note,
                        gymId = excluded.gymId
                    """, arguments: [
                        r.id, r.deviceId, r.startTs, r.endTs, r.sport,
                        r.programId, r.programName, r.sessionRpe, r.note, r.gymId,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// Sessions for a device that started within `[fromTs, toTs]` inclusive, most recent first.
    public func liftSessions(deviceId: String, fromTs: Int, toTs: Int) async throws -> [LiftSessionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs DESC
                """, arguments: [deviceId, fromTs, toTs]).map(LiftSessionRow.decode)
        }
    }

    /// Every set from sessions that STARTED before `startTs`, in session then performed order: the history a
    /// session's records are held against (`LiftRecords.sessionRecords`). A personal log is a few thousand
    /// rows at most, so this reads them all rather than guessing which exercises matter.
    public func liftSetsBefore(deviceId: String, startTs: Int) async throws -> [LiftSetRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT s.* FROM liftSet s
                JOIN liftSession sess ON sess.id = s.sessionId
                WHERE s.deviceId = ? AND sess.startTs < ?
                ORDER BY sess.startTs ASC, s.ord ASC
                """, arguments: [deviceId, startTs]).map(LiftSetRow.decode)
        }
    }

    /// One exercise's whole history: its sets, oldest session first, and when each session started.
    public struct LiftExerciseHistory: Equatable, Sendable {
        public let sets: [LiftSetRow]
        public let sessionStart: [String: Int]

        public init(sets: [LiftSetRow], sessionStart: [String: Int]) {
            self.sets = sets
            self.sessionStart = sessionStart
        }
    }

    /// Every set of one exercise, matched by name OR by catalogue id, so a catalogue exercise logged under
    /// an older or translated name still reads as the same exercise.
    public func liftExerciseHistory(deviceId: String, exercise: String,
                                    catalogueId: String?) async throws -> LiftExerciseHistory {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*, sess.startTs AS sessionStartTs FROM liftSet s
                JOIN liftSession sess ON sess.id = s.sessionId
                WHERE s.deviceId = ? AND (s.exercise = ? OR (? IS NOT NULL AND s.catalogueId = ?))
                ORDER BY sess.startTs ASC, s.ord ASC
                """, arguments: [deviceId, exercise, catalogueId, catalogueId])
            var starts: [String: Int] = [:]
            let sets = rows.map { row -> LiftSetRow in
                let set = LiftSetRow.decode(row)
                starts[set.sessionId] = row["sessionStartTs"]
                return set
            }
            return LiftExerciseHistory(sets: sets, sessionStart: starts)
        }
    }

    /// Delete a session and every set in it. Returns true if a session row was removed.
    @discardableResult
    public func deleteLiftSession(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftSet WHERE sessionId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM liftSession WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Delete individual sets, as editing a finished session does when a set is removed. The session
    /// itself stays. Returns how many rows went.
    ///
    /// The Kotlin twin is `DeviceRegistryDao.deleteLiftSets`.
    @discardableResult
    public func deleteLiftSets(ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for id in ids {
                try db.execute(sql: "DELETE FROM liftSet WHERE id = ?", arguments: [id])
                n += db.changesCount
            }
            return n
        }
    }

    // MARK: Sets

    /// Upsert sets by `id`. Called as each set is logged, so a session in progress is durable set by
    /// set rather than only on finish.
    @discardableResult
    public func upsertLiftSets(_ rows: [LiftSetRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO liftSet
                        (id, deviceId, sessionId, ord, exercise, primaryMuscle, secondaryMuscles,
                         setIndex, weightKg, reps, rpe, isWarmup, startTs, endTs, restSec, note,
                         setType, dropsJSON, isFailure, rir, side, durationSec, distanceM, catalogueId,
                         targetReps, targetWeightKg, planJSON, supersetGroup, swappedFrom)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        ord = excluded.ord,
                        exercise = excluded.exercise,
                        primaryMuscle = excluded.primaryMuscle,
                        secondaryMuscles = excluded.secondaryMuscles,
                        setIndex = excluded.setIndex,
                        weightKg = excluded.weightKg,
                        reps = excluded.reps,
                        rpe = excluded.rpe,
                        isWarmup = excluded.isWarmup,
                        startTs = excluded.startTs,
                        endTs = excluded.endTs,
                        restSec = excluded.restSec,
                        note = excluded.note,
                        setType = excluded.setType,
                        dropsJSON = excluded.dropsJSON,
                        isFailure = excluded.isFailure,
                        rir = excluded.rir,
                        side = excluded.side,
                        durationSec = excluded.durationSec,
                        distanceM = excluded.distanceM,
                        catalogueId = excluded.catalogueId,
                        targetReps = excluded.targetReps,
                        targetWeightKg = excluded.targetWeightKg,
                        planJSON = excluded.planJSON,
                        supersetGroup = excluded.supersetGroup,
                        swappedFrom = excluded.swappedFrom
                    """, arguments: [
                        r.id, r.deviceId, r.sessionId, r.ord, r.exercise,
                        r.primaryMuscle?.rawValue,
                        LiftMuscle.encodeList(r.secondaryMuscles, excluding: r.primaryMuscle),
                        r.setIndex, r.weightKg, r.reps, r.rpe, r.isWarmup,
                        r.startTs, r.endTs, r.restSec, r.note,
                        r.setType.storedValue, LiftSetPart.encode(r.parts), r.isFailure, r.rir,
                        r.side?.rawValue, r.durationSec, r.distanceM, r.catalogueId,
                        r.targetReps, r.targetWeightKg, LiftPlanStamp.encode(r.plan),
                        r.supersetGroup, r.swappedFrom,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// Every set in a session, in the order they were performed.
    public func liftSets(sessionId: String) async throws -> [LiftSetRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftSet
                WHERE sessionId = ?
                ORDER BY ord ASC
                """, arguments: [sessionId]).map(LiftSetRow.decode)
        }
    }

    /// The sets from the most recent session that contained `exercise`, in performed order.
    ///
    /// This is the read the whole feature exists for: it pre-fills the next session with what you
    /// actually did last time, which the user then confirms or overrides. Empty when the exercise
    /// has never been logged. `before` excludes the session currently in progress (pass its
    /// `startTs`) so a running session never pre-fills from itself. Sets with zero reps were not
    /// performed (`LiftMetrics.isPerformed`) and are skipped, so a discarded set never becomes the next
    /// session's grey numbers, and a session holding only such sets is not "last time" for the exercise.
    public func lastLiftSets(deviceId: String, exercise: String, before: Int? = nil) async throws -> [LiftSetRow] {
        try syncRead { db in
            // Two steps rather than a correlated subquery: find the latest qualifying session, then
            // read its sets in order. Served by idx_liftSet_device_exercise + idx_liftSession_natural.
            let cutoff = before ?? Int.max
            guard let sessionId = try String.fetchOne(db, sql: """
                SELECT s.sessionId FROM liftSet s
                JOIN liftSession sess ON sess.id = s.sessionId
                WHERE s.deviceId = ? AND s.exercise = ? AND sess.startTs < ?
                  AND (s.reps IS NULL OR s.reps <> 0)
                ORDER BY sess.startTs DESC
                LIMIT 1
                """, arguments: [deviceId, exercise, cutoff]) else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM liftSet
                WHERE sessionId = ? AND exercise = ? AND (reps IS NULL OR reps <> 0)
                ORDER BY ord ASC
                """, arguments: [sessionId, exercise]).map(LiftSetRow.decode)
        }
    }

    /// Per-muscle working-set counts over `[fromTs, toTs]`, from the classification each set was
    /// logged under.
    ///
    /// `fractional` is the headline figure: direct sets count 1, indirect sets count 0.5. That is
    /// not a house convention — the 2025 dose-response meta-regression tested exactly this choice
    /// against counting indirect sets as 1 and as 0, and the evidence was strongest for 0.5, which
    /// its primary models then used. The reference doses NOOP displays come from those models, so
    /// the count and the reference must stay on the same method.
    ///
    /// `direct` and `indirect` are returned alongside so the arithmetic is inspectable rather than
    /// asserted.
    ///
    /// **Warm-ups and sets with zero reps (never performed, `LiftMetrics.isPerformed`) are excluded;
    /// nothing else is.** In particular this does NOT filter by RPE, even
    /// though a hard set is the thing that drives adaptation — because the reference doses were
    /// derived from unfiltered working-set counts, and filtering here would quietly compare a
    /// smaller number against a scale built from a larger one. Proximity to failure is reported
    /// separately by `LiftMetrics.rpeProfile` instead, where it can inform without corrupting the count.
    public func liftSetCounts(
        deviceId: String,
        fromTs: Int,
        toTs: Int
    ) async throws -> (fractional: [LiftMuscle: Double], direct: [LiftMuscle: Int], indirect: [LiftMuscle: Int]) {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.primaryMuscle AS primaryMuscle, s.secondaryMuscles AS secondaryMuscles
                FROM liftSet s
                JOIN liftSession sess ON sess.id = s.sessionId
                WHERE s.deviceId = ?
                  AND sess.startTs >= ? AND sess.startTs <= ?
                  AND s.isWarmup = 0
                  AND (s.reps IS NULL OR s.reps <> 0)
                """, arguments: [deviceId, fromTs, toTs])

            var direct: [LiftMuscle: Int] = [:]
            var indirect: [LiftMuscle: Int] = [:]
            for row in rows {
                if let token: String = row["primaryMuscle"], let m = LiftMuscle(rawValue: token) {
                    direct[m, default: 0] += 1
                }
                // A muscle listed BOTH as primary and as secondary is credited once, as direct.
                // `LiftMuscle.encodeList(_:excluding:)` already strips the primary on the way in, so
                // today no stored row needs this — but "today no row needs it" is not a guarantee,
                // and without the guard this aggregation and `LiftMetrics.muscleCounts` (which has
                // always had it) would report DIFFERENT numbers for the same set: the hub's weekly
                // card and the session detail, disagreeing, with nothing to catch it. The two are
                // pinned against each other by
                // `LiftMetricsStoreAgreementTests.testBothImplementationsAgree…`.
                let primary: LiftMuscle? = (row["primaryMuscle"] as String?).flatMap(LiftMuscle.init(rawValue:))
                for m in LiftMuscle.decodeList(row["secondaryMuscles"]) where m != primary {
                    indirect[m, default: 0] += 1
                }
            }
            var fractional: [LiftMuscle: Double] = [:]
            for (m, n) in direct { fractional[m, default: 0] += Double(n) * LiftMuscle.directSetCredit }
            for (m, n) in indirect { fractional[m, default: 0] += Double(n) * LiftMuscle.indirectSetCredit }
            return (fractional, direct, indirect)
        }
    }

}
