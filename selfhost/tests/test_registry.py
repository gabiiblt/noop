from noop_selfhost.registry import EXT, REGISTRY, V1, streams_for

V1_NAMES = {
    "hrSample", "rrInterval", "event", "battery", "spo2Sample", "skinTempSample",
    "respSample", "gravitySample", "dailyMetric", "sleepSession", "workout", "journal",
}


def test_v1_has_exactly_twelve_streams():
    assert {s.name for s in streams_for(V1)} == V1_NAMES
    assert len(streams_for(V1)) == 12


def test_rr_key_includes_seq():
    assert [c.name for c in REGISTRY["rrInterval"].key] == ["ts", "rrMs", "seq"]


def test_sleep_session_is_replace_window_on_startTs():
    s = REGISTRY["sleepSession"]
    assert (s.delivery, s.selector) == ("replace_window", "startTs")
    assert [c.name for c in s.key] == ["startTs"]


def test_append_and_window_split_matches_protocol():
    append = {s.name for s in streams_for(V1) if s.delivery == "append"}
    assert append == {"hrSample", "rrInterval", "event", "battery", "spo2Sample",
                      "skinTempSample", "respSample", "gravitySample"}


def test_ext_includes_waveforms_and_lift_tables():
    names = {s.name for s in streams_for(EXT)}
    assert {"ppgWaveformSample", "ecgWaveformSample", "v18AuxSample", "stepSample",
            "ppgHrSample", "sleepStateSample", "metricSeries", "liftSet"} <= names
    assert names >= V1_NAMES


def test_forbidden_streams_absent():
    for bad in ("coachMessage", "device", "cursors", "rawBatch", "rawImuSample"):
        assert bad not in REGISTRY


def test_streams_for_v1_excludes_ext():
    assert "ppgWaveformSample" not in {s.name for s in streams_for(V1)}


def test_ext_adds_extra_members_to_v1_streams_only_under_ext():
    daily = REGISTRY["dailyMetric"]
    assert "avgSdnn" not in [c.name for c in daily.data_for(V1)]
    assert "avgSdnn" in [c.name for c in daily.data_for(EXT)]


def test_blob_columns_are_flagged():
    assert [c.name for c in REGISTRY["ppgWaveformSample"].data if c.type == "blob"] == ["samples"]


def test_unknown_version_rejected():
    import pytest
    with pytest.raises(ValueError):
        streams_for("9.9")


def test_apple_step_hour_is_a_replace_window_on_ts_because_the_app_updates_hours_in_place():
    s = REGISTRY["appleStepHour"]
    assert (s.delivery, s.selector) == ("replace_window", "ts")
    assert [c.name for c in s.key] == ["ts"]
