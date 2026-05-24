"""
scripts/ablation_study.py
---------------------------
ML feature ablation for Table (ML Feature Ablation).

Three configurations evaluated with HistGBM 5-fold CV on the
full combined dataset (6,590 segments):
  1. Full system: all features including traffic_level and weather
  2. Without weather/traffic: only GPS-derived features
  3. Distance-only baseline: distance_km alone

Output: ml_pipeline/saved_models/ablation_results.csv
"""

import os
import sys
import warnings
warnings.filterwarnings("ignore")
import numpy as np; np.seterr(divide='ignore', invalid='ignore', over='ignore')

import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from ml_pipeline.preprocessor import NUMERIC_FEATURES, TARGET
from ml_pipeline.model_trainer import build_preprocessor
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import KFold, cross_validate

RANDOM_STATE = 42
N_FOLDS = 5
OUT = os.path.join(ROOT, "ml_pipeline", "saved_models", "ablation_results.csv")
DATA = os.path.join(ROOT, "data", "combined_for_training.csv")

print("Loading combined dataset...")
df = pd.read_csv(DATA)
df["cluster_dest_cat"] = df["cluster_dest_cat"].astype(str)
print(f"  {len(df)} segments loaded")

kf = KFold(n_splits=N_FOLDS, shuffle=True, random_state=RANDOM_STATE)

FULL_CATS     = ["cluster_dest_cat", "vehicle_type", "traffic_level", "weather"]
REDUCED_CATS  = ["cluster_dest_cat", "vehicle_type"]

configs = [
    {
        "name":     "Full system (all features)",
        "num_cols": NUMERIC_FEATURES,
        "cat_cols": FULL_CATS,
    },
    {
        "name":     "Without weather / traffic features",
        "num_cols": NUMERIC_FEATURES,
        "cat_cols": REDUCED_CATS,
    },
    {
        "name":     "Distance-only baseline",
        "num_cols": ["distance_km"],
        "cat_cols": [],
    },
]

print(f"\n{'─'*65}")
print(f"  ML FEATURE ABLATION  (HistGBM, {N_FOLDS}-fold CV, n={len(df)})")
print(f"{'─'*65}")
print(f"  {'Configuration':<38} {'MAE':>7} {'±std':>6} {'R²':>8}")

rows = []
for cfg in configs:
    num_cols = cfg["num_cols"]
    cat_cols = [c for c in cfg["cat_cols"] if c in df.columns]
    feat_cols = num_cols + cat_cols
    X = df[feat_cols].copy()
    y = df[TARGET]

    if cat_cols:
        prep = build_preprocessor(cat_features=cat_cols)
        # rebuild to use only the num_cols we want
        from sklearn.compose import ColumnTransformer
        from sklearn.preprocessing import OneHotEncoder
        prep = ColumnTransformer([
            ("num", StandardScaler(), num_cols),
            ("cat", OneHotEncoder(handle_unknown="ignore", sparse_output=False), cat_cols),
        ], remainder="drop") if cat_cols else ColumnTransformer([
            ("num", StandardScaler(), num_cols),
        ], remainder="drop")
    else:
        from sklearn.compose import ColumnTransformer
        prep = ColumnTransformer([
            ("num", StandardScaler(), num_cols),
        ], remainder="drop")

    pipeline = Pipeline([
        ("prep", prep),
        ("model", HistGradientBoostingRegressor(
            max_iter=300, max_depth=6, learning_rate=0.05,
            min_samples_leaf=4, random_state=RANDOM_STATE,
        )),
    ])

    cv = cross_validate(
        pipeline, X, y,
        cv=kf,
        scoring=["neg_mean_absolute_error", "r2"],
        n_jobs=1,
    )
    mae     = -cv["test_neg_mean_absolute_error"].mean()
    mae_std =  cv["test_neg_mean_absolute_error"].std()
    r2      =  cv["test_r2"].mean()

    rows.append({
        "configuration": cfg["name"],
        "cv_mae":   round(mae, 2),
        "cv_mae_std": round(mae_std, 2),
        "cv_r2":    round(r2, 3),
    })
    print(f"  {cfg['name']:<38} {mae:>7.2f} {mae_std:>6.2f} {r2:>8.3f}")

df_out = pd.DataFrame(rows)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
df_out.to_csv(OUT, index=False)
print(f"\nSaved → {OUT}")
