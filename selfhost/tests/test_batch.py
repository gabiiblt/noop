import base64
import gzip
import json
import uuid

import pytest

from noop_selfhost.batch import MAX_DECODED, ProtocolError, parse_batch
from noop_selfhost.registry import EXT, V1, REGISTRY

SRC = "3a3486dd-5030-4e17-a00d-a781399890f9"
H64 = "a" * 64
ALL = set(REGISTRY)


def nd(*objs, trailing=True) -> bytes:
    s = "\n".join(json.dumps(o, separators=(",", ":")) for o in objs)
    return (s + ("\n" if trailing else "")).encode()


def hdr(stream="hrSample", n=2, **kw):
    h = {"type": "batch", "protocolVersion": V1, "batchId": str(uuid.uuid4()), "sourceId": SRC,
         "deviceId": "strap-local-id", "stream": stream, "delivery": "append", "recordCount": n,
         "startCursor": None, "endCursor": {"rowId": 10, "keySha256": H64}}
    h.update(kw)
    return h


def rec(key, data):
    return {"type": "record", "key": key, "data": data}


def hr_body(n=2, **kw):
    return nd(hdr(n=n, **kw), *[rec({"ts": 1723939201 + i}, {"bpm": 60 + i}) for i in range(n)])


def parse(body, enc=None, version=V1, allowed=ALL):
    return parse_batch(body, enc, version, allowed)


def status(body, enc=None, version=V1, allowed=ALL):
    with pytest.raises(ProtocolError) as e:
        parse(body, enc, version, allowed)
    return e.value.status


def test_parses_spec_hr_example():
    b = parse(hr_body())
    assert b.header["stream"] == "hrSample" and len(b.records) == 2
    assert b.records[0].key == {"ts": 1723939201} and b.records[0].data == {"bpm": 60}


def test_gzip_and_identity_have_same_sha256():
    body = hr_body()
    assert parse(body).sha256 == parse(gzip.compress(body), "gzip").sha256


def test_gzip_bomb_rejected_413():
    bomb = gzip.compress(b"\n" * (MAX_DECODED + 1000))
    assert len(bomb) < 100_000
    assert status(bomb, "gzip") == 413


def test_identity_over_limit_413():
    assert status(b"x" * (MAX_DECODED + 1)) == 413


def test_unsupported_content_encoding_415():
    assert status(hr_body(), "br") == 415


def test_version_none_takes_it_from_header_and_rejects_unknown():
    assert parse_batch(hr_body(), None, None, ALL).header["protocolVersion"] == V1
    with pytest.raises(ProtocolError) as e:
        parse_batch(hr_body(protocolVersion="3.0"), None, None, ALL)
    assert e.value.status == 422


def test_wrong_record_count_400():
    assert status(hr_body(n=2, recordCount=3)) == 400


def test_duplicate_keys_in_batch_400():
    body = nd(hdr(n=2), rec({"ts": 1}, {"bpm": 60}), rec({"ts": 1}, {"bpm": 61}))
    assert status(body) == 400


@pytest.mark.parametrize("stream,version,allowed", [
    ("nope", V1, ALL),
    ("hrSample", V1, {"battery"}),
    ("ppgWaveformSample", V1, ALL),
])
def test_unknown_or_disallowed_stream_422(stream, version, allowed):
    body = nd(hdr(stream=stream, n=0, endCursor=None))
    assert status(body, version=version, allowed=allowed) == 422


def test_append_end_cursor_must_exceed_start_cursor():
    body = hr_body(startCursor={"rowId": 10, "keySha256": H64}, endCursor={"rowId": 10, "keySha256": H64})
    assert status(body) == 400


def test_append_requires_records_and_end_cursor():
    assert status(nd(hdr(n=0))) == 400
    assert status(hr_body(endCursor=None)) == 400


def test_cursor_fingerprint_must_be_sha256_hex():
    assert status(hr_body(endCursor={"rowId": 10, "keySha256": "xyz"})) == 400


def test_two_equal_rr_beats_with_distinct_seq_accepted():
    body = nd(hdr("rrInterval", 2),
              rec({"ts": 5, "rrMs": 800, "seq": 0}, {}), rec({"ts": 5, "rrMs": 800, "seq": 1}, {}))
    assert len(parse(body).records) == 2


def test_identical_rr_key_is_duplicate_400():
    body = nd(hdr("rrInterval", 2),
              rec({"ts": 5, "rrMs": 800, "seq": 0}, {}), rec({"ts": 5, "rrMs": 800, "seq": 0}, {}))
    assert status(body) == 400


def test_blank_line_or_bom_400():
    good = hr_body()
    assert status(b"\xef\xbb\xbf" + good) == 400
    assert status(good.replace(b"\n", b"\n\n", 1)) == 400
    assert status(good.rstrip(b"\n")) == 400  # missing trailing LF


def test_missing_required_member_422():
    body = nd(hdr(n=1), rec({"ts": 1}, {}))
    assert status(body) == 422


def test_wrong_type_is_422_and_bool_is_not_int():
    assert status(nd(hdr(n=1), rec({"ts": 1}, {"bpm": "60"}))) == 422
    assert status(nd(hdr(n=1), rec({"ts": 1}, {"bpm": True}))) == 422


def test_unknown_data_member_is_ignored():
    b = parse(nd(hdr(n=1), rec({"ts": 1}, {"bpm": 60, "future": 1})))
    assert b.records[0].data == {"bpm": 60}


def test_ext_member_only_accepted_under_ext():
    body = lambda v: nd(hdr("dailyMetric", 0, delivery="replace_window", endCursor=None, protocolVersion=v,
                            window=win("day", "2026-01-01", "2026-01-15")))
    parse(body(EXT), version=EXT)  # empty window is fine
    r = rec({"day": "2026-01-02"}, {"avgSdnn": 55.0})
    b1 = nd(hdr("dailyMetric", 1, delivery="replace_window", endCursor=None,
                window=win("day", "2026-01-01", "2026-01-15")), r)
    assert "avgSdnn" not in parse(b1).records[0].data  # ignored under 1.0
    b2 = nd(hdr("dailyMetric", 1, delivery="replace_window", endCursor=None, protocolVersion=EXT,
                window=win("day", "2026-01-01", "2026-01-15")), r)
    assert parse(b2, version=EXT).records[0].data["avgSdnn"] == 55.0


def win(selector, a, b, part=1, parts=1):
    return {"replacementId": str(uuid.uuid4()), "selector": selector, "startInclusive": a,
            "endExclusive": b, "part": part, "parts": parts}


def test_window_header_required_for_replace_window():
    body = nd(hdr("sleepSession", 0, delivery="replace_window", endCursor=None))
    assert status(body) == 400


def test_delivery_must_match_registry():
    body = nd(hdr("sleepSession", 0, delivery="append"))
    assert status(body) == 422


def test_window_record_outside_window_422():
    body = nd(hdr("sleepSession", 1, delivery="replace_window", endCursor=None,
                  window=win("startTs", 100, 200)),
              rec({"startTs": 250}, {"endTs": 300, "userEdited": False}))
    assert status(body) == 422


def test_window_bounds_half_open_and_ordered():
    body = nd(hdr("sleepSession", 0, delivery="replace_window", endCursor=None, window=win("startTs", 200, 200)))
    assert status(body) == 400


def test_blob_member_base64_decoded_to_bytes():
    raw = bytes(range(48))
    body = nd(hdr("ppgWaveformSample", 1, protocolVersion=EXT),
              rec({"ts": 1}, {"samples": base64.b64encode(raw).decode()}))
    assert parse(body, version=EXT).records[0].data["samples"] == raw


def test_bad_base64_422():
    body = nd(hdr("ppgWaveformSample", 1, protocolVersion=EXT), rec({"ts": 1}, {"samples": "***"}))
    assert status(body, version=EXT) == 422


def test_snapshot_requires_all_selector():
    body = nd(hdr("liftSet", 0, protocolVersion=EXT, delivery="snapshot", endCursor=None,
                  window=win("all", "", "")))
    assert parse(body, version=EXT).records == []
    bad = nd(hdr("liftSet", 0, protocolVersion=EXT, delivery="snapshot", endCursor=None,
                 window=win("day", "a", "b")))
    assert status(bad, version=EXT) == 400
