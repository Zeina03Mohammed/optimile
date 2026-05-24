"""
scripts/generate_figures.py
-----------------------------
Generates all 13 figures referenced in paper.tex.

Figures:
  1.  Fig/methodology.png           — System architecture diagram
  2.  Fig/delivery_time_dist.png    — Real GPS delivery time distribution
  3.  Fig/gps_cluster_map.png       — GPS stops with DBSCAN clusters
  4.  Fig/correlation_real.png      — Feature correlation heatmap (real GPS)
  5.  Fig/time_by_hour.png          — Delivery time by hour of day
  6.  Fig/dist_vs_time.png          — Distance vs travel time scatter
  7.  Fig/time_by_traffic.png       — Delivery time by traffic level (synthetic)
  8.  Fig/time_by_weather.png       — Delivery time by weather (synthetic)
  9.  Fig/model_mae_real.png        — CV-MAE & RMSE per model (real GPS)
  10. Fig/model_r2.png              — R² per model (real GPS & combined)
  11. Fig/actual_vs_predicted_real.png — Actual vs predicted (real GPS hold-out)
  12. Fig/augmentation_trajectory.png  — From ablation_synthetic_volume.csv
  13. Fig/alns_convergence.png      — ALNS convergence curve (15-stop instance)
"""

import os
import sys
import math
import warnings
warnings.filterwarnings("ignore")
import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

FIG_DIR = os.path.join(ROOT, "Fig")
os.makedirs(FIG_DIR, exist_ok=True)

BG      = "#F9F5F5"
GRID    = "#E0E0E0"
C_MAIN  = "#1565C0"
C_ACC   = "#E65100"
C_GRN   = "#2E7D32"
C_GOLD  = "#F57F17"

# ─────────────────────────────────────────────────────────────────────────────
# Load data
# ─────────────────────────────────────────────────────────────────────────────
print("Loading data...")
from ml_pipeline.preprocessor import (
    run_preprocessing, NUMERIC_FEATURES, CATEGORICAL_FEATURES, TARGET,
)
real = run_preprocessing(verbose=False)
real["cluster_dest_cat"] = real["cluster_dest_cat"].astype(str)
print(f"  {len(real)} real segments")

syn = pd.read_csv(os.path.join(ROOT, "data", "cairo_delivery_segments.csv"))
syn["cluster_dest_cat"] = syn["cluster_dest_cat"].astype(str)
print(f"  {len(syn)} synthetic segments")


def save(name):
    path = os.path.join(FIG_DIR, name)
    plt.savefig(path, dpi=150, bbox_inches="tight", facecolor=BG)
    plt.close()
    print(f"  Saved → {path}")


# ─────────────────────────────────────────────────────────────────────────────
# 1. methodology.png — system architecture
# ─────────────────────────────────────────────────────────────────────────────
print("\n[1] methodology.png")
fig, ax = plt.subplots(figsize=(9, 3.5), facecolor=BG)
ax.set_facecolor(BG)
ax.set_xlim(0, 10)
ax.set_ylim(0, 3)
ax.axis("off")

boxes = [
    (0.5, 1.25, "Real GPS\nData\n(590 segs)", C_MAIN),
    (2.3, 1.25, "Physics\nAugmentation\n(6,000 segs)", C_GRN),
    (4.3, 1.25, "HistGBM\nTravel Time\nPredictor", "#6A1B9A"),
    (6.3, 1.25, "BF Stop\nSequencing\n(neg. weights)", C_ACC),
    (8.2, 1.25, "ALNS\nRoute\nOptimiser", "#1565C0"),
]
for (x, y, label, color) in boxes:
    ax.add_patch(mpatches.FancyBboxPatch(
        (x - 0.7, y - 0.55), 1.4, 1.1,
        boxstyle="round,pad=0.1", facecolor=color, edgecolor="white",
        linewidth=1.5, zorder=3,
    ))
    ax.text(x, y, label, ha="center", va="center",
            fontsize=7.5, color="white", fontweight="bold", zorder=4)

for i in range(len(boxes) - 1):
    x1 = boxes[i][0] + 0.7
    x2 = boxes[i + 1][0] - 0.7
    y  = boxes[i][1]
    ax.annotate("", xy=(x2, y), xytext=(x1, y),
                arrowprops=dict(arrowstyle="->", color="#333", lw=1.5))

ax.text(5.0, 2.7, "Optimile System Architecture", ha="center", va="top",
        fontsize=12, fontweight="bold", color="#1A1A2E")
ax.text(1.9, 0.3, "Training Pipeline", ha="center", fontsize=8, color="#555",
        style="italic")
ax.text(7.25, 0.3, "Routing Engine", ha="center", fontsize=8, color="#555",
        style="italic")
ax.axvline(3.6, ymin=0.12, ymax=0.88, color="#999", linestyle="--", linewidth=0.8)
save("methodology.png")


# ─────────────────────────────────────────────────────────────────────────────
# 2. delivery_time_dist.png
# ─────────────────────────────────────────────────────────────────────────────
print("[2] delivery_time_dist.png")
fig, ax = plt.subplots(figsize=(7, 4), facecolor=BG)
ax.set_facecolor(BG)
ax.grid(axis="y", color=GRID, zorder=0)
ax.hist(real[TARGET], bins=40, color=C_MAIN, edgecolor="white", linewidth=0.5,
        zorder=3, alpha=0.85)
ax.axvline(real[TARGET].mean(), color=C_ACC, linestyle="--", linewidth=1.5,
           label=f"Mean = {real[TARGET].mean():.1f} min")
ax.axvline(real[TARGET].median(), color=C_GRN, linestyle=":", linewidth=1.5,
           label=f"Median = {real[TARGET].median():.1f} min")
ax.set_xlabel("Time to next stop (min)", fontsize=11)
ax.set_ylabel("Count", fontsize=11)
ax.set_title("Real GPS Inter-Stop Delivery Time Distribution (590 segments)", fontsize=11)
ax.legend(fontsize=9)
ax.spines[["top", "right"]].set_visible(False)
save("delivery_time_dist.png")


# ─────────────────────────────────────────────────────────────────────────────
# 3. gps_cluster_map.png — plot from raw GPS stops (all 36 zones)
# ─────────────────────────────────────────────────────────────────────────────
print("[3] gps_cluster_map.png")
from ml_pipeline.preprocessor import load_raw, assign_clusters
df_raw = load_raw(verbose=False)
df_clust = assign_clusters(df_raw, verbose=False)

fig, ax = plt.subplots(figsize=(7, 6), facecolor=BG)
ax.set_facecolor("#E8F4F8")
ax.grid(color=GRID, zorder=0)

cluster_ids = df_clust["cluster_id"].astype(int)
unique_clusters = sorted(cluster_ids.unique())
cmap = plt.cm.tab20
noise_mask = (cluster_ids == -1)

for cid in [c for c in unique_clusters if c != -1]:
    mask = cluster_ids == cid
    color = cmap(cid % 20)
    ax.scatter(
        df_clust.loc[mask, "lng"], df_clust.loc[mask, "lat"],
        s=18, color=color, alpha=0.7, zorder=3, label=f"Zone {cid}" if cid < 6 else None,
    )
if noise_mask.any():
    ax.scatter(
        df_clust.loc[noise_mask, "lng"], df_clust.loc[noise_mask, "lat"],
        s=10, color="#999", alpha=0.4, zorder=2, label="Noise",
    )

n_zones = len([c for c in unique_clusters if c != -1])
ax.set_xlabel("Longitude", fontsize=11)
ax.set_ylabel("Latitude", fontsize=11)
ax.set_title(f"DBSCAN Delivery Zones — Real Cairo GPS Stops ({n_zones} zones)", fontsize=11)
handles, labels = ax.get_legend_handles_labels()
ax.legend(handles[:7], labels[:7], fontsize=7.5, loc="upper right",
          framealpha=0.85, ncol=2)
ax.spines[["top", "right"]].set_visible(False)
save("gps_cluster_map.png")


# ─────────────────────────────────────────────────────────────────────────────
# 4. correlation_real.png
# ─────────────────────────────────────────────────────────────────────────────
print("[4] correlation_real.png")
corr_cols = ["distance_km", "hour_sin", "hour_cos", "stop_index",
             "stops_in_route", "route_progress", "is_same_cluster",
             "bearing_deg", "time_to_next_stop_min"]
present = [c for c in corr_cols if c in real.columns]
corr = real[present].corr()

fig, ax = plt.subplots(figsize=(8, 7), facecolor=BG)
im = ax.imshow(corr.values, cmap="RdBu_r", vmin=-1, vmax=1, aspect="auto")
ax.set_xticks(range(len(present)))
ax.set_yticks(range(len(present)))
labels = [c.replace("_", "\n") for c in present]
ax.set_xticklabels(labels, fontsize=7, rotation=45, ha="right")
ax.set_yticklabels(labels, fontsize=7)
for i in range(len(present)):
    for j in range(len(present)):
        v = corr.values[i, j]
        ax.text(j, i, f"{v:.2f}", ha="center", va="center",
                fontsize=6, color="white" if abs(v) > 0.5 else "#222")
plt.colorbar(im, ax=ax, fraction=0.03, pad=0.04)
ax.set_title("Feature Correlation Matrix — Real GPS Segments", fontsize=11, pad=12)
save("correlation_real.png")


# ─────────────────────────────────────────────────────────────────────────────
# 5. time_by_hour.png
# ─────────────────────────────────────────────────────────────────────────────
print("[5] time_by_hour.png")
if "hour" in real.columns:
    fig, ax = plt.subplots(figsize=(9, 4.5), facecolor=BG)
    ax.set_facecolor(BG)
    ax.grid(axis="y", color=GRID, zorder=0)
    hours = sorted(real["hour"].unique())
    data_by_hour = [real.loc[real["hour"] == h, TARGET].values for h in hours]
    bp = ax.boxplot(data_by_hour, positions=hours, widths=0.6,
                    patch_artist=True,
                    medianprops=dict(color=C_ACC, linewidth=2),
                    flierprops=dict(marker="o", markersize=2, alpha=0.3))
    for patch in bp["boxes"]:
        patch.set_facecolor(C_MAIN)
        patch.set_alpha(0.65)
    ax.set_xlabel("Hour of day", fontsize=11)
    ax.set_ylabel("Travel time (min)", fontsize=11)
    ax.set_title("Delivery Time Distribution by Hour (Real GPS)", fontsize=11)
    ax.spines[["top", "right"]].set_visible(False)
    save("time_by_hour.png")


# ─────────────────────────────────────────────────────────────────────────────
# 6. dist_vs_time.png
# ─────────────────────────────────────────────────────────────────────────────
print("[6] dist_vs_time.png")
fig, ax = plt.subplots(figsize=(7, 5), facecolor=BG)
ax.set_facecolor(BG)
ax.grid(color=GRID, zorder=0)
ax.scatter(real["distance_km"], real[TARGET], s=12, color=C_MAIN,
           alpha=0.45, zorder=3, label="Real GPS")
z = np.polyfit(real["distance_km"], real[TARGET], 1)
xr = np.linspace(real["distance_km"].min(), real["distance_km"].max(), 100)
ax.plot(xr, np.polyval(z, xr), color=C_ACC, linewidth=2, label="Linear fit")
ax.set_xlabel("Distance (km)", fontsize=11)
ax.set_ylabel("Travel time (min)", fontsize=11)
ax.set_title("Distance vs Travel Time — Real GPS Segments", fontsize=11)
ax.legend(fontsize=9)
ax.spines[["top", "right"]].set_visible(False)
corr_val = real["distance_km"].corr(real[TARGET])
ax.text(0.05, 0.93, f"r = {corr_val:.2f}", transform=ax.transAxes,
        fontsize=9, color="#333")
save("dist_vs_time.png")


# ─────────────────────────────────────────────────────────────────────────────
# 7. time_by_traffic.png
# ─────────────────────────────────────────────────────────────────────────────
print("[7] time_by_traffic.png")
fig, ax = plt.subplots(figsize=(8, 4.5), facecolor=BG)
ax.set_facecolor(BG)
ax.grid(axis="y", color=GRID, zorder=0)
traffic_order = ["Low", "Normal", "Medium", "High", "Jam"]
present_traffic = [t for t in traffic_order if t in syn["traffic_level"].values]
data_traffic = [syn.loc[syn["traffic_level"] == t, TARGET].values for t in present_traffic]
colors = [C_GRN, C_MAIN, C_GOLD, C_ACC, "#B71C1C"][:len(present_traffic)]
bp = ax.boxplot(data_traffic, labels=present_traffic, patch_artist=True,
                medianprops=dict(color="white", linewidth=2),
                flierprops=dict(marker="o", markersize=2, alpha=0.3))
for patch, c in zip(bp["boxes"], colors):
    patch.set_facecolor(c)
    patch.set_alpha(0.8)
ax.set_xlabel("Traffic level", fontsize=11)
ax.set_ylabel("Travel time (min)", fontsize=11)
ax.set_title("Delivery Time by Traffic Level (Synthetic Dataset)", fontsize=11)
ax.spines[["top", "right"]].set_visible(False)
save("time_by_traffic.png")


# ─────────────────────────────────────────────────────────────────────────────
# 8. time_by_weather.png
# ─────────────────────────────────────────────────────────────────────────────
print("[8] time_by_weather.png")
fig, ax = plt.subplots(figsize=(8, 4.5), facecolor=BG)
ax.set_facecolor(BG)
ax.grid(axis="y", color=GRID, zorder=0)
weather_order = ["Sunny", "Windy", "Rainy", "Foggy", "Sandstorm"]
present_weather = [w for w in weather_order if w in syn["weather"].values]
data_weather = [syn.loc[syn["weather"] == w, TARGET].values for w in present_weather]
wcolors = [C_GOLD, "#42A5F5", "#1565C0", "#78909C", "#8D6E63"][:len(present_weather)]
bp = ax.boxplot(data_weather, labels=present_weather, patch_artist=True,
                medianprops=dict(color="white", linewidth=2),
                flierprops=dict(marker="o", markersize=2, alpha=0.3))
for patch, c in zip(bp["boxes"], wcolors):
    patch.set_facecolor(c)
    patch.set_alpha(0.8)
ax.set_xlabel("Weather condition", fontsize=11)
ax.set_ylabel("Travel time (min)", fontsize=11)
ax.set_title("Delivery Time by Weather Condition (Synthetic Dataset)", fontsize=11)
ax.spines[["top", "right"]].set_visible(False)
save("time_by_weather.png")


# ─────────────────────────────────────────────────────────────────────────────
# 9. model_mae_real.png
# ─────────────────────────────────────────────────────────────────────────────
print("[9] model_mae_real.png")
# Real GPS only results (from paper Table 1)
real_models  = ["ElasticNet", "Random\nForest", "Gradient\nBoosting", "HistGBM"]
real_mae  = [11.31, 10.50, 11.10, 11.26]
real_rmse = [15.38, 14.85, 15.67, 15.94]
x = np.arange(len(real_models))
width = 0.35

fig, ax = plt.subplots(figsize=(8, 5), facecolor=BG)
ax.set_facecolor(BG)
ax.grid(axis="y", color=GRID, zorder=0)
b1 = ax.bar(x - width / 2, real_mae,  width, label="CV-MAE",  color=C_ACC,
            edgecolor="white", zorder=3)
b2 = ax.bar(x + width / 2, real_rmse, width, label="CV-RMSE", color=C_MAIN,
            edgecolor="white", zorder=3, alpha=0.8)
for bar, v in zip(b1, real_mae):
    ax.text(bar.get_x() + bar.get_width() / 2, v + 0.2, f"{v:.1f}",
            ha="center", va="bottom", fontsize=8.5, color=C_ACC, fontweight="bold")
for bar, v in zip(b2, real_rmse):
    ax.text(bar.get_x() + bar.get_width() / 2, v + 0.2, f"{v:.1f}",
            ha="center", va="bottom", fontsize=8.5, color=C_MAIN, fontweight="bold")
ax.set_xticks(x)
ax.set_xticklabels(real_models, fontsize=9)
ax.set_ylabel("Error (minutes)", fontsize=11)
ax.set_title("CV-MAE and CV-RMSE — Real GPS Segments (590 segments, 5-fold)", fontsize=10)
ax.legend(fontsize=9, framealpha=0.9)
ax.set_ylim(0, 19)
ax.spines[["top", "right"]].set_visible(False)
save("model_mae_real.png")


# ─────────────────────────────────────────────────────────────────────────────
# 10. model_r2.png
# ─────────────────────────────────────────────────────────────────────────────
print("[10] model_r2.png")
models_label = ["ElasticNet", "Random\nForest", "Gradient\nBoosting", "HistGBM"]
real_r2  = [0.2615, 0.3031, 0.2326, 0.2019]
comb_r2  = [0.6084, 0.9243, 0.9477, 0.9486]
x = np.arange(len(models_label))
width = 0.35

fig, ax = plt.subplots(figsize=(8, 5), facecolor=BG)
ax.set_facecolor(BG)
ax.grid(axis="y", color=GRID, zorder=0)
b1 = ax.bar(x - width / 2, real_r2, width, label="Real GPS (590)",
            color=C_ACC, edgecolor="white", zorder=3, alpha=0.85)
b2 = ax.bar(x + width / 2, comb_r2, width, label="Combined (6,590)",
            color=C_MAIN, edgecolor="white", zorder=3)
for bar, v in zip(b1, real_r2):
    ax.text(bar.get_x() + bar.get_width() / 2, v + 0.015, f"{v:.3f}",
            ha="center", va="bottom", fontsize=7.5, color=C_ACC)
for bar, v in zip(b2, comb_r2):
    ax.text(bar.get_x() + bar.get_width() / 2, v + 0.015, f"{v:.3f}",
            ha="center", va="bottom", fontsize=7.5, color=C_MAIN)
ax.set_xticks(x)
ax.set_xticklabels(models_label, fontsize=9)
ax.set_ylabel("CV-R²", fontsize=11)
ax.set_ylim(0, 1.1)
ax.set_title("CV-R² Comparison — Real GPS vs Combined Dataset", fontsize=10)
ax.legend(fontsize=9, framealpha=0.9)
ax.axhline(0.8, color="#9E9E9E", linestyle="--", linewidth=0.8)
ax.text(3.42, 0.82, "R²=0.80", fontsize=7.5, color="#757575")
ax.spines[["top", "right"]].set_visible(False)
save("model_r2.png")


# ─────────────────────────────────────────────────────────────────────────────
# 11. actual_vs_predicted_real.png
# ─────────────────────────────────────────────────────────────────────────────
print("[11] actual_vs_predicted_real.png")
from sklearn.model_selection import train_test_split
from ml_pipeline.model_trainer import build_preprocessor
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import StandardScaler, OneHotEncoder
from sklearn.metrics import r2_score, mean_absolute_error

real2 = real.copy()
real2["traffic_level"] = "Unknown"
real2["weather"] = "Unknown"
cat_cols = ["cluster_dest_cat", "vehicle_type", "traffic_level", "weather"]
feat_cols = NUMERIC_FEATURES + cat_cols
X_r = real2[feat_cols]
y_r = real2[TARGET]

X_train, X_test, y_train, y_test = train_test_split(
    X_r, y_r, test_size=0.20, random_state=42,
)

prep = ColumnTransformer([
    ("num", StandardScaler(), NUMERIC_FEATURES),
    ("cat", OneHotEncoder(handle_unknown="ignore", sparse_output=False), cat_cols),
], remainder="drop")
pipe = Pipeline([
    ("prep", prep),
    ("model", HistGradientBoostingRegressor(
        max_iter=300, max_depth=6, learning_rate=0.05,
        min_samples_leaf=4, random_state=42,
    )),
])
pipe.fit(X_train, y_train)
y_pred = pipe.predict(X_test)
r2 = r2_score(y_test, y_pred)
mae = mean_absolute_error(y_test, y_pred)

fig, ax = plt.subplots(figsize=(6, 5.5), facecolor=BG)
ax.set_facecolor(BG)
ax.grid(color=GRID, zorder=0)
ax.scatter(y_test, y_pred, s=20, color=C_MAIN, alpha=0.55, zorder=3)
lo = min(y_test.min(), y_pred.min())
hi = max(y_test.max(), y_pred.max())
ax.plot([lo, hi], [lo, hi], color=C_ACC, linewidth=1.8, linestyle="--",
        label="Perfect prediction", zorder=4)
ax.set_xlabel("Actual travel time (min)", fontsize=11)
ax.set_ylabel("Predicted travel time (min)", fontsize=11)
ax.set_title("Actual vs Predicted — HistGBM on Real GPS Hold-Out (20%)", fontsize=10)
ax.legend(fontsize=9)
ax.text(0.05, 0.92, f"R² = {r2:.3f}\nMAE = {mae:.2f} min",
        transform=ax.transAxes, fontsize=9, color="#333",
        verticalalignment="top",
        bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.8))
ax.spines[["top", "right"]].set_visible(False)
save("actual_vs_predicted_real.png")


# ─────────────────────────────────────────────────────────────────────────────
# 12. augmentation_trajectory.png — from CSV if available, else generate inline
# ─────────────────────────────────────────────────────────────────────────────
print("[12] augmentation_trajectory.png")
aug_csv = os.path.join(ROOT, "ml_pipeline", "saved_models", "ablation_synthetic_volume.csv")
if os.path.exists(aug_csv):
    aug = pd.read_csv(aug_csv)
    totals = aug["total"].tolist()
    maes   = aug["cv_mae"].tolist()
    r2s    = aug["cv_r2"].tolist()
else:
    # Fallback: use paper's Table 4 values
    totals = [590, 1090, 1590, 2590, 3590, 5090, 6590]
    maes   = [11.26, 8.25, 6.24, 4.35, 3.36, 2.68, 2.27]
    r2s    = [0.202, 0.603, 0.740, 0.852, 0.900, 0.931, 0.948]

fig, ax1 = plt.subplots(figsize=(7, 4), facecolor=BG)
ax1.set_facecolor(BG)
ax2 = ax1.twinx()

l1, = ax1.plot(totals, maes,  "o-", color=C_ACC,  linewidth=2, markersize=6,
               label="CV-MAE (min)")
l2, = ax2.plot(totals, r2s,   "s--", color=C_MAIN, linewidth=2, markersize=6,
               label="CV-R²")
ax1.set_xlabel("Total training segments (real + synthetic)", fontsize=11)
ax1.set_ylabel("CV-MAE (min)", color=C_ACC, fontsize=11)
ax2.set_ylabel("CV-R²", color=C_MAIN, fontsize=11)
ax1.tick_params(axis="y", labelcolor=C_ACC)
ax2.tick_params(axis="y", labelcolor=C_MAIN)
ax2.set_ylim(0, 1.05)
ax1.set_title("Augmentation Trajectory: CV-MAE and CV-R² vs Synthetic Volume",
              fontsize=10, pad=10)
lines = [l1, l2]
ax1.legend(lines, [l.get_label() for l in lines], loc="upper right", fontsize=9)
ax1.grid(color=GRID, zorder=0)
plt.tight_layout()
save("augmentation_trajectory.png")


# ─────────────────────────────────────────────────────────────────────────────
# 13. alns_convergence.png
# ─────────────────────────────────────────────────────────────────────────────
print("[13] alns_convergence.png")

def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0
    la1, lo1, la2, lo2 = map(math.radians, [lat1, lon1, lat2, lon2])
    dlat, dlon = la2 - la1, lo2 - lo1
    a = math.sin(dlat / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dlon / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


rng = np.random.default_rng(42)
n_stops = 15
lats = rng.uniform(29.9, 30.2, n_stops)
lngs = rng.uniform(31.1, 31.5, n_stops)
coords = list(zip(lats.tolist(), lngs.tolist()))

matrix = {}
for i in range(n_stops):
    for j in range(n_stops):
        if i != j:
            matrix[(i, j)] = haversine_km(coords[i][0], coords[i][1],
                                           coords[j][0], coords[j][1])

def rc(order):
    return sum(matrix[(order[i], order[i + 1])] for i in range(len(order) - 1))

# BF init: nearest neighbour
visited = [False] * n_stops
cur_order = [0]; visited[0] = True
for _ in range(n_stops - 1):
    cur = cur_order[-1]
    best_d, best_j = float("inf"), -1
    for j in range(n_stops):
        if not visited[j] and matrix[(cur, j)] < best_d:
            best_d, best_j = matrix[(cur, j)], j
    cur_order.append(best_j); visited[best_j] = True

current = list(cur_order)
current_cost = rc(current)
best = list(current)
best_cost = current_cost
T0 = best_cost * 0.15
alpha = (0.01 / max(T0, 1e-9)) ** (1.0 / 400)
T = T0
alns_rng = np.random.default_rng(42)

best_history = []
for _ in range(400):
    i, j = sorted(alns_rng.choice(range(1, n_stops), size=2, replace=False))
    candidate = current[:i] + current[i:j + 1][::-1] + current[j + 1:]
    cand_cost = rc(candidate)
    delta = cand_cost - current_cost
    if delta < 0 or alns_rng.random() < math.exp(-delta / max(T, 1e-9)):
        current = candidate
        current_cost = cand_cost
    if current_cost < best_cost:
        best = list(current)
        best_cost = current_cost
    best_history.append(best_cost)
    T *= alpha

fig, ax = plt.subplots(figsize=(7, 4), facecolor=BG)
ax.set_facecolor(BG)
ax.grid(color=GRID, zorder=0)
ax.plot(range(1, 401), best_history, color=C_MAIN, linewidth=1.8, zorder=3)
ax.fill_between(range(1, 401), best_history, best_history[-1],
                alpha=0.12, color=C_MAIN)
ax.axhline(best_cost, color=C_ACC, linestyle="--", linewidth=1.2,
           label=f"Final best = {best_cost:.3f} km")
ax.set_xlabel("ALNS Iteration", fontsize=11)
ax.set_ylabel("Best route cost (km)", fontsize=11)
ax.set_title("ALNS Convergence — 15-Stop Instance (random_state=42)", fontsize=11)
ax.legend(fontsize=9)
ax.spines[["top", "right"]].set_visible(False)
save("alns_convergence.png")

print(f"\nAll 13 figures saved to {FIG_DIR}/")
