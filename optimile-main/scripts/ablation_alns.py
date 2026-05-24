"""
scripts/ablation_alns.py
--------------------------
NN-only nearest-neighbor dispatch ablation for Table 3.

Generates the NN-only column: greedy nearest-neighbor route ordering
on randomly generated instances at stop counts 5, 10, 15, 20.
30 instances per stop count, random_state=42.

Output: ml_pipeline/saved_models/ablation_alns.csv
"""

import os
import sys
import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

STOP_COUNTS = [5, 10, 15, 20]
N_INSTANCES = 30
RANDOM_STATE = 42
OUT = os.path.join(ROOT, "ml_pipeline", "saved_models", "ablation_alns.csv")

rng = np.random.default_rng(RANDOM_STATE)

# Cairo bounding box (lat/lng)
LAT_MIN, LAT_MAX = 29.9, 30.2
LNG_MIN, LNG_MAX = 31.1, 31.5


def haversine_km(lat1, lon1, lat2, lon2):
    from math import radians, sin, cos, sqrt, atan2
    R = 6371.0
    la1, lo1, la2, lo2 = map(radians, [lat1, lon1, lat2, lon2])
    dlat, dlon = la2 - la1, lo2 - lo1
    a = sin(dlat / 2) ** 2 + cos(la1) * cos(la2) * sin(dlon / 2) ** 2
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))


def route_cost(coords, order):
    """Total haversine distance (km) of a route in visit order."""
    total = 0.0
    for i in range(len(order) - 1):
        a, b = order[i], order[i + 1]
        total += haversine_km(coords[a][0], coords[a][1], coords[b][0], coords[b][1])
    return total


def nn_route(coords, start=0):
    """Nearest-neighbor greedy dispatch from `start`."""
    n = len(coords)
    visited = [False] * n
    order = [start]
    visited[start] = True
    for _ in range(n - 1):
        cur = order[-1]
        best_dist, best_next = float("inf"), -1
        for j in range(n):
            if visited[j]:
                continue
            d = haversine_km(coords[cur][0], coords[cur][1], coords[j][0], coords[j][1])
            if d < best_dist:
                best_dist, best_next = d, j
        order.append(best_next)
        visited[best_next] = True
    return order


print(f"{'─'*50}")
print(f"  NN-ONLY ABLATION  (30 instances × 4 stop counts)")
print(f"{'─'*50}")

rows = []
for n_stops in STOP_COUNTS:
    costs = []
    for _ in range(N_INSTANCES):
        lats = rng.uniform(LAT_MIN, LAT_MAX, n_stops)
        lngs = rng.uniform(LNG_MIN, LNG_MAX, n_stops)
        coords = list(zip(lats, lngs))
        order = nn_route(coords, start=0)
        costs.append(route_cost(coords, order))
    mean_cost = float(np.mean(costs))
    rows.append({"stops": n_stops, "nn_cost": round(mean_cost, 3)})
    print(f"  {n_stops:>3} stops  →  NN mean cost = {mean_cost:.3f} km")

df = pd.DataFrame(rows)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
df.to_csv(OUT, index=False)
print(f"\nSaved → {OUT}")
