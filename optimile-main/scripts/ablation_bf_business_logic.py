"""
scripts/ablation_bf_business_logic.py
---------------------------------------
Ablation of Bellman-Ford business-logic edge weight modifiers.

Tests the impact of each modifier (fragile penalty, urgency reward,
cluster proximity reward, traffic penalty) on routing cost and ordering
quality across random instances.

Output: ml_pipeline/saved_models/ablation_bf_business_logic.csv
"""

import os
import sys
import math
import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

N_INSTANCES  = 50
N_STOPS      = 10
RANDOM_STATE = 42
OUT = os.path.join(ROOT, "ml_pipeline", "saved_models", "ablation_bf_business_logic.csv")

rng = np.random.default_rng(RANDOM_STATE)

from model.bellman_ford import compute_edge_weight, bellman_ford

LAT_MIN, LAT_MAX = 29.9, 30.2
LNG_MIN, LNG_MAX = 31.1, 31.5


def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0
    la1, lo1, la2, lo2 = map(math.radians, [lat1, lon1, lat2, lon2])
    dlat, dlon = la2 - la1, lo2 - lo1
    a = math.sin(dlat / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dlon / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def build_graph(coords, fragile_flags=None, time_windows=None, context=None):
    n = len(coords)
    graph = {}
    for i in range(n):
        graph[i] = []
        for j in range(n):
            if i == j:
                continue
            base_km = haversine_km(coords[i][0], coords[i][1],
                                   coords[j][0], coords[j][1])
            base_sec = (base_km / 40.0) * 3600.0
            w = compute_edge_weight(
                base_sec, i, j,
                fragile_flags=fragile_flags,
                time_windows=time_windows,
                context=context,
            )
            graph[i].append((j, w))
    return graph


def order_cost(coords, order):
    total = 0.0
    for i in range(len(order) - 1):
        a, b = order[i], order[i + 1]
        total += haversine_km(coords[a][0], coords[a][1],
                              coords[b][0], coords[b][1])
    return total


configs = {
    "baseline_only":       dict(fragile_flags=None, time_windows=None, context={}),
    "with_fragile":        dict(fragile_flags=None, time_windows=None, context={}),  # set per instance
    "with_urgency":        dict(fragile_flags=None, time_windows=None, context={}),
    "with_traffic_heavy":  dict(fragile_flags=None, time_windows=None, context={"traffic": "Heavy"}),
    "with_traffic_jam":    dict(fragile_flags=None, time_windows=None, context={"traffic": "Jam"}),
    "full_business_logic": dict(fragile_flags=None, time_windows=None, context={"traffic": "Medium"}),
}

rows = []
for inst_i in range(N_INSTANCES):
    lats = rng.uniform(LAT_MIN, LAT_MAX, N_STOPS)
    lngs = rng.uniform(LNG_MIN, LNG_MAX, N_STOPS)
    coords = list(zip(lats.tolist(), lngs.tolist()))

    # Random fragile flags (30% probability)
    fragile = [bool(rng.random() < 0.30) for _ in range(N_STOPS)]

    # Random urgency windows (some stops have 20–40 min windows)
    start_time = int(rng.integers(7 * 60, 11 * 60))  # 7–11 AM
    time_windows = []
    for _ in range(N_STOPS):
        if rng.random() < 0.4:
            slack = int(rng.integers(10, 45))
            time_windows.append((start_time, start_time + slack))
        else:
            time_windows.append((None, None))

    instance_row = {"instance": inst_i}

    # Baseline (no modifiers)
    g_base = build_graph(coords)
    dist_base, _, _ = bellman_ford(g_base, 0, n_nodes=N_STOPS)
    others = sorted([i for i in range(1, N_STOPS)], key=lambda x: dist_base[x])
    order_base = [0] + others
    instance_row["baseline_cost"] = round(order_cost(coords, order_base), 4)

    # Fragile
    g_frag = build_graph(coords, fragile_flags=fragile)
    dist_frag, _, _ = bellman_ford(g_frag, 0, n_nodes=N_STOPS)
    others = sorted([i for i in range(1, N_STOPS)], key=lambda x: dist_frag[x])
    order_frag = [0] + others
    instance_row["fragile_cost"] = round(order_cost(coords, order_frag), 4)

    # Urgency windows
    g_urg = build_graph(coords, time_windows=time_windows, context={})
    dist_urg, _, _ = bellman_ford(g_urg, 0, n_nodes=N_STOPS)
    others = sorted([i for i in range(1, N_STOPS)], key=lambda x: dist_urg[x])
    order_urg = [0] + others
    instance_row["urgency_cost"] = round(order_cost(coords, order_urg), 4)

    # Full business logic
    g_full = build_graph(coords, fragile_flags=fragile, time_windows=time_windows,
                         context={"traffic": "Medium", "weather": "Clear"})
    dist_full, _, _ = bellman_ford(g_full, 0, n_nodes=N_STOPS)
    others = sorted([i for i in range(1, N_STOPS)], key=lambda x: dist_full[x])
    order_full = [0] + others
    instance_row["full_biz_cost"] = round(order_cost(coords, order_full), 4)

    rows.append(instance_row)

df = pd.DataFrame(rows)
df["fragile_delta_pct"]  = ((df["fragile_cost"]  - df["baseline_cost"]) / df["baseline_cost"] * 100).round(2)
df["urgency_delta_pct"]  = ((df["urgency_cost"]  - df["baseline_cost"]) / df["baseline_cost"] * 100).round(2)
df["full_biz_delta_pct"] = ((df["full_biz_cost"] - df["baseline_cost"]) / df["baseline_cost"] * 100).round(2)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
df.to_csv(OUT, index=False)
print(f"Saved {len(df)} instances → {OUT}")
print(f"\nMean cost delta vs baseline:")
print(f"  Fragile flags:      {df['fragile_delta_pct'].mean():.2f}%")
print(f"  Urgency windows:    {df['urgency_delta_pct'].mean():.2f}%")
print(f"  Full business logic:{df['full_biz_delta_pct'].mean():.2f}%")
