import Foundation

public enum PushVersion: String, Sendable {
    case v1 = "1.0"
    case ext = "1.100"
}

public enum ColumnKind: String, Sendable {
    case int, real, text, bool, blob
}

public struct Column: Equatable, Sendable {
    public let name: String
    public let kind: ColumnKind
    public let nullable: Bool
}

public enum Delivery: String, Sendable {
    case append
    case replaceWindow = "replace_window"
    case snapshot
}

public enum Selector: String, Sendable {
    case ts, day, startTs
}

public enum Phase: String, Sendable {
    case v1, ext
}

/// One exported stream. The source table has the same name as the stream and a `deviceId` column.
/// Kept in lock-step with selfhost/src/noop_selfhost/registry.py (RegistryParityTests compares both
/// against Parity/registry.json).
public struct StreamSpec: Equatable, Sendable {
    public let name: String
    public let key: [Column]
    /// Members of the v1 registry.
    public let data: [Column]
    /// Optional members only sent under the `1.100` extension.
    public let extData: [Column]
    public let delivery: Delivery
    public let selector: Selector?
    public let phase: Phase

    public func dataColumns(ext: Bool) -> [Column] {
        return ext ? data + extData : data
    }
}

/// "ts:int!, bpm:int!, note:text" -> columns. A trailing `!` means NOT NULL.
private func columns(_ spec: String) -> [Column] {
    var out: [Column] = []
    for raw in spec.split(separator: ",") {
        let part = raw.trimmingCharacters(in: .whitespaces)
        if part.isEmpty { continue }
        let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
        var typeName = pieces[1]
        let notNull = typeName.hasSuffix("!")
        if notNull { typeName.removeLast() }
        out.append(Column(name: pieces[0], kind: ColumnKind(rawValue: typeName)!, nullable: !notNull))
    }
    return out
}

private func stream(_ name: String, _ key: String, _ data: String,
                    _ delivery: Delivery = .append, _ selector: Selector? = nil,
                    ext: String = "", phase: Phase = .v1) -> StreamSpec {
    return StreamSpec(name: name, key: columns(key), data: columns(data), extData: columns(ext),
                      delivery: delivery, selector: selector, phase: phase)
}

public enum PushRegistry {
    /// Every stream, v1 first then the extension, in the order cheap/high-value streams go first.
    public static let all: [StreamSpec] = [
        // v1 append
        stream("hrSample", "ts:int!", "bpm:int!", .append, .ts),
        stream("rrInterval", "ts:int!, rrMs:int!, seq:int!", "ord:int, srcChannel:int, tsSuspect:int", .append, .ts),
        stream("event", "ts:int!, kind:text!", "payloadJSON:text!", .append, .ts),
        stream("battery", "ts:int!", "soc:real, mv:int, charging:bool", .append, .ts),
        stream("spo2Sample", "ts:int!", "red:int!, ir:int!", .append, .ts),
        stream("skinTempSample", "ts:int!", "raw:int!, aux1Raw:int, aux2Raw:int", .append, .ts),
        stream("respSample", "ts:int!", "raw:int!", .append, .ts),
        stream("gravitySample", "ts:int!", "x:real!, y:real!, z:real!, dynAccel:real", .append, .ts),
        // v1 replace-window
        stream("dailyMetric", "day:text!",
               "totalSleepMin:real, efficiency:real, deepMin:real, remMin:real, lightMin:real, disturbances:int, restingHr:int, avgHrv:real, recovery:real, strain:real, exerciseCount:int, spo2Pct:real, skinTempDevC:real, respRateBpm:real, steps:int, activeKcalEst:real, spo2Red:int, spo2Ir:int",
               .replaceWindow, .day, ext: "avgSdnn:real, skinTempC:real, sleepHrOnly:bool"),
        stream("sleepSession", "startTs:int!",
               "endTs:int!, efficiency:real, restingHr:int, avgHrv:real, stagesJSON:text, userEdited:bool!, startTsAdjusted:int, motionJSON:text, sleepStateJSON:text, stagingSparse:int",
               .replaceWindow, .startTs),
        stream("workout", "startTs:int!, sport:text!",
               "endTs:int!, source:text!, durationS:real, energyKcal:real, avgHr:int, maxHr:int, strain:real, distanceM:real, zonesJSON:text, notes:text, routePolyline:text, steps:int",
               .replaceWindow, .startTs),
        stream("journal", "day:text!, question:text!", "answeredYes:bool!, notes:text, numericValue:real",
               .replaceWindow, .day),
        // ext: insertion-only
        stream("stepSample", "ts:int!", "counter:int!, activityClass:int", .append, .ts, phase: .ext),
        stream("ppgHrSample", "ts:int!", "bpm:real!, conf:real!", .append, .ts, phase: .ext),
        stream("sleepStateSample", "ts:int!", "state:int!, rawByte:int", .append, .ts, phase: .ext),
        stream("appleStepHour", "ts:int!", "steps:int!", .replaceWindow, .ts, phase: .ext),
        stream("v18AuxSample", "ts:int!", "fields:blob!", .append, .ts, phase: .ext),
        stream("ppgWaveformSample", "ts:int!", "samples:blob!, burstIndex:int, baseCode:int", .append, .ts, phase: .ext),
        stream("ecgWaveformSample", "ts:int!, sequence:int!", "record:blob!", .append, .ts, phase: .ext),
        // ext: mutable, replace-window
        stream("appleDaily", "day:text!",
               "steps:int, activeKcal:real, basalKcal:real, vo2max:real, avgHr:int, maxHr:int, walkingHr:int, weightKg:real", .replaceWindow, .day, phase: .ext),
        stream("metricSeries", "day:text!, key:text!", "value:real!", .replaceWindow, .day, phase: .ext),
        stream("scoreInputProvenance", "day:text!, key:text!", "sourceId:text!", .replaceWindow, .day, phase: .ext),
        stream("liveSession", "startTs:int!",
               "endTs:int, chargeAtStart:real, floorBpm:real, ceilingBpm:real, inBandSec:real, belowSec:real, aboveSec:real, pushCount:int, easeCount:int, hrSource:text", .replaceWindow, .startTs, phase: .ext),
        // ext: whole-table snapshots
        stream("ouraRaw", "endpoint:text!, documentId:text!", "day:text, payloadJSON:text, fetchedAt:int",
               .snapshot, phase: .ext),
        stream("labMarker", "id:text!",
               "markerKey:text, category:text, day:text, takenAt:int, value:real, valueText:text, unit:text, source:text, note:text, referenceText:text", .snapshot, phase: .ext),
        stream("liftExercise", "id:text!",
               "name:text, primaryMuscle:text, secondaryMuscles:text, createdAt:int, lastUsedTs:int, catalogueId:text, equipment:text",
               .snapshot, phase: .ext),
        stream("liftProgram", "id:text!", "name:text, note:text, createdAt:int, updatedAt:int, archived:int",
               .snapshot, phase: .ext),
        stream("liftProgramItem", "id:text!",
               "programId:text, ord:int, exercise:text, targetSets:int, targetRepsLow:int, targetRepsHigh:int, targetRpe:real, targetWeightKg:real, restSec:int, note:text, catalogueId:text", .snapshot, phase: .ext),
        stream("liftSession", "id:text!",
               "startTs:int, endTs:int, sport:text, programId:text, programName:text, sessionRpe:real, note:text",
               .snapshot, phase: .ext),
        stream("liftSet", "id:text!",
               "sessionId:text, ord:int, exercise:text, primaryMuscle:text, secondaryMuscles:text, setIndex:int, weightKg:real, reps:int, rpe:real, isWarmup:int, startTs:int, endTs:int, restSec:int, note:text, setType:text, dropsJSON:text, isFailure:int, rir:real, side:text, durationSec:int, distanceM:real, catalogueId:text",
               .snapshot, phase: .ext),
    ]

    public static var v1: [StreamSpec] { return all.filter { $0.phase == .v1 } }
    public static var ext: [StreamSpec] { return all }

    public static func streams(for version: PushVersion) -> [StreamSpec] {
        return version == .v1 ? v1 : ext
    }

    public static func spec(named name: String) -> StreamSpec? {
        return all.first { $0.name == name }
    }
}
