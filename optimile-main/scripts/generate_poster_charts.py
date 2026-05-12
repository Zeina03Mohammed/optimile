"""
scripts/generate_poster_charts.py
-----------------------------------
Generates poster-ready ML result charts matching the academic poster style
seen in MindMend / Aqua Shield sample posters.

Output: ml_pipeline/saved_models/poster_chart.png
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
import os

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "ml_pipeline", "saved_models")
OUT     = os.path.join(OUT_DIR, "poster_chart.png")

# ── Data ──────────────────────────────────────────────────────────────────────
models = ["ElasticNet", "Random\nForest", "Gradient\nBoosting", "Hist Gradient\nBoosting"]

# CV results
cv_r2   = [0.4246, 0.7711, 0.8171, 0.8219]
cv_mae  = [6.996,  4.324,  3.705,  3.643]
cv_rmse = [10.572, 6.657,  5.958,  5.874]

# Hold-out test results (best model only — HistGradientBoosting)
test_r2   = [None, None, None, 0.829]
test_mae  = [None, None, None, 3.75]
test_rmse = [None, None, None, 6.05]

x      = np.arange(len(models))
width  = 0.25

# ── Color palette matching academic poster style ───────────────────────────────
C_R2   = "#2196F3"   # blue  — R²
C_MAE  = "#FF9800"   # orange — MAE
C_RMSE = "#4CAF50"   # green  — RMSE
C_TEST = "#E91E63"   # pink   — hold-out accent

BG     = "#F9F5F5"
GRID   = "#E0E0E0"

# ── Figure: two panels ────────────────────────────────────────────────────────
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5.5), facecolor=BG)
fig.subplots_adjust(wspace=0.38, top=0.82, bottom=0.18, left=0.07, right=0.97)

fig.suptitle("ML Model Comparison — Delivery Time Prediction",
             fontsize=14, fontweight="bold", y=0.97, color="#1A1A2E")

# ─────────────────────────────────────────────────────────────────────────────
# Panel 1 — R² comparison (CV)
# ─────────────────────────────────────────────────────────────────────────────
ax1.set_facecolor(BG)
ax1.grid(axis="y", color=GRID, zorder=0)

bars = ax1.bar(x, cv_r2, width=0.5, color=[C_R2]*3 + [C_TEST],
               edgecolor="white", linewidth=1.2, zorder=3)

# Value labels on bars
for bar, v in zip(bars, cv_r2):
    ax1.text(bar.get_x() + bar.get_width()/2, v + 0.012,
             f"{v:.3f}", ha="center", va="bottom",
             fontsize=9.5, fontweight="bold",
             color="#1A1A2E" if v < 0.82 else C_TEST)

# Mark best model
ax1.bar(x[-1], cv_r2[-1], width=0.5, color=C_TEST,
        edgecolor="#C2185B", linewidth=1.8, zorder=4)

ax1.set_ylim(0, 1.05)
ax1.set_ylabel("R² Score  (higher = better)", fontsize=10, labelpad=6)
ax1.set_title("Cross-Validation R² (5-fold)", fontsize=11, fontweight="bold",
              color="#1A1A2E", pad=8)
ax1.set_xticks(x)
ax1.set_xticklabels(models, fontsize=9)
ax1.tick_params(axis="both", which="both", length=0)
ax1.spines[["top","right","left","bottom"]].set_visible(False)

# Horizontal reference line at R²=0.8
ax1.axhline(0.80, color="#9E9E9E", linestyle="--", linewidth=0.9, zorder=2)
ax1.text(3.32, 0.805, "R²=0.80", fontsize=7.5, color="#757575")

best_patch  = mpatches.Patch(color=C_TEST, label="Best model")
other_patch = mpatches.Patch(color=C_R2,  label="Other models")
ax1.legend(handles=[best_patch, other_patch], fontsize=8.5,
           framealpha=0.85, loc="upper left")

# ─────────────────────────────────────────────────────────────────────────────
# Panel 2 — MAE & RMSE comparison (CV)
# ─────────────────────────────────────────────────────────────────────────────
ax2.set_facecolor(BG)
ax2.grid(axis="y", color=GRID, zorder=0)

b_mae  = ax2.bar(x - width/2, cv_mae,  width=width, label="MAE (min)",
                 color=C_MAE,  edgecolor="white", linewidth=1.2, zorder=3)
b_rmse = ax2.bar(x + width/2, cv_rmse, width=width, label="RMSE (min)",
                 color=C_RMSE, edgecolor="white", linewidth=1.2, zorder=3)

for bar, v in zip(b_mae, cv_mae):
    ax2.text(bar.get_x() + bar.get_width()/2, v + 0.15,
             f"{v:.2f}", ha="center", va="bottom", fontsize=8.5, fontweight="bold",
             color="#E65100")

for bar, v in zip(b_rmse, cv_rmse):
    ax2.text(bar.get_x() + bar.get_width()/2, v + 0.15,
             f"{v:.2f}", ha="center", va="bottom", fontsize=8.5, fontweight="bold",
             color="#1B5E20")

ax2.set_ylabel("Error (minutes)  (lower = better)", fontsize=10, labelpad=6)
ax2.set_title("Cross-Validation MAE & RMSE (5-fold)", fontsize=11,
              fontweight="bold", color="#1A1A2E", pad=8)
ax2.set_xticks(x)
ax2.set_xticklabels(models, fontsize=9)
ax2.tick_params(axis="both", which="both", length=0)
ax2.spines[["top","right","left","bottom"]].set_visible(False)
ax2.set_ylim(0, 13)
ax2.legend(fontsize=9, framealpha=0.85)

# ─────────────────────────────────────────────────────────────────────────────
# Footer: hold-out test metrics for the best model
# ─────────────────────────────────────────────────────────────────────────────
footer = (
    "Best model  (Hist Gradient Boosting) — Hold-out Test Set:   "
    "MAE = 3.75 min   |   RMSE = 6.05 min   |   R² = 0.829"
)
fig.text(0.5, 0.02, footer, ha="center", va="bottom",
         fontsize=9.5, color="white",
         bbox=dict(boxstyle="round,pad=0.4", facecolor="#1565C0",
                   edgecolor="none", alpha=0.92))

plt.savefig(OUT, dpi=180, bbox_inches="tight", facecolor=BG)
print(f"Chart saved → {OUT}")
plt.close()
