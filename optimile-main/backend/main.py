from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime
import json
from model.impact import estimate_delay
from model.decision import should_reoptimize

from model.alns_optimizer import optimize_route
import joblib

ml_model = joblib.load("model/optimize_model.pkl")
from datetime import datetime


app = FastAPI()

# =========================
# API MODELS
# =========================

class Stop(BaseModel):
    lat: float
    lng: float
    is_fragile: bool = False

    # time window in minutes from start of day (e.g. 480 = 08:00)
    window_start: Optional[int] = None
    window_end: Optional[int] = None


class OptimizeRequest(BaseModel):
    stops: List[Stop]
    vehicle: str              # motorcycle | scooter | van
    traffic: str
    weather: str
    start_time: Optional[str] = None  # ISO string from frontend


class ReoptimizeRequest(BaseModel):
    current_lat: float
    current_lng: float
    remaining_stops: List[Stop]
    vehicle: str
    traffic: str
    weather: str
    reason: str


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
    if req.start_time:
        dt = datetime.fromisoformat(req.start_time)
    else:
        dt = datetime.now()

    start_time = dt.hour * 60 + dt.minute   # ✅ INTEGER MINUTES

    context = {
        "vehicle": req.vehicle.lower(),
        "traffic": req.traffic,
        "weather": req.weather,
        "order_minutes": start_time,
        "day_of_week": dt.weekday(),
    }

    order, cost = optimize_route(
        coords=coords,
        fragile_flags=fragile_flags,
        time_windows=time_windows,
        context=context,
        start_time_min=start_time,  # ← minutes
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
        baseline_eta=20,  # computed from Google Maps
    )

    should = should_reoptimize(
        delay_minutes=event_delay,
        next_stop_fragile=req.remaining_stops[0].is_fragile,
        time_window_slack=15,
        last_reopt_seconds=120,
    )

    if not should:
        return {"rerouted": False}

    # ONLY remaining route
    coords = [(req.current_lat, req.current_lng)] + [
        (s.lat, s.lng) for s in req.remaining_stops
    ]

    fragile_flags = [False] + [s.is_fragile for s in req.remaining_stops]
    time_windows = [(None, None)] + [
        (s.window_start, s.window_end) for s in req.remaining_stops
    ]

    order, cost = optimize_route(
        coords=coords,
        fragile_flags=fragile_flags,
        time_windows=time_windows,
        context={
            "vehicle": req.vehicle,
            "traffic": req.traffic,
            "weather": req.weather,
            "order_minutes": datetime.now().hour * 60,
            "day_of_week": datetime.now().weekday(),
        },
        start_time_min=datetime.now().hour * 60,
    )

    order = [i - 1 for i in order if i != 0]

    return {
        "rerouted": True,
        "optimized_route": [
            {
                "lat": req.remaining_stops[i].lat,
                "lng": req.remaining_stops[i].lng,
                "is_fragile": req.remaining_stops[i].is_fragile,
            }
            for i in order
        ],
        "cost": round(cost, 2),
        "reason": req.reason,
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