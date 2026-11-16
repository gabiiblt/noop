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
CREATE TABLE IF NOT EXISTS window_seen (
  _src TEXT NOT NULL, _dev TEXT NOT NULL, stream TEXT NOT NULL, replacementId TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('current','superseded','applied')),
  PRIMARY KEY (_src, _dev, stream, replacementId));
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
            for t in ("ledger", "window_parts", "window_seen"):
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

    def accept_window_part(self, batch: Batch) -> dict:
        """Stage one part of an authoritative replacement; apply atomically when the set is complete.

        The acknowledgement of the completing part is returned only after the apply committed
        (ack, ledger row, upsert and delete share one transaction).
        """
        h, s = batch.header, batch.stream
        if s.delivery not in ("replace_window", "snapshot"):
            raise ProtocolError(422, "unsupported_delivery")
        w = h["window"]
        src, dev, bid, rid = h["sourceId"], h["deviceId"], h["batchId"], w["replacementId"]
        scope = (src, dev, s.name)
        with self.transaction() as c:
            row = c.execute("SELECT bodySha256, ackJson FROM ledger WHERE _src=? AND _dev=? AND batchId=?",
                            (src, dev, bid)).fetchone()
            if row is not None:
                if row[0] != batch.sha256:
                    raise ProtocolError(409, "batch_id_conflict")
                return json.loads(row[1])
            seen = c.execute("SELECT state FROM window_seen WHERE _src=? AND _dev=? AND stream=? "
                             "AND replacementId=?", (*scope, rid)).fetchone()
            if seen is None:  # first part of a new generation supersedes older incomplete ones
                c.execute("UPDATE window_seen SET state='superseded' WHERE _src=? AND _dev=? AND stream=? "
                          "AND state='current'", scope)
                c.execute("DELETE FROM window_parts WHERE _src=? AND _dev=? AND stream=?", scope)
                c.execute("INSERT INTO window_seen VALUES (?,?,?,?, 'current')", (*scope, rid))
            elif seen[0] == "superseded":
                raise ProtocolError(409, "superseded_generation")
            elif seen[0] == "applied":
                raise ProtocolError(409, "conflicting_replacement")
            start, end = str(w.get("startInclusive", "")), str(w.get("endExclusive", ""))
            for p, parts, a, b in c.execute(
                    "SELECT part, parts, startInclusive, endExclusive FROM window_parts WHERE _src=? AND _dev=? "
                    "AND stream=? AND replacementId=?", (*scope, rid)).fetchall():
                if p == w["part"] or parts != w["parts"] or (a, b) != (start, end):
                    raise ProtocolError(409, "conflicting_part")
            ack = {"protocolVersion": h["protocolVersion"], "batchId": bid, "stream": s.name,
                   "deviceId": dev, "endCursor": None, "acceptedRows": len(batch.records),
                   "status": "accepted"}
            c.execute("INSERT INTO window_parts (_src,_dev,stream,replacementId,part,parts,batchId,bodySha256,"
                      "payload,startInclusive,endExclusive,selector,ackJson) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                      (*scope, rid, w["part"], w["parts"], bid, batch.sha256,
                       json.dumps([[r.key, r.data] for r in batch.records]), start, end,
                       w["selector"], json.dumps(ack)))
            c.execute("INSERT INTO ledger VALUES (?,?,?,?,?)", (src, dev, bid, batch.sha256, json.dumps(ack)))
            staged = c.execute("SELECT payload FROM window_parts WHERE _src=? AND _dev=? AND stream=? "
                               "AND replacementId=? ORDER BY part", (*scope, rid)).fetchall()
            if len(staged) == w["parts"]:
                self._apply_window(c, s, src, dev, w, h["protocolVersion"], [json.loads(p[0]) for p in staged])
                c.execute("UPDATE window_seen SET state='applied' WHERE _src=? AND _dev=? AND stream=? "
                          "AND replacementId=?", (*scope, rid))
                c.execute("DELETE FROM window_parts WHERE _src=? AND _dev=? AND stream=? AND replacementId=?",
                          (*scope, rid))
        return ack

    def _apply_window(self, c: sqlite3.Connection, s: Stream, src: str, dev: str, w: dict,
                      version: str, parts: list[list]) -> None:
        names = [col.name for col in s.key]
        rows = [(k, d) for part in parts for k, d in part]
        keep = {tuple(k[n] for n in names) for k, _ in rows}
        if len(keep) != len(rows):
            raise ProtocolError(400, "duplicate_key")
        self.upsert_rows(s, src, dev, rows, version, conn=c)
        select = f"SELECT {', '.join(_q(n) for n in names)} FROM {_q(s.name)} WHERE _src=? AND _dev=?"
        if s.delivery == "snapshot":  # whole-table replacement for this (source, device)
            existing = c.execute(select, (src, dev)).fetchall()
        else:
            sel = _q(s.selector)
            existing = c.execute(f"{select} AND {sel} >= ? AND {sel} < ?",
                                 (src, dev, w["startInclusive"], w["endExclusive"])).fetchall()
        gone = [tuple(r) for r in existing if tuple(r) not in keep]
        where = " AND ".join(f"{_q(n)}=?" for n in names)
        c.executemany(f"DELETE FROM {_q(s.name)} WHERE _src=? AND _dev=? AND {where}",
                      [(src, dev, *g) for g in gone])

    @staticmethod
    def connect_ro(path: str) -> sqlite3.Connection:
        c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        c.execute("PRAGMA query_only=ON")
        c.row_factory = sqlite3.Row
        return c
