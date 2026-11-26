import json
from noop_selfhost import queries as q
from noop_selfhost.db import Store
from noop_selfhost.registry import REGISTRY


def seed(store):
    store.upsert_rows(REGISTRY["liftSession"], "s", "d", [
        ({"id": "a"}, {"startTs": 1000, "endTs": 4000, "programName": "Push", "sessionRpe": 8.0}),
        ({"id": "b"}, {"startTs": 90000, "endTs": 93000, "programName": "Push"})], "1.100")
    def st(i, sess, ord_, ex, w, r, **kw):
        d = {"sessionId": sess, "ord": ord_, "exercise": ex, "setIndex": ord_ + 1, "weightKg": w, "reps": r,
             "isWarmup": kw.pop("warm", 0), "isFailure": kw.pop("fail", 0)}
        d.update(kw)
        return ({"id": i}, d)
    store.upsert_rows(REGISTRY["liftSet"], "s", "d", [
        st("1", "a", 0, "Bench", 20, 10, warm=1), st("2", "a", 1, "Bench", 60, 8, catalogueId="0025"),
        st("3", "a", 2, "Bench", 40, 10, setType="dropset", dropsJSON='[{"weightKg":30,"reps":6}]', fail=1),
        st("4", "a", 3, "Curl", 12, 0),
        st("5", "b", 0, "Développé couché", 70, 5, catalogueId="0025")], "1.100")


def test_sessions_summarise_like_the_app(tmp_path):
    store = Store(str(tmp_path / "x.sqlite")); seed(store)
    out = q.lift_sessions(Store.connect_ro(store.path), 0, 50000, with_sets=True)
    assert out["count"] == 1
    bench = out["sessions"][0]["exercises"][0]
    assert bench == {"exercise": "Bench", "working_sets": 2, "reps": 18, "volume_kg": 60 * 8 + 400 + 180,
                     "top_weight_kg": 60, "best_e1rm_kg": round(60 * (1 + 8 / 30), 1)}
    assert [e["exercise"] for e in out["sessions"][0]["exercises"]] == ["Bench"], "0-rep sets are not performed"
    drop = [s for s in out["sessions"][0]["sets"] if s.get("type") == "dropset"][0]
    assert drop["to_failure"] is True


def test_progress_follows_the_catalogue_link_across_a_rename(tmp_path):
    store = Store(str(tmp_path / "x.sqlite")); seed(store)
    p = q.exercise_progress(Store.connect_ro(store.path), "Bench")
    assert p["sessions"] == 2 and p["heaviest_kg"] == 70
    assert p["best_e1rm_kg"] == round(70 * (1 + 5 / 30), 1)


def test_e1rm_matches_the_app_rules():
    assert q.e1rm(100, 1) == 100 and q.e1rm(100, 13) is None and q.e1rm(0, 5) is None


def test_sets_carry_their_target_and_plan(tmp_path):
    store = Store(str(tmp_path / "x.sqlite")); seed(store)
    plan = '{"progression":"triple","repsHigh":12,"repsLow":8,"sets":3,"setsMax":5,"weightKg":60}'
    store.upsert_rows(REGISTRY["liftSet"], "s", "d", [
        ({"id": "6"}, {"sessionId": "a", "ord": 4, "exercise": "Row", "setIndex": 1, "weightKg": 50, "reps": 12,
                       "isWarmup": 0, "isFailure": 0, "targetReps": 12, "targetWeightKg": 50, "planJSON": plan}),
        ({"id": "7"}, {"sessionId": "a", "ord": 5, "exercise": "Row", "setIndex": 2, "weightKg": 50, "reps": 9,
                       "isWarmup": 0, "isFailure": 0, "planJSON": "{nope"})], "1.100")
    sets = q.lift_sessions(Store.connect_ro(store.path), 0, 50000, with_sets=True)["sessions"][0]["sets"]
    row = [s for s in sets if s["exercise"] == "Row"]
    assert row[0]["target_reps"] == 12 and row[0]["target_weight_kg"] == 50
    assert row[0]["plan"] == {"progression": "triple", "repsHigh": 12, "repsLow": 8, "sets": 3, "setsMax": 5, "weightKg": 60}
    assert "plan" not in row[1] and "target_reps" not in row[1], "a malformed stamp reads as none, the set still reads"


def test_progression_rules_list_only_lines_with_a_rule(tmp_path):
    store = Store(str(tmp_path / "x.sqlite"))
    store.upsert_rows(REGISTRY["liftProgram"], "s", "d", [
        ({"id": "p"}, {"name": "Push", "archived": 0, "createdAt": 1, "updatedAt": 1})], "1.100")
    store.upsert_rows(REGISTRY["liftProgramItem"], "s", "d", [
        ({"id": "i1"}, {"programId": "p", "ord": 0, "exercise": "Bench", "targetSets": 3, "targetRepsLow": 8,
                        "targetRepsHigh": 12, "targetWeightKg": 60, "progression": "triple", "targetSetsMax": 5,
                        "incrementKg": 2.5, "deloadFactor": 0.9}),
        ({"id": "i2"}, {"programId": "p", "ord": 1, "exercise": "Row", "targetSets": 3})], "1.100")
    out = q.progression_rules(Store.connect_ro(store.path))
    assert out["count"] == 1
    assert out["lines"][0] == {"program": "Push", "archived": False, "exercise": "Bench", "rule": "triple",
                               "sets": 3, "reps_low": 8, "reps_high": 12, "weight_kg": 60.0, "sets_max": 5,
                               "increment": 2.5, "deload_factor": 0.9}


def test_progression_rules_say_so_when_there_are_none(tmp_path):
    store = Store(str(tmp_path / "x.sqlite"))
    out = q.progression_rules(Store.connect_ro(store.path))
    assert out["count"] == 0 and "note" in out
