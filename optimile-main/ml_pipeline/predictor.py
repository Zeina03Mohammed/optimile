"""
ml_pipeline/predictor.py
=========================
Runtime prediction interface consumed by the ALNS optimizer.

Design principles (senior ML + systems):
  - Lazy-loads the model on first call (no startup cost if ML is disabled)
  - Returns None gracefully when the model is not trained yet (ALNS falls
    back to its formula-based cost — no crashes)
  - Prediction input mirrors exactly what route_cost() knows at each leg:
      lat/lng of origin & destination, current clock time, route context
  - Confidence guard: if predicted time is physically impossible (< 0.5 min
    for any real leg or > 90 min) the prediction is discarded and the
    caller falls back to the formula — prevents model extrapolation from
    poisoning the optimizer
"""

import os
import math
from typing import Optional
import numpy as np
import pandas as pd

from ml_pipeline.preprocessor import NUMERIC_FEATURES, CATEGORICAL_FEATURES

_MODEL = None   # module-level singleton


# ─────────────────────────────────────────────────────────────────────────────
# LAZY LOADER
# ─────────────────────────────────────────────────────────────────────────────

def _load_model():
    global _MODEL
    if _MODEL is not None:
        return _MODEL
    try:
        from ml_pipeline.model_trainer import load_best_model
        _MODEL = load_best_model()
    except FileNotFoundError:
        _MODEL = None   # model not trained yet → caller uses fallback
    return _MODEL


# ─────────────────────────────────────────────────────────────────────────────
# GEOMETRY HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def _haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0
    lat1, lon1, lat2, lon2 = map(math.radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _bearing_deg(lat1, lon1, lat2, lon2):
    dlng = math.radians(lon2 - lon1)
    lat1, lat2 = math.radians(lat1), math.radians(lat2)
    x = math.sin(dlng) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlng)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


# ─────────────────────────────────────────────────────────────────────────────
# CLUSTER LOOKUP  (built once from training data)
# ─────────────────────────────────────────────────────────────────────────────

_CLUSTER_MODEL = None


def _get_cluster_model():
    """
    Returns a fitted DBSCAN instance (or None) that can be used to assign
    cluster_id to new coordinates at inference time.
    We re-run DBSCAN on the training set and store it as a KNN approximation:
    the nearest centroid cluster is used for new points.
    """
    global _CLUSTER_MODEL
    if _CLUSTER_MODEL is not None:
        return _CLUSTER_MODEL
    try:
        from ml_pipeline.preprocessor import load_raw, assign_clusters
        from sklearn.neighbors import NearestNeighbors
        import warnings
        warnings.filterwarnings("ignore")

        df = load_raw()           # verbose=False by default → no prints
        df = assign_clusters(df)  # verbose=False by default → no prints
        # Build a lookup: for each cluster (≠ noise) compute centroid
        clusters = df[df["cluster_id"] != -1].groupby("cluster_id")[["lat", "lng"]].mean()
        if len(clusters) == 0:
            return None
        centroids = clusters.values
        labels = clusters.index.tolist()
        nn = NearestNeighbors(n_neighbors=1, algorithm="ball_tree")
        nn.fit(centroids)
        _CLUSTER_MODEL = (nn, labels, centroids)
    except Exception:
        _CLUSTER_MODEL = None
    return _CLUSTER_MODEL


def _predict_cluster(lat, lng):
    """Return cluster_id string for a coordinate, or '-1' if unavailable."""
    cm = _get_cluster_model()
    if cm is None:
        return "-1"
    nn, labels, _ = cm
    dist, idx = nn.kneighbors([[lat, lng]])
    # If nearest centroid is > 2 km away → treat as noise
    if dist[0][0] > 2.0 / 111.0:  # ~2 km in degrees
        return "-1"
    return str(labels[idx[0][0]])


# ─────────────────────────────────────────────────────────────────────────────
# MAIN PREDICTION FUNCTION
# ─────────────────────────────────────────────────────────────────────────────

def predict_leg_time(
    lat_origin: float,
    lng_origin: float,
    lat_dest: float,
    lng_dest: float,
    current_time_min: float,    # minutes since midnight
    stop_index: int = 0,
    stops_in_route: int = 5,
    cluster_dest: str = None,   # pass if already known
) -> Optional[float]:
    """
    Predict the time (minutes) to complete leg (origin → destination).
    Returns None if the model is unavailable or the prediction is
    physically implausible — callers must handle None by falling back.

    Parameters
    ----------
    lat_origin, lng_origin : float
        GPS coordinates of the current stop (departure point).
    lat_dest, lng_dest : float
        GPS coordinates of the next stop.
    current_time_min : float
        Wall-clock minutes since midnight at the moment of departure.
        E.g. 8:30 AM → 510.0
    stop_index : int
        Index of this leg in the current route (0 = first leg).
    stops_in_route : int
        Total number of stops in the route for today.
    cluster_dest : str, optional
        Pre-computed cluster label for dest.  If None, auto-inferred.

    Returns
    -------
    float | None
        Predicted leg time in minutes, or None on failure.
    """
    model = _load_model()
    if model is None:
        return None

    try:
        hour = int(current_time_min // 60) % 24
        dow = 0          # day-of-week unknown at runtime → use Monday as neutral
        month = 6        # month unknown at runtime → use June as mid-year neutral

        dist_km = _haversine_km(lat_origin, lng_origin, lat_dest, lng_dest)
        bearing = _bearing_deg(lat_origin, lng_origin, lat_dest, lng_dest)

        if cluster_dest is None:
            cluster_dest = _predict_cluster(lat_dest, lng_dest)

        cluster_origin = _predict_cluster(lat_origin, lng_origin)
        is_same = int(cluster_origin == cluster_dest and cluster_dest != "-1")

        stops_remaining = max(stops_in_route - stop_index - 1, 0)
        route_progress = stop_index / max(stops_in_route - 1, 1)

        row = {
            "distance_km": dist_km,
            "hour_sin": math.sin(2 * math.pi * hour / 24),
            "hour_cos": math.cos(2 * math.pi * hour / 24),
            "dow_sin": math.sin(2 * math.pi * dow / 7),
            "dow_cos": math.cos(2 * math.pi * dow / 7),
            "month": month,
            "stop_index": stop_index,
            "stops_in_route": stops_in_route,
            "stops_remaining": stops_remaining,
            "route_progress": route_progress,
            "is_same_cluster": is_same,
            "bearing_deg": bearing,
            "lat_dest": lat_dest,
            "lng_dest": lng_dest,
            "cluster_dest_cat": str(cluster_dest),
        }

        X = pd.DataFrame([row])
        pred = float(model.predict(X)[0])

        # Sanity / confidence guard
        if pred < 0.5 or pred > 90.0:
            return None

        return pred

    except Exception:
        return None


# ─────────────────────────────────────────────────────────────────────────────
# BATCH PREDICTION  (useful for pre-computing cost matrices)
# ─────────────────────────────────────────────────────────────────────────────

def predict_cost_matrix(
    coords: list[tuple[float, float]],
    current_time_min: float,
    stops_in_route: int = None,
) -> Optional[np.ndarray]:
    """
    Compute an N×N predicted-time matrix for a list of (lat, lng) stops.
    Returns None if the model is unavailable.

    coords : list of (lat, lng) tuples
    current_time_min : float
    stops_in_route : int, defaults to len(coords)
    """
    model = _load_model()
    if model is None:
        return None

    model = _load_model()
    if model is None:
        return None

    n = len(coords)
    if stops_in_route is None:
        stops_in_route = n

    hour = int(current_time_min // 60) % 24
    dow, month = 0, 6

    # Build all N*(N-1) rows in one shot → single model.predict() call
    rows = []
    pairs = []   # (i, j) index for filling the matrix
    for i in range(n):
        for j in range(n):
            if i == j:
                continue
            lat1, lng1 = coords[i]
            lat2, lng2 = coords[j]
            dist_km = _haversine_km(lat1, lng1, lat2, lng2)
            bearing  = _bearing_deg(lat1, lng1, lat2, lng2)
            c_dest   = _predict_cluster(lat2, lng2)
            c_origin = _predict_cluster(lat1, lng1)
            is_same  = int(c_origin == c_dest and c_dest != "-1")
            stops_remaining = max(stops_in_route - i - 1, 0)
            route_progress  = i / max(stops_in_route - 1, 1)
            rows.append({
                "distance_km":    dist_km,
                "hour_sin":        math.sin(2 * math.pi * hour / 24),
                "hour_cos":        math.cos(2 * math.pi * hour / 24),
                "dow_sin":         math.sin(2 * math.pi * dow / 7),
                "dow_cos":         math.cos(2 * math.pi * dow / 7),
                "month":           month,
                "stop_index":      i,
                "stops_in_route":  stops_in_route,
                "stops_remaining": stops_remaining,
                "route_progress":  route_progress,
                "is_same_cluster": is_same,
                "bearing_deg":     bearing,
                "cluster_dest_cat": str(c_dest),
            })
            pairs.append((i, j))

    try:
        X = pd.DataFrame(rows)
        preds = model.predict(X)
    except Exception:
        return None

    matrix = np.zeros((n, n))
    for (i, j), pred in zip(pairs, preds):
        matrix[i][j] = float(pred) if 0.5 <= float(pred) <= 90.0 else 0.0

    return matrix


# ─────────────────────────────────────────────────────────────────────────────
# STATUS CHECK
# ─────────────────────────────────────────────────────────────────────────────

def is_model_available() -> bool:
    """Quick check — does not load the model into memory if not already loaded."""
    from ml_pipeline.model_trainer import BEST_MODEL_PATH
    return os.path.exists(BEST_MODEL_PATH)


def model_metadata() -> dict:
    """Returns metadata dict saved alongside the model, or empty dict."""
    from ml_pipeline.model_trainer import RESULTS_PATH
    if not os.path.exists(RESULTS_PATH):
        return {}
    import json
    with open(RESULTS_PATH) as f:
        return json.load(f)


# ─────────────────────────────────────────────────────────────────────────────
# STARTUP PRE-WARM
# ─────────────────────────────────────────────────────────────────────────────
# Load model + cluster centroids in a background thread at import time.
# By the time the first HTTP request arrives the cold-start cost is already
# paid — no 950 ms lag on the first /optimize call.

def _prewarm() -> None:
    try:
        _load_model()
        _get_cluster_model()
    except Exception:
        pass   # server still works without ML; ALNS falls back to formula


if is_model_available():
    import threading as _threading
    _threading.Thread(target=_prewarm, daemon=True).start()
