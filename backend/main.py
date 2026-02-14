from fastapi import FastAPI
from pydantic import BaseModel, StrictInt
from typing import List, Optional
from datetime import datetime
import json
from model.impact import estimate_delay
from model.decision import should_reoptimize
from model.traffic_provider import fetch_incidents_along_route

from model.alns_optimizer import optimize_route, route_cost
import joblib


app = FastAPI()

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


# =========================
# OPTIMIZE
# =========================

@app.post("/optimize")
def optimize(req: OptimizeRequest):
    coords = [(s.lat, s.lng) for s in req.stops]

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

    # baseline identity route cost (for logging / validation)
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
        start_time_min=start_time,  # ← minutes
    )

    improvement = baseline_cost - cost

    # lightweight, explainable log for debugging/evaluation
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
    event_delay = estimate_delay(
        event=req.reason,
        baseline_eta=20,  # nominal remaining ETA in minutes
    )
    # Simulate / manual trigger: use severity as extra delay so we always reoptimize
    if req.severity and req.severity > 0:
        event_delay = max(event_delay, req.severity * 15)  # severity 0.5 -> 7.5 min

    should = should_reoptimize(
        delay_minutes=event_delay,
        next_stop_fragile=req.remaining_stops[0].is_fragile,
        time_window_slack=15,
        last_reopt_seconds=120,
    )

    if not should:
        return {"rerouted": False}

    # ONLY remaining route (driver position + remaining stops)
    coords = [(req.current_lat, req.current_lng)] + [
        (s.lat, s.lng) for s in req.remaining_stops
    ]

    fragile_flags = [False] + [s.is_fragile for s in req.remaining_stops]
    time_windows = [(None, None)] + [
        (s.window_start, s.window_end) for s in req.remaining_stops
    ]

    now = datetime.now()
    start_time = now.hour * 60 + now.minute

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