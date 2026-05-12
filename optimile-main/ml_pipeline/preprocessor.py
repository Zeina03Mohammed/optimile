"""
ml_pipeline/preprocessor.py
============================
Loads and cleans drivers_movements.csv, engineers inter-stop features,
and runs DBSCAN to assign geographic cluster labels.

Key design decisions (senior ML perspective):
  - Target variable: time_to_next_stop_min
      = minutes from arriving at stop i to arriving at stop i+1
      (travel time + service/dwell time combined — only signal available)
  - Outlier removal: gaps < 1 min (GPS duplicates) and > 90 min (lunch
    breaks, end-of-shift anomalies) are dropped before training
  - DBSCAN uses haversine-aware epsilon (0.008 deg ~ 0.9 km at lat 30)
    to discover natural delivery zones across the Egyptian regions present
  - Driver name is normalised (lowercase + strip) before grouping to
    handle the mixed-case entries in the raw file
"""

import os
import warnings
import numpy as np
import pandas as pd
from math import radians, sin, cos, sqrt, atan2
from sklearn.cluster import DBSCAN

warnings.filterwarnings("ignore")

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

DATA_PATH = os.path.join(os.path.dirname(__file__), "../data/drivers_movements.csv")

# Outlier thresholds for inter-stop gap (minutes)
MIN_GAP_MIN = 1.0    # below → GPS duplicate / same-stop ping
MAX_GAP_MIN = 90.0   # above → lunch break / end-of-shift

# DBSCAN: ~0.9 km radius at Egyptian latitudes, min 3 pings = a zone
DBSCAN_EPS_DEG = 0.008
DBSCAN_MIN_SAMPLES = 3

# Driver ID → vehicle type mapping (from driver profiles)
DRIVER_VEHICLE_MAP = {
    28: "car",   # Ali Edris
    57: "car",   # Abd El Rahman Mostafa
    31: "car",   # Ahmed Hossam
    62: "car",   # Ayman Hamad
    72: "car",   # Basma Saber
    29: "van",   # Hassan Hossny
    64: "van",   # Mohamed Samir
    40: "van",   # Abdeen
}


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def haversine_km(lat1, lon1, lat2, lon2):
    """Great-circle distance in km between two (lat, lon) pairs."""
    R = 6371.0
    lat1, lon1, lat2, lon2 = map(radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))


def _parse_datetime(date_str, time_str):
    """Robust parse for messy date/time strings (leading/trailing spaces etc.)."""
    dt_str = f"{date_str.strip()} {time_str.strip()}"
    for fmt in ("%d/%m/%Y %H:%M:%S", "%d/%m/%Y %H:%M"):
        try:
            return pd.to_datetime(dt_str, format=fmt)
        except ValueError:
            pass
    return pd.NaT


# ─────────────────────────────────────────────────────────────────────────────
# LOAD + CLEAN
# ─────────────────────────────────────────────────────────────────────────────

def load_raw(path: str = DATA_PATH, verbose: bool = False) -> pd.DataFrame:
    df = pd.read_csv(path)
    df.columns = df.columns.str.strip()

    # Normalise string columns
    for col in ["Driver Name", "Date Of Arrival", "Time Of Arrival"]:
        df[col] = df[col].astype(str).str.strip()

    df["driver_key"] = df["Driver Name"].str.lower()  # case-insensitive grouping
    df["datetime"] = df.apply(
        lambda r: _parse_datetime(r["Date Of Arrival"], r["Time Of Arrival"]), axis=1
    )

    n_bad = df["datetime"].isna().sum()
    if n_bad and verbose:
        print(f"  [warn] Dropped {n_bad} rows with unparseable datetime.")
    df = df.dropna(subset=["datetime"]).reset_index(drop=True)

    # Coerce lat/lng to numeric; drop rows where GPS data is malformed
    # (e.g. row with a time string accidentally placed in the Lng column)
    df["lat"] = pd.to_numeric(df["Lat"].astype(str).str.strip(), errors="coerce")
    df["lng"] = pd.to_numeric(df["Lng"].astype(str).str.strip(), errors="coerce")
    n_gps_bad = df[["lat", "lng"]].isna().any(axis=1).sum()
    if n_gps_bad and verbose:
        print(f"  [warn] Dropped {n_gps_bad} rows with malformed GPS coordinates.")
    df = df.dropna(subset=["lat", "lng"]).reset_index(drop=True)

    df = df.rename(columns={"Driver ID": "driver_id"})
    df["vehicle_type"] = df["driver_id"].map(DRIVER_VEHICLE_MAP).fillna("car")
    return df


# ─────────────────────────────────────────────────────────────────────────────
# GEOGRAPHIC CLUSTERING  (DBSCAN)
# ─────────────────────────────────────────────────────────────────────────────

def assign_clusters(df: pd.DataFrame, verbose: bool = False) -> pd.DataFrame:
    """
    Runs DBSCAN on all stop coordinates to assign a delivery zone label.
    Label -1 means 'noise' (isolated stop).  Labels 0, 1, 2, … are zones.
    """
    coords = df[["lat", "lng"]].values
    db = DBSCAN(eps=DBSCAN_EPS_DEG, min_samples=DBSCAN_MIN_SAMPLES, algorithm="ball_tree")
    df = df.copy()
    df["cluster_id"] = db.fit_predict(coords)
    n_clusters = len(set(df["cluster_id"])) - (1 if -1 in df["cluster_id"].values else 0)
    noise = (df["cluster_id"] == -1).sum()
    if verbose:
        print(f"  [DBSCAN] {n_clusters} delivery zones found  |  {noise} noise stops")
    return df


# ─────────────────────────────────────────────────────────────────────────────
# ROUTE SORTING + INTER-STOP FEATURE ENGINEERING
# ─────────────────────────────────────────────────────────────────────────────

def build_segments(df: pd.DataFrame) -> pd.DataFrame:
    """
    Groups stops by (driver_key, date), sorts by time, then computes
    consecutive-stop features and the target variable.

    Returns a DataFrame where each row is one *segment* (stop_i → stop_i+1).
    """
    df = df.sort_values(["driver_key", "datetime"]).copy()
    df["date_str"] = df["datetime"].dt.date.astype(str)

    records = []

    for (driver, date), grp in df.groupby(["driver_key", "date_str"], sort=False):
        grp = grp.sort_values("datetime").reset_index(drop=True)

        # Need at least 2 stops to form a segment
        if len(grp) < 2:
            continue

        n_stops = len(grp)

        for i in range(n_stops - 1):
            row_a = grp.iloc[i]
            row_b = grp.iloc[i + 1]

            gap_min = (row_b["datetime"] - row_a["datetime"]).total_seconds() / 60.0

            # Skip GPS duplicates and long breaks
            if gap_min < MIN_GAP_MIN or gap_min > MAX_GAP_MIN:
                continue

            dist_km = haversine_km(row_a["lat"], row_a["lng"], row_b["lat"], row_b["lng"])

            # Very small displacement (< 50 m) → probable same-building ping
            if dist_km < 0.05:
                continue

            records.append(
                {
                    # ── identifiers ──────────────────────────────────────────
                    "driver_key": driver,
                    "date": date,
                    "vehicle_type": row_a["vehicle_type"],
                    # ── origin stop ──────────────────────────────────────────
                    "lat_origin": row_a["lat"],
                    "lng_origin": row_a["lng"],
                    "cluster_origin": row_a["cluster_id"],
                    # ── destination stop ─────────────────────────────────────
                    "lat_dest": row_b["lat"],
                    "lng_dest": row_b["lng"],
                    "cluster_dest": row_b["cluster_id"],
                    # ── temporal ─────────────────────────────────────────────
                    "hour": row_a["datetime"].hour,
                    "day_of_week": row_a["datetime"].dayofweek,   # 0=Mon
                    "month": row_a["datetime"].month,
                    # ── route context ────────────────────────────────────────
                    "stop_index": i,                      # 0 = first leg
                    "stops_in_route": n_stops,
                    "stops_remaining": n_stops - i - 1,
                    # ── spatial features ─────────────────────────────────────
                    "distance_km": dist_km,
                    "is_same_cluster": int(
                        row_a["cluster_id"] == row_b["cluster_id"]
                        and row_a["cluster_id"] != -1
                    ),
                    # ── TARGET ───────────────────────────────────────────────
                    "time_to_next_stop_min": gap_min,
                }
            )

    seg = pd.DataFrame(records)
    print(f"  [segments] {len(seg)} valid inter-stop segments from {df['driver_key'].nunique()} drivers")
    return seg


# ─────────────────────────────────────────────────────────────────────────────
# ADDITIONAL FEATURE ENGINEERING
# ─────────────────────────────────────────────────────────────────────────────

def engineer_features(seg: pd.DataFrame) -> pd.DataFrame:
    """Derived features that add predictive signal."""
    seg = seg.copy()

    # Speed of this leg if we knew the time — circular, but avg of prev legs
    # Instead: implied speed proxy using distance / target (for EDA only)
    # Not used as a feature (would leak target). Left as comment.

    # Bearing between origin and destination (captures direction patterns)
    dlng = np.radians(seg["lng_dest"] - seg["lng_origin"])
    lat1 = np.radians(seg["lat_origin"])
    lat2 = np.radians(seg["lat_dest"])
    x = np.sin(dlng) * np.cos(lat2)
    y = np.cos(lat1) * np.sin(lat2) - np.sin(lat1) * np.cos(lat2) * np.cos(dlng)
    seg["bearing_deg"] = (np.degrees(np.arctan2(x, y)) + 360) % 360

    # Cyclic time encoding (captures smooth hour/weekday periodicity)
    seg["hour_sin"] = np.sin(2 * np.pi * seg["hour"] / 24)
    seg["hour_cos"] = np.cos(2 * np.pi * seg["hour"] / 24)
    seg["dow_sin"] = np.sin(2 * np.pi * seg["day_of_week"] / 7)
    seg["dow_cos"] = np.cos(2 * np.pi * seg["day_of_week"] / 7)

    # Destination cluster as categorical (−1 → 'noise')
    seg["cluster_dest_cat"] = seg["cluster_dest"].clip(lower=-1).astype(str)

    # Route progress ratio (0.0 = start, 1.0 = last leg)
    seg["route_progress"] = seg["stop_index"] / (seg["stops_in_route"] - 1).clip(lower=1)

    return seg


# ─────────────────────────────────────────────────────────────────────────────
# FULL PIPELINE
# ─────────────────────────────────────────────────────────────────────────────

def run_preprocessing(path: str = DATA_PATH, verbose: bool = True) -> pd.DataFrame:
    """
    End-to-end preprocessing.  Returns a clean feature DataFrame with:
      - numeric features ready for scaling
      - cluster_dest_cat as a categorical column (needs OHE downstream)
      - target column: time_to_next_stop_min
    """
    if verbose:
        print("=" * 60)
        print("PREPROCESSING  drivers_movements.csv")
        print("=" * 60)

    df_raw = load_raw(path, verbose=verbose)
    if verbose:
        print(f"  Loaded {len(df_raw)} stops  |  {df_raw['driver_key'].nunique()} unique drivers")

    df_clustered = assign_clusters(df_raw, verbose=verbose)
    segments = build_segments(df_clustered)
    segments = engineer_features(segments)

    if verbose:
        print(f"\n  Target stats (time_to_next_stop_min):")
        print(f"    mean  = {segments['time_to_next_stop_min'].mean():.1f} min")
        print(f"    median= {segments['time_to_next_stop_min'].median():.1f} min")
        print(f"    std   = {segments['time_to_next_stop_min'].std():.1f} min")
        print(f"    min   = {segments['time_to_next_stop_min'].min():.1f} min")
        print(f"    max   = {segments['time_to_next_stop_min'].max():.1f} min")
        print(f"\n  Feature columns: {len(segments.columns) - 3}")  # minus id cols + target
        print("=" * 60)

    return segments


# ─────────────────────────────────────────────────────────────────────────────
# FEATURE / TARGET SPLIT  (used by model_trainer)
# ─────────────────────────────────────────────────────────────────────────────

NUMERIC_FEATURES = [
    "distance_km",
    "hour_sin", "hour_cos",
    "dow_sin", "dow_cos",
    "month",
    "stop_index",
    "stops_in_route",
    "stops_remaining",
    "route_progress",
    "is_same_cluster",
    "bearing_deg",
    # lat_dest / lng_dest omitted: raw coordinates cause extreme z-scores
    # when CV folds span different Egyptian cities (Alexandria vs Ismailia),
    # overflowing linear model matmul.  Geography is already encoded by
    # cluster_dest_cat which handles cross-city generalisation cleanly.
]

CATEGORICAL_FEATURES = [
    "cluster_dest_cat",
    "vehicle_type",
    "traffic_level",
    "weather",
]

# Features that are only present in the physics-generated dataset.
# get_X_y drops them silently when missing (real GPS data doesn't have them).
OPTIONAL_CATEGORICAL = ["traffic_level", "weather"]

TARGET = "time_to_next_stop_min"


def get_X_y(segments: pd.DataFrame):
    """Return (X, y) ready for sklearn pipelines.

    Optional categorical features (traffic_level, weather) are included only
    when present — real GPS segments don't have them but the physics-generated
    dataset does.
    """
    present_cat = [c for c in CATEGORICAL_FEATURES if c in segments.columns]
    X = segments[NUMERIC_FEATURES + present_cat].copy()
    y = segments[TARGET].copy()
    return X, y


if __name__ == "__main__":
    seg = run_preprocessing()
    print(seg[NUMERIC_FEATURES + CATEGORICAL_FEATURES + [TARGET]].head(10).to_string())
