from fastapi import FastAPI
from pydantic import BaseModel
from typing import List
import pandas as pd
import optimile_model as om

app = FastAPI()


class Stop(BaseModel):
    Order_ID: str
    Drop_Latitude: float
    Drop_Longitude: float
    Store_Latitude: float
    Store_Longitude: float
    Agent_Rating: float
    Agent_Age: int
    Weather: str
    Traffic: str
    Vehicle: str
    Area: str
    Category: str
    hour: int
    dayofweek: int


class OptimizeRequest(BaseModel):
    stops: List[Stop]



# ---------- API ENDPOINT ----------
@app.post("/optimize")
def optimize_route(request: OptimizeRequest):

    df = pd.DataFrame([s.dict() for s in request.stops])

    if len(df) < 2:
        return {"error": "At least 2 stops are required"}
    initial_cost = om.route_cost(df)
    best_route, best_cost = om.optimize_route(df)

    result = []
    for i, row in best_route.reset_index(drop=True).iterrows():
        result.append({
            "stop_number": i + 1,
            "Order_ID": row["Order_ID"],
            "Drop_Latitude": row["Drop_Latitude"],
            "Drop_Longitude": row["Drop_Longitude"]
        })

    return {
        "initial_cost": float(initial_cost),
        "optimized_cost": float(best_cost),
        "optimized_route": result
    }
