import sqlite3

import pytest
from fastapi.testclient import TestClient

from noop_selfhost.db import Store
from noop_selfhost.receiver import create_app
from noop_selfhost.simulator import push_all

GRDB_SCHEMA = """
CREATE TABLE hrSample (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, bpm INTEGER NOT NULL,
  synced INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (deviceId, ts));
CREATE TABLE rrInterval (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, rrMs INTEGER NOT NULL,
  seq INTEGER NOT NULL DEFAULT 0, synced INTEGER NOT NULL DEFAULT 0, ord INTEGER, srcChannel INTEGER,
  tsSuspect INTEGER, PRIMARY KEY (deviceId, ts, rrMs, seq));
CREATE TABLE sleepSession (deviceId TEXT NOT NULL, startTs INTEGER NOT NULL, endTs INTEGER NOT NULL,
  efficiency REAL, restingHr INTEGER, avgHrv REAL, stagesJSON TEXT, userEdited INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (deviceId, startTs));
CREATE TABLE dailyMetric (deviceId TEXT NOT NULL, day TEXT NOT NULL, recovery REAL, PRIMARY KEY (deviceId, day));
"""


@pytest.fixture
def phone_db(tmp_path):
    p = str(tmp_path / "whoop.sqlite")
    c = sqlite3.connect(p)
    c.executescript(GRDB_SCHEMA)
    c.executemany("INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('strap', ?, ?)",
                  [(1_700_000_000 + i, 50 + i % 40) for i in range(12000)])
    c.executemany("INSERT INTO rrInterval (deviceId, ts, rrMs, seq) VALUES ('strap', 1700000000, 800, ?)",
                  [(0,), (1,)])
    c.execute("INSERT INTO rrInterval (deviceId, ts, rrMs, seq, tsSuspect) VALUES ('strap', 1700000001, 900, 0, 1)")
    c.execute("INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency, userEdited) "
              "VALUES ('strap', 1700000000, 1700028000, 0.9, 1)")
    c.executemany("INSERT INTO dailyMetric (deviceId, day, recovery) VALUES ('strap', ?, ?)",
                  [("2023-11-14", 60.0), ("2023-11-15", 70.0)])
    c.commit()
    c.close()
    return p


@pytest.fixture
def server(tmp_path):
    store = Store(str(tmp_path / "recv.sqlite"))
    return store, TestClient(create_app(store, "tok"))


def counts(store):
    q = lambda t: store.conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]  # noqa: E731
    return {t: q(t) for t in ("hrSample", "rrInterval", "sleepSession", "dailyMetric")}


def test_simulator_pushes_fixture_db_and_receiver_matches_counts(phone_db, server):
    store, http = server
    sent = push_all(phone_db, http, "/push", "tok", source_id="3a3486dd-5030-4e17-a00d-a781399890f9")
    assert counts(store) == {"hrSample": 12000, "rrInterval": 3, "sleepSession": 1, "dailyMetric": 2}
    assert sent["hrSample"] == 12000 and sent["rrInterval"] == 3
    # round-trips the booleans and equal-beat seq
    assert store.conn.execute("SELECT userEdited FROM sleepSession").fetchone()[0] == 1
    assert sorted(r[0] for r in store.conn.execute("SELECT seq FROM rrInterval WHERE rrMs=800")) == [0, 1]
    assert store.conn.execute("SELECT tsSuspect FROM rrInterval WHERE rrMs=900").fetchone()[0] == 1


def test_second_run_adds_zero_rows(phone_db, server):
    store, http = server
    sid = "3a3486dd-5030-4e17-a00d-a781399890f9"
    push_all(phone_db, http, "/push", "tok", source_id=sid)
    before = counts(store)
    push_all(phone_db, http, "/push", "tok", source_id=sid)
    assert counts(store) == before


def test_wrong_token_fails_loudly_and_sends_no_health_data(phone_db, server):
    store, http = server
    with pytest.raises(RuntimeError, match="401"):
        push_all(phone_db, http, "/push", "wrong", source_id="3a3486dd-5030-4e17-a00d-a781399890f9")
    assert counts(store)["hrSample"] == 0


def test_missing_tables_and_columns_are_skipped_or_null(tmp_path, server):
    store, http = server
    p = str(tmp_path / "old.sqlite")
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY(deviceId, ts))")
    c.execute("INSERT INTO hrSample VALUES ('strap', 5, 60)")
    c.commit()
    c.close()
    push_all(p, http, "/push", "tok", source_id="3a3486dd-5030-4e17-a00d-a781399890f9")
    assert counts(store)["hrSample"] == 1
