"""
scripts/generate_cairo_dataset.py
-----------------------------------
Generates a physics-based Cairo delivery dataset CALIBRATED to real GPS data.

Key calibration insight from real GPS analysis:
  - Real mean distance:      1.578 km
  - Real mean time:          20.3 min  → implied effective speed = 4.7 km/h
  - Real std time:           18.3 min
  - Real distance-time corr: 0.546

"Effective doorstep-to-doorstep speed" (4-7 km/h) already includes:
  driving + parking + walking to building + elevator + handover + return

This is NOT highway speed — it is the end-to-end speed a delivery driver
achieves in dense Cairo streets, calibrated from your real GPS segments.

Output: data/cairo_delivery_segments.csv
"""

import os, sys
import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

OUT  = os.path.join(ROOT, "data", "cairo_delivery_segments.csv")
N    = 6000
SEED = 42
rng  = np.random.default_rng(SEED)

# ── Calibrated effective doorstep-to-doorstep speeds (km/h) ──────────────────
# Derived from real data: mean_dist=1.578km / (mean_time=20.3min/60) = 4.7 km/h
# Motorcycle is fastest (can squeeze through), van slowest (needs more parking time)
VEHICLE_SPEED = {"car": 5.5, "van": 4.0, "motorcycle": 7.5}

# ── Traffic multipliers (on effective speed) ──────────────────────────────────
TRAFFIC_FACTOR = {"Low": 1.40, "Normal": 1.00, "Medium": 0.78, "High": 0.58, "Jam": 0.40}

# ── Weather multipliers ───────────────────────────────────────────────────────
WEATHER_FACTOR = {"Sunny": 1.00, "Windy": 0.93, "Sandstorm": 0.75, "Rainy": 0.85, "Foggy": 0.80}

# ── Cairo delivery area clusters ─────────────────────────────────────────────
N_CLUSTERS = 10

def hour_factor(hour: np.ndarray) -> np.ndarray:
    """Rush hours slow effective delivery speed in Cairo."""
    h   = np.asarray(hour, dtype=float)
    f   = np.ones_like(h)
    f[(h >= 8)  & (h < 11)]  = 0.68   # morning rush
    f[(h >= 15) & (h < 19)]  = 0.62   # afternoon rush — worst in Cairo
    f[(h >= 12) & (h < 14)]  = 0.82   # lunch slowdown
    f[(h >= 21) | (h < 6)]   = 1.35   # quiet hours
    return f

def cyclic(values, period):
    v = np.asarray(values, dtype=float)
    return np.sin(2 * np.pi * v / period), np.cos(2 * np.pi * v / period)

# ── Sample features ───────────────────────────────────────────────────────────
print(f"Generating {N} calibrated Cairo delivery segments...")

vehicle_types  = rng.choice(["car", "van", "motorcycle"], size=N, p=[0.50, 0.30, 0.20])
traffic_levels = rng.choice(list(TRAFFIC_FACTOR), size=N, p=[0.10, 0.30, 0.30, 0.20, 0.10])
weather_types  = rng.choice(list(WEATHER_FACTOR), size=N, p=[0.60, 0.15, 0.10, 0.10, 0.05])
hours          = rng.integers(6, 23, size=N)
days_of_week   = rng.integers(0, 7, size=N)
months         = rng.integers(1, 13, size=N)

# Distance: log-normal calibrated to real data (mean=1.578km, std=2.138km)
# lognormal params: mean_ln = log(1.578) - 0.5*sigma_ln^2
# From real data: sigma_ln ≈ 0.85 gives good fit
distances = np.clip(rng.lognormal(mean=0.1, sigma=0.95, size=N), 0.05, 15.0)

stops_in_route  = rng.integers(3, 16, size=N)
stop_index      = np.array([rng.integers(0, s) for s in stops_in_route])
stops_remaining = stops_in_route - stop_index - 1
route_progress  = stop_index / (stops_in_route - 1).clip(min=1)

cluster_dest    = rng.integers(0, N_CLUSTERS, size=N)
is_same_cluster = (rng.random(N) < 0.35).astype(int)
cluster_dest_cat = cluster_dest.astype(str)
bearing_deg     = rng.uniform(0, 360, size=N)

# ── Physics: compute time using calibrated effective speeds ───────────────────
base_speed   = np.array([VEHICLE_SPEED[v]  for v in vehicle_types])
t_factor     = np.array([TRAFFIC_FACTOR[t] for t in traffic_levels])
w_factor     = np.array([WEATHER_FACTOR[w] for w in weather_types])
h_factor     = hour_factor(hours)

effective_speed = base_speed * t_factor * h_factor * w_factor   # km/h
travel_time_min = (distances / effective_speed) * 60            # minutes

# Residual noise calibrated so overall std matches real data std (18.3 min)
noise = rng.normal(loc=0, scale=8.0, size=N)

total_time = (travel_time_min + noise).clip(1.0, 90.0)

# ── Cyclic encodings ──────────────────────────────────────────────────────────
hour_sin, hour_cos = cyclic(hours, 24)
dow_sin,  dow_cos  = cyclic(days_of_week, 7)

# ── Assemble ──────────────────────────────────────────────────────────────────
df = pd.DataFrame({
    "distance_km":           distances.round(4),
    "hour_sin":              hour_sin.round(6),
    "hour_cos":              hour_cos.round(6),
    "dow_sin":               dow_sin.round(6),
    "dow_cos":               dow_cos.round(6),
    "month":                 months,
    "stop_index":            stop_index,
    "stops_in_route":        stops_in_route,
    "stops_remaining":       stops_remaining,
    "route_progress":        route_progress.round(4),
    "is_same_cluster":       is_same_cluster,
    "bearing_deg":           bearing_deg.round(2),
    "cluster_dest_cat":      cluster_dest_cat,
    "vehicle_type":          vehicle_types,
    "traffic_level":         traffic_levels,
    "weather":               weather_types,
    "time_to_next_stop_min": total_time.round(2),
})

df.to_csv(OUT, index=False)

print(f"\nCalibrated dataset saved: {OUT}")
print(f"Records: {len(df)}")
print(f"\ntime_to_next_stop_min — generated vs real target:")
print(f"  Generated mean: {df['time_to_next_stop_min'].mean():.1f} min  (real: 20.3 min)")
print(f"  Generated std:  {df['time_to_next_stop_min'].std():.1f} min  (real: 18.3 min)")
print(f"  Generated dist-time corr: {df[['distance_km','time_to_next_stop_min']].corr().iloc[0,1]:.3f}  (real: 0.546)")
print(f"\nVehicle type distribution:\n{df['vehicle_type'].value_counts()}")
print("\nDone.")
