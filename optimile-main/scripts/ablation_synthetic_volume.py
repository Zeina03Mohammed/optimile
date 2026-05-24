"""
scripts/ablation_synthetic_volume.py
-------------------------------------
Table 4: Effect of synthetic volume on HistGBM 5-fold CV performance.

Holds real GPS segments fixed (590 rows, traffic_level='Unknown',
weather='Unknown') and sweeps synthetic volume from 0 to 6,000.

Output:
  ml_pipeline/saved_models/ablation_synthetic_volume.csv
  Fig/augmentation_trajectory.png
"""

import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
import warnings
warnings.filterwarnings("ignore")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from ml_pipeline.preprocessor import (
    run_preprocessing, NUMERIC_FEATURES, CATEGORICAL_FEATURES, TARGET,
)
from ml_pipeline.model_trainer import build_preprocessor
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.pipeline import Pipeline
from sklearn.model_selection import KFold, cross_validate

SYNTHETIC_VOLUMES = [0, 500, 1000, 2000, 3000, 4500, 6000]
RANDOM_STATE = 42
N_FOLDS = 5
OUT_CSV = os.path.join(ROOT, "ml_pipeline", "saved_models", "ablation_synthetic_volume.csv")
FIG_DIR = os.path.join(ROOT, "Fig")
OUT_FIG = os.path.join(FIG_DIR, "augmentation_trajectory.png")

# ── Load data ─────────────────────────────────────────────────────────────────
print("Loading real GPS segments...")
real = run_preprocessing(verbose=False)
print(f"  {len(real)} real segments")

real = real.copy()
real["traffic_level"] = "Unknown"
real["weather"] = "Unknown"
real["cluster_dest_cat"] = real["cluster_dest_cat"].astype(str)

feat_cols = NUMERIC_FEATURES + CATEGORICAL_FEATURES + [TARGET]
df_real = real[feat_cols].copy()

print("Loading synthetic segments...")
syn_path = os.path.join(ROOT, "data", "cairo_delivery_segments.csv")
df_syn = pd.read_csv(syn_path)
df_syn["cluster_dest_cat"] = df_syn["cluster_dest_cat"].astype(str)
df_syn = df_syn[feat_cols].copy()
print(f"  {len(df_syn)} synthetic segments available")

# ── Pipeline builder ──────────────────────────────────────────────────────────
def make_pipeline():
    prep = build_preprocessor(cat_features=CATEGORICAL_FEATURES)
    return Pipeline([
        ("prep", prep),
        ("model", HistGradientBoostingRegressor(
            max_iter=300,
            max_depth=6,
            learning_rate=0.05,
            min_samples_leaf=4,
            random_state=RANDOM_STATE,
        )),
    ])

kf = KFold(n_splits=N_FOLDS, shuffle=True, random_state=RANDOM_STATE)

# ── Sweep ─────────────────────────────────────────────────────────────────────
print(f"\n{'─'*60}")
print(f"  AUGMENTATION SWEEP  ({N_FOLDS}-fold CV, HistGradientBoosting)")
print(f"{'─'*60}")
print(f"  {'Synthetic':>10} {'Total':>8} {'MAE':>8} {'R²':>8}")

rows = []
for vol in SYNTHETIC_VOLUMES:
    if vol == 0:
        df = df_real.copy()
    else:
        syn_sample = df_syn.sample(n=vol, random_state=RANDOM_STATE, replace=False)
        df = pd.concat([df_real, syn_sample], ignore_index=True)

    X = df[NUMERIC_FEATURES + CATEGORICAL_FEATURES]
    y = df[TARGET]

    cv = cross_validate(
        make_pipeline(), X, y,
        cv=kf,
        scoring=["neg_mean_absolute_error", "r2"],
        n_jobs=1,
    )
    mae = -cv["test_neg_mean_absolute_error"].mean()
    r2  =  cv["test_r2"].mean()

    rows.append({"synthetic_added": vol, "total": len(df), "cv_mae": round(mae, 2), "cv_r2": round(r2, 3)})
    print(f"  {vol:>10} {len(df):>8} {mae:>8.2f} {r2:>8.3f}")

results = pd.DataFrame(rows)
os.makedirs(os.path.dirname(OUT_CSV), exist_ok=True)
results.to_csv(OUT_CSV, index=False)
print(f"\nSaved → {OUT_CSV}")

# ── Figure ────────────────────────────────────────────────────────────────────
os.makedirs(FIG_DIR, exist_ok=True)

fig, ax1 = plt.subplots(figsize=(7, 4))
ax2 = ax1.twinx()

totals = results["total"].tolist()
maes   = results["cv_mae"].tolist()
r2s    = results["cv_r2"].tolist()

l1, = ax1.plot(totals, maes,  "o-", color="#E65100", linewidth=2, markersize=6, label="CV-MAE (min)")
l2, = ax2.plot(totals, r2s,   "s--", color="#1565C0", linewidth=2, markersize=6, label="CV-R²")

ax1.set_xlabel("Total training segments (real + synthetic)", fontsize=11)
ax1.set_ylabel("CV-MAE (min)", color="#E65100", fontsize=11)
ax2.set_ylabel("CV-R²", color="#1565C0", fontsize=11)
ax1.tick_params(axis="y", labelcolor="#E65100")
ax2.tick_params(axis="y", labelcolor="#1565C0")
ax2.set_ylim(0, 1.05)

for x, m, r in zip(totals, maes, r2s):
    ax1.annotate(f"{m:.2f}", (x, m), textcoords="offset points", xytext=(0, 8),
                 ha="center", fontsize=7.5, color="#E65100")
    ax2.annotate(f"{r:.3f}", (x, r), textcoords="offset points", xytext=(0, -14),
                 ha="center", fontsize=7.5, color="#1565C0")

ax1.set_title("Augmentation Trajectory: CV-MAE and CV-R² vs Synthetic Volume", fontsize=11, pad=10)
lines = [l1, l2]
ax1.legend(lines, [l.get_label() for l in lines], loc="upper right", fontsize=9)

plt.tight_layout()
plt.savefig(OUT_FIG, dpi=150, bbox_inches="tight")
print(f"Figure saved → {OUT_FIG}")
plt.close()
