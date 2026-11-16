"""Shared NDJSON builders for receiver tests."""
import json
import uuid

from noop_selfhost.registry import V1

SRC = "3a3486dd-5030-4e17-a00d-a781399890f9"
H64 = "b" * 64


def nd(*objs) -> bytes:
    return ("\n".join(json.dumps(o, separators=(",", ":")) for o in objs) + "\n").encode()


def hdr(stream="hrSample", n=2, **kw):
    h = {"type": "batch", "protocolVersion": V1, "batchId": str(uuid.uuid4()), "sourceId": SRC,
         "deviceId": "strap-local-id", "stream": stream, "delivery": "append", "recordCount": n,
         "startCursor": None, "endCursor": {"rowId": 10, "keySha256": H64}}
    h.update(kw)
    return h


def rec(key, data):
    return {"type": "record", "key": key, "data": data}


def win(selector, a, b, part=1, parts=1, rid=None):
    return {"replacementId": rid or str(uuid.uuid4()), "selector": selector,
            "startInclusive": a, "endExclusive": b, "part": part, "parts": parts}


def hr_batch(batch_id=None, source=SRC, bpm0=60, n=2, **kw):
    h = hdr(n=n, sourceId=source, **kw)
    if batch_id:
        h["batchId"] = batch_id
    return nd(h, *[rec({"ts": 1000 + i}, {"bpm": bpm0 + i}) for i in range(n)])


AUTH = {"Authorization": "Bearer tok"}
