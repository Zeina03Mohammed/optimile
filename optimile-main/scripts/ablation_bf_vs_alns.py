"""
scripts/ablation_bf_vs_alns.py
--------------------------------
BF-only vs BF+ALNS routing ablation for Table 3.

Compares Bellman-Ford initialisation alone vs BF + 400 ALNS iterations
on random instances at stop counts 5, 10, 15, 20.
30 instances per stop count, random_state=42.

Output: ml_pipeline/saved_models/ablation_bf_vs_alns.csv
"""

import os
import sys
import random
import math
import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

STOP_COUNTS  = [5, 10, 15, 20]
N_INSTANCES  = 30
ALNS_ITERS   = 400
RANDOM_STATE = 42
OUT = os.path.join(ROOT, "ml_pipeline", "saved_models", "ablation_bf_vs_alns.csv")

rng = np.random.default_rng(RANDOM_STATE)

LAT_MIN, LAT_MAX = 29.9, 30.2
LNG_MIN, LNG_MAX = 31.1, 31.5


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
    """BF shortest-distance ordering from start."""
    n = len(coords)
    matrix = build_matrix(coords)
    dist = {i: float("inf") for i in range(n)}
    dist[start] = 0.0
    for _ in range(n - 1):
        for u in range(n):
            if dist[u] == float("inf"):
                continue
            for v in range(n):
                if u == v:
                    continue
                nd = dist[u] + matrix[(u, v)]
                if nd < dist[v]:
                    dist[v] = nd
    others = sorted([i for i in range(n) if i != start], key=lambda x: dist[x])
    return [start] + others


def alns_optimize(order, matrix, n_iters, rng_inst):
    """Stripped ALNS: random segment reversal with Metropolis acceptance."""
    current = list(order)
    current_cost = route_cost(current, matrix)
    best = list(current)
    best_cost = current_cost

    T0 = current_cost * 0.15
    alpha = (0.01 / max(T0, 1e-9)) ** (1.0 / max(n_iters, 1))
    T = T0

    for _ in range(n_iters):
        n = len(current)
        i, j = sorted(rng_inst.choice(range(1, n), size=2, replace=False))
        candidate = current[:i] + current[i:j + 1][::-1] + current[j + 1:]
        cand_cost = route_cost(candidate, matrix)
        delta = cand_cost - current_cost
        if delta < 0 or rng_inst.random() < math.exp(-delta / max(T, 1e-9)):
            current = candidate
            current_cost = cand_cost
        if current_cost < best_cost:
            best = list(current)
            best_cost = current_cost
        T *= alpha

    return best, best_cost


print(f"{'─'*60}")
print(f"  BF vs BF+ALNS ABLATION  ({N_INSTANCES} instances × {len(STOP_COUNTS)} stop counts)")
print(f"{'─'*60}")
print(f"  {'Stops':>5} {'BF cost':>10} {'BF+ALNS':>10} {'vs NN':>8} {'vs BF':>8}")

rows = []
# Pre-generate all instances consistently
all_instances = {}
for n_stops in STOP_COUNTS:
    instances = []
    for _ in range(N_INSTANCES):
        lats = rng.uniform(LAT_MIN, LAT_MAX, n_stops)
        lngs = rng.uniform(LNG_MIN, LNG_MAX, n_stops)
        instances.append(list(zip(lats.tolist(), lngs.tolist())))
    all_instances[n_stops] = instances

# NN costs (for vs-NN column) — use same instances
nn_costs_by_stops = {}
for n_stops, instances in all_instances.items():
    nn_costs = []
    for coords in instances:
        n = len(coords)
        matrix = build_matrix(coords)
        visited = [False] * n
        order = [0]
        visited[0] = True
        for _ in range(n - 1):
            cur = order[-1]
            best_d, best_j = float("inf"), -1
            for j in range(n):
                if not visited[j] and matrix[(cur, j)] < best_d:
                    best_d, best_j = matrix[(cur, j)], j
            order.append(best_j)
            visited[best_j] = True
        nn_costs.append(route_cost(order, matrix))
    nn_costs_by_stops[n_stops] = float(np.mean(nn_costs))

for n_stops, instances in all_instances.items():
    bf_costs, alns_costs = [], []
    for seed_i, coords in enumerate(instances):
        matrix = build_matrix(coords)
        inst_rng = np.random.default_rng(RANDOM_STATE + seed_i)

        bf_ord = bf_order(coords)
        bf_c   = route_cost(bf_ord, matrix)
        bf_costs.append(bf_c)

        _, alns_c = alns_optimize(bf_ord, matrix, ALNS_ITERS, inst_rng)
        alns_costs.append(alns_c)

    mean_nn   = nn_costs_by_stops[n_stops]
    mean_bf   = float(np.mean(bf_costs))
    mean_alns = float(np.mean(alns_costs))
    vs_nn = (mean_nn   - mean_alns) / mean_nn   * 100
    vs_bf = (mean_bf   - mean_alns) / mean_bf   * 100

    rows.append({
        "stops":    n_stops,
        "nn_cost":   round(mean_nn,   3),
        "bf_cost":   round(mean_bf,   3),
        "alns_cost": round(mean_alns, 3),
        "vs_nn_pct": round(vs_nn, 1),
        "vs_bf_pct": round(vs_bf, 1),
    })
    print(f"  {n_stops:>5} {mean_bf:>10.3f} {mean_alns:>10.3f} {vs_nn:>7.1f}% {vs_bf:>7.1f}%")

df = pd.DataFrame(rows)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
df.to_csv(OUT, index=False)
print(f"\nSaved → {OUT}")
