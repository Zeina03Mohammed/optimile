"""
scripts/ablation_real_routes.py
---------------------------------
BF-only vs BF+ALNS on real Cairo driver routes for Table (Real Routes).

Reconstructs actual routes from drivers_movements.csv (≥4 stops,
sorted by arrival timestamp) and compares BF vs BF+ALNS routing cost.

Output: ml_pipeline/saved_models/ablation_real_routes.csv
"""

import os
import sys
import math
import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

ALNS_ITERS   = 400
RANDOM_STATE = 42
OUT = os.path.join(ROOT, "ml_pipeline", "saved_models", "ablation_real_routes.csv")

from ml_pipeline.preprocessor import load_raw, assign_clusters


def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0
    la1, lo1, la2, lo2 = map(math.radians, [lat1, lon1, lat2, lon2])
    dlat, dlon = la2 - la1, lo2 - lo1
    a = math.sin(dlat / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dlon / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def build_matrix(coords):
    n = len(coords)
    m = {}
    for i in range(n):
        for j in range(n):
            if i != j:
                m[(i, j)] = haversine_km(coords[i][0], coords[i][1],
                                          coords[j][0], coords[j][1])
    return m


def route_cost(order, matrix):
    return sum(matrix[(order[i], order[i + 1])] for i in range(len(order) - 1))


def bf_order(coords, start=0):
    n = len(coords)
    matrix = build_matrix(coords)
    dist = {i: float("inf") for i in range(n)}
    dist[start] = 0.0
    for _ in range(n - 1):
        for u in range(n):
            if dist[u] == float("inf"):
                continue
            for v in range(n):
                if u != v:
                    nd = dist[u] + matrix[(u, v)]
                    if nd < dist[v]:
                        dist[v] = nd
    others = sorted([i for i in range(n) if i != start], key=lambda x: dist[x])
    return [start] + others


def alns_optimize(order, matrix, n_iters, seed):
    inst_rng = np.random.default_rng(seed)
    current = list(order)
    current_cost = route_cost(current, matrix)
    best = list(current)
    best_cost = current_cost
    T0 = current_cost * 0.15
    alpha = (0.01 / max(T0, 1e-9)) ** (1.0 / max(n_iters, 1))
    T = T0
    for _ in range(n_iters):
        n = len(current)
        i, j = sorted(inst_rng.choice(range(1, n), size=2, replace=False))
        candidate = current[:i] + current[i:j + 1][::-1] + current[j + 1:]
        cand_cost = route_cost(candidate, matrix)
        delta = cand_cost - current_cost
        if delta < 0 or inst_rng.random() < math.exp(-delta / max(T, 1e-9)):
            current = candidate
            current_cost = cand_cost
        if current_cost < best_cost:
            best = list(current)
            best_cost = current_cost
        T *= alpha
    return best, best_cost


# ── Load real routes ──────────────────────────────────────────────────────────
print("Loading real driver routes...")
df_raw = load_raw(verbose=False)
df_raw["date_str"] = df_raw["datetime"].dt.date.astype(str)
df_raw = df_raw.sort_values(["driver_key", "datetime"])

routes = []
for (driver, date), grp in df_raw.groupby(["driver_key", "date_str"]):
    grp = grp.sort_values("datetime").reset_index(drop=True)
    if len(grp) >= 4:
        coords = list(zip(grp["lat"].tolist(), grp["lng"].tolist()))
        routes.append({"driver": driver, "date": date, "coords": coords, "n_stops": len(coords)})

print(f"  {len(routes)} routes with ≥4 stops")

# ── Run ablation ──────────────────────────────────────────────────────────────
bins = [(4, 6), (7, 10), (11, 15), (16, 999)]
bin_labels = ["4--6 stops", "7--10 stops", "11--15 stops", "16+ stops"]

rows = []
for route_i, route in enumerate(routes):
    coords = route["coords"]
    matrix = build_matrix(coords)
    bf_ord = bf_order(coords)
    bf_c = route_cost(bf_ord, matrix)
    _, alns_c = alns_optimize(bf_ord, matrix, ALNS_ITERS, RANDOM_STATE + route_i)
    improvement = (bf_c - alns_c) / bf_c * 100 if bf_c > 0 else 0.0
    rows.append({
        "driver": route["driver"],
        "date": route["date"],
        "n_stops": route["n_stops"],
        "bf_cost": round(bf_c, 3),
        "alns_cost": round(alns_c, 3),
        "improvement_pct": round(improvement, 2),
    })

df = pd.DataFrame(rows)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
df.to_csv(OUT, index=False)
print(f"Saved {len(df)} route results → {OUT}")

# ── Summary by bin ────────────────────────────────────────────────────────────
print(f"\n{'─'*55}")
print(f"  {'Route size':<14} {'Routes':>7} {'Mean improvement':>17}")
for (lo, hi), label in zip(bins, bin_labels):
    subset = df[(df["n_stops"] >= lo) & (df["n_stops"] <= hi)]
    if len(subset):
        mean_imp = subset["improvement_pct"].mean()
        print(f"  {label:<14} {len(subset):>7} {mean_imp:>14.1f}%")
overall_mean   = df["improvement_pct"].mean()
overall_median = df["improvement_pct"].median()
print(f"  {'Overall':>14} {len(df):>7}  mean {overall_mean:.1f}% / median {overall_median:.1f}%")
