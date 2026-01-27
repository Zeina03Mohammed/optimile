from fastapi import FastAPI
from pydantic import BaseModel
import joblib
from model.lns_optimizer import lns_optimize, predict_cost
from typing import List
import json
from datetime import datetime

app = FastAPI()
model = joblib.load("model/optimize_model.pkl")


class Stop(BaseModel):
    lat: float
    lng: float


class RouteRequest(BaseModel):
    stops: List[Stop]
    vehicle: str
    traffic: str
    weather: str


class ReoptimizeRequest(BaseModel):
    current_lat: float
    current_lng: float
    remaining_stops: List[Stop]
    vehicle: str
    traffic: str
    weather: str
    reason: str


@app.post("/optimize")
def optimize(req: RouteRequest):
    context = {
        "agent_age": 30,
        "agent_rating": 4.7,
        "order_minutes": 600,
        "pickup_delay": 10,
        "day_of_week": 2,
        "weather": req.weather,
        "traffic": req.traffic,
        "vehicle": req.vehicle,
        "area": "Urban",
        "category": "Grocery",
    }

    stops = [{"lat": s.lat, "lng": s.lng} for s in req.stops]
    original_route = stops[:]

    optimized_route, opt_cost = lns_optimize(
        stops, model, context, iterations=300
    )

    # 🔐 SAFETY
    try:
        original_cost = predict_cost(original_route, model, context)
    except Exception as e:
        print("⚠ Cost prediction failed:", e)
        original_cost = opt_cost

    final_cost = min(opt_cost, original_cost)
    time_saved = max(original_cost - final_cost, 0)

    if final_cost == original_cost:
        optimized_route = original_route

    return {
        "optimized_route": optimized_route,
        "estimated_cost": round(final_cost, 2),
        "original_cost": round(original_cost, 2),
        "time_saved": round(time_saved, 2),
        "status": "ok" if time_saved > 0 else "no_improvement",
    }


@app.post("/reoptimize")
def reoptimize(req: ReoptimizeRequest):
    context = {
        "agent_age": 30,
        "agent_rating": 4.7,
        "order_minutes": 600,
        "pickup_delay": 10,
        "day_of_week": 2,
        "weather": req.weather,
        "traffic": req.traffic,
        "vehicle": req.vehicle,
        "area": "Urban",
        "category": "Grocery",
    }

    current_pos = {"lat": req.current_lat, "lng": req.current_lng}
    remaining = [{"lat": s.lat, "lng": s.lng} for s in req.remaining_stops]

    route, cost = lns_optimize(
        [current_pos] + remaining,
        model,
        context,
        iterations=120,
    )

    return {
        "optimized_route": route[1:],
        "estimated_cost": round(cost, 2),
        "reason": req.reason,
    }


@app.post("/anomaly-log")
def anomaly_log(data: dict):
    entry = {
        "timestamp": datetime.utcnow().isoformat(),
        "reason": data["reason"],
        "lat": data["current_lat"],
        "lng": data["current_lng"],
        "remaining_stops": len(data["remaining_stops"]),
        "vehicle": data["vehicle"],
        "traffic": data["traffic"],
        "weather": data["weather"],
    }

    with open("anomalies.json", "a") as f:
        f.write(json.dumps(entry) + "\n")

    return {"status": "logged"}
