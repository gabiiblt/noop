import math

from noop_selfhost.stress import (
    HR_DELTA, MIN_BEATS, WINDOW_S, Baseline, compute_stress_timeline, gravity_motion,
    personal_baseline, rmssd,
)

BASE = Baseline(median=50.0, mad=10.0, rest_hr=60.0)


def test_rmssd_matches_hand_computed_oracle():
    # diffs 20,-40,20,20,-40 -> mean square 880 -> sqrt(880). Hand-computed (HRVAnalyzer.rmssdRaw formula);
    # all beats pass the range + 20 % ectopic filters.
    assert math.isclose(rmssd([800, 820, 780, 800, 820, 780]), 29.66479394838265, rel_tol=1e-12)


def test_ectopic_beat_dropped_and_difference_across_it_skipped():
    # Gap-aware like HRVAnalyzer.cleanRRGapAware: no difference is taken across the removed 1600 ms beat.
    assert rmssd([800] * 10 + [1600] + [800] * 10) == 0.0


def test_out_of_range_beats_ignored():
    assert rmssd([250, 800, 2500, 800, 800]) == 0.0


def test_rmssd_none_when_fewer_than_two_clean_beats():
    assert rmssd([]) is None and rmssd([800]) is None and rmssd([100, 5000]) is None


def beats(start, target_rmssd, hr_ms=800):
    """RR beats alternating +/-a around hr_ms so successive differences are +/-2a (rmssd = 2a)."""
    a = target_rmssd / 2
    t, i, out = float(start), 0, []
    while t < start + WINDOW_S:
        rr = int(hr_ms + (a if i % 2 == 0 else -a))
        out.append((int(t), rr))
        t += rr / 1000
        i += 1
    return out


def hr_samples(start, bpm):
    return [(start + s, bpm) for s in range(0, WINDOW_S, 5)]


def motion(start, v):
    return [(start + s, v) for s in range(0, WINDOW_S, 5)]


def one(rr, hr, mo, base=BASE):
    w = compute_stress_timeline(rr, hr, mo, base)
    assert len(w) == 1
    return w[0]


def test_tracks_varying_input_not_one_match():
    scores = {}
    for target in (20, 40, 80):
        start = 3000
        scores[target] = one(beats(start, target), hr_samples(start, 70), motion(start, 0.01)).score
    assert scores[20] > scores[40] > scores[80]
    assert scores[20] >= 70 and scores[80] <= 30


def test_stressed_requires_low_rmssd_and_high_hr_and_low_motion():
    s = 3000
    rr = beats(s, 20)
    w = one(rr, hr_samples(s, 75), motion(s, 0.01))
    assert w.label == "stressed" and w.rmssd is not None and abs(w.rmssd - 20) < 1.5
    w = one(rr, hr_samples(s, 62), motion(s, 0.01))
    assert w.label == "elevated" and "hr" in w.reason
    w = one(rr, hr_samples(s, 75), motion(s, 0.5))
    assert w.label == "elevated" and "moving" in w.reason
    w = one(rr, hr_samples(s, 75), [])
    assert w.label == "elevated" and "motion_unknown" in w.reason
    w = one(beats(s, 60), hr_samples(s, 75), motion(s, 0.01))
    assert w.label == "calm"


def test_exercise_is_not_stress():
    s = 3000
    w = one(beats(s, 15, hr_ms=450), hr_samples(s, 150), motion(s, 0.8))
    assert w.label != "stressed"


def test_too_few_beats_gives_unknown_score_none():
    s = 3000
    rr = beats(s, 20)[: MIN_BEATS - 1]
    w = one(rr, hr_samples(s, 75), motion(s, 0.01))
    assert (w.label, w.score, w.rmssd) == ("unknown", None, None) and "too_few_beats" in w.reason


def test_no_baseline_gives_unknown_but_reports_inputs():
    s = 3000
    w = one(beats(s, 20), hr_samples(s, 75), motion(s, 0.01), base=None)
    assert w.label == "unknown" and w.score is None and "no_baseline" in w.reason and w.rmssd is not None


def test_windows_are_epoch_aligned_and_empty_input_is_empty():
    assert compute_stress_timeline([], [], [], BASE) == []
    w = compute_stress_timeline(beats(3010, 40), hr_samples(3010, 65), [], BASE)
    assert all(x.start_ts % WINDOW_S == 0 and x.end_ts - x.start_ts == WINDOW_S for x in w)
    assert [x.start_ts for x in w] == sorted(x.start_ts for x in w)


def test_mad_floor_prevents_division_blowup():
    s = 3000
    w = one(beats(s, 20), hr_samples(s, 75), motion(s, 0.01), base=Baseline(50.0, 0.0, 60.0))
    assert w.score is not None and 0 <= w.score <= 100


def test_personal_baseline_median_mad_rest_hr_and_minimum_windows():
    hist = [(40.0 + i, 62.0 + i % 5) for i in range(25)]  # rmssd 40..64
    b = personal_baseline(hist)
    assert b.median == 52.0 and b.mad == 6.0 and 62.0 <= b.rest_hr <= 63.0
    assert personal_baseline(hist[:5]) is None


def test_hr_delta_constant_documented_default():
    assert HR_DELTA == 10


def test_gravity_motion_is_l2_between_consecutive_samples_and_ignores_gaps():
    g = [(0, 0.0, 0.0, 1.0), (1, 0.0, 0.03, 1.0), (2, 0.0, 0.03, 0.96), (100, 0.0, 0.5, 0.5)]
    out = gravity_motion(g)
    assert [t for t, _ in out] == [1, 2]
    assert math.isclose(out[0][1], 0.03) and math.isclose(out[1][1], 0.04)
