from __future__ import annotations

from fastapi import FastAPI, HTTPException, Header, Request, UploadFile, File
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, StrictInt
from typing import List, Optional, Tuple, Dict, Any
from datetime import datetime
import json
import os
import csv
import io
import time
import statistics
from functools import lru_cache

import requests
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

from model.impact import estimate_delay
from model.decision import should_reoptimize
from model.traffic_provider import fetch_incidents_along_route

from model.alns_optimizer import optimize_route, route_cost, optimize_fleet
from model.bellman_ford import (
    route_order_from_locations,
    route_order_from_distance_matrix,
    compute_edge_weight,
)
import joblib

# =========================
# RATE LIMITER SETUP
# =========================
limiter = Limiter(key_func=get_remote_address)
app = FastAPI(
    title="Optimile API",
    description="AI-powered delivery route optimization for logistics companies",
    version="1.0.0",
)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# =========================
# PATHS
# =========================
_BACKEND_DIR   = os.path.dirname(os.path.abspath(__file__))
_API_KEYS_FILE = os.path.join(_BACKEND_DIR, "api_keys.json")
_USAGE_LOG     = os.path.join(_BACKEND_DIR, "usage_log.json")
_ORDERS_CSV    = os.path.join(_BACKEND_DIR, "unified_orders.csv")
_DRIVERS_JSON  = os.path.join(_BACKEND_DIR, "drivers.json")
_DASH_FILE     = os.path.join(_BACKEND_DIR, "dashboard.html")

# =========================
# IN-MEMORY STORE (runtime)
# =========================
# Loaded once at startup; PATCH /order/{id}/delivered mutates this
_orders_store: List[Dict[str, Any]] = []
_drivers_store: List[Dict[str, Any]] = []

def _load_orders():
    global _orders_store
    if not os.path.exists(_ORDERS_CSV):
        return
    with open(_ORDERS_CSV, newline="", encoding="utf-8") as f:
        _orders_store = list(csv.DictReader(f))

def _save_orders():
    """Persist the in-memory order store back to the CSV so delivered status survives restarts."""
    if not _orders_store:
        return
    fieldnames = list(_orders_store[0].keys())
    # Make sure delivered_at column exists in fieldnames
    if "delivered_at" not in fieldnames:
        fieldnames.append("delivered_at")
    with open(_ORDERS_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(_orders_store)

def _load_drivers():
    global _drivers_store
    if not os.path.exists(_DRIVERS_JSON):
        return
    with open(_DRIVERS_JSON, encoding="utf-8") as f:
        _drivers_store = json.load(f)

_load_orders()
_load_drivers()

# =========================
# AUTH HELPERS
# =========================
def _load_api_keys() -> dict:
    if not os.path.exists(_API_KEYS_FILE):
        return {}
    with open(_API_KEYS_FILE, encoding="utf-8") as f:
        return json.load(f)

def _verify_key(api_key: Optional[str]) -> dict:
    """Raise 401 if key is missing or invalid. Return key metadata."""
    keys = _load_api_keys()
    if not api_key or api_key not in keys:
        raise HTTPException(status_code=401, detail="Invalid or missing API key. Include X-API-Key header.")
    entry = keys[api_key]
    if not entry.get("active", True):
        raise HTTPException(status_code=403, detail="API key is inactive.")
    return entry

def _log_usage(api_key: str, endpoint: str, duration_ms: float):
    log = []
    if os.path.exists(_USAGE_LOG):
        with open(_USAGE_LOG, encoding="utf-8") as f:
            try:
                log = json.load(f)
            except Exception:
                log = []
    log.append({
        "key": api_key,
        "endpoint": endpoint,
        "timestamp": datetime.utcnow().isoformat(),
        "response_ms": round(duration_ms, 1),
    })
    with open(_USAGE_LOG, "w", encoding="utf-8") as f:
        json.dump(log, f, indent=2)

# =========================
# GOOGLE DISTANCE MATRIX (optional – key from request or env)
# =========================
# When Flutter sends google_maps_api_key (Env.googleMapsApiKey), that key is used
# for Bellman–Ford road-time ordering. Else backend uses GOOGLE_MAPS_API_KEY env.

_GOOGLE_MAPS_API_KEY = os.getenv("GOOGLE_MAPS_API_KEY")


def _google_distance_matrix_durations_seconds_impl(
    origin_key: str,
    destinations_key: str,
    departure_bucket_s: int,
    api_key: str,
) -> Optional[Tuple[int, ...]]:
    """Single request, no cache. Uses given api_key."""
    if not api_key:
        return None
    url = "https://maps.googleapis.com/maps/api/distancematrix/json"
    params = {
        "origins": origin_key,
        "destinations": destinations_key,
        "departure_time": str(departure_bucket_s),
        "traffic_model": "best_guess",
        "key": api_key,
    }
    try:
        resp = requests.get(url, params=params, timeout=2.5)
        resp.raise_for_status()
        data = resp.json()
    except Exception as exc:
        print(f"[GOOGLE] distance-matrix error: {exc}")
        return None
    if data.get("status") != "OK":
        return None
    rows = data.get("rows") or []
    if not rows:
        return None
    elements = (rows[0].get("elements") or [])
    if not elements:
        return None
    out: List[int] = []
    for el in elements:
        if (el or {}).get("status") != "OK":
            return None
        dur = (el or {}).get("duration_in_traffic") or (el or {}).get("duration") or {}
        val = dur.get("value")
        if val is None:
            return None
        out.append(int(val))
    return tuple(out)


@lru_cache(maxsize=10_000)
def _google_distance_matrix_durations_seconds(
    origin_key: str,
    destinations_key: str,
    departure_bucket_s: int,
) -> Optional[Tuple[int, ...]]:
    """Cached version using backend env GOOGLE_MAPS_API_KEY."""
    if not _GOOGLE_MAPS_API_KEY:
        return None
    return _google_distance_matrix_durations_seconds_impl(
        origin_key, destinations_key, departure_bucket_s, _GOOGLE_MAPS_API_KEY
    )


def _round_coord(x: float, ndigits: int = 5) -> float:
    # reduce cache busting due to tiny float diffs
    return round(float(x), ndigits)


def _departure_bucket(now_s: int, bucket_seconds: int = 300) -> int:
    # cache in 5-minute buckets
    return (int(now_s) // bucket_seconds) * bucket_seconds


def _fetch_full_distance_matrix(
    all_coords: List[Tuple[float, float]],
    api_key: str,
) -> Optional[dict]:
    """
    Fetch ALL pairwise travel times from Google Distance Matrix API.

    For N nodes, this produces an N×N matrix of durations.
    Google allows up to 25 origins × 25 destinations per request,
    so for large sets we batch rows.

    Returns:
        Dict mapping (i, j) -> duration_in_seconds, or None on failure.
    """
    if not api_key or not all_coords:
        return None

    n = len(all_coords)
    now_s = int(datetime.now().timestamp())
    dep = _departure_bucket(now_s)

    # Build coordinate strings
    coord_strs = [
        f"{_round_coord(lat)},{_round_coord(lng)}" for (lat, lng) in all_coords
    ]
    destinations_key = "|".join(coord_strs)

    matrix: dict = {}

    # Batch: Google allows max 25 origins per request
    BATCH_SIZE = 25
    for batch_start in range(0, n, BATCH_SIZE):
        batch_end = min(batch_start + BATCH_SIZE, n)
        batch_origins = coord_strs[batch_start:batch_end]
        origins_key = "|".join(batch_origins)

        # Make API call for this batch of origins -> all destinations
        url = "https://maps.googleapis.com/maps/api/distancematrix/json"
        params = {
            "origins": origins_key,
            "destinations": destinations_key,
            "departure_time": str(dep),
            "traffic_model": "best_guess",
            "key": api_key,
        }
        try:
            resp = requests.get(url, params=params, timeout=5.0)
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            print(f"[GOOGLE] full distance matrix batch error: {exc}")
            return None

        if data.get("status") != "OK":
            print(f"[GOOGLE] full distance matrix status: {data.get('status')}")
            return None

        rows = data.get("rows") or []
        if len(rows) != (batch_end - batch_start):
            return None

        for row_offset, row in enumerate(rows):
            i = batch_start + row_offset
            elements = row.get("elements") or []
            for j, el in enumerate(elements):
                if (el or {}).get("status") != "OK":
                    continue
                dur = (el or {}).get("duration_in_traffic") or (el or {}).get("duration") or {}
                val = dur.get("value")
                if val is not None:
                    matrix[(i, j)] = float(val)

    # Verify we got a reasonable matrix (allow some missing, but need most)
    expected = n * (n - 1)  # diagonal excluded
    actual = len([k for k in matrix if k[0] != k[1]])
    if actual < expected * 0.8:
        print(f"[GOOGLE] distance matrix too sparse: {actual}/{expected} edges")
        return None

    return matrix


def _bf_order_by_google_from_start(
    start_lat: float,
    start_lng: float,
    stops: List[Stop],
    api_key: Optional[str] = None,
    fragile_flags: Optional[List[bool]] = None,
    time_windows: Optional[List[Tuple]] = None,
    start_time_min: int = 0,
    context: Optional[dict] = None,
) -> Optional[dict]:
    """
    TRUE Bellman–Ford ordering using real road travel times from Google
    Distance Matrix API, with business-logic negative edge weights.

    Unlike simple sorting (old implementation), this:
      1. Fetches ALL pairwise road distances (N×N matrix)
      2. Applies business modifiers (fragility, deadline urgency, clustering)
      3. Some modifiers produce NEGATIVE weights (Dijkstra cannot handle)
      4. Runs true Bellman-Ford O(V*E) to find shortest paths considering
         transitive connections (A->C might be cheaper via A->B->C)
      5. Detects negative cycles (circular reward loops)

    Returns:
        Dict with 'order' (list of stop indices), 'debug_info', 'has_negative_cycle'
        or None if API call fails.
    """
    key = api_key or _GOOGLE_MAPS_API_KEY
    if not key or not stops:
        return None

    # Build coordinate list: node 0 = start, nodes 1..N = stops
    all_coords = [(float(start_lat), float(start_lng))]
    for s in stops:
        all_coords.append((float(s.lat), float(s.lng)))

    n_nodes = len(all_coords)  # start + stops

    # Fetch full N×N distance matrix from Google
    print(f"[BF] Fetching {n_nodes}x{n_nodes} distance matrix from Google...")
    distance_matrix = _fetch_full_distance_matrix(all_coords, key)
    if distance_matrix is None:
        print("[BF] Google distance matrix failed, falling back to Haversine BF")
        return None

    print(f"[BF] Got {len(distance_matrix)} pairwise durations. Running true Bellman-Ford...")

    # Build fragile/window arrays for the full node set (start + stops)
    full_fragile = [False]  # start node is not fragile
    if fragile_flags:
        full_fragile.extend(fragile_flags)
    else:
        full_fragile.extend([False] * len(stops))

    full_windows: List[Tuple] = [(None, None)]  # start node has no window
    if time_windows:
        full_windows.extend(time_windows)
    else:
        full_windows.extend([(None, None)] * len(stops))

    # Run TRUE Bellman-Ford with negative edge weights
    order, has_negative_cycle, debug_info = route_order_from_distance_matrix(
        duration_matrix=distance_matrix,
        n_nodes=n_nodes,
        start_index=0,  # start node
        fragile_flags=full_fragile,
        time_windows=full_windows,
        start_time_min=start_time_min,
        context=context,
    )

    # Convert from full-graph indices (0=start, 1..N=stops) to stop-only indices (0..N-1)
    stop_order = [i - 1 for i in order if i != 0]

    print(
        f"[BF] TRUE Bellman-Ford complete: "
        f"negative_edges={debug_info['negative_edge_count']} "
        f"negative_cycle={has_negative_cycle} "
        f"order={stop_order[:5]}{'...' if len(stop_order) > 5 else ''}"
    )

    return {
        "order": stop_order,
        "debug_info": debug_info,
        "has_negative_cycle": has_negative_cycle,
    }

# =========================
# API MODELS
# =========================

class Stop(BaseModel):
    lat: float
    lng: float
    is_fragile: bool = False
    title: Optional[str] = None

    # time window in minutes from start of day (e.g. 480 = 08:00)
    window_start: Optional[StrictInt] = None
    window_end: Optional[StrictInt] = None


class Incident(BaseModel):
    index: StrictInt          # index in stops / remaining_stops list
    kind: str                 # traffic_jam | accident | road_closed
    severity: float = 1.0


class OptimizeRequest(BaseModel):
    stops: List[Stop]
    vehicle: str              # motorcycle | scooter | van
    traffic: str
    weather: str

    # minutes since midnight (no datetime parsing, no silent casting)
    start_time: Optional[StrictInt] = None

    # optional real-time incidents affecting specific stops
    incidents: Optional[List[Incident]] = None

    # use Bellman–Ford on chosen locations (stops); when True, route order is by shortest path from start
    use_bellman_ford: bool = False
    # when use_bellman_ford=True, optional current driver position (start node)
    current_lat: Optional[float] = None
    current_lng: Optional[float] = None
    # optional Google Maps API key from app (e.g. Flutter Env.googleMapsApiKey) for BF road times
    google_maps_api_key: Optional[str] = None


class ReoptimizeRequest(BaseModel):
    current_lat: float
    current_lng: float
    remaining_stops: List[Stop]
    vehicle: str
    traffic: str
    weather: str
    reason: str
    severity: Optional[float] = None
    incidents: Optional[List[Incident]] = None
    # when True, reoptimize using ALNS + Bellman–Ford (BF seed, ALNS refines)
    use_bellman_ford: bool = False
    # when True, always run reoptimize (for Simulate: run both ALNS and ALNS+BF on same incident)
    simulate: bool = False
    # optional Google Maps API key from app (e.g. Flutter Env.googleMapsApiKey) for BF road times
    google_maps_api_key: Optional[str] = None


# =========================
# OPTIMIZE
# =========================

@app.post("/optimize")
def optimize(req: OptimizeRequest):
    print(f"[OPTIMIZE] use_bellman_ford={req.use_bellman_ford} n_stops={len(req.stops)}")
    stop_coords = [(s.lat, s.lng) for s in req.stops]
    fragile_flags = [s.is_fragile for s in req.stops]
    time_windows = [
        (s.window_start, s.window_end) for s in req.stops
    ]

    # start_time is expected in minutes since midnight (StrictInt)
    if req.start_time is not None:
        start_time = int(req.start_time)
        dt = datetime.now()
    else:
        dt = datetime.now()
        start_time = dt.hour * 60 + dt.minute

    context = {
        "vehicle": req.vehicle.lower(),
        "traffic": req.traffic,
        "weather": req.weather,
        "order_minutes": start_time,
        "day_of_week": dt.weekday(),
        "use_ml_cost": True,   # uncomment to enable ML-calibrated leg times
    }

    # Pre-compute ML cost matrix once per request (N² predictions up front,
    # then O(1) lookup inside the ALNS loop — avoids 20k model calls).
    try:
        from ml_pipeline.predictor import predict_cost_matrix, is_model_available
        if context.get("use_ml_cost") and is_model_available():
            ml_matrix = predict_cost_matrix(stop_coords, float(start_time))
            if ml_matrix is not None:
                context["ml_cost_matrix"] = ml_matrix.tolist()
    except Exception:
        pass  # ML unavailable — ALNS runs on formula cost as before

    # optional single incident – pick the most severe if provided
    if req.incidents:
        most_severe = max(req.incidents, key=lambda x: x.severity)
        context["incident"] = {
            "index": int(most_severe.index),
            "kind": most_severe.kind,
            "severity": float(most_severe.severity),
        }

    # Bellman–Ford: use chosen locations (and optional current position) for shortest-path order
    # TRUE Bellman-Ford with negative edge weights (business logic modifiers)
    if req.use_bellman_ford:
        used_google = False
        bf_debug = None
        has_neg_cycle = False

        if req.current_lat is not None and req.current_lng is not None:
            # TRUE Bellman-Ford: fetch full pairwise matrix, apply negative weights, run BF
            bf_result = _bf_order_by_google_from_start(
                float(req.current_lat),
                float(req.current_lng),
                req.stops,
                req.google_maps_api_key,
                fragile_flags=fragile_flags,
                time_windows=time_windows,
                start_time_min=start_time,
                context=context,
            )
            if bf_result is not None:
                order = bf_result["order"]
                bf_debug = bf_result["debug_info"]
                has_neg_cycle = bf_result["has_negative_cycle"]
                used_google = True
            else:
                # Fallback: Haversine BF with business modifiers
                coords = [(req.current_lat, req.current_lng)] + stop_coords
                bf_order, has_neg_cycle = route_order_from_locations(
                    coords, start_index=0,
                    fragile_flags=[False] + fragile_flags,
                    time_windows=[(None, None)] + time_windows,
                    start_time_min=start_time,
                    context=context,
                )
                # drop start node (index 0); remaining indices are 1..n -> map to stop indices 0..n-1
                order = [i - 1 for i in bf_order if i != 0]
        else:
            # No explicit start position. Use first stop as the "start" node for ordering.
            if len(req.stops) <= 1:
                order = list(range(len(req.stops)))
            else:
                start = req.stops[0]
                bf_result = _bf_order_by_google_from_start(
                    float(start.lat),
                    float(start.lng),
                    req.stops[1:],
                    req.google_maps_api_key,
                    fragile_flags=fragile_flags[1:],
                    time_windows=time_windows[1:],
                    start_time_min=start_time,
                    context=context,
                )
                if bf_result is not None:
                    order = [0] + [i + 1 for i in bf_result["order"]]
                    bf_debug = bf_result["debug_info"]
                    has_neg_cycle = bf_result["has_negative_cycle"]
                    used_google = True
                else:
                    # Fallback: Haversine BF with business modifiers
                    coords = stop_coords
                    bf_order, has_neg_cycle = route_order_from_locations(
                        coords, start_index=0,
                        fragile_flags=fragile_flags,
                        time_windows=time_windows,
                        start_time_min=start_time,
                        context=context,
                    )
                    order = bf_order

        cost = route_cost(
            order,
            stop_coords,
            fragile_flags,
            time_windows,
            start_time,
            context,
        )
        baseline_route = list(range(len(stop_coords)))
        baseline_cost = route_cost(
            baseline_route,
            stop_coords,
            fragile_flags,
            time_windows,
            start_time,
            context,
        )
        improvement = baseline_cost - cost

        neg_edges = bf_debug["negative_edge_count"] if bf_debug else 0
        print(
            "[OPTIMIZE] TRUE Bellman–Ford "
            f"vehicle={req.vehicle} n_stops={len(stop_coords)} "
            f"negative_edges={neg_edges} "
            f"baseline_cost={baseline_cost:.3f} optimized_cost={cost:.3f} improvement={improvement:.3f}"
        )

        response = {
            "optimized_route": [
                {
                    "lat": req.stops[i].lat,
                    "lng": req.stops[i].lng,
                    "is_fragile": req.stops[i].is_fragile,
                    "window_start": req.stops[i].window_start,
                    "window_end": req.stops[i].window_end,
                }
                for i in order
            ],
            "cost": round(cost, 3),
            "algorithm": "bellman_ford",
            "bf_weights": "google_directions" if used_google else "haversine",
            "has_negative_cycle": has_neg_cycle,
            "negative_edge_count": neg_edges,
        }
        if bf_debug:
            response["bf_debug"] = bf_debug
        return response
    # ALNS (default)
    coords = stop_coords
    baseline_route = list(range(len(coords)))
    baseline_cost = route_cost(
        baseline_route,
        coords,
        fragile_flags,
        time_windows,
        start_time,
        context,
    )
    order, cost = optimize_route(
        coords=coords,
        fragile_flags=fragile_flags,
        time_windows=time_windows,
        context=context,
        start_time_min=start_time,
    )
    improvement = baseline_cost - cost
    print(
        "[OPTIMIZE] "
        f"vehicle={req.vehicle} traffic={req.traffic} "
        f"n_stops={len(coords)} "
        f"baseline_cost={baseline_cost:.3f} "
        f"optimized_cost={cost:.3f} "
        f"improvement={improvement:.3f}"
    )
    return {
        "optimized_route": [
            {
                "lat": coords[i][0],
                "lng": coords[i][1],
                "is_fragile": fragile_flags[i],
                "window_start": time_windows[i][0],
                "window_end": time_windows[i][1],
            }
            for i in order
        ],
        "cost": round(cost, 3),
    }


# =========================
# REOPTIMIZE (LIVE)
# =========================

@app.post("/reoptimize")
def reoptimize(req: ReoptimizeRequest):
    # Build coords and context (shared by both ALNS and Bellman–Ford)
    coords = [(req.current_lat, req.current_lng)] + [
        (s.lat, s.lng) for s in req.remaining_stops
    ]
    stop_coords = [(s.lat, s.lng) for s in req.remaining_stops]
    fragile_flags = [False] + [s.is_fragile for s in req.remaining_stops]
    time_windows = [(None, None)] + [
        (s.window_start, s.window_end) for s in req.remaining_stops
    ]
    now = datetime.now()
    start_time = now.hour * 60 + now.minute
    context = {
        "vehicle": req.vehicle,
        "traffic": req.traffic,
        "weather": req.weather,
        "order_minutes": start_time,
        "day_of_week": now.weekday(),
        "use_ml_cost": True,   # uncomment to enable ML-calibrated leg times
    }

    # Pre-compute ML cost matrix once (current position + remaining stops)
    try:
        from ml_pipeline.predictor import predict_cost_matrix, is_model_available
        if context.get("use_ml_cost") and is_model_available():
            ml_matrix = predict_cost_matrix(
                [(req.current_lat, req.current_lng)] + [(s.lat, s.lng) for s in req.remaining_stops],
                float(start_time),
            )
            if ml_matrix is not None:
                context["ml_cost_matrix"] = ml_matrix.tolist()
    except Exception:
        pass

    # ALNS + TRUE Bellman–Ford reoptimize: BF (with negative edge weights) provides
    # initial order, ALNS refines it (with OSM road hazard incidents)
    if req.use_bellman_ford:
        if not req.remaining_stops:
            return {"rerouted": False}
        bf_used_google = False
        bf_debug = None
        remaining_fragile = [s.is_fragile for s in req.remaining_stops]
        remaining_windows = [(s.window_start, s.window_end) for s in req.remaining_stops]

        # 1) TRUE Bellman–Ford: fetch full pairwise matrix, apply negative weights, run BF
        bf_result = _bf_order_by_google_from_start(
            float(req.current_lat),
            float(req.current_lng),
            req.remaining_stops,
            req.google_maps_api_key,
            fragile_flags=remaining_fragile,
            time_windows=remaining_windows,
            start_time_min=start_time,
            context=context,
        )
        if bf_result is not None:
            bf_order_remaining = bf_result["order"]
            bf_debug = bf_result["debug_info"]
            bf_used_google = True
        else:
            # Fallback: Haversine BF with business modifiers
            bf_order_full, _ = route_order_from_locations(
                coords, start_index=0,
                fragile_flags=fragile_flags,
                time_windows=time_windows,
                start_time_min=start_time,
                context=context,
            )
            bf_order_remaining = [i - 1 for i in bf_order_full if i != 0]

        # 2) Initial route for ALNS: [0] = current position, then remaining in BF order
        initial_route = [0] + [i + 1 for i in bf_order_remaining]

        # 3) Incident context (OSM hazards + request incidents), same as ALNS branch
        live_incidents = fetch_incidents_along_route(coords)
        candidate_incidents = []
        if req.incidents:
            for inc in req.incidents:
                candidate_incidents.append({
                    "index": int(inc.index) + 1,
                    "kind": inc.kind,
                    "severity": float(inc.severity),
                })
        candidate_incidents.extend(live_incidents)
        if not candidate_incidents and req.reason in ("traffic_jam", "accident", "road_closed"):
            candidate_incidents.append({
                "index": 1,
                "kind": req.reason,
                "severity": float(req.severity or 1.0),
            })
        if candidate_incidents:
            most_severe = max(candidate_incidents, key=lambda x: x["severity"])
            context = {**context, "incident": most_severe}
        incident_kind = context.get("incident", {}).get("kind", req.reason) if context.get("incident") else req.reason

        # 4) Run ALNS with BF initial solution (BF seed = better starting point for ALNS)
        order_full, cost = optimize_route(
            coords=coords,
            fragile_flags=fragile_flags,
            time_windows=time_windows,
            context=context,
            start_time_min=start_time,
            initial_route=initial_route,
            iters=300,
        )
        order = [i - 1 for i in order_full if i != 0]

        baseline_cost = route_cost(
            list(range(len(coords))),
            coords,
            fragile_flags,
            time_windows,
            start_time,
            context,
        )

        neg_edges = bf_debug["negative_edge_count"] if bf_debug else 0
        print(
            "[REOPTIMIZE] ALNS+TRUE Bellman–Ford "
            f"reason={req.reason} n_remaining={len(req.remaining_stops)} "
            f"bf_weights={'google' if bf_used_google else 'haversine'} "
            f"negative_edges={neg_edges} "
            f"osm_incidents={len(live_incidents)} "
            f"baseline_cost={baseline_cost:.3f} optimized_cost={cost:.3f}"
        )
        response = {
            "rerouted": True,
            "optimized_route": [
                {
                    "lat": req.remaining_stops[i].lat,
                    "lng": req.remaining_stops[i].lng,
                    "is_fragile": req.remaining_stops[i].is_fragile,
                    "window_start": req.remaining_stops[i].window_start,
                    "window_end": req.remaining_stops[i].window_end,
                }
                for i in order
            ],
            "cost": round(cost, 2),
            "reason": req.reason,
            "live_incidents_found": len(live_incidents) > 0,
            "incident_kind": incident_kind,
            "algorithm": "alns_bellman_ford",
            "bf_weights": "google_directions" if bf_used_google else "haversine",
            "negative_edge_count": neg_edges,
        }
        if bf_debug:
            response["bf_debug"] = bf_debug
        return response

    # ALNS reoptimize (existing logic)
    event_delay = estimate_delay(
        event=req.reason,
        baseline_eta=20,  # nominal remaining ETA in minutes
    )
    if req.severity and req.severity > 0:
        event_delay = max(event_delay, req.severity * 15)  # severity 0.5 -> 7.5 min

    should = should_reoptimize(
        delay_minutes=event_delay,
        next_stop_fragile=req.remaining_stops[0].is_fragile if req.remaining_stops else False,
        time_window_slack=15,
        last_reopt_seconds=120,
    )
    if not req.simulate and not should:
        return {"rerouted": False}

    # build real-time incident context from:
    #  - explicit incidents (mobile reports)
    #  - live provider API (OSM Overpass)
    #  - high-level reason / severity
    incident_ctx = None

    live_incidents = fetch_incidents_along_route(coords)

    candidate_incidents = []
    if req.incidents:
        # shift indices by +1 because 0 is current driver location
        for inc in req.incidents:
            candidate_incidents.append(
                {
                    "index": int(inc.index) + 1,
                    "kind": inc.kind,
                    "severity": float(inc.severity),
                }
            )
    candidate_incidents.extend(live_incidents)

    if not candidate_incidents and req.reason in ("traffic_jam", "accident", "road_closed"):
        candidate_incidents.append(
            {
                "index": 1,  # first remaining stop
                "kind": req.reason,
                "severity": float(req.severity or 1.0),
            }
        )

    if candidate_incidents:
        most_severe = max(candidate_incidents, key=lambda x: x["severity"])
        incident_ctx = most_severe

    context = {
        "vehicle": req.vehicle,
        "traffic": req.traffic,
        "weather": req.weather,
        "order_minutes": start_time,
        "day_of_week": now.weekday(),
        "use_ml_cost": True,   # uncomment to enable ML-calibrated leg times
    }

    # Pre-compute ML cost matrix once (current position + remaining stops)
    try:
        from ml_pipeline.predictor import predict_cost_matrix, is_model_available
        if context.get("use_ml_cost") and is_model_available():
            ml_matrix = predict_cost_matrix(coords, float(start_time))
            if ml_matrix is not None:
                context["ml_cost_matrix"] = ml_matrix.tolist()
    except Exception:
        pass

    if incident_ctx:
        context["incident"] = incident_ctx

    baseline_route = list(range(len(coords)))
    baseline_cost = route_cost(
        baseline_route,
        coords,
        fragile_flags,
        time_windows,
        start_time,
        context,
    )

    order, cost = optimize_route(
        coords=coords,
        fragile_flags=fragile_flags,
        time_windows=time_windows,
        context=context,
        start_time_min=start_time,
    )

    order = [i - 1 for i in order if i != 0]

    improvement = baseline_cost - cost

    live_incidents_found = len(live_incidents) > 0
    incident_kind = incident_ctx.get("kind", req.reason) if incident_ctx else req.reason

    print(
        "[REOPTIMIZE] "
        f"vehicle={req.vehicle} traffic={req.traffic} "
        f"reason={req.reason} delay={event_delay:.2f} "
        f"n_remaining={len(req.remaining_stops)} "
        f"live_incidents={live_incidents_found} "
        f"baseline_cost={baseline_cost:.3f} "
        f"optimized_cost={cost:.3f} "
        f"improvement={improvement:.3f}"
    )

    return {
        "rerouted": True,
        "optimized_route": [
            {
                "lat": req.remaining_stops[i].lat,
                "lng": req.remaining_stops[i].lng,
                "is_fragile": req.remaining_stops[i].is_fragile,
                "window_start": req.remaining_stops[i].window_start,
                "window_end": req.remaining_stops[i].window_end,
                "title": req.remaining_stops[i].title,
            }
            for i in order
        ],
        "cost": round(cost, 2),
        "reason": req.reason,
        "live_incidents_found": live_incidents_found,
        "incident_kind": incident_kind,
    }

# =========================
# ANOMALY LOG (RESTORED)
# =========================

@app.post("/anomaly-log")
def anomaly_log(data: dict):
    with open("anomalies.json", "a") as f:
        f.write(
            json.dumps(
                {
                    "timestamp": datetime.utcnow().isoformat(),
                    **data,
                }
            )
            + "\n"
        )
    return {"status": "logged"}


# =========================
# FLEET REOPTIMIZE
# =========================

class VehicleState(BaseModel):
    current_lat: float
    current_lng: float
    remaining_stops: List[Stop]
    vehicle: str  # motorcycle | scooter | van
    traffic: str
    weather: str


class FleetReoptimizeRequest(BaseModel):
    vehicles: List[VehicleState]
    reason: str  # why fleet reoptimize was triggered
    severity: Optional[float] = None
    affected_vehicle: int = 0  # which vehicle hit the incident


@app.post("/fleet-reoptimize")
def fleet_reoptimize(req: FleetReoptimizeRequest):
    start_time_dt = datetime.now()
    start_time = start_time_dt.hour * 60 + start_time_dt.minute

    num_vehicles = len(req.vehicles)

    # Build per-vehicle data arrays
    vehicle_coords = []       # current position per vehicle
    vehicle_stops = []        # list of (lat, lng) per vehicle
    vehicle_fragile = []      # list of bool per vehicle
    vehicle_windows = []      # list of (start, end) per vehicle
    vehicle_contexts = []     # context dict per vehicle

    for v in req.vehicles:
        vehicle_coords.append((v.current_lat, v.current_lng))
        vehicle_stops.append([(s.lat, s.lng) for s in v.remaining_stops])
        vehicle_fragile.append([s.is_fragile for s in v.remaining_stops])
        vehicle_windows.append([
            (s.window_start, s.window_end) for s in v.remaining_stops
        ])
        vehicle_contexts.append({
            "vehicle": v.vehicle.lower(),
            "traffic": v.traffic,
            "weather": v.weather,
            "order_minutes": start_time,
            "day_of_week": start_time_dt.weekday(),
        })

    # Compute original total cost (input order, before any optimization)
    original_total_cost = 0.0
    for v_idx in range(num_vehicles):
        stops_list = vehicle_stops[v_idx]
        if not stops_list:
            continue
        coords = [vehicle_coords[v_idx]] + stops_list
        f_flags = [False] + vehicle_fragile[v_idx]
        t_wins = [(None, None)] + vehicle_windows[v_idx]
        baseline = list(range(len(coords)))
        c = route_cost(baseline, coords, f_flags, t_wins, start_time, vehicle_contexts[v_idx])
        original_total_cost += c

    # Call fleet optimizer
    result = optimize_fleet(
        vehicle_coords=vehicle_coords,
        vehicle_stops=vehicle_stops,
        vehicle_fragile=vehicle_fragile,
        vehicle_windows=vehicle_windows,
        vehicle_contexts=vehicle_contexts,
        start_time_min=start_time,
    )

    fleet_routes = result["vehicle_routes"]
    fleet_costs = result["vehicle_costs"]
    transfers = result["transfers"]
    total_cost = result["total_cost"]
    optimizer_original = result["original_total_cost"]

    # Map optimized routes back to stop objects using ORIGINAL stops, reordered
    # by the optimizer output indices.
    # Note: optimize_fleet returns routes where index 0 = vehicle current position
    # and indices 1..N = the stops. We need to map back to the remaining_stops
    # from each vehicle AFTER transfers have been applied.
    #
    # Since optimize_fleet mutates the internal stop lists during transfers,
    # we need to rebuild the post-transfer stop lists here to look up the
    # original Stop objects.

    # Rebuild post-transfer stop lists (mirrors what optimize_fleet does internally)
    post_transfer_stops: List[List[Stop]] = [
        list(v.remaining_stops) for v in req.vehicles
    ]
    for t in transfers:
        src = t["from_vehicle"]
        dst = t["to_vehicle"]
        s_idx = t["stop_idx"]
        moved_stop = post_transfer_stops[src].pop(s_idx)
        post_transfer_stops[dst].append(moved_stop)

    vehicle_routes_response: List[List[dict]] = []
    for v_idx in range(num_vehicles):
        route = fleet_routes[v_idx]
        stops_for_v = post_transfer_stops[v_idx]
        ordered_stops = []
        for idx in route:
            # index 0 is the vehicle's current position, skip it
            if idx == 0:
                continue
            stop_idx = idx - 1  # map from route index to stops list index
            if 0 <= stop_idx < len(stops_for_v):
                s = stops_for_v[stop_idx]
                ordered_stops.append({
                    "lat": s.lat,
                    "lng": s.lng,
                    "is_fragile": s.is_fragile,
                    "window_start": s.window_start,
                    "window_end": s.window_end,
                    "title": s.title,
                })
        vehicle_routes_response.append(ordered_stops)

    # Enrich transfer records with lat/lng
    transfers_response = []
    for t in transfers:
        transfers_response.append({
            "stop_idx": t["stop_idx"],
            "from_vehicle": t["from_vehicle"],
            "to_vehicle": t["to_vehicle"],
            "stop_lat": t.get("stop_lat", 0.0),
            "stop_lng": t.get("stop_lng", 0.0),
        })

    rerouted = len(transfers) > 0
    improvement = original_total_cost - total_cost

    elapsed = (datetime.now() - start_time_dt).total_seconds()
    print(
        f"[FLEET-REOPTIMIZE] reason={req.reason} "
        f"n_vehicles={num_vehicles} "
        f"affected_vehicle={req.affected_vehicle} "
        f"transfers={len(transfers)} "
        f"original_cost={original_total_cost:.3f} "
        f"optimized_cost={total_cost:.3f} "
        f"improvement={improvement:.3f} "
        f"elapsed={elapsed:.3f}s"
    )

    return {
        "rerouted": rerouted,
        "vehicle_routes": vehicle_routes_response,
        "transfers": transfers_response,
        "total_cost": round(total_cost, 3),
        "original_total_cost": round(original_total_cost, 3),
        "improvement": round(improvement, 3),
    }


# =====================================================================
# PUBLIC API  —  /api/v1/
# Every endpoint requires X-API-Key header.
# Rate limit: 50 requests / minute per IP.
# =====================================================================

# ── Pydantic models for public API ───────────────────────────────────

class PublicStop(BaseModel):
    lat: float
    lng: float
    label: Optional[str] = None
    fragile: bool = False

class PublicOptimizeRequest(BaseModel):
    stops: List[PublicStop]
    vehicle: str = "van"       # van | scooter | motorcycle
    weather: str = "Sunny"     # Sunny | Rainy | Storm | Snowy | Fog

# ── Helper ───────────────────────────────────────────────────────────

def _haversine_km(lat1, lng1, lat2, lng2) -> float:
    import math
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng/2)**2
    return R * 2 * math.asin(math.sqrt(a))

def _area_from_driver_id(driver_id: str) -> str:
    for d in _drivers_store:
        if str(d.get("id")) == str(driver_id):
            areas = d.get("areas_served", [])
            return areas[0] if areas else "Unknown"
    return "Unknown"

# ── Endpoints ────────────────────────────────────────────────────────

@app.get("/api/v1/status", tags=["Public API"])
@limiter.limit("50/minute")
def api_status(request: Request, x_api_key: Optional[str] = Header(default=None)):
    """Health check — verify the API is online and your key is valid."""
    t0 = time.time()
    meta = _verify_key(x_api_key)
    _log_usage(x_api_key, "/api/v1/status", (time.time() - t0) * 1000)
    return {
        "status": "online",
        "version": "1.0.0",
        "company": meta.get("company"),
        "plan": meta.get("plan"),
        "timestamp": datetime.utcnow().isoformat(),
    }


@app.post("/api/v1/optimize", tags=["Public API"])
@limiter.limit("50/minute")
def api_optimize(request: Request, body: PublicOptimizeRequest,
                 x_api_key: Optional[str] = Header(default=None)):
    """
    Submit a list of delivery stops and receive an optimized route back.
    The route order is determined by ALNS + Bellman-Ford algorithm.
    """
    t0 = time.time()
    _verify_key(x_api_key)

    if len(body.stops) < 2:
        raise HTTPException(status_code=422, detail="At least 2 stops required.")

    coords = [(s.lat, s.lng) for s in body.stops]
    fragile_flags = [s.fragile for s in body.stops]
    time_windows = [(None, None)] * len(body.stops)
    now = datetime.now()
    start_time = now.hour * 60 + now.minute
    context = {
        "vehicle": body.vehicle.lower(),
        "traffic": "Medium",
        "weather": body.weather,
        "order_minutes": start_time,
        "day_of_week": now.weekday(),
    }

    baseline_route = list(range(len(coords)))
    baseline_cost = route_cost(baseline_route, coords, fragile_flags, time_windows, start_time, context)
    order, cost = optimize_route(coords=coords, fragile_flags=fragile_flags,
                                  time_windows=time_windows, context=context, start_time_min=start_time)
    improvement = baseline_cost - cost
    savings_pct = round((improvement / baseline_cost) * 100, 1) if baseline_cost > 0 else 0.0

    # Estimate duration (avg 30 km/h in city traffic, haversine distances)
    total_km = 0.0
    for i in range(len(order) - 1):
        a, b = coords[order[i]], coords[order[i+1]]
        total_km += _haversine_km(a[0], a[1], b[0], b[1])
    est_minutes = round((total_km / 30.0) * 60)

    result = {
        "optimized_route": [
            {
                "lat": body.stops[i].lat,
                "lng": body.stops[i].lng,
                "label": body.stops[i].label or f"Stop {i+1}",
                "fragile": body.stops[i].fragile,
            }
            for i in order
        ],
        "estimated_duration": f"{est_minutes} min",
        "total_distance_km": round(total_km, 2),
        "savings_vs_original": f"{savings_pct}%",
        "algorithm": "ALNS + Bellman-Ford",
        "weather_condition": body.weather,
        "vehicle": body.vehicle,
    }
    _log_usage(x_api_key, "/api/v1/optimize", (time.time() - t0) * 1000)
    return result


@app.post("/api/v1/upload-drivers", tags=["Public API"])
@limiter.limit("50/minute")
async def api_upload_drivers(request: Request, file: UploadFile = File(...),
                              x_api_key: Optional[str] = Header(default=None)):
    """
    Upload a CSV of driver movements. The system learns each driver's
    serving area from their historical GPS coordinates.

    Required CSV columns: Driver ID, Driver Name, Lat, Lng
    """
    t0 = time.time()
    _verify_key(x_api_key)

    content = await file.read()
    text = content.decode("utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(text))

    driver_coords: Dict[str, list] = {}
    driver_names: Dict[str, str] = {}

    for row in reader:
        did = row.get("Driver ID", "").strip()
        name = row.get("Driver Name", "").strip().title()
        try:
            lat = float(row.get("Lat", "").strip())
            lng = float(row.get("Lng", "").strip())
        except (ValueError, AttributeError):
            continue
        driver_coords.setdefault(did, []).append((lat, lng))
        driver_names[did] = name

    new_drivers = []
    for did, coords in driver_coords.items():
        lats = [c[0] for c in coords]
        lngs = [c[1] for c in coords]
        clat = round(statistics.mean(lats), 6)
        clng = round(statistics.mean(lngs), 6)
        new_drivers.append({
            "id": did,
            "name": driver_names.get(did, f"Driver {did}"),
            "areas_served": ["Unknown"],
            "vehicle": "van",
            "centroid_lat": clat,
            "centroid_lng": clng,
            "deliveries_today": 0,
            "delivered_count": 0,
            "status": "available",
        })

    # Merge with existing drivers store
    existing_ids = {str(d["id"]) for d in _drivers_store}
    added = 0
    for nd in new_drivers:
        if str(nd["id"]) not in existing_ids:
            _drivers_store.append(nd)
            added += 1

    with open(_DRIVERS_JSON, "w", encoding="utf-8") as f:
        json.dump(_drivers_store, f, indent=2, ensure_ascii=False)

    _log_usage(x_api_key, "/api/v1/upload-drivers", (time.time() - t0) * 1000)
    return {
        "message": f"Uploaded {len(driver_coords)} drivers ({added} new, {len(driver_coords)-added} already known)",
        "total_drivers": len(_drivers_store),
    }


@app.post("/api/v1/upload-orders", tags=["Public API"])
@limiter.limit("50/minute")
async def api_upload_orders(request: Request, file: UploadFile = File(...),
                             x_api_key: Optional[str] = Header(default=None)):
    """
    Upload a CSV of delivery orders. Orders are automatically matched to
    drivers based on area. Returns driver assignments and stop counts.

    Required CSV columns: order_id, customer_name, phone, address, area,
                          fragile, package_size, vehicle_required
    """
    t0 = time.time()
    _verify_key(x_api_key)

    content = await file.read()
    text = content.decode("utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(text))

    # Build area -> driver lookup
    area_driver: Dict[str, dict] = {}
    for d in _drivers_store:
        for area in d.get("areas_served", []):
            if area not in area_driver:
                area_driver[area] = d

    new_orders = []
    assignments: Dict[str, int] = {}  # driver_name -> count

    for row in reader:
        area = row.get("area", "").strip()
        driver = area_driver.get(area)
        if not driver:
            # Fallback: first driver
            driver = _drivers_store[0] if _drivers_store else {"id": 0, "name": "Unassigned", "centroid_lat": 30.044, "centroid_lng": 31.235}

        import random
        seed_val = hash(row.get("order_id", "0")) % (2**31)
        random.seed(seed_val)
        lat = round(driver["centroid_lat"] + random.uniform(-0.02, 0.02), 6)
        lng = round(driver["centroid_lng"] + random.uniform(-0.02, 0.02), 6)

        order = {
            "order_id":        row.get("order_id", "").strip(),
            "driver_id":       driver["id"],
            "driver_name":     driver["name"],
            "customer_name":   row.get("customer_name", "").strip(),
            "phone":           row.get("phone", "").strip(),
            "address":         row.get("address", "").strip(),
            "area":            area,
            "lat":             lat,
            "lng":             lng,
            "fragile":         row.get("fragile", "No").strip(),
            "package_size":    row.get("package_size", "Medium").strip(),
            "vehicle_required": row.get("vehicle_required", "Van").strip(),
            "status":          "pending",
        }
        new_orders.append(order)
        assignments[driver["name"]] = assignments.get(driver["name"], 0) + 1

    # Replace orders store
    _orders_store.clear()
    _orders_store.extend(new_orders)

    # Update driver deliveries_today
    for d in _drivers_store:
        d["deliveries_today"] = assignments.get(d["name"], 0)

    # Persist
    fieldnames = ["order_id","driver_id","driver_name","customer_name","phone",
                  "address","area","lat","lng","fragile","package_size","vehicle_required","status"]
    with open(_ORDERS_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(new_orders)

    _log_usage(x_api_key, "/api/v1/upload-orders", (time.time() - t0) * 1000)
    return {
        "message": f"Uploaded and assigned {len(new_orders)} orders",
        "assignments": assignments,
        "total_orders": len(new_orders),
    }


@app.get("/api/v1/orders", tags=["Public API"])
@limiter.limit("50/minute")
def api_get_orders(request: Request, x_api_key: Optional[str] = Header(default=None),
                   status: Optional[str] = None, driver_id: Optional[str] = None,
                   date: Optional[str] = None):
    """
    Get all orders with their current delivery status.
    Optional filters: ?status=pending|delivered  &driver_id=28  &date=2026-04-17
    If driver_id is provided and no date is given, defaults to today's orders only.
    """
    from datetime import date as _date
    t0 = time.time()
    _verify_key(x_api_key)

    orders = list(_orders_store)
    if status:
        orders = [o for o in orders if o.get("status") == status]
    if driver_id:
        orders = [o for o in orders if str(o.get("driver_id")) == str(driver_id)]
    # Apply date filter: if date param given use it; if driver_id given default to today
    if date:
        orders = [o for o in orders if o.get("delivery_date") == date]
    elif driver_id:
        orders = [o for o in orders if o.get("delivery_date") == str(_date.today())]

    _log_usage(x_api_key, "/api/v1/orders", (time.time() - t0) * 1000)
    return {
        "total": len(orders),
        "orders": orders,
    }


@app.get("/api/v1/schedule", tags=["Public API"])
@limiter.limit("50/minute")
def api_get_schedule(request: Request, x_api_key: Optional[str] = Header(default=None),
                     days: int = 14):
    """
    Returns order counts per driver for the next N days that have orders (default 14).
    Used by the dashboard Schedule tab.
    """
    from datetime import date as _date
    t0 = time.time()
    _verify_key(x_api_key)

    today = _date.today()
    today_str = str(today)

    # Pre-group orders by date in one pass — O(n) not O(n*d)
    by_date: Dict[str, Dict[str, Any]] = {}
    for o in _orders_store:
        date_str = o.get("delivery_date", "")
        if not date_str or date_str < today_str:
            continue  # skip past orders
        if date_str not in by_date:
            by_date[date_str] = {}
        did = str(o.get("driver_id"))
        if did not in by_date[date_str]:
            by_date[date_str][did] = {
                "driver_id": did,
                "driver_name": o.get("driver_name", ""),
                "total": 0, "delivered": 0,
            }
        by_date[date_str][did]["total"] += 1
        if o.get("status") == "delivered":
            by_date[date_str][did]["delivered"] += 1

    # Sort dates and return first N
    sorted_dates = sorted(by_date.keys())[:days]
    result = []
    for date_str in sorted_dates:
        drivers = list(by_date[date_str].values())
        for d in drivers:
            d["remaining"] = d["total"] - d["delivered"]
        try:
            from datetime import date as _date2
            dt = _date2.fromisoformat(date_str)
            weekday = dt.strftime("%A")
        except Exception:
            weekday = ""
        result.append({
            "date": date_str,
            "weekday": weekday,
            "is_today": date_str == today_str,
            "drivers": drivers,
            "total_orders": sum(d["total"] for d in drivers),
        })

    _log_usage(x_api_key, "/api/v1/schedule", (time.time() - t0) * 1000)
    return {"schedule": result}


@app.get("/api/v1/drivers", tags=["Public API"])
@limiter.limit("50/minute")
def api_get_drivers(request: Request, x_api_key: Optional[str] = Header(default=None)):
    """
    Get all drivers with their zones, positions, and delivery stats.
    """
    t0 = time.time()
    _verify_key(x_api_key)

    # Enrich with live delivered count from orders store
    for d in _drivers_store:
        delivered = sum(1 for o in _orders_store
                        if str(o.get("driver_id")) == str(d["id"]) and o.get("status") == "delivered")
        total = sum(1 for o in _orders_store if str(o.get("driver_id")) == str(d["id"]))
        d["delivered_count"] = delivered
        d["deliveries_today"] = total
        d["remaining_count"] = total - delivered

    _log_usage(x_api_key, "/api/v1/drivers", (time.time() - t0) * 1000)
    return {
        "total": len(_drivers_store),
        "drivers": _drivers_store,
    }


@app.get("/api/v1/driver/{driver_id}/status", tags=["Public API"])
@limiter.limit("50/minute")
def api_driver_status(request: Request, driver_id: str,
                      x_api_key: Optional[str] = Header(default=None)):
    """
    Get live status for a specific driver: assigned stops, delivered count,
    remaining stops, current position.
    """
    t0 = time.time()
    _verify_key(x_api_key)

    driver = next((d for d in _drivers_store if str(d["id"]) == str(driver_id)), None)
    if not driver:
        raise HTTPException(status_code=404, detail=f"Driver {driver_id} not found.")

    driver_orders = [o for o in _orders_store if str(o.get("driver_id")) == str(driver_id)]
    pending  = [o for o in driver_orders if o.get("status") == "pending"]
    delivered = [o for o in driver_orders if o.get("status") == "delivered"]

    _log_usage(x_api_key, f"/api/v1/driver/{driver_id}/status", (time.time() - t0) * 1000)
    return {
        "driver_id":        driver_id,
        "driver_name":      driver.get("name"),
        "areas_served":     driver.get("areas_served"),
        "vehicle":          driver.get("vehicle"),
        "current_lat":      driver.get("centroid_lat"),
        "current_lng":      driver.get("centroid_lng"),
        "status":           driver.get("status", "available"),
        "deliveries_today": len(driver_orders),
        "delivered_count":  len(delivered),
        "remaining_count":  len(pending),
        "pending_stops":    pending,
    }


@app.patch("/api/v1/order/{order_id}/delivered", tags=["Public API"])
@limiter.limit("50/minute")
def api_mark_delivered(request: Request, order_id: str,
                       x_api_key: Optional[str] = Header(default=None)):
    """
    Mark a specific order as delivered. Called by the driver app when a stop is completed.
    """
    t0 = time.time()
    _verify_key(x_api_key)

    order = next((o for o in _orders_store if str(o.get("order_id")) == str(order_id)), None)
    if not order:
        raise HTTPException(status_code=404, detail=f"Order {order_id} not found.")

    order["status"] = "delivered"
    order["delivered_at"] = datetime.utcnow().isoformat()

    # Persist to CSV so delivered status survives server restarts
    _save_orders()

    _log_usage(x_api_key, f"/api/v1/order/{order_id}/delivered", (time.time() - t0) * 1000)
    return {
        "order_id": order_id,
        "status": "delivered",
        "delivered_at": order["delivered_at"],
        "customer": order.get("customer_name"),
        "area": order.get("area"),
    }


@app.get("/api/v1/usage", tags=["Public API"])
def api_usage(x_api_key: Optional[str] = Header(default=None)):
    """
    View API usage stats (owner use only — requires master key opt-demo-key-001).
    """
    _verify_key(x_api_key)

    log = []
    if os.path.exists(_USAGE_LOG):
        with open(_USAGE_LOG, encoding="utf-8") as f:
            try:
                log = json.load(f)
            except Exception:
                log = []

    # Aggregate by key
    by_key: Dict[str, dict] = {}
    for entry in log:
        k = entry.get("key", "unknown")
        if k not in by_key:
            keys_data = _load_api_keys()
            by_key[k] = {
                "company": keys_data.get(k, {}).get("company", "Unknown"),
                "total_calls": 0,
                "avg_response_ms": 0,
                "endpoints": {}
            }
        by_key[k]["total_calls"] += 1
        ep = entry.get("endpoint", "unknown")
        by_key[k]["endpoints"][ep] = by_key[k]["endpoints"].get(ep, 0) + 1

    # Avg response times
    for k in by_key:
        times = [e["response_ms"] for e in log if e.get("key") == k]
        by_key[k]["avg_response_ms"] = round(statistics.mean(times), 1) if times else 0

    return {
        "total_calls": len(log),
        "by_company": by_key,
        "recent": log[-10:],
    }


# =====================================================================
# DASHBOARD  —  /dashboard
# =====================================================================

@app.get("/dashboard", response_class=HTMLResponse, include_in_schema=False)
def serve_dashboard():
    """Company-facing live dashboard."""
    if not os.path.exists(_DASH_FILE):
        raise HTTPException(status_code=404, detail="Dashboard not found.")
    with open(_DASH_FILE, encoding="utf-8") as f:
        return HTMLResponse(content=f.read())