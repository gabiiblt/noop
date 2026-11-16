from noop_selfhost.rr_policy import apply_read_policy


def row(ts, rr, seq=0, ord_=None, ch=None, dev="strap", src="A"):
    return {"ts": ts, "rrMs": rr, "seq": seq, "ord": ord_, "srcChannel": ch, "dev": dev, "src": src}


def rr_values(rows):
    return [r["rrMs"] for r in apply_read_policy(rows)]


def test_identical_beats_from_two_sources_are_counted_once():
    a = [row(1, 800, src="A"), row(2, 810, src="A")]
    b = [row(1, 800, src="B"), row(2, 810, src="B")]
    assert rr_values(a + b) == [800, 810]


def test_equal_consecutive_beats_with_distinct_seq_both_survive():
    rows = [row(5, 800, seq=0), row(5, 800, seq=1)]
    assert rr_values(rows) == [800, 800]
    assert rr_values(rows + [row(5, 800, seq=0, src="B"), row(5, 800, seq=1, src="B")]) == [800, 800]


def test_whoop5_keeps_the_lowest_scorable_channel_per_hour():
    rows = [row(1, 800, ch=7), row(1, 800, ch=5), row(2, 810, ch=7), row(2, 810, ch=5), row(3, 700, ch=6)]
    assert rr_values(rows) == [800, 810]            # channel 5 wins; 6 (labelling channel) is not scorable


def test_whoop5_channel_choice_is_per_hour_not_global():
    rows = [row(1, 800, ch=5), row(1, 800, ch=7), row(3601, 900, ch=7)]  # hour 2 only has channel 7
    assert rr_values(rows) == [800, 900]


def test_whoop4_historical_channel_is_kept_when_no_whoop5_channel_present():
    rows = [row(1, 800, ch=8), row(2, 810, ch=8), row(3, 820, ch=None)]
    assert rr_values(rows) == [800, 810]


def test_untagged_rows_are_kept_when_nothing_in_the_hour_is_tagged():
    assert rr_values([row(1, 800), row(2, 810)]) == [800, 810]


def test_unlabelled_rows_beside_tagged_ones_are_dropped_as_duplicates():
    rows = [row(1, 800, ch=7), row(1, 800, ch=None), row(2, 810, ch=7)]
    assert rr_values(rows) == [800, 810]


def test_devices_are_independent_and_output_is_ordered_by_ts_then_ord_then_seq():
    rows = [row(2, 810, ord_=2, dev="a"), row(1, 800, ord_=1, dev="a"), row(1, 900, dev="b")]
    out = apply_read_policy(rows)
    assert [(r["ts"], r["rrMs"]) for r in out] == [(1, 800), (1, 900), (2, 810)]


def test_empty_input():
    assert apply_read_policy([]) == []
