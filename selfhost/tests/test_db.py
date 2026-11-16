import sqlite3

import pytest

from noop_selfhost.db import Store
from noop_selfhost.registry import REGISTRY


def test_state_id_stable_across_reopen(tmp_path):
    p = str(tmp_path / "s.sqlite")
    first = Store(p).receiver_state_id()
    assert Store(p).receiver_state_id() == first
    assert len(first) == 36 and first == first.lower()


def test_rotate_changes_id_and_clears_ledger(tmp_path):
    s = Store(str(tmp_path / "s.sqlite"))
    old = s.receiver_state_id()
    s.conn.execute("INSERT INTO ledger VALUES ('src','dev','b1','h','{}')")
    s.conn.execute("INSERT INTO window_parts (_src,_dev,stream,replacementId,part,parts,batchId,"
                   "bodySha256,payload,startInclusive,endExclusive,selector,ackJson) "
                   "VALUES ('src','dev','sleepSession','r',1,2,'b','h','[]','0','1','startTs','{}')")
    new = s.rotate_receiver_state_id()
    assert new != old and s.receiver_state_id() == new
    assert s.conn.execute("SELECT COUNT(*) FROM ledger").fetchone()[0] == 0
    assert s.conn.execute("SELECT COUNT(*) FROM window_parts").fetchone()[0] == 0


def test_tables_exist_for_every_registry_stream(tmp_path):
    s = Store(str(tmp_path / "s.sqlite"))
    have = {r[0] for r in s.conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert set(REGISTRY) <= have


def test_ro_connection_rejects_writes(tmp_path):
    p = str(tmp_path / "s.sqlite")
    Store(p)
    ro = Store.connect_ro(p)
    with pytest.raises(sqlite3.OperationalError):
        ro.execute("INSERT INTO hrSample (_src,_dev,ts,bpm) VALUES ('a','b',1,60)")


def test_blob_column_roundtrips_bytes(tmp_path):
    s = Store(str(tmp_path / "s.sqlite"))
    blob = bytes(range(48))
    s.upsert_rows(REGISTRY["ppgWaveformSample"], "src", "dev",
                  [({"ts": 10}, {"samples": blob, "burstIndex": None})], "1.100")
    got = s.conn.execute("SELECT samples FROM ppgWaveformSample WHERE ts=10").fetchone()[0]
    assert got == blob


def test_upsert_is_idempotent_and_overwrites(tmp_path):
    s = Store(str(tmp_path / "s.sqlite"))
    hr = REGISTRY["hrSample"]
    s.upsert_rows(hr, "src", "dev", [({"ts": 1}, {"bpm": 60})], "1.0")
    s.upsert_rows(hr, "src", "dev", [({"ts": 1}, {"bpm": 61})], "1.0")
    assert s.conn.execute("SELECT COUNT(*), MAX(bpm) FROM hrSample").fetchone() == (1, 61)


def test_scopes_do_not_overwrite_each_other(tmp_path):
    s = Store(str(tmp_path / "s.sqlite"))
    hr = REGISTRY["hrSample"]
    s.upsert_rows(hr, "src1", "dev", [({"ts": 1}, {"bpm": 60})], "1.0")
    s.upsert_rows(hr, "src2", "dev", [({"ts": 1}, {"bpm": 70})], "1.0")
    assert s.conn.execute("SELECT COUNT(*) FROM hrSample").fetchone()[0] == 2


def test_ts_index_exists_for_every_time_keyed_append_stream(tmp_path):
    """Range reads by time (MCP tools) must not scan whole tables: the PK starts with the source/device scope."""
    s = Store(str(tmp_path / "s.sqlite"))
    idx = {r[0] for r in s.conn.execute("SELECT name FROM sqlite_master WHERE type='index'")}
    for name, st in REGISTRY.items():
        if st.delivery == "append" and st.key[0].name == "ts":
            assert f"idx_{name}_ts" in idx, name


def test_ts_range_query_uses_the_index(tmp_path):
    s = Store(str(tmp_path / "s.sqlite"))
    plan = " ".join(str(r[3]) for r in s.conn.execute(
        "EXPLAIN QUERY PLAN SELECT ts, bpm FROM hrSample WHERE ts>=1 AND ts<100"))
    assert "idx_hrSample_ts" in plan, plan


def test_existing_database_gains_the_indexes_on_reopen(tmp_path):
    p = str(tmp_path / "s.sqlite")
    Store(p).conn.execute("DROP INDEX idx_hrSample_ts")
    again = Store(p)
    assert again.conn.execute("SELECT 1 FROM sqlite_master WHERE name='idx_hrSample_ts'").fetchone()
