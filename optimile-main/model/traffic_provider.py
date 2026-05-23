from __future__ import annotations

"""
Live road hazard provider — OSM Overpass API (no API key required).

Mirrors the logic in flutter_application_1/lib/services/road_hazard_service.dart.
Detects physical road hazards (flood-prone roads, fords, tunnels, unpaved
surfaces) from OpenStreetMap data and maps them to the nearest downstream stop.
"""

import requests
from typing import List, Dict, Tuple


_OVERPASS_URL = "https://overpass-api.de/api/interpreter"
_TIMEOUT_S    = 10


def _bbox(coords: List[Tuple[float, float]], pad: float = 0.04):
    lats = [c[0] for c in coords]
    lngs = [c[1] for c in coords]
    return min(lats) - pad, min(lngs) - pad, max(lats) + pad, max(lngs) + pad


def _dist2(lat1, lng1, lat2, lng2) -> float:
    return (lat1 - lat2) ** 2 + (lng1 - lng2) ** 2


def fetch_incidents_along_route(coords: List[Tuple[float, float]]) -> List[Dict]:
    """
    Query OSM Overpass for road hazards inside the bounding box of the
    current route and map each hazard to the nearest downstream stop.

    Returns a list of incident dicts compatible with the backend Incident model:
        {"index": int, "kind": "traffic_jam"|"road_closed", "severity": float}
    """
    if len(coords) < 2:
        return []

    s, w, n, e = _bbox(coords)

    query = f"""
[out:json][timeout:9];
(
  way["flood_prone"="yes"]({s},{w},{n},{e});
  way["highway"="ford"]({s},{w},{n},{e});
  way["tunnel"="yes"]({s},{w},{n},{e});
  way["surface"~"^(unpaved|dirt|gravel|mud|sand|ground|grass)$"]({s},{w},{n},{e});
  node["ford"="yes"]({s},{w},{n},{e});
);
out center tags;
"""

    try:
        resp = requests.post(
            _OVERPASS_URL,
            data=query,
            headers={
                "Content-Type": "text/plain",
                "Accept": "*/*",
                "User-Agent": "optimile-backend/1.0",
            },
            timeout=_TIMEOUT_S,
        )
        resp.raise_for_status()
        elements = resp.json().get("elements", []) or []
    except Exception as exc:
        print(f"[TRAFFIC] OSM Overpass error: {exc}")
        return []

    mapped: List[Dict] = []

    for el in elements:
        tags = el.get("tags") or {}

        # node has lat/lon directly; way exposes a center object
        if "lat" in el:
            lat_i, lng_i = float(el["lat"]), float(el["lon"])
        else:
            center = el.get("center") or {}
            if not center:
                continue
            lat_i, lng_i = float(center["lat"]), float(center["lon"])

        kind, severity = _classify(tags)

        # Map to nearest downstream stop (skip index 0 = vehicle position)
        best_idx, best_d2 = None, None
        for idx, (lat, lng) in enumerate(coords):
            if idx == 0:
                continue
            d2 = _dist2(lat, lng, lat_i, lng_i)
            if best_idx is None or d2 < best_d2:
                best_idx, best_d2 = idx, d2

        if best_idx is None:
            continue

        existing = next((m for m in mapped if m["index"] == best_idx), None)
        if existing is None:
            mapped.append({"index": int(best_idx), "kind": kind, "severity": float(severity)})
        elif severity > existing["severity"] or (
            severity == existing["severity"] and kind == "road_closed"
        ):
            existing["kind"] = kind
            existing["severity"] = float(severity)

    if mapped:
        print(f"[TRAFFIC] OSM hazards mapped={mapped}")

    return mapped


def _classify(tags: dict) -> Tuple[str, float]:
    """Map OSM tags to (incident_kind, severity 0..1)."""
    if tags.get("flood_prone") == "yes":
        return "road_closed", 0.85
    if tags.get("highway") == "ford" or tags.get("ford") == "yes":
        return "road_closed", 0.90
    if tags.get("tunnel") == "yes":
        return "traffic_jam", 0.50

    surface_map = {
        "mud":     ("road_closed", 0.85),
        "sand":    ("traffic_jam", 0.70),
        "gravel":  ("traffic_jam", 0.45),
        "dirt":    ("traffic_jam", 0.55),
        "ground":  ("traffic_jam", 0.55),
        "grass":   ("traffic_jam", 0.50),
        "unpaved": ("traffic_jam", 0.55),
    }
    surface = tags.get("surface", "")
    if surface in surface_map:
        return surface_map[surface]

    return "traffic_jam", 0.35
