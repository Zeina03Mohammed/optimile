"""
Shared pytest fixtures for the Optimile backend test suite.

Run all tests from the optimile-main/ directory:
    pytest

Run a single file:
    pytest backend/tests/test_optimize_endpoint.py -v
"""

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

# Make optimile-main/ the root so every module import works correctly.
_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))

from backend.main import app  # noqa: E402  (import after sys.path insert)


# ─────────────────────────────────────────────────────────────────────────────
# HTTP CLIENT
# ─────────────────────────────────────────────────────────────────────────────

@pytest.fixture(scope="session")
def client():
    """Single FastAPI TestClient shared across the whole test session."""
    return TestClient(app)


# ─────────────────────────────────────────────────────────────────────────────
# REUSABLE STOP LISTS  (realistic Egyptian delivery coordinates)
# ─────────────────────────────────────────────────────────────────────────────

CAIRO_STOPS = [
    {"lat": 30.0444, "lng": 31.2357, "is_fragile": False, "title": "Tahrir Square"},
    {"lat": 30.0626, "lng": 31.2497, "is_fragile": True,  "title": "Heliopolis"},
    {"lat": 30.0131, "lng": 31.2089, "is_fragile": False, "title": "Maadi"},
    {"lat": 30.0561, "lng": 31.2394, "is_fragile": False, "title": "Zamalek"},
    {"lat": 30.0761, "lng": 31.2999, "is_fragile": False, "title": "Nasr City"},
]

ALEX_STOPS = [
    {"lat": 31.2001, "lng": 29.9187, "is_fragile": False, "title": "Stanley"},
    {"lat": 31.1960, "lng": 29.8950, "is_fragile": True,  "title": "Sidi Gaber"},
    {"lat": 31.2093, "lng": 29.9553, "is_fragile": False, "title": "Miami"},
]


@pytest.fixture
def cairo_stops():
    return [dict(s) for s in CAIRO_STOPS]


@pytest.fixture
def alex_stops():
    return [dict(s) for s in ALEX_STOPS]


# ─────────────────────────────────────────────────────────────────────────────
# PRE-BUILT REQUEST BODIES
# ─────────────────────────────────────────────────────────────────────────────

@pytest.fixture
def optimize_body(cairo_stops):
    return {
        "stops": cairo_stops,
        "vehicle": "van",
        "traffic": "Normal",
        "weather": "Sunny",
        "start_time": 480,          # 08:00
        "use_bellman_ford": False,
    }


@pytest.fixture
def reoptimize_body(cairo_stops):
    return {
        "current_lat": 30.0444,
        "current_lng": 31.2357,
        "remaining_stops": cairo_stops[1:],
        "vehicle": "van",
        "traffic": "Heavy",
        "weather": "Sunny",
        "reason": "traffic_jam",
        "severity": 0.7,
        "simulate": True,           # always reroute — no delay threshold check
        "use_bellman_ford": False,
    }


@pytest.fixture
def fleet_body(cairo_stops, alex_stops):
    return {
        "vehicles": [
            {
                "current_lat": 30.0444,
                "current_lng": 31.2357,
                "remaining_stops": cairo_stops[:3],
                "vehicle": "van",
                "traffic": "Normal",
                "weather": "Sunny",
            },
            {
                "current_lat": 31.2001,
                "current_lng": 29.9187,
                "remaining_stops": alex_stops,
                "vehicle": "motorcycle",
                "traffic": "Normal",
                "weather": "Sunny",
            },
        ],
        "reason": "traffic_jam",
        "severity": 0.5,
        "affected_vehicle": 0,
    }
