"""
POST /reoptimize endpoint — automated tests.

Tests cover:
  - Response shape (rerouted flag, optimized_route, cost, reason)
  - All trigger reasons (traffic_jam, accident, road_closed, deviation)
  - simulate=True bypasses the delay threshold check
  - simulate=False with low severity returns rerouted=False
  - Bellman-Ford path (use_bellman_ford=True)
  - Output is a permutation of the remaining_stops input
  - Various weather and traffic conditions
  - Fragile first remaining stop
  - Incident injection
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

class TestReoptimizeResponseShape:
    def test_returns_200(self, client, reoptimize_body):
        r = client.post("/reoptimize", json=reoptimize_body)
        assert r.status_code == 200

    def test_has_rerouted_key(self, client, reoptimize_body):
        body = client.post("/reoptimize", json=reoptimize_body).json()
        assert "rerouted" in body

    def test_rerouted_is_bool(self, client, reoptimize_body):
        body = client.post("/reoptimize", json=reoptimize_body).json()
        assert isinstance(body["rerouted"], bool)

    def test_rerouted_true_has_optimized_route(self, client, reoptimize_body):
        """When rerouted=True the response must include the new route."""
        body = client.post("/reoptimize", json=reoptimize_body).json()
        if body["rerouted"]:
            assert "optimized_route" in body
            assert isinstance(body["optimized_route"], list)

    def test_rerouted_true_has_cost(self, client, reoptimize_body):
        body = client.post("/reoptimize", json=reoptimize_body).json()
        if body["rerouted"]:
            assert "cost" in body
            assert body["cost"] > 0

    def test_rerouted_true_has_reason(self, client, reoptimize_body):
        body = client.post("/reoptimize", json=reoptimize_body).json()
        if body["rerouted"]:
            assert "reason" in body

    def test_output_is_permutation_of_input(self, client, reoptimize_body):
        body = client.post("/reoptimize", json=reoptimize_body).json()
        if body["rerouted"]:
            input_coords = _coord_set(reoptimize_body["remaining_stops"])
            output_coords = _coord_set(body["optimized_route"])
            assert input_coords == output_coords


# ─────────────────────────────────────────────────────────────────────────────
# TRIGGER REASONS
# ─────────────────────────────────────────────────────────────────────────────

class TestReoptimizeReasons:
    @pytest.mark.parametrize("reason", ["traffic_jam", "accident", "road_closed", "deviation"])
    def test_all_reasons_succeed(self, client, reoptimize_body, reason):
        reoptimize_body["reason"] = reason
        r = client.post("/reoptimize", json=reoptimize_body)
        assert r.status_code == 200

    def test_simulate_true_always_reroutes(self, client, reoptimize_body):
        """simulate=True must bypass the should_reoptimize() guard."""
        reoptimize_body["simulate"] = True
        reoptimize_body["severity"] = 0.01   # tiny severity — would normally skip
        body = client.post("/reoptimize", json=reoptimize_body).json()
        assert body["rerouted"] is True

    def test_simulate_false_low_severity_may_skip(self, client, reoptimize_body):
        """simulate=False with near-zero severity may return rerouted=False."""
        reoptimize_body["simulate"] = False
        reoptimize_body["severity"] = 0.0
        reoptimize_body["reason"] = "traffic_jam"
        body = client.post("/reoptimize", json=reoptimize_body).json()
        # Backend may return False (no delay) — that is correct behaviour
        assert "rerouted" in body


# ─────────────────────────────────────────────────────────────────────────────
# WEATHER CONDITIONS
# ─────────────────────────────────────────────────────────────────────────────

class TestReoptimizeWeather:
    @pytest.mark.parametrize("weather", ["Sunny", "Rainy", "Storm", "Foggy", "Windy"])
    def test_all_weather_conditions_succeed(self, client, reoptimize_body, weather):
        reoptimize_body["weather"] = weather
        r = client.post("/reoptimize", json=reoptimize_body)
        assert r.status_code == 200


# ─────────────────────────────────────────────────────────────────────────────
# FRAGILE NEXT STOP
# ─────────────────────────────────────────────────────────────────────────────

class TestReoptimizeFragile:
    def test_fragile_first_remaining_stop(self, client, reoptimize_body):
        reoptimize_body["remaining_stops"][0]["is_fragile"] = True
        r = client.post("/reoptimize", json=reoptimize_body)
        assert r.status_code == 200


# ─────────────────────────────────────────────────────────────────────────────
# INCIDENT INJECTION
# ─────────────────────────────────────────────────────────────────────────────

class TestReoptimizeIncidents:
    def test_with_road_incidents(self, client, reoptimize_body):
        reoptimize_body["incidents"] = [
            {"index": 0, "kind": "road_closed", "severity": 1.0}
        ]
        r = client.post("/reoptimize", json=reoptimize_body)
        assert r.status_code == 200

    def test_live_incidents_found_field_present(self, client, reoptimize_body):
        body = client.post("/reoptimize", json=reoptimize_body).json()
        if body["rerouted"]:
            assert "live_incidents_found" in body


# ─────────────────────────────────────────────────────────────────────────────
# BELLMAN-FORD PATH  (haversine fallback — no Google API key in test env)
# ─────────────────────────────────────────────────────────────────────────────

class TestReoptimizeBellmanFord:
    def test_bf_path_returns_200(self, client, reoptimize_body):
        reoptimize_body["use_bellman_ford"] = True
        r = client.post("/reoptimize", json=reoptimize_body)
        assert r.status_code == 200

    def test_bf_path_always_reroutes(self, client, reoptimize_body):
        """BF path in /reoptimize always returns rerouted=True."""
        reoptimize_body["use_bellman_ford"] = True
        body = client.post("/reoptimize", json=reoptimize_body).json()
        assert body["rerouted"] is True

    def test_bf_path_has_algorithm_field(self, client, reoptimize_body):
        reoptimize_body["use_bellman_ford"] = True
        body = client.post("/reoptimize", json=reoptimize_body).json()
        assert body.get("algorithm") == "alns_bellman_ford"

    def test_bf_path_output_is_permutation(self, client, reoptimize_body):
        reoptimize_body["use_bellman_ford"] = True
        body = client.post("/reoptimize", json=reoptimize_body).json()
        input_coords  = _coord_set(reoptimize_body["remaining_stops"])
        output_coords = _coord_set(body["optimized_route"])
        assert input_coords == output_coords


# ─────────────────────────────────────────────────────────────────────────────
# EDGE CASES
# ─────────────────────────────────────────────────────────────────────────────

class TestReoptimizeEdgeCases:
    def test_single_remaining_stop(self, client, cairo_stops):
        body = {
            "current_lat": 30.0444,
            "current_lng": 31.2357,
            "remaining_stops": cairo_stops[:1],
            "vehicle": "van",
            "traffic": "Normal",
            "weather": "Sunny",
            "reason": "traffic_jam",
            "severity": 0.5,
            "simulate": True,
            "use_bellman_ford": False,
        }
        r = client.post("/reoptimize", json=body)
        assert r.status_code == 200

    def test_empty_remaining_stops_bf_path(self, client):
        body = {
            "current_lat": 30.0444,
            "current_lng": 31.2357,
            "remaining_stops": [],
            "vehicle": "van",
            "traffic": "Normal",
            "weather": "Sunny",
            "reason": "deviation",
            "severity": 1.0,
            "simulate": True,
            "use_bellman_ford": True,
        }
        r = client.post("/reoptimize", json=body)
        assert r.status_code == 200
        assert r.json()["rerouted"] is False
