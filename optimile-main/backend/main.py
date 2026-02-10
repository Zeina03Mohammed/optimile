from __future__ import annotations

from fastapi import FastAPI
from pydantic import BaseModel, StrictInt
from typing import List, Optional, Tuple
from datetime import datetime
import json
import os
from functools import lru_cache

import requests
from model.impact import estimate_delay
from model.decision import should_reoptimize
from model.traffic_provider import fetch_incidents_along_route

from model.alns_optimizer import optimize_route, route_cost
from model.bellman_ford import route_order_from_locations
import joblib


app = FastAPI()

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


def _bf_order_by_google_from_start(
    start_lat: float,
    start_lng: float,
    stops: List[Stop],
    api_key: Optional[str] = None,
) -> Optional[List[int]]:
    """
    Returns a Bellman–Ford-style ordering using real road travel time:
    sort stops by Google Distance Matrix duration from the start node.

    Uses api_key if provided (e.g. from Flutter env.dart); else GOOGLE_MAPS_API_KEY env.
    Returns None if no key or request fails.
    """
    key = api_key or _GOOGLE_MAPS_API_KEY
    if not key or not stops:
        return None

    now_s = int(datetime.now().timestamp())
    dep = _departure_bucket(now_s)

    o_lat = _round_coord(start_lat)
    o_lng = _round_coord(start_lng)
    origin_key = f"{o_lat},{o_lng}"

    dest_parts: List[str] = []
    for s in stops:
        d_lat = _round_coord(s.lat)
        d_lng = _round_coord(s.lng)
        dest_parts.append(f"{d_lat},{d_lng}")
    destinations_key = "|".join(dest_parts)

    if api_key:
        durations = _google_distance_matrix_durations_seconds_impl(
            origin_key, destinations_key, dep, api_key
        )
    else:
        durations = _google_distance_matrix_durations_seconds(origin_key, destinations_key, dep)
    if durations is None:
        return None

    scored: List[tuple[int, int]] = [(i, int(sec)) for i, sec in enumerate(durations)]

    scored.sort(key=lambda x: (x[1], x[0]))
    return [i for (i, _) in scored]

# =========================
# API MODELS
# =========================

class Stop(BaseModel):
    lat: float
    lng: float
    is_fragile: bool = False

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
    }

    # optional single incident – pick the most severe if provided
    if req.incidents:
        most_severe = max(req.incidents, key=lambda x: x.severity)
        context["incident"] = {
            "index": int(most_severe.index),
            "kind": most_severe.kind,
            "severity": float(most_severe.severity),
        }

    # Bellman–Ford: use chosen locations (and optional current position) for shortest-path order
    if req.use_bellman_ford:
        used_google = False
        if req.current_lat is not None and req.current_lng is not None:
            google_order = _bf_order_by_google_from_start(
                float(req.current_lat),
                float(req.current_lng),
                req.stops,
                req.google_maps_api_key,
            )
            if google_order is not None:
                order = google_order
                used_google = True
            else:
                coords = [(req.current_lat, req.current_lng)] + stop_coords
                bf_order, _ = route_order_from_locations(coords, start_index=0)
                # drop start node (index 0); remaining indices are 1..n -> map to stop indices 0..n-1
                order = [i - 1 for i in bf_order if i != 0]
        else:
            # No explicit start position. Use first stop as the "start" node for ordering.
            if len(req.stops) <= 1:
                order = list(range(len(req.stops)))
            else:
                start = req.stops[0]
                google_order_rest = _bf_order_by_google_from_start(
                    float(start.lat),
                    float(start.lng),
                    req.stops[1:],
                    req.google_maps_api_key,
                )
                if google_order_rest is not None:
                    order = [0] + [i + 1 for i in google_order_rest]
                    used_google = True
                else:
                    coords = stop_coords
                    bf_order, _ = route_order_from_locations(coords, start_index=0)
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
        print(
            "[OPTIMIZE] Bellman–Ford "
            f"vehicle={req.vehicle} n_stops={len(stop_coords)} "
            f"baseline_cost={baseline_cost:.3f} optimized_cost={cost:.3f} improvement={improvement:.3f}"
        )
        return {
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
        }
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
    }

    # ALNS + Bellman–Ford reoptimize: BF provides initial order, ALNS refines it (with TomTom incidents)
    if req.use_bellman_ford:
        if not req.remaining_stops:
            return {"rerouted": False}
        bf_used_google = False

        # 1) Bellman–Ford: get initial ordering of remaining stops (by distance / Google drive time)
        google_order = _bf_order_by_google_from_start(
            float(req.current_lat),
            float(req.current_lng),
            req.remaining_stops,
            req.google_maps_api_key,
        )
        if google_order is not None:
            bf_order_remaining = google_order
            bf_used_google = True
        else:
            bf_order_full, _ = route_order_from_locations(coords, start_index=0)
            bf_order_remaining = [i - 1 for i in bf_order_full if i != 0]

        # 2) Initial route for ALNS: [0] = current position, then remaining in BF order
        initial_route = [0] + [i + 1 for i in bf_order_remaining]

        # 3) Incident context (TomTom + request incidents), same as ALNS branch
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

        # 4) Run ALNS with BF initial solution
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
        print(
            "[REOPTIMIZE] ALNS+Bellman–Ford "
            f"reason={req.reason} n_remaining={len(req.remaining_stops)} "
            f"bf_weights={'google' if bf_used_google else 'haversine'} "
            f"tomtom_incidents={len(live_incidents)} "
            f"baseline_cost={baseline_cost:.3f} optimized_cost={cost:.3f}"
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
                }
                for i in order
            ],
            "cost": round(cost, 2),
            "reason": req.reason,
            "live_incidents_found": len(live_incidents) > 0,
            "incident_kind": incident_kind,
            "algorithm": "alns_bellman_ford",
            "bf_weights": "google_directions" if bf_used_google else "haversine",
        }

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
    #  - live provider API (TomTom example)
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
    }

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