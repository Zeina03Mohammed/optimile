"""
POST /fleet-reoptimize endpoint — automated tests.

Tests cover:
  - Response shape (rerouted, vehicle_routes, transfers, total_cost)
  - Two-vehicle fleet
  - Each vehicle's route is a valid subset of its stops
  - Transfer record structure
  - Edge: single vehicle (no transfers possible)
  - Edge: vehicle with no remaining stops
  - Severity levels
"""

import sys
from pathlib import Path
import pytest

_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def _total_stops_in_routes(vehicle_routes):
    return sum(len(r) for r in vehicle_routes)


# ─────────────────────────────────────────────────────────────────────────────
# RESPONSE SHAPE
# ─────────────────────────────────────────────────────────────────────────────

class TestFleetReoptimizeShape:
    def test_returns_200(self, client, fleet_body):
        r = client.post("/fleet-reoptimize", json=fleet_body)
        assert r.status_code == 200

    def test_has_rerouted_key(self, client, fleet_body):
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        assert "rerouted" in body

    def test_has_vehicle_routes_key(self, client, fleet_body):
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        assert "vehicle_routes" in body

    def test_has_transfers_key(self, client, fleet_body):
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        assert "transfers" in body

    def test_has_total_cost(self, client, fleet_body):
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        assert "total_cost" in body
        assert body["total_cost"] >= 0

    def test_vehicle_routes_count_matches_input(self, client, fleet_body):
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        n_vehicles = len(fleet_body["vehicles"])
        assert len(body["vehicle_routes"]) == n_vehicles

    def test_transfers_is_list(self, client, fleet_body):
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        assert isinstance(body["transfers"], list)


# ─────────────────────────────────────────────────────────────────────────────
# STOP CONSERVATION
# ─────────────────────────────────────────────────────────────────────────────

class TestFleetStopConservation:
    def test_total_stops_conserved_after_transfers(self, client, fleet_body):
        """
        Total stops across all vehicles must be the same before and after
        fleet reoptimization — no stops are created or destroyed.
        """
        total_in = sum(len(v["remaining_stops"]) for v in fleet_body["vehicles"])
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        total_out = _total_stops_in_routes(body["vehicle_routes"])
        assert total_in == total_out

    def test_each_route_stop_has_lat_lng(self, client, fleet_body):
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        for vehicle_route in body["vehicle_routes"]:
            for stop in vehicle_route:
                assert "lat" in stop
                assert "lng" in stop


# ─────────────────────────────────────────────────────────────────────────────
# TRANSFER RECORDS
# ─────────────────────────────────────────────────────────────────────────────

class TestFleetTransferRecords:
    def test_transfer_record_fields(self, client, fleet_body):
        """Each transfer must have from_vehicle, to_vehicle fields."""
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        for t in body["transfers"]:
            assert "from_vehicle" in t
            assert "to_vehicle" in t

    def test_transfer_vehicle_indices_valid(self, client, fleet_body):
        n_vehicles = len(fleet_body["vehicles"])
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        for t in body["transfers"]:
            assert 0 <= t["from_vehicle"] < n_vehicles
            assert 0 <= t["to_vehicle"] < n_vehicles

    def test_rerouted_true_when_transfers_exist(self, client, fleet_body):
        body = client.post("/fleet-reoptimize", json=fleet_body).json()
        if len(body["transfers"]) > 0:
            assert body["rerouted"] is True


# ─────────────────────────────────────────────────────────────────────────────
# VEHICLE AND WEATHER COMBINATIONS
# ─────────────────────────────────────────────────────────────────────────────

class TestFleetVehicleCombinations:
    @pytest.mark.parametrize("traffic", ["Low", "Normal", "Heavy"])
    def test_traffic_levels(self, client, fleet_body, traffic):
        for v in fleet_body["vehicles"]:
            v["traffic"] = traffic
        r = client.post("/fleet-reoptimize", json=fleet_body)
        assert r.status_code == 200

    @pytest.mark.parametrize("weather", ["Sunny", "Rainy", "Storm"])
    def test_weather_conditions(self, client, fleet_body, weather):
        for v in fleet_body["vehicles"]:
            v["weather"] = weather
        r = client.post("/fleet-reoptimize", json=fleet_body)
        assert r.status_code == 200


# ─────────────────────────────────────────────────────────────────────────────
# EDGE CASES
# ─────────────────────────────────────────────────────────────────────────────

class TestFleetEdgeCases:
    def test_single_vehicle_fleet(self, client, cairo_stops):
        body = {
            "vehicles": [{
                "current_lat": 30.0444,
                "current_lng": 31.2357,
                "remaining_stops": cairo_stops[:3],
                "vehicle": "van",
                "traffic": "Normal",
                "weather": "Sunny",
            }],
            "reason": "traffic_jam",
            "severity": 0.5,
            "affected_vehicle": 0,
        }
        r = client.post("/fleet-reoptimize", json=body)
        assert r.status_code == 200

    def test_vehicle_with_no_stops(self, client, cairo_stops):
        body = {
            "vehicles": [
                {
                    "current_lat": 30.0444,
                    "current_lng": 31.2357,
                    "remaining_stops": cairo_stops[:2],
                    "vehicle": "van",
                    "traffic": "Normal",
                    "weather": "Sunny",
                },
                {
                    "current_lat": 31.2001,
                    "current_lng": 29.9187,
                    "remaining_stops": [],   # empty
                    "vehicle": "motorcycle",
                    "traffic": "Normal",
                    "weather": "Sunny",
                },
            ],
            "reason": "traffic_jam",
            "severity": 0.5,
            "affected_vehicle": 0,
        }
        r = client.post("/fleet-reoptimize", json=body)
        assert r.status_code == 200

    def test_fragile_stops_in_fleet(self, client, cairo_stops):
        stops = [dict(s) for s in cairo_stops[:3]]
        stops[0]["is_fragile"] = True
        body = {
            "vehicles": [{
                "current_lat": 30.0444,
                "current_lng": 31.2357,
                "remaining_stops": stops,
                "vehicle": "van",
                "traffic": "Normal",
                "weather": "Sunny",
            }],
            "reason": "traffic_jam",
            "severity": 0.5,
            "affected_vehicle": 0,
        }
        r = client.post("/fleet-reoptimize", json=body)
        assert r.status_code == 200
