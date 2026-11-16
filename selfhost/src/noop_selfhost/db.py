"""Receiver SQLite store. One file, WAL; the MCP server opens it read-only via `connect_ro`.

Every exported table is scoped by `(_src, _dev)` = (sourceId, deviceId) plus the stream key.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from typing import Iterable, Iterator

from .batch import Batch, ProtocolError
from .registry import REGISTRY, Col, Stream

_SQL_TYPE = {"int": "INTEGER", "real": "REAL", "text": "TEXT", "bool": "INTEGER", "blob": "BLOB"}


def _q(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _col_sql(c: Col, force_notnull: bool = False) -> str:
    nn = " NOT NULL" if (force_notnull or not c.nullable) else ""
    return f"{_q(c.name)} {_SQL_TYPE[c.type]}{nn}"


def _table_sql(s: Stream) -> str:
    cols = ['"_src" TEXT NOT NULL', '"_dev" TEXT NOT NULL']
    cols += [_col_sql(c, True) for c in s.key]
    # Data columns added only under the extension are always nullable (v1 rows never carry them).
    cols += [_col_sql(c) for c in s.data]
    cols += [f"{_q(c.name)} {_SQL_TYPE[c.type]}" for c in s.ext_data]
    pk = ", ".join(['"_src"', '"_dev"'] + [_q(c.name) for c in s.key])
    return f"CREATE TABLE IF NOT EXISTS {_q(s.name)} ({', '.join(cols)}, PRIMARY KEY ({pk}))"


_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS ledger (
  _src TEXT NOT NULL, _dev TEXT NOT NULL, batchId TEXT NOT NULL,
  bodySha256 TEXT NOT NULL, ackJson TEXT NOT NULL,
  PRIMARY KEY (_src, _dev, batchId));
CREATE TABLE IF NOT EXISTS window_parts (
  _src TEXT NOT NULL, _dev TEXT NOT NULL, stream TEXT NOT NULL, replacementId TEXT NOT NULL,
  part INTEGER NOT NULL, parts INTEGER NOT NULL, batchId TEXT NOT NULL, bodySha256 TEXT NOT NULL,
  payload TEXT NOT NULL, startInclusive TEXT NOT NULL, endExclusive TEXT NOT NULL,
  selector TEXT NOT NULL, ackJson TEXT NOT NULL,
  PRIMARY KEY (_src, _dev, stream, replacementId, part));
CREATE TABLE IF NOT EXISTS window_generation (
  _src TEXT NOT NULL, _dev TEXT NOT NULL, stream TEXT NOT NULL, replacementId TEXT NOT NULL,
  PRIMARY KEY (_src, _dev, stream));
"""


class Store:
    def __init__(self, path: str) -> None:
        self.path = path
        self.lock = threading.RLock()
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.executescript(_SCHEMA)
        for s in REGISTRY.values():
            self.conn.execute(_table_sql(s))
        with self.lock:
            if self.conn.execute("SELECT 1 FROM meta WHERE k='receiver_state_id'").fetchone() is None:
                self.conn.execute("INSERT INTO meta VALUES ('receiver_state_id', ?)", (str(uuid.uuid4()),))

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                yield self.conn
            except BaseException:
                self.conn.execute("ROLLBACK")
                raise
            else:
                self.conn.execute("COMMIT")

    def receiver_state_id(self) -> str:
        return self.conn.execute("SELECT v FROM meta WHERE k='receiver_state_id'").fetchone()[0]

    def rotate_receiver_state_id(self) -> str:
        new = str(uuid.uuid4())
        with self.transaction() as c:
            c.execute("UPDATE meta SET v=? WHERE k='receiver_state_id'", (new,))
            for t in ("ledger", "window_parts", "window_generation"):
                c.execute(f"DELETE FROM {t}")
        return new

    def upsert_rows(self, stream: Stream, src: str, dev: str,
                    rows: Iterable[tuple[dict, dict]], version: str,
                    conn: sqlite3.Connection | None = None) -> int:
        """Idempotent upsert of (key, data) pairs. Members absent from `data` become NULL."""
        data_cols = stream.data_for(version)
        names = ["_src", "_dev"] + [c.name for c in stream.key] + [c.name for c in data_cols]
        conflict = ", ".join(['"_src"', '"_dev"'] + [_q(c.name) for c in stream.key])
        sets = ", ".join(f"{_q(c.name)}=excluded.{_q(c.name)}" for c in data_cols)
        sql = (f"INSERT INTO {_q(stream.name)} ({', '.join(_q(n) for n in names)}) "
               f"VALUES ({', '.join('?' * len(names))}) "
               + (f"ON CONFLICT ({conflict}) DO UPDATE SET {sets}" if sets
                  else f"ON CONFLICT ({conflict}) DO NOTHING"))
        params = [
            [src, dev] + [key[c.name] for c in stream.key] + [data.get(c.name) for c in data_cols]
            for key, data in rows
        ]

        def run(c: sqlite3.Connection) -> int:
            c.executemany(sql, params)
            return len(params)

        if conn is not None:
            return run(conn)
        with self.transaction() as c:
            return run(c)

    def accept_append(self, batch: Batch) -> dict:
        """Apply an append batch and record its acknowledgement atomically (idempotent by batchId)."""
        h = batch.header
        src, dev, bid = h["sourceId"], h["deviceId"], h["batchId"]
        with self.transaction() as c:
            row = c.execute("SELECT bodySha256, ackJson FROM ledger WHERE _src=? AND _dev=? AND batchId=?",
                            (src, dev, bid)).fetchone()
            if row is not None:
                if row[0] != batch.sha256:
                    raise ProtocolError(409, "batch_id_conflict")
                return json.loads(row[1])
            self.upsert_rows(batch.stream, src, dev, [(r.key, r.data) for r in batch.records],
                             h["protocolVersion"], conn=c)
            ack = {"protocolVersion": h["protocolVersion"], "batchId": bid, "stream": h["stream"],
                   "deviceId": dev, "endCursor": h["endCursor"], "acceptedRows": len(batch.records),
                   "status": "accepted"}
            c.execute("INSERT INTO ledger VALUES (?,?,?,?,?)", (src, dev, bid, batch.sha256, json.dumps(ack)))
        return ack

    @staticmethod
    def connect_ro(path: str) -> sqlite3.Connection:
        c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        c.execute("PRAGMA query_only=ON")
        c.row_factory = sqlite3.Row
        return c
