"""
scripts/ablation_learning_curve.py
------------------------------------
Learning curve for real GPS segments only (no synthetic data).

Shows how model performance changes as real GPS data grows.
Useful for projecting future performance as the fleet collects more data.

Output: ml_pipeline/saved_models/ablation_learning_curve.csv
"""

import os
import sys
import warnings
warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from ml_pipeline.preprocessor import run_preprocessing, NUMERIC_FEATURES, TARGET
from ml_pipeline.model_trainer import build_preprocessor
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.pipeline import Pipeline
from sklearn.model_selection import KFold, cross_validate

RANDOM_STATE = 42
N_FOLDS = 5
OUT = os.path.join(ROOT, "ml_pipeline", "saved_models", "ablation_learning_curve.csv")

CAT_FEATURES = ["cluster_dest_cat", "vehicle_type"]  # only features present in real GPS

print("Loading real GPS segments...")
real = run_preprocessing(verbose=False)
n_total = len(real)
real["cluster_dest_cat"] = real["cluster_dest_cat"].astype(str)
print(f"  {n_total} real segments loaded")

# Sweep fractions from 10% to 100%
fractions = [0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00]
feat_cols = NUMERIC_FEATURES + CAT_FEATURES + [TARGET]

def make_pipeline():
    prep = build_preprocessor(cat_features=CAT_FEATURES)
    return Pipeline([
        ("prep", prep),
        ("model", HistGradientBoostingRegressor(
            max_iter=200, max_depth=5, learning_rate=0.05,
            min_samples_leaf=4, random_state=RANDOM_STATE,
        )),
    ])

kf = KFold(n_splits=N_FOLDS, shuffle=True, random_state=RANDOM_STATE)

print(f"\n{'─'*55}")
print(f"  REAL DATA LEARNING CURVE  (HistGBM, {N_FOLDS}-fold CV)")
print(f"{'─'*55}")
print(f"  {'Fraction':>10} {'Samples':>9} {'MAE':>8} {'R²':>8}")

rows = []
df_full = real[feat_cols].copy()
rng = np.random.default_rng(RANDOM_STATE)

for frac in fractions:
    n_samples = max(int(n_total * frac), N_FOLDS * 5)
    idx = rng.choice(n_total, size=min(n_samples, n_total), replace=False)
    df = df_full.iloc[idx].reset_index(drop=True)
    X = df[NUMERIC_FEATURES + CAT_FEATURES]
    y = df[TARGET]

    if len(X) < N_FOLDS * 3:
        continue

    cv = cross_validate(
        make_pipeline(), X, y,
        cv=kf, scoring=["neg_mean_absolute_error", "r2"], n_jobs=1,
    )
    mae = -cv["test_neg_mean_absolute_error"].mean()
    r2  =  cv["test_r2"].mean()
    rows.append({"fraction": frac, "n_samples": len(X),
                 "cv_mae": round(mae, 2), "cv_r2": round(r2, 3)})
    print(f"  {frac:>10.0%} {len(X):>9} {mae:>8.2f} {r2:>8.3f}")

df_out = pd.DataFrame(rows)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
df_out.to_csv(OUT, index=False)
print(f"\nSaved → {OUT}")
