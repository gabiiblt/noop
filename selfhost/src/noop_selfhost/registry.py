"""Stream registry: the single source of truth for what the receiver stores and the MCP reads.

`1.0` is docs/PUSH_PROTOCOL.md v1 (12 streams, exact member lists). `1.100` is this fork's
extension (see selfhost/PROTOCOL_EXT.md): every other user-data table, extra optional members
on v1 streams, full-history windows. Receiver scope columns are `_src` / `_dev`, never plain
`sourceId`/`deviceId`, because some exported tables carry their own `sourceId` data column.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

V1 = "1.0"
EXT = "1.100"
VERSIONS = (EXT, V1)  # receiver preference order

ColType = Literal["int", "real", "text", "bool", "blob"]
Delivery = Literal["append", "replace_window", "snapshot"]
Selector = Literal["ts", "day", "startTs"]


@dataclass(frozen=True)
class Col:
    name: str
    type: ColType
    nullable: bool = True


def _c(spec: str) -> tuple[Col, ...]:
    """'ts:int, bpm:int!, note:text' -> columns; '!' marks NOT NULL (default nullable)."""
    out = []
    for part in (p.strip() for p in spec.split(",") if p.strip()):
        name, _, typ = part.partition(":")
        notnull = typ.endswith("!")
        out.append(Col(name, typ.rstrip("!"), not notnull))  # type: ignore[arg-type]
    return tuple(out)


@dataclass(frozen=True)
class Stream:
    name: str
    key: tuple[Col, ...]
    data: tuple[Col, ...]
    delivery: Delivery
    selector: Selector | None = None
    ext_data: tuple[Col, ...] = ()  # optional members only accepted under EXT
    phase: Literal["v1", "ext"] = "v1"

    def data_for(self, version: str) -> tuple[Col, ...]:
        return self.data + self.ext_data if version == EXT else self.data

    @property
    def all_data(self) -> tuple[Col, ...]:
        return self.data + self.ext_data


def _s(name, key, data, delivery="append", selector=None, ext_data="", phase="v1") -> Stream:
    return Stream(name, _c(key), _c(data), delivery, selector, _c(ext_data), phase)


_STREAMS = [
    # --- v1 append streams -------------------------------------------------------------
    _s("hrSample", "ts:int!", "bpm:int!", selector="ts"),
    _s("rrInterval", "ts:int!, rrMs:int!, seq:int!", "ord:int, srcChannel:int, tsSuspect:int", selector="ts"),
    _s("event", "ts:int!, kind:text!", "payloadJSON:text!", selector="ts"),
    _s("battery", "ts:int!", "soc:real, mv:int, charging:bool", selector="ts"),
    _s("spo2Sample", "ts:int!", "red:int!, ir:int!", selector="ts"),
    _s("skinTempSample", "ts:int!", "raw:int!, aux1Raw:int, aux2Raw:int", selector="ts"),
    _s("respSample", "ts:int!", "raw:int!", selector="ts"),
    _s("gravitySample", "ts:int!", "x:real!, y:real!, z:real!, dynAccel:real", selector="ts"),
    # --- v1 replace-window streams -----------------------------------------------------
    _s("dailyMetric", "day:text!",
       "totalSleepMin:real, efficiency:real, deepMin:real, remMin:real, lightMin:real, "
       "disturbances:int, restingHr:int, avgHrv:real, recovery:real, strain:real, "
       "exerciseCount:int, spo2Pct:real, skinTempDevC:real, respRateBpm:real, steps:int, "
       "activeKcalEst:real, spo2Red:int, spo2Ir:int",
       "replace_window", "day", ext_data="avgSdnn:real, skinTempC:real, sleepHrOnly:bool"),
    _s("sleepSession", "startTs:int!",
       "endTs:int!, efficiency:real, restingHr:int, avgHrv:real, stagesJSON:text, "
       "userEdited:bool!, startTsAdjusted:int, motionJSON:text, sleepStateJSON:text, stagingSparse:int",
       "replace_window", "startTs"),
    _s("workout", "startTs:int!, sport:text!",
       "endTs:int!, source:text!, durationS:real, energyKcal:real, avgHr:int, maxHr:int, "
       "strain:real, distanceM:real, zonesJSON:text, notes:text, routePolyline:text, steps:int",
       "replace_window", "startTs"),
    _s("journal", "day:text!, question:text!", "answeredYes:bool!, notes:text, numericValue:real",
       "replace_window", "day"),
    # --- ext: insertion-only, append by rowid (appleStepHour moved to the windows below: updated in place) --
    _s("stepSample", "ts:int!", "counter:int!, activityClass:int", selector="ts", phase="ext"),
    _s("ppgHrSample", "ts:int!", "bpm:real!, conf:real!", selector="ts", phase="ext"),
    _s("sleepStateSample", "ts:int!", "state:int!, rawByte:int", selector="ts", phase="ext"),
    _s("appleStepHour", "ts:int!", "steps:int!", "replace_window", "ts", phase="ext"),
    _s("v18AuxSample", "ts:int!", "fields:blob!", selector="ts", phase="ext"),
    _s("ppgWaveformSample", "ts:int!", "samples:blob!, burstIndex:int, baseCode:int", selector="ts", phase="ext"),
    _s("ecgWaveformSample", "ts:int!, sequence:int!", "record:blob!", selector="ts", phase="ext"),
    # --- ext: mutable, day/startTs-keyed, replace-window -------------------------------
    _s("appleDaily", "day:text!",
       "steps:int, activeKcal:real, basalKcal:real, vo2max:real, avgHr:int, maxHr:int, "
       "walkingHr:int, weightKg:real", "replace_window", "day", phase="ext"),
    _s("metricSeries", "day:text!, key:text!", "value:real!", "replace_window", "day", phase="ext"),
    _s("scoreInputProvenance", "day:text!, key:text!", "sourceId:text!", "replace_window", "day", phase="ext"),
    _s("liveSession", "startTs:int!",
       "endTs:int, chargeAtStart:real, floorBpm:real, ceilingBpm:real, inBandSec:real, belowSec:real, "
       "aboveSec:real, pushCount:int, easeCount:int, hrSource:text", "replace_window", "startTs", phase="ext"),
    # --- ext: small id-keyed tables, whole-table snapshot ------------------------------
    _s("ouraRaw", "endpoint:text!, documentId:text!", "day:text, payloadJSON:text, fetchedAt:int",
       "snapshot", phase="ext"),
    _s("labMarker", "id:text!",
       "markerKey:text, category:text, day:text, takenAt:int, value:real, valueText:text, unit:text, "
       "source:text, note:text, referenceText:text", "snapshot", phase="ext"),
    _s("liftExercise", "id:text!", "name:text, primaryMuscle:text, secondaryMuscles:text, createdAt:int, "
       "lastUsedTs:int", "snapshot", phase="ext"),
    _s("liftProgram", "id:text!", "name:text, note:text, createdAt:int, updatedAt:int, archived:int",
       "snapshot", phase="ext"),
    _s("liftProgramItem", "id:text!",
       "programId:text, ord:int, exercise:text, targetSets:int, targetRepsLow:int, targetRepsHigh:int, "
       "targetRpe:real, targetWeightKg:real, restSec:int, note:text", "snapshot", phase="ext"),
    _s("liftSession", "id:text!", "startTs:int, endTs:int, sport:text, programId:text, programName:text, "
       "sessionRpe:real, note:text", "snapshot", phase="ext"),
    _s("liftSet", "id:text!",
       "sessionId:text, ord:int, exercise:text, primaryMuscle:text, secondaryMuscles:text, setIndex:int, "
       "weightKg:real, reps:int, rpe:real, isWarmup:int, startTs:int, endTs:int, restSec:int, note:text",
       "snapshot", phase="ext"),
]

REGISTRY: dict[str, Stream] = {s.name: s for s in _STREAMS}


def streams_for(version: str) -> list[Stream]:
    if version == V1:
        return [s for s in _STREAMS if s.phase == "v1"]
    if version == EXT:
        return list(_STREAMS)
    raise ValueError(f"unsupported protocol version: {version}")


def registry_json() -> dict:
    """Machine-readable registry. Committed as the fixture the Swift package's parity test reads
    (Packages/SelfHostPush/Tests/SelfHostPushTests/Fixtures/registry.json); regenerate with
    `python -m noop_selfhost.registry > <that file>` after any registry change."""
    def col(c: Col) -> dict:
        return {"name": c.name, "type": c.type, "nullable": c.nullable}

    return {"streams": [
        {"name": s.name, "phase": s.phase, "delivery": s.delivery, "selector": s.selector,
         "key": [col(c) for c in s.key], "data": [col(c) for c in s.data],
         "extData": [col(c) for c in s.ext_data]}
        for s in _STREAMS]}


if __name__ == "__main__":
    import json
    print(json.dumps(registry_json(), indent=1))
