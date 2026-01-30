from __future__ import annotations

"""
Live traffic / incident provider integration.

This module is intentionally small and replaceable. At runtime it should
call a REAL traffic / incident API (e.g. TomTom, HERE, Google Routes).

We keep the interface simple:

    fetch_incidents_along_route(coords) -> List[dict]

Where each returned dict is compatible with the backend Incident model:
    {
        "index": int,          # stop index in the coords list (>= 1)
        "kind": "traffic_jam" | "accident" | "road_closed",
        "severity": float,     # 0..1+
    }
"""

import os
from typing import List, Dict, Tuple

import requests


def _bbox_for_coords(coords: List[Tuple[float, float]]) -> Tuple[float, float, float, float]:
    lats = [c[0] for c in coords]
    lngs = [c[1] for c in coords]
    return min(lats), min(lngs), max(lats), max(lngs)


def fetch_incidents_along_route(coords: List[Tuple[float, float]]) -> List[Dict]:
    """
    Query a real traffic incident API for a bounding box that covers
    the current route and map the response to our Incident objects.

    This implementation uses the TomTom Traffic Incidents API as an
    example. You must set the TOMTOM_API_KEY environment variable
    in your runtime for this to be active.
    """
    api_key = os.getenv("TOMTOM_API_KEY")
    if not api_key or len(coords) < 2:
        # No live key configured -> no automatic incidents
        return []

    south, west, north, east = _bbox_for_coords(coords)

    # See: https://developer.tomtom.com/traffic-api/documentation/traffic-incidents
    url = "https://api.tomtom.com/traffic/services/5/incidentDetails"
    params = {
        "bbox": f"{south},{west},{north},{east}",
        "key": api_key,
        "fields": "id,geometry,properties{iconCategory,magnitudeOfDelay,incidentCategory}",
        "language": "en-GB",
    }

    try:
        resp = requests.get(url, params=params, timeout=2.5)
        resp.raise_for_status()
    except Exception as exc:
        # Never break optimization because the traffic API failed
        print(f"[TRAFFIC] incident API error: {exc}")
        return []

    data = resp.json()
    incidents_raw = data.get("incidents", []) or []

    mapped: List[Dict] = []

    for inc in incidents_raw:
        props = inc.get("properties", {}) or {}
        mag = float(props.get("magnitudeOfDelay", 0.0) or 0.0)
        cat = str(props.get("incidentCategory", "") or "").lower()

        # Map provider-specific categories to our internal ones
        if "accident" in cat:
            kind = "accident"
        elif "road" in cat and "closed" in cat:
            kind = "road_closed"
        else:
            kind = "traffic_jam"

        # crude nearest-stop mapping: pick the closest stop index >= 1
        geom = inc.get("geometry", {}) or {}
        points = geom.get("coordinates") or []
        if not points:
            continue

        # TomTom coordinates are [lng, lat]; pick first point
        first_point = points[0]
        if not isinstance(first_point, (list, tuple)) or len(first_point) < 2:
            continue
        lng_i, lat_i = float(first_point[0]), float(first_point[1])

        best_idx = None
        best_dist2 = None
        for idx, (lat, lng) in enumerate(coords):
            if idx == 0:
                # idx 0 is vehicle position; we only penalize downstream stops
                continue
            d2 = (lat - lat_i) ** 2 + (lng - lng_i) ** 2
            if best_idx is None or d2 < best_dist2:
                best_idx = idx
                best_dist2 = d2

        if best_idx is None:
            continue

        severity = max(0.1, min(1.0, mag / 5.0))
        mapped.append(
            {
                "index": int(best_idx),
                "kind": kind,
                "severity": float(severity),
            }
        )

    if mapped:
        print(f"[TRAFFIC] live incidents mapped={mapped}")

    return mapped

