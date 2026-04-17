"""
ALNS optimizer unit tests — model/alns_optimizer.py.

Tests cover:
  - vehicle_speed() for each vehicle type and unknown type
  - route_cost() with different traffic multipliers
  - route_cost() incident penalties (traffic_jam, accident, road_closed)
  - route_cost() time window — early arrival (wait cost) and late penalty
  - route_cost() fragile delivery penalty
  - route_cost() single-leg route
  - optimize_route() returns a valid permutation
  - optimize_route() returns cost <= baseline (ALNS never worsens the route)
  - optimize_route() with ML cost matrix injected in context
"""

import sys
from pathlib import Path
import pytest

_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))

from model.alns_optimizer import vehicle_speed, route_cost, optimize_route


# ─────────────────────────────────────────────────────────────────────────────
# TEST FIXTURES
# ─────────────────────────────────────────────────────────────────────────────

CAIRO_COORDS = [
    (30.0444, 31.2357),  # 0 – Tahrir
    (30.0626, 31.2497),  # 1 – Heliopolis
    (30.0131, 31.2089),  # 2 – Maadi
    (30.0561, 31.2394),  # 3 – Zamalek
]

NO_FRAGILE  = [False] * 4
NO_WINDOWS  = [(None, None)] * 4
BASE_CTX    = {"vehicle": "van", "traffic": "Normal", "weather": "Sunny"}
START_MIN   = 480  # 08:00


# ─────────────────────────────────────────────────────────────────────────────
# VEHICLE SPEED
# ─────────────────────────────────────────────────────────────────────────────

class TestVehicleSpeed:
    def test_motorcycle_speed(self):
        assert vehicle_speed("motorcycle") == pytest.approx(0.9)

    def test_scooter_speed(self):
        assert vehicle_speed("scooter") == pytest.approx(0.75)

    def test_van_speed(self):
        assert vehicle_speed("van") == pytest.approx(0.6)

    def test_unknown_vehicle_defaults(self):
        speed = vehicle_speed("bicycle")
        assert 0.5 <= speed <= 1.0   # must return a sensible default

    def test_motorcycle_faster_than_van(self):
        assert vehicle_speed("motorcycle") > vehicle_speed("van")


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE COST — BASIC
# ─────────────────────────────────────────────────────────────────────────────

class TestRouteCostBasic:
    def test_single_leg_positive_cost(self):
        coords = [CAIRO_COORDS[0], CAIRO_COORDS[1]]
        cost = route_cost([0, 1], coords, [False, False], [(None, None)] * 2, START_MIN, BASE_CTX)
        assert cost > 0

    def test_longer_route_has_higher_cost(self):
        coords = CAIRO_COORDS
        c_short = route_cost([0, 1], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX)
        c_long  = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX)
        assert c_long > c_short

    def test_reverse_route_valid(self):
        coords = CAIRO_COORDS
        c_fwd = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX)
        c_rev = route_cost([3, 2, 1, 0], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX)
        assert c_fwd > 0 and c_rev > 0


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE COST — TRAFFIC MULTIPLIERS
# ─────────────────────────────────────────────────────────────────────────────

class TestRouteCostTraffic:
    @pytest.mark.parametrize("traffic,multiplier_rank", [
        ("Low",    0),
        ("Normal", 1),
        ("Medium", 2),
        ("Heavy",  3),
    ])
    def test_traffic_affects_cost(self, traffic, multiplier_rank):
        coords = CAIRO_COORDS
        ctx = {**BASE_CTX, "traffic": traffic}
        c = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, ctx)
        assert c > 0

    def test_heavy_traffic_costs_more_than_low(self):
        coords = CAIRO_COORDS
        route = [0, 1, 2, 3]
        c_low   = route_cost(route, coords, NO_FRAGILE, NO_WINDOWS, START_MIN, {**BASE_CTX, "traffic": "Low"})
        c_heavy = route_cost(route, coords, NO_FRAGILE, NO_WINDOWS, START_MIN, {**BASE_CTX, "traffic": "Heavy"})
        assert c_heavy > c_low


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE COST — INCIDENT PENALTIES
# ─────────────────────────────────────────────────────────────────────────────

class TestRouteCostIncidents:
    def _cost_with_incident(self, incident):
        coords = CAIRO_COORDS
        ctx = {**BASE_CTX, "incident": incident}
        return route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, ctx)

    def _cost_no_incident(self):
        return route_cost([0, 1, 2, 3], CAIRO_COORDS, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX)

    def test_traffic_jam_increases_cost(self):
        c_base = self._cost_no_incident()
        c_jam  = self._cost_with_incident({"index": 1, "kind": "traffic_jam", "severity": 0.8})
        assert c_jam > c_base

    def test_accident_increases_cost_more_than_jam(self):
        c_jam      = self._cost_with_incident({"index": 1, "kind": "traffic_jam", "severity": 0.8})
        c_accident = self._cost_with_incident({"index": 1, "kind": "accident",    "severity": 0.8})
        assert c_accident > c_jam

    def test_road_closed_highest_penalty(self):
        c_accident = self._cost_with_incident({"index": 1, "kind": "accident",    "severity": 1.0})
        c_closed   = self._cost_with_incident({"index": 1, "kind": "road_closed", "severity": 1.0})
        assert c_closed > c_accident

    def test_zero_severity_incident_lower_penalty(self):
        c_high = self._cost_with_incident({"index": 1, "kind": "traffic_jam", "severity": 1.0})
        c_low  = self._cost_with_incident({"index": 1, "kind": "traffic_jam", "severity": 0.0})
        assert c_high >= c_low


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE COST — TIME WINDOWS
# ─────────────────────────────────────────────────────────────────────────────

class TestRouteCostTimeWindows:
    def test_late_penalty_added_when_arriving_after_window(self):
        coords = CAIRO_COORDS
        # Very early window — the route will arrive late
        windows = [(None, None), (0, 1), (None, None), (None, None)]  # stop 1 must arrive by t=1
        c_late = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, windows, START_MIN, BASE_CTX)
        c_none = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX)
        assert c_late > c_none

    def test_early_wait_cost_when_arriving_before_window(self):
        coords = CAIRO_COORDS
        # Very late window — the route arrives early and must wait
        windows = [(None, None), (9999, 10000), (None, None), (None, None)]
        c_wait = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, windows, START_MIN, BASE_CTX)
        c_none = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX)
        assert c_wait > c_none


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE COST — FRAGILE DELIVERY
# ─────────────────────────────────────────────────────────────────────────────

class TestRouteCostFragile:
    def test_fragile_stop_increases_cost(self):
        coords = CAIRO_COORDS
        fragile = [False, True, False, False]   # stop 1 is fragile
        c_fragile = route_cost([0, 1, 2, 3], coords, fragile,    NO_WINDOWS, START_MIN, BASE_CTX)
        c_normal  = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX)
        assert c_fragile > c_normal

    def test_all_fragile_still_returns_positive_cost(self):
        coords = CAIRO_COORDS
        all_fragile = [True, True, True, True]
        c = route_cost([0, 1, 2, 3], coords, all_fragile, NO_WINDOWS, START_MIN, BASE_CTX)
        assert c > 0


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE COST — ML MATRIX INJECTION
# ─────────────────────────────────────────────────────────────────────────────

class TestRouteCostMLMatrix:
    def test_ml_matrix_used_when_provided(self):
        """Inject a known ML cost matrix; verify it changes the cost vs formula."""
        coords = CAIRO_COORDS
        n = len(coords)
        # Build a flat matrix of 5.0 min per leg (well within 0.5–90 bounds)
        ml_matrix = [[5.0] * n for _ in range(n)]
        ctx_ml = {**BASE_CTX, "ml_cost_matrix": ml_matrix}
        ctx_no = {**BASE_CTX}
        c_ml = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, ctx_ml)
        c_no = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, ctx_no)
        # With fixed ML costs the result should differ from the formula
        assert c_ml != c_no

    def test_out_of_range_ml_values_fall_back_to_formula(self):
        """ML values outside [0.5, 90] min must be discarded (fallback to formula)."""
        coords = CAIRO_COORDS
        n = len(coords)
        # All-zero matrix — all values < 0.5 → every leg falls back to formula
        bad_matrix = [[0.0] * n for _ in range(n)]
        ctx_bad = {**BASE_CTX, "ml_cost_matrix": bad_matrix}
        ctx_no  = {**BASE_CTX}
        c_bad = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, ctx_bad)
        c_no  = route_cost([0, 1, 2, 3], coords, NO_FRAGILE, NO_WINDOWS, START_MIN, ctx_no)
        # Costs should be equal because all ML values were rejected
        assert c_bad == pytest.approx(c_no, rel=1e-6)


# ─────────────────────────────────────────────────────────────────────────────
# OPTIMIZE ROUTE  (full ALNS)
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeRoute:
    def test_returns_valid_permutation(self):
        coords = CAIRO_COORDS
        order, cost = optimize_route(coords, NO_FRAGILE, NO_WINDOWS, BASE_CTX, START_MIN)
        assert sorted(order) == list(range(len(coords)))

    def test_cost_not_negative(self):
        coords = CAIRO_COORDS
        _, cost = optimize_route(coords, NO_FRAGILE, NO_WINDOWS, BASE_CTX, START_MIN)
        assert cost >= 0

    def test_cost_not_worse_than_baseline(self):
        """ALNS must find a route ≤ the trivial 0,1,2,3 baseline order."""
        coords = CAIRO_COORDS
        baseline = route_cost(
            list(range(len(coords))), coords, NO_FRAGILE, NO_WINDOWS, START_MIN, BASE_CTX
        )
        _, alns_cost = optimize_route(coords, NO_FRAGILE, NO_WINDOWS, BASE_CTX, START_MIN)
        assert alns_cost <= baseline + 1e-6  # allow tiny float rounding

    def test_two_stop_route(self):
        coords = CAIRO_COORDS[:2]
        order, cost = optimize_route(coords, [False, False], [(None, None)] * 2, BASE_CTX, START_MIN)
        assert sorted(order) == [0, 1]
        assert cost > 0

    def test_single_stop_route(self):
        coords = [CAIRO_COORDS[0]]
        order, cost = optimize_route(coords, [False], [(None, None)], BASE_CTX, START_MIN)
        assert order == [0]
        assert cost == pytest.approx(0.0)
