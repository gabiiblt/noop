"""NDJSON batch parsing and validation (PUSH_PROTOCOL.md v1 + PROTOCOL_EXT.md 1.100)."""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import math
import re
import uuid
import zlib
from dataclasses import dataclass, field

from .registry import REGISTRY, VERSIONS, Col, Stream, streams_for

MAX_RECORDS = 5000
MAX_DECODED = 4_194_304
MAX_WIRE = 4_194_304 + 65_536

_HEX64 = re.compile(r"^[0-9a-f]{64}$")


class ProtocolError(Exception):
    def __init__(self, status: int, code: str) -> None:
        super().__init__(f"{status} {code}")
        self.status = status
        self.code = code


@dataclass
class Record:
    key: dict
    data: dict


@dataclass
class Batch:
    header: dict
    records: list[Record] = field(default_factory=list)
    sha256: str = ""

    @property
    def stream(self) -> Stream:
        return REGISTRY[self.header["stream"]]


def _decode(body: bytes, content_encoding: str | None) -> bytes:
    if len(body) > MAX_WIRE:
        raise ProtocolError(413, "payload_too_large")
    enc = (content_encoding or "identity").strip().lower()
    if enc == "identity":
        if len(body) > MAX_DECODED:
            raise ProtocolError(413, "payload_too_large")
        return body
    if enc != "gzip":
        raise ProtocolError(415, "unsupported_content_encoding")
    d = zlib.decompressobj(wbits=31)
    try:
        out = d.decompress(body, MAX_DECODED + 1)
    except zlib.error:
        raise ProtocolError(400, "bad_gzip") from None
    if len(out) > MAX_DECODED or d.unconsumed_tail:
        raise ProtocolError(413, "payload_too_large")
    if not d.eof:
        raise ProtocolError(400, "bad_gzip")
    return out


def _json(line: bytes):
    def bad_const(_c: str):
        raise ValueError("non-finite number")

    try:
        return json.loads(line.decode("utf-8"), parse_constant=bad_const)
    except (ValueError, UnicodeDecodeError):
        raise ProtocolError(400, "malformed_ndjson") from None


def _is_uuid(v) -> bool:
    if not isinstance(v, str) or v != v.lower():
        return False
    try:
        return str(uuid.UUID(v)) == v
    except ValueError:
        return False


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _value(col: Col, v, what: str):
    """Validate/convert one JSON value for a column; raise 422 on a malformed known member."""
    if v is None:
        if not col.nullable:
            raise ProtocolError(422, "invalid_record")
        return None
    ok = {
        "int": _is_int(v),
        "real": (_is_int(v) or isinstance(v, float)) and not (isinstance(v, float) and not math.isfinite(v)),
        "text": isinstance(v, str),
        "bool": isinstance(v, bool),
        "blob": isinstance(v, str),
    }[col.type]
    if not ok:
        raise ProtocolError(422, "invalid_record")
    if col.type == "blob":
        try:
            return base64.b64decode(v, validate=True)
        except (binascii.Error, ValueError):
            raise ProtocolError(422, "invalid_record") from None
    return v


def _check_cursor(c, *, nullable: bool) -> None:
    if c is None:
        if nullable:
            return
        raise ProtocolError(400, "bad_cursor")
    if (not isinstance(c, dict) or not _is_int(c.get("rowId")) or c["rowId"] < 0
            or not isinstance(c.get("keySha256"), str) or not _HEX64.match(c["keySha256"])):
        raise ProtocolError(400, "bad_cursor")


def _check_window(h: dict, s: Stream) -> dict:
    w = h.get("window")
    if not isinstance(w, dict):
        raise ProtocolError(400, "missing_window")
    if not _is_uuid(w.get("replacementId")):
        raise ProtocolError(400, "bad_window")
    part, parts = w.get("part"), w.get("parts")
    if not (_is_int(part) and _is_int(parts) and 1 <= part <= parts):
        raise ProtocolError(400, "bad_window")
    if s.delivery == "snapshot":
        if w.get("selector") != "all":
            raise ProtocolError(400, "bad_window")
        return w
    if w.get("selector") != s.selector:
        raise ProtocolError(400, "bad_window")
    a, b = w.get("startInclusive"), w.get("endExclusive")
    types_ok = (isinstance(a, str) and isinstance(b, str)) if s.selector == "day" else (_is_int(a) and _is_int(b))
    if not types_ok or not a < b:
        raise ProtocolError(400, "bad_window")
    return w


def parse_batch(body: bytes, content_encoding: str | None, version: str | None, allowed: set[str]) -> Batch:
    """`version=None` takes the protocol version from the batch header (it must be a known one)."""
    decoded = _decode(body, content_encoding)
    if decoded.startswith(b"\xef\xbb\xbf") or not decoded.endswith(b"\n"):
        raise ProtocolError(400, "malformed_ndjson")
    lines = decoded[:-1].split(b"\n")
    if any(not ln.strip() for ln in lines):
        raise ProtocolError(400, "malformed_ndjson")
    objs = [_json(ln) for ln in lines]
    h = objs[0]
    if not isinstance(h, dict) or h.get("type") != "batch":
        raise ProtocolError(400, "bad_header")
    if version is None:
        version = h.get("protocolVersion")
    if version not in VERSIONS or h.get("protocolVersion") != version:
        raise ProtocolError(422, "unsupported_version")
    for k in ("batchId", "sourceId"):
        if not _is_uuid(h.get(k)):
            raise ProtocolError(400, "bad_header")
    if not isinstance(h.get("deviceId"), str) or not h["deviceId"]:
        raise ProtocolError(400, "bad_header")
    name = h.get("stream")
    names = {s.name for s in streams_for(version)}
    if not isinstance(name, str) or name not in names or name not in allowed:
        raise ProtocolError(422, "unsupported_stream")
    s = REGISTRY[name]
    if h.get("delivery") != s.delivery:
        raise ProtocolError(422, "delivery_mismatch")
    n = h.get("recordCount")
    if not _is_int(n) or not 0 <= n <= MAX_RECORDS:
        raise ProtocolError(400, "bad_record_count")
    if len(objs) - 1 != n:
        raise ProtocolError(400, "record_count_mismatch")

    window = None
    if s.delivery == "append":
        if n < 1:
            raise ProtocolError(400, "empty_append")
        _check_cursor(h.get("startCursor"), nullable=True)
        _check_cursor(h.get("endCursor"), nullable=False)
        sc = h.get("startCursor")
        if sc is not None and not sc["rowId"] < h["endCursor"]["rowId"]:
            raise ProtocolError(400, "bad_cursor")
    else:
        if h.get("startCursor") is not None or h.get("endCursor") is not None:
            raise ProtocolError(400, "bad_cursor")
        window = _check_window(h, s)

    key_names = [c.name for c in s.key]
    data_cols = s.data_for(version)
    records: list[Record] = []
    seen: set[tuple] = set()
    for o in objs[1:]:
        if not isinstance(o, dict) or o.get("type") != "record":
            raise ProtocolError(400, "bad_record")
        key, data = o.get("key"), o.get("data")
        if not isinstance(key, dict) or not isinstance(data, dict) or set(key) != set(key_names):
            raise ProtocolError(422, "invalid_record")
        k = {c.name: _value(c, key[c.name], "key") for c in s.key}
        d = {c.name: _value(c, data.get(c.name), "data") for c in data_cols if c.name in data or not c.nullable}
        ident = tuple(k[n] for n in key_names)
        if ident in seen:
            raise ProtocolError(400, "duplicate_key")
        seen.add(ident)
        if window is not None and s.delivery == "replace_window":
            sel = k[s.selector]
            if not window["startInclusive"] <= sel < window["endExclusive"]:
                raise ProtocolError(422, "record_outside_window")
        records.append(Record(k, d))
    return Batch(h, records, hashlib.sha256(decoded).hexdigest())
