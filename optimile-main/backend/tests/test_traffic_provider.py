"""
Unit tests for model/traffic_provider.py — OSM Overpass road hazard detection.

Tests cover:
  - _classify(): correct (kind, severity) for each OSM hazard tag
  - fetch_incidents_along_route(): with mocked HTTP (avoids live API calls)
  - Empty coord list returns []
  - Single coord (< 2 nodes) returns []
  - Hazard mapped to nearest downstream stop
  - Network/timeout errors handled gracefully
"""

import sys
from pathlib import Path
from unittest.mock import patch, MagicMock
import pytest

_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))

from model.traffic_provider import _classify, fetch_incidents_along_route


# ─────────────────────────────────────────────────────────────────────────────
# _classify()
# ─────────────────────────────────────────────────────────────────────────────

class TestClassify:
    def test_flood_prone(self):
        kind, severity = _classify({"flood_prone": "yes"})
        assert kind == "road_closed"
        assert severity == pytest.approx(0.85)

    def test_ford_highway(self):
        kind, severity = _classify({"highway": "ford"})
        assert kind == "road_closed"
        assert severity == pytest.approx(0.90)

    def test_ford_node(self):
        kind, severity = _classify({"ford": "yes"})
        assert kind == "road_closed"
        assert severity == pytest.approx(0.90)

    def test_tunnel(self):
        kind, severity = _classify({"tunnel": "yes"})
        assert kind == "traffic_jam"
        assert severity == pytest.approx(0.50)

    @pytest.mark.parametrize("surface,expected_kind,expected_sev", [
        ("mud",     "road_closed", 0.85),
        ("sand",    "traffic_jam", 0.70),
        ("gravel",  "traffic_jam", 0.45),
        ("dirt",    "traffic_jam", 0.55),
        ("ground",  "traffic_jam", 0.55),
        ("grass",   "traffic_jam", 0.50),
        ("unpaved", "traffic_jam", 0.55),
    ])
    def test_unpaved_surfaces(self, surface, expected_kind, expected_sev):
        kind, severity = _classify({"surface": surface})
        assert kind == expected_kind
        assert severity == pytest.approx(expected_sev)

    def test_unknown_tags_return_default(self):
        kind, severity = _classify({})
        assert kind == "traffic_jam"
        assert severity == pytest.approx(0.35)

    def test_severity_between_0_and_1(self):
        """All classified severities must be in [0, 1]."""
        for tags in [
            {"flood_prone": "yes"},
            {"highway": "ford"},
            {"tunnel": "yes"},
            {"surface": "mud"},
            {},
        ]:
            _, severity = _classify(tags)
            assert 0.0 <= severity <= 1.0


# ─────────────────────────────────────────────────────────────────────────────
# fetch_incidents_along_route() — edge cases (no mocking needed)
# ─────────────────────────────────────────────────────────────────────────────

class TestFetchIncidentsEdgeCases:
    def test_empty_coords_returns_empty_list(self):
        result = fetch_incidents_along_route([])
        assert result == []

    def test_single_coord_returns_empty_list(self):
        result = fetch_incidents_along_route([(30.0444, 31.2357)])
        assert result == []

    def test_returns_list_type(self):
        with patch("model.traffic_provider.requests.post") as mock_post:
            mock_post.side_effect = Exception("network error")
            result = fetch_incidents_along_route([(30.0, 31.0), (30.1, 31.1)])
        assert isinstance(result, list)


# ─────────────────────────────────────────────────────────────────────────────
# fetch_incidents_along_route() — mocked Overpass API
# ─────────────────────────────────────────────────────────────────────────────

class TestFetchIncidentsMocked:
    def _mock_overpass_response(self, elements):
        mock_resp = MagicMock()
        mock_resp.raise_for_status = MagicMock()
        mock_resp.json.return_value = {"elements": elements}
        return mock_resp

    def test_flood_prone_way_mapped_to_nearest_stop(self):
        coords = [
            (30.0444, 31.2357),   # start / vehicle position (index 0)
            (30.0626, 31.2497),   # stop 1
            (30.0131, 31.2089),   # stop 2
        ]
        elements = [{
            "type": "way",
            "center": {"lat": 30.0630, "lon": 31.2500},  # very close to stop 1
            "tags": {"flood_prone": "yes"},
        }]
        with patch("model.traffic_provider.requests.post") as mock_post:
            mock_post.return_value = self._mock_overpass_response(elements)
            result = fetch_incidents_along_route(coords)

        assert len(result) == 1
        assert result[0]["kind"] == "road_closed"
        assert result[0]["index"] == 1   # mapped to stop 1

    def test_tunnel_way_produces_traffic_jam(self):
        coords = [(30.0, 31.0), (30.1, 31.1), (30.2, 31.2)]
        elements = [{
            "type": "way",
            "center": {"lat": 30.1, "lon": 31.1},
            "tags": {"tunnel": "yes"},
        }]
        with patch("model.traffic_provider.requests.post") as mock_post:
            mock_post.return_value = self._mock_overpass_response(elements)
            result = fetch_incidents_along_route(coords)

        assert any(r["kind"] == "traffic_jam" for r in result)

    def test_node_ford_mapped_correctly(self):
        coords = [(30.0, 31.0), (30.05, 31.05), (30.1, 31.1)]
        elements = [{
            "type": "node",
            "lat": 30.05,
            "lon": 31.05,
            "tags": {"ford": "yes"},
        }]
        with patch("model.traffic_provider.requests.post") as mock_post:
            mock_post.return_value = self._mock_overpass_response(elements)
            result = fetch_incidents_along_route(coords)

        assert len(result) == 1
        assert result[0]["kind"] == "road_closed"

    def test_empty_overpass_elements_returns_empty_list(self):
        coords = [(30.0, 31.0), (30.1, 31.1)]
        with patch("model.traffic_provider.requests.post") as mock_post:
            mock_post.return_value = self._mock_overpass_response([])
            result = fetch_incidents_along_route(coords)
        assert result == []

    def test_api_error_returns_empty_list(self):
        coords = [(30.0, 31.0), (30.1, 31.1)]
        with patch("model.traffic_provider.requests.post") as mock_post:
            mock_post.side_effect = Exception("timeout")
            result = fetch_incidents_along_route(coords)
        assert result == []

    def test_http_error_returns_empty_list(self):
        coords = [(30.0, 31.0), (30.1, 31.1)]
        mock_resp = MagicMock()
        mock_resp.raise_for_status.side_effect = Exception("HTTP 500")
        with patch("model.traffic_provider.requests.post", return_value=mock_resp):
            result = fetch_incidents_along_route(coords)
        assert result == []

    def test_result_has_required_fields(self):
        coords = [(30.0, 31.0), (30.1, 31.1)]
        elements = [{
            "type": "node",
            "lat": 30.1,
            "lon": 31.1,
            "tags": {"flood_prone": "yes"},
        }]
        with patch("model.traffic_provider.requests.post") as mock_post:
            mock_post.return_value = self._mock_overpass_response(elements)
            result = fetch_incidents_along_route(coords)

        for r in result:
            assert "index" in r
            assert "kind" in r
            assert "severity" in r

    def test_index_never_zero(self):
        """Index 0 is the vehicle position — hazards must map to stop indices >= 1."""
        coords = [(30.0, 31.0), (30.1, 31.1), (30.2, 31.2)]
        elements = [{
            "type": "node",
            "lat": 30.0,    # very close to the vehicle (index 0)
            "lon": 31.0,
            "tags": {"tunnel": "yes"},
        }]
        with patch("model.traffic_provider.requests.post") as mock_post:
            mock_post.return_value = self._mock_overpass_response(elements)
            result = fetch_incidents_along_route(coords)

        for r in result:
            assert r["index"] != 0
