"""Push simulator: replays a copy of a real NOOP `whoop.sqlite` (the 12 protocol-v1 streams) to a
receiver, speaking the same wire format the iPhone client will. Lets the server side be verified
before the app is built. Full-table baseline each run; safe to repeat (the receiver upserts).

    noop-push-simulator --db ~/whoop-copy.sqlite --endpoint https://server.tailfb9ed9.ts.net/push \
        --token-file /etc/noop-selfhost/token
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import sqlite3
import sys
import uuid
from datetime import date, timedelta

from .batch import MAX_DECODED, MAX_RECORDS
from .registry import V1, Stream, streams_for


def _line(o: dict) -> bytes:
    return json.dumps(o, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"


def _fingerprint(stream: str, device: str, key: dict) -> str:
    compact = json.dumps(key, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(f"{stream}\n{device}\n{compact}".encode()).hexdigest()


def _conv(col, v):
    if v is None:
        return False if (col.type == "bool" and not col.nullable) else None
    return bool(v) if col.type == "bool" else v


class _Sender:
    def __init__(self, http, endpoint: str, token: str, source_id: str) -> None:
        self.http, self.endpoint, self.source_id = http, endpoint, source_id
        self.headers = {"Authorization": f"Bearer {token}"}

    def capabilities(self) -> set[str]:
        r = self.http.get(self.endpoint, headers={**self.headers, "NOOP-Push-Accept-Version": V1})
        if r.status_code != 200:
            raise RuntimeError(f"capabilities request failed: HTTP {r.status_code}")
        return set(r.json()["streams"])

    def send(self, header: dict, records: list[dict]) -> int:
        body = _line(header) + b"".join(_line(r) for r in records)
        r = self.http.post(self.endpoint, content=gzip.compress(body), headers={
            **self.headers, "Content-Type": "application/x-ndjson", "Content-Encoding": "gzip"})
        if r.status_code != 200:
            raise RuntimeError(f"batch rejected: HTTP {r.status_code} {r.text[:120]}")
        ack = r.json()
        expect = {"protocolVersion": V1, "batchId": header["batchId"], "stream": header["stream"],
                  "deviceId": header["deviceId"], "endCursor": header["endCursor"],
                  "acceptedRows": header["recordCount"], "status": "accepted"}
        if {k: ack.get(k) for k in expect} != expect:
            raise RuntimeError(f"acknowledgement mismatch: {ack}")
        return header["recordCount"]

    def header(self, s: Stream, device: str, n: int, **extra) -> dict:
        return {"type": "batch", "protocolVersion": V1, "batchId": str(uuid.uuid4()),
                "sourceId": self.source_id, "deviceId": device, "stream": s.name, "delivery": s.delivery,
                "recordCount": n, "startCursor": None, "endCursor": None, **extra}


def _next_day(d: str) -> str:
    return (date.fromisoformat(d) + timedelta(days=1)).isoformat()


def push_all(db_path: str, http, endpoint: str, token: str, source_id: str | None = None) -> dict[str, int]:
    sender = _Sender(http, endpoint, token, source_id or str(uuid.uuid4()))
    advertised = sender.capabilities()
    src = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    src.row_factory = sqlite3.Row
    tables = {r[0] for r in src.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    sent: dict[str, int] = {}
    for s in streams_for(V1):
        if s.name not in advertised or s.name not in tables:
            continue
        have = {r[1] for r in src.execute(f'PRAGMA table_info("{s.name}")')}
        key_cols = list(s.key)
        data_cols = [c for c in s.data if c.name in have]
        for c in s.data:
            if c.name not in have and not c.nullable and c.type != "bool":
                raise RuntimeError(f"{s.name}.{c.name} is required but missing in the source database")
        names = [c.name for c in key_cols + data_cols]
        select = ", ".join(f'"{n}"' for n in names)
        devices = [r[0] for r in src.execute(f'SELECT DISTINCT deviceId FROM "{s.name}" ORDER BY 1')]

        def record(r) -> dict:
            data = {c.name: _conv(c, r[c.name]) for c in data_cols}
            data.update({c.name: _conv(c, None) for c in s.data if c.name not in have})
            return {"type": "record", "key": {c.name: r[c.name] for c in key_cols}, "data": data}

        total = 0
        for dev in devices:
            if s.delivery == "append":
                last_rowid, start_cursor = 0, None
                while True:
                    rows = src.execute(f'SELECT rowid AS _rid, {select} FROM "{s.name}" WHERE deviceId=? '
                                       f"AND rowid>? ORDER BY rowid LIMIT ?", (dev, last_rowid, MAX_RECORDS)).fetchall()
                    recs, size = [], 0
                    for r in rows:
                        rec = record(r)
                        if size + len(_line(rec)) > MAX_DECODED - 4096:
                            break
                        recs.append((r["_rid"], rec))
                        size += len(_line(rec))
                    if not recs:
                        break
                    end_rid, end_rec = recs[-1]
                    end_cursor = {"rowId": end_rid, "keySha256": _fingerprint(s.name, dev, end_rec["key"])}
                    h = sender.header(s, dev, len(recs), startCursor=start_cursor)
                    h["endCursor"] = end_cursor
                    total += sender.send(h, [r for _, r in recs])
                    last_rowid, start_cursor = end_rid, end_cursor
            else:
                order = ", ".join(f'"{c.name}"' for c in key_cols)
                rows = [record(r) for r in src.execute(
                    f'SELECT {select} FROM "{s.name}" WHERE deviceId=? ORDER BY {order}', (dev,))]
                if not rows:
                    continue
                sel = [r["key"][s.selector] for r in rows]
                lo, hi = min(sel), max(sel)
                hi_excl = _next_day(hi) if s.selector == "day" else hi + 1
                chunks = [rows[i:i + MAX_RECORDS] for i in range(0, len(rows), MAX_RECORDS)]
                rid = str(uuid.uuid4())
                for n, chunk in enumerate(chunks, 1):
                    h = sender.header(s, dev, len(chunk), window={
                        "replacementId": rid, "selector": s.selector, "startInclusive": lo,
                        "endExclusive": hi_excl, "part": n, "parts": len(chunks)})
                    total += sender.send(h, chunk)
        sent[s.name] = total
    src.close()
    return sent


def main(argv: list[str] | None = None) -> None:
    import httpx
    ap = argparse.ArgumentParser(prog="noop-push-simulator")
    ap.add_argument("--db", required=True, help="a COPY of the phone's whoop.sqlite")
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--source-id", default=None)
    a = ap.parse_args(argv)
    token = open(a.token_file, encoding="utf-8").read().strip()
    sid = a.source_id or str(uuid.uuid5(uuid.NAMESPACE_URL, "noop-simulator:" + a.db))
    with httpx.Client(timeout=60.0, follow_redirects=False) as http:
        try:
            sent = push_all(a.db, http, a.endpoint, token, sid)
        except (RuntimeError, httpx.HTTPError) as e:
            sys.exit(f"noop-push-simulator: {e}")
    for name, n in sent.items():
        print(f"{name}: {n} rows")


if __name__ == "__main__":
    main()
