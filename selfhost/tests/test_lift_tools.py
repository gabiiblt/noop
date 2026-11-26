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
