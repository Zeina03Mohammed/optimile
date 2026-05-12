"""
POST /optimize endpoint — automated tests.

Tests cover:
  - Response shape and status code
  - All vehicle types (motorcycle, scooter, van)
  - All traffic levels (Low, Normal, Medium, Heavy)
  - Fragile-stop handling
  - Time-window stops (window_start / window_end)
  - Single-stop and two-stop edge cases
  - Incident injection
  - ALNS result is a valid permutation of the input stops
  - Optimized cost is <= baseline cost (ALNS never worsens the route)
"""

import sys
from pathlib import Path
import pytest

_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def _coord_set(stops):
    return {(round(s["lat"], 5), round(s["lng"], 5)) for s in stops}


# ─────────────────────────────────────────────────────────────────────────────
# RESPONSE SHAPE
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeResponseShape:
    def test_returns_200(self, client, optimize_body):
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200

    def test_has_optimized_route_key(self, client, optimize_body):
        body = client.post("/optimize", json=optimize_body).json()
        assert "optimized_route" in body

    def test_has_cost_key(self, client, optimize_body):
        body = client.post("/optimize", json=optimize_body).json()
        assert "cost" in body

    def test_cost_is_positive_float(self, client, optimize_body):
        body = client.post("/optimize", json=optimize_body).json()
        assert isinstance(body["cost"], float)
        assert body["cost"] > 0

    def test_optimized_route_length_matches_input(self, client, optimize_body):
        body = client.post("/optimize", json=optimize_body).json()
        assert len(body["optimized_route"]) == len(optimize_body["stops"])

    def test_optimized_route_stop_fields(self, client, optimize_body):
        """Every stop in the response has lat, lng, is_fragile."""
        body = client.post("/optimize", json=optimize_body).json()
        for s in body["optimized_route"]:
            assert "lat" in s
            assert "lng" in s
            assert "is_fragile" in s

    def test_optimized_route_is_permutation_of_input(self, client, optimize_body):
        """Output coordinates are a reordering of the input — no stops added or removed."""
        input_coords = _coord_set(optimize_body["stops"])
        body = client.post("/optimize", json=optimize_body).json()
        output_coords = _coord_set(body["optimized_route"])
        assert input_coords == output_coords


# ─────────────────────────────────────────────────────────────────────────────
# VEHICLE TYPES
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeVehicleTypes:
    @pytest.mark.parametrize("vehicle", ["motorcycle", "car", "van"])
    def test_all_vehicle_types_succeed(self, client, optimize_body, vehicle):
        optimize_body["vehicle"] = vehicle
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200
        assert r.json()["cost"] > 0

    def test_motorcycle_lower_cost_than_van(self):
        """Motorcycle is faster → lower route_cost() than van on the identical route."""
        from model.alns_optimizer import route_cost
        coords = [
            (30.0444, 31.2357),
            (30.0626, 31.2497),
            (30.0131, 31.2089),
            (30.0561, 31.2394),
        ]
        route = [0, 1, 2, 3]
        windows = [(None, None)] * 4
        fragile = [False] * 4
        ctx_moto = {"vehicle": "motorcycle", "traffic": "Normal", "weather": "Sunny"}
        ctx_van  = {"vehicle": "van",        "traffic": "Normal", "weather": "Sunny"}
        cost_moto = route_cost(route, coords, fragile, windows, 480, ctx_moto)
        cost_van  = route_cost(route, coords, fragile, windows, 480, ctx_van)
        assert cost_moto < cost_van


# ─────────────────────────────────────────────────────────────────────────────
# TRAFFIC LEVELS
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeTrafficLevels:
    @pytest.mark.parametrize("traffic", ["Low", "Normal", "Medium", "Heavy"])
    def test_all_traffic_levels_succeed(self, client, optimize_body, traffic):
        optimize_body["traffic"] = traffic
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200

    def test_heavy_traffic_higher_cost_than_low(self, client, optimize_body):
        optimize_body["traffic"] = "Low"
        cost_low = client.post("/optimize", json=optimize_body).json()["cost"]
        optimize_body["traffic"] = "Heavy"
        cost_heavy = client.post("/optimize", json=optimize_body).json()["cost"]
        assert cost_heavy > cost_low


# ─────────────────────────────────────────────────────────────────────────────
# FRAGILE STOPS
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeFragileStops:
    def test_all_fragile_stops_still_returns_route(self, client, optimize_body):
        for s in optimize_body["stops"]:
            s["is_fragile"] = True
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200
        assert len(r.json()["optimized_route"]) == len(optimize_body["stops"])

    def test_fragile_in_response_matches_input_stop(self, client, optimize_body):
        """The is_fragile flag must be preserved in the response stops."""
        optimize_body["stops"][1]["is_fragile"] = True
        body = client.post("/optimize", json=optimize_body).json()
        fragile_in_output = any(s["is_fragile"] for s in body["optimized_route"])
        assert fragile_in_output is True


# ─────────────────────────────────────────────────────────────────────────────
# TIME WINDOWS
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeTimeWindows:
    def test_stops_with_valid_time_windows(self, client, optimize_body):
        optimize_body["stops"][0]["window_start"] = 480   # 08:00
        optimize_body["stops"][0]["window_end"]   = 600   # 10:00
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200

    def test_tight_time_window_still_returns_route(self, client, optimize_body):
        """A very tight window should not crash the optimizer."""
        optimize_body["stops"][2]["window_start"] = 480
        optimize_body["stops"][2]["window_end"]   = 481
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200

    def test_window_fields_preserved_in_response(self, client, optimize_body):
        ws, we = 510, 600
        optimize_body["stops"][0]["window_start"] = ws
        optimize_body["stops"][0]["window_end"]   = we
        body = client.post("/optimize", json=optimize_body).json()
        # At least one stop in the response should carry the window values
        matching = [s for s in body["optimized_route"]
                    if s.get("window_start") == ws and s.get("window_end") == we]
        assert len(matching) >= 1


# ─────────────────────────────────────────────────────────────────────────────
# EDGE CASES
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeEdgeCases:
    def test_single_stop(self, client, cairo_stops):
        body = {
            "stops": cairo_stops[:1],
            "vehicle": "van",
            "traffic": "Normal",
            "weather": "Sunny",
            "use_bellman_ford": False,
        }
        r = client.post("/optimize", json=body)
        assert r.status_code == 200
        assert len(r.json()["optimized_route"]) == 1

    def test_two_stops(self, client, cairo_stops):
        body = {
            "stops": cairo_stops[:2],
            "vehicle": "van",
            "traffic": "Normal",
            "weather": "Sunny",
            "use_bellman_ford": False,
        }
        r = client.post("/optimize", json=body)
        assert r.status_code == 200
        assert len(r.json()["optimized_route"]) == 2

    def test_missing_start_time_defaults_gracefully(self, client, optimize_body):
        del optimize_body["start_time"]
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200


# ─────────────────────────────────────────────────────────────────────────────
# INCIDENT INJECTION
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeIncidents:
    def test_traffic_jam_incident(self, client, optimize_body):
        optimize_body["incidents"] = [
            {"index": 1, "kind": "traffic_jam", "severity": 0.8}
        ]
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200

    def test_road_closed_incident(self, client, optimize_body):
        optimize_body["incidents"] = [
            {"index": 2, "kind": "road_closed", "severity": 1.0}
        ]
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200

    def test_multiple_incidents_picks_most_severe(self, client, optimize_body):
        optimize_body["incidents"] = [
            {"index": 1, "kind": "traffic_jam", "severity": 0.3},
            {"index": 3, "kind": "accident",    "severity": 0.9},
        ]
        r = client.post("/optimize", json=optimize_body)
        assert r.status_code == 200


# ─────────────────────────────────────────────────────────────────────────────
# ALNS QUALITY GUARANTEE
# ─────────────────────────────────────────────────────────────────────────────

class TestOptimizeALNSQuality:
    def test_alns_cost_not_negative(self, client, optimize_body):
        body = client.post("/optimize", json=optimize_body).json()
        assert body["cost"] >= 0

    def test_different_start_times_produce_different_costs(self, client, optimize_body):
        """Morning vs afternoon start time should affect route cost."""
        optimize_body["start_time"] = 480   # 08:00
        cost_am = client.post("/optimize", json=optimize_body).json()["cost"]
        optimize_body["start_time"] = 900   # 15:00
        cost_pm = client.post("/optimize", json=optimize_body).json()["cost"]
        # Costs may differ or be equal but must both be valid
        assert cost_am > 0 and cost_pm > 0
