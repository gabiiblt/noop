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


def test_gyms_list_each_inventory_and_count_their_sessions(tmp_path):
    store = Store(str(tmp_path / "x.sqlite"))
    store.upsert_rows(REGISTRY["liftGym"], "s", "d", [
        ({"id": "g1"}, {"name": "Home", "unit": "kg", "createdAt": 1, "lastUsedTs": 5000,
                        "platesJSON": '[{"pairs":2,"size":20},{"pairs":1,"size":5}]',
                        "barsJSON": '{"barbell":15}', "dumbbellsJSON": "[5,10]",
                        "stacksJSON": '{"Leg curl":[5,11.3]}'}),
        ({"id": "g2"}, {"name": "Bare", "unit": "lb", "createdAt": 2, "platesJSON": "{nope"})], "1.100")
    store.upsert_rows(REGISTRY["liftSession"], "s", "d", [
        ({"id": "a"}, {"startTs": 1000, "endTs": 4000, "programName": "Push", "gymId": "g1"}),
        ({"id": "b"}, {"startTs": 9000, "endTs": 9500, "gymId": "deleted"})], "1.100")
    out = q.gyms(Store.connect_ro(store.path))
    home = out["gyms"][0]
    assert home["name"] == "Home" and home["sessions"] == 1
    assert home["plates"] == [{"size": 20, "pairs": 2}, {"size": 5, "pairs": 1}]
    assert home["bars"] == {"barbell": 15} and home["dumbbells"] == [5, 10] and home["stacks"] == {"Leg curl": [5, 11.3]}
    bare = out["gyms"][1]
    assert bare["unit"] == "lb" and bare["plates"] is None, "malformed inventory reads as none"
    sessions = q.lift_sessions(Store.connect_ro(store.path), 0, 50000)["sessions"]
    assert sessions[0]["gym"] == "Home"
    assert sessions[1]["gym"] is None, "a deleted gym names nothing"


def test_gyms_say_so_when_there_are_none(tmp_path):
    store = Store(str(tmp_path / "x.sqlite"))
    out = q.gyms(Store.connect_ro(store.path))
    assert out["count"] == 0 and "note" in out


def test_programs_list_lines_with_their_superset_and_backups(tmp_path):
    store = Store(str(tmp_path / "x.sqlite"))
    store.upsert_rows(REGISTRY["liftProgram"], "s", "d", [
        ({"id": "p"}, {"name": "Push", "archived": 0, "createdAt": 1, "updatedAt": 1})], "1.100")
    store.upsert_rows(REGISTRY["liftProgramItem"], "s", "d", [
        ({"id": "i1"}, {"programId": "p", "ord": 0, "exercise": "Bench", "targetSets": 3, "supersetGroup": "g",
                        "backupsJSON": '["Dumbbell press","Push-up"]', "progression": "double"}),
        ({"id": "i2"}, {"programId": "p", "ord": 1, "exercise": "Row", "targetSets": 3, "supersetGroup": "g",
                        "backupsJSON": "{nope"}),
        ({"id": "i3"}, {"programId": "p", "ord": 2, "exercise": "Curl", "targetSets": 2})], "1.100")
    out = q.programs(Store.connect_ro(store.path))
    lines = out["programs"][0]["lines"]
    assert [l["exercise"] for l in lines] == ["Bench", "Row", "Curl"]
    assert lines[0]["superset"] == lines[1]["superset"] == "g" and "superset" not in lines[2]
    assert lines[0]["backups"] == ["Dumbbell press", "Push-up"] and lines[0]["rule"] == "double"
    assert "backups" not in lines[1], "a malformed list reads as none"


def test_sets_name_their_superset_and_what_they_were_swapped_from(tmp_path):
    store = Store(str(tmp_path / "x.sqlite")); seed(store)
    store.upsert_rows(REGISTRY["liftSet"], "s", "d", [
        ({"id": "9"}, {"sessionId": "a", "ord": 9, "exercise": "Hack squat", "setIndex": 1, "weightKg": 100, "reps": 8,
                       "isWarmup": 0, "isFailure": 0, "supersetGroup": "g", "swappedFrom": "Leg press"})], "1.100")
    sets = q.lift_sessions(Store.connect_ro(store.path), 0, 50000, with_sets=True)["sessions"][0]["sets"]
    hack = [s for s in sets if s["exercise"] == "Hack squat"][0]
    assert hack["superset"] == "g" and hack["swapped_from"] == "Leg press"


def _rotation_store(tmp_path, with_session=True, rest=0):
    store = Store(str(tmp_path / "x.sqlite"))
    store.upsert_rows(REGISTRY["liftProgram"], "s", "d", [
        ({"id": "a"}, {"name": "Push", "archived": 0, "createdAt": 1, "updatedAt": 1, "rotationOrd": 0, "restDaysAfter": rest}),
        ({"id": "b"}, {"name": "Pull", "archived": 0, "createdAt": 2, "updatedAt": 2, "rotationOrd": 1}),
        ({"id": "c"}, {"name": "Legs", "archived": 0, "createdAt": 3, "updatedAt": 3, "rotationOrd": 2}),
        ({"id": "x"}, {"name": "Arms", "archived": 0, "createdAt": 4, "updatedAt": 4})], "1.100")
    if with_session:
        store.upsert_rows(REGISTRY["liftSession"], "s", "d", [
            ({"id": "s1"}, {"startTs": 1_800_000_000, "endTs": 1_800_003_600, "programId": "a"})], "1.100")
    return store


def test_the_rotation_says_what_is_up_next(tmp_path):
    store = _rotation_store(tmp_path)
    day = 86400
    out = q.programs(Store.connect_ro(store.path), 1_800_000_000 + 2 * day)
    assert out["rotation_next"] == {"next": "Pull", "after": "Push", "state": "due", "overdue_days": 1}
    pull = [p for p in out["programs"] if p["name"] == "Pull"][0]
    assert pull["rotation_position"] == 2 and pull["rest_days_after"] == 0
    arms = [p for p in out["programs"] if p["name"] == "Arms"][0]
    assert "rotation_position" not in arms


def test_rest_days_make_the_next_session_wait(tmp_path):
    store = _rotation_store(tmp_path, rest=2)
    out = q.programs(Store.connect_ro(store.path), 1_800_000_000 + 3600)
    assert out["rotation_next"]["state"] == "rest" and out["rotation_next"]["days_left"] == 3


def test_a_rotation_with_no_session_starts_at_the_first_program(tmp_path):
    store = _rotation_store(tmp_path, with_session=False)
    assert q.programs(Store.connect_ro(store.path), 1_800_000_000)["rotation_next"] == {
        "next": "Push", "state": "not_started", "after": None}


def test_no_rotation_no_rotation_next(tmp_path):
    store = Store(str(tmp_path / "x.sqlite"))
    store.upsert_rows(REGISTRY["liftProgram"], "s", "d", [
        ({"id": "a"}, {"name": "Push", "archived": 0, "createdAt": 1, "updatedAt": 1})], "1.100")
    assert "rotation_next" not in q.programs(Store.connect_ro(store.path), 1_800_000_000)
