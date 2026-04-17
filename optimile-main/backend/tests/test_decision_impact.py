"""
Unit tests for model/decision.py and model/impact.py.

decision.py: should_reoptimize() — decides whether to run ALNS again.
impact.py:   estimate_delay()    — estimates delay in minutes for an event.
"""

import sys
from pathlib import Path
import pytest

_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))

from model.decision import should_reoptimize
from model.impact   import estimate_delay


# ─────────────────────────────────────────────────────────────────────────────
# should_reoptimize()
# ─────────────────────────────────────────────────────────────────────────────

class TestShouldReoptimize:
    # ── False conditions ──────────────────────────────────────────────────────

    def test_zero_delay_returns_false(self):
        assert should_reoptimize(
            delay_minutes=0.0,
            next_stop_fragile=False,
            time_window_slack=30,
            last_reopt_seconds=120,
        ) is False

    def test_negative_delay_returns_false(self):
        assert should_reoptimize(
            delay_minutes=-5.0,
            next_stop_fragile=True,
            time_window_slack=0,
            last_reopt_seconds=0,
        ) is False

    def test_sub_one_minute_delay_returns_false(self):
        assert should_reoptimize(
            delay_minutes=0.99,
            next_stop_fragile=True,
            time_window_slack=0,
            last_reopt_seconds=0,
        ) is False

    # ── True conditions ───────────────────────────────────────────────────────

    def test_one_minute_delay_returns_true(self):
        assert should_reoptimize(
            delay_minutes=1.0,
            next_stop_fragile=False,
            time_window_slack=30,
            last_reopt_seconds=120,
        ) is True

    def test_small_positive_delay_returns_true(self):
        assert should_reoptimize(
            delay_minutes=2.5,
            next_stop_fragile=False,
            time_window_slack=30,
            last_reopt_seconds=120,
        ) is True

    def test_large_delay_returns_true(self):
        assert should_reoptimize(
            delay_minutes=30.0,
            next_stop_fragile=True,
            time_window_slack=5,
            last_reopt_seconds=10,
        ) is True

    def test_fragile_next_stop_with_delay_returns_true(self):
        assert should_reoptimize(
            delay_minutes=5.0,
            next_stop_fragile=True,
            time_window_slack=2,
            last_reopt_seconds=60,
        ) is True

    # ── Return type ───────────────────────────────────────────────────────────

    def test_returns_bool_type(self):
        result = should_reoptimize(1.0, False, 30, 120)
        assert isinstance(result, bool)


# ─────────────────────────────────────────────────────────────────────────────
# estimate_delay()
# ─────────────────────────────────────────────────────────────────────────────

class TestEstimateDelay:
    # ── Known event types ─────────────────────────────────────────────────────

    def test_traffic_jam_factor(self):
        delay = estimate_delay("traffic_jam", 100.0)
        assert delay == pytest.approx(30.0)     # 30% of 100

    def test_accident_factor(self):
        delay = estimate_delay("accident", 100.0)
        assert delay == pytest.approx(50.0)     # 50% of 100

    def test_road_closed_factor(self):
        delay = estimate_delay("road_closed", 100.0)
        assert delay == pytest.approx(90.0)     # 90% of 100

    def test_deviation_factor(self):
        delay = estimate_delay("deviation", 100.0)
        assert delay == pytest.approx(40.0)     # 40% of 100

    # ── Proportionality ───────────────────────────────────────────────────────

    def test_delay_scales_with_baseline_eta(self):
        d20  = estimate_delay("traffic_jam", 20.0)
        d100 = estimate_delay("traffic_jam", 100.0)
        assert d100 == pytest.approx(5 * d20)

    # ── Edge cases ────────────────────────────────────────────────────────────

    def test_zero_baseline_returns_zero(self):
        assert estimate_delay("traffic_jam", 0.0) == pytest.approx(0.0)

    def test_negative_baseline_returns_zero(self):
        assert estimate_delay("accident", -10.0) == pytest.approx(0.0)

    def test_unknown_event_returns_zero(self):
        assert estimate_delay("alien_invasion", 50.0) == pytest.approx(0.0)

    def test_empty_event_string_returns_zero(self):
        assert estimate_delay("", 50.0) == pytest.approx(0.0)

    # ── Return type ───────────────────────────────────────────────────────────

    def test_returns_float(self):
        result = estimate_delay("traffic_jam", 20.0)
        assert isinstance(result, float)

    def test_result_non_negative(self):
        for event in ["traffic_jam", "accident", "road_closed", "deviation", "unknown"]:
            assert estimate_delay(event, 20.0) >= 0.0

    # ── Ordering — more severe events produce larger delays ───────────────────

    def test_road_closed_larger_than_accident(self):
        assert estimate_delay("road_closed", 50) > estimate_delay("accident", 50)

    def test_accident_larger_than_traffic_jam(self):
        assert estimate_delay("accident", 50) > estimate_delay("traffic_jam", 50)
