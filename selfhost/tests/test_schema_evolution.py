"""A receiver database created before the registry grew gains the new columns on start-up."""
import sqlite3

from noop_selfhost.db import Store
from noop_selfhost.registry import REGISTRY


def test_existing_table_gains_new_data_columns_and_keeps_rows(tmp_path):
    path = str(tmp_path / "old.sqlite")
    old = sqlite3.connect(path)
    # liftSet exactly as the v48-era receiver created it.
    old.execute('CREATE TABLE "liftSet" ("_src" TEXT NOT NULL, "_dev" TEXT NOT NULL, "id" TEXT NOT NULL, '
                '"sessionId" TEXT, "ord" INTEGER, "exercise" TEXT, "weightKg" REAL, "reps" INTEGER, '
                'PRIMARY KEY ("_src", "_dev", "id"))')
    old.execute("INSERT INTO liftSet VALUES ('s', 'd', 'a', 'x', 0, 'Curl', 40, 10)")
    old.commit()
    old.close()

    store = Store(path)
    cols = {r[1] for r in store.conn.execute("PRAGMA table_info(liftSet)")}
    for c in REGISTRY["liftSet"].all_data:
        assert c.name in cols
    assert store.conn.execute("SELECT exercise, reps, setType FROM liftSet").fetchone() == ("Curl", 10, None)

    # And the new members are accepted end to end.
    store.upsert_rows(REGISTRY["liftSet"], "s", "d",
                      [({"id": "b"}, {"exercise": "Curl", "setType": "dropset", "dropsJSON": '[{"reps":6}]',
                                      "isFailure": 1, "catalogueId": "0294"})], "1.100")
    assert store.conn.execute("SELECT setType, catalogueId FROM liftSet WHERE id='b'").fetchone() == ("dropset", "0294")


def test_reopening_is_idempotent(tmp_path):
    path = str(tmp_path / "r.sqlite")
    Store(path)
    Store(path)  # must not try to add the same column twice
