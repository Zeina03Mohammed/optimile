"""
scripts/generate_visuals.py
----------------------------
Generates four publication-quality figures for paper.tex:

  1. Fig/methodology.png        — redesigned architecture (offline/online/adaptation)
  2. Fig/route_comparison.png   — before/after route with metrics on figure
  3. Fig/alns_flow.png          — ALNS destroy-repair flow diagram
  4. Fig/rerouting_xai.png      — rerouting + XAI decision diagram
"""

import os, sys, warnings
warnings.filterwarnings("ignore")
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
FIG_DIR = os.path.join(ROOT, "Fig")
os.makedirs(FIG_DIR, exist_ok=True)

BG      = "#F9F5F5"
BLUE    = "#1565C0"
ORANGE  = "#E65100"
GREEN   = "#2E7D32"
RED     = "#C62828"
PURPLE  = "#6A1B9A"
GRAY    = "#546E7A"
LIGHT   = "#ECEFF1"

def save(name):
    path = os.path.join(FIG_DIR, name)
    plt.savefig(path, dpi=150, bbox_inches="tight", facecolor=BG)
    plt.close()
    print(f"  Saved → {path}")


# ─────────────────────────────────────────────────────────────────────────────
# 1. methodology.png — three-band architecture (offline / runtime / adaptation)
# ─────────────────────────────────────────────────────────────────────────────
print("[1] methodology.png")
fig, ax = plt.subplots(figsize=(12, 7.5), facecolor=BG)
ax.set_facecolor(BG)
ax.set_xlim(0, 12)
ax.set_ylim(0, 7.5)
ax.axis("off")

# ── band helper ──────────────────────────────────────────────────────────────
def band(ax, y_bot, height, color, label):
    ax.add_patch(mpatches.FancyBboxPatch(
        (0.15, y_bot), 11.7, height,
        boxstyle="round,pad=0.12",
        facecolor=color + "18", edgecolor=color, linewidth=1.4, zorder=1,
    ))
    ax.text(0.38, y_bot + height - 0.22, label,
            fontsize=8.5, color=color, fontweight="bold", va="top", zorder=2)

band(ax, 5.2, 2.0,  BLUE,   "OFFLINE TRAINING")
band(ax, 2.7, 2.2,  ORANGE, "RUNTIME OPTIMIZATION")
band(ax, 0.25, 2.2, GREEN,  "LIVE ADAPTATION")

# ── box helper ───────────────────────────────────────────────────────────────
def box(ax, cx, cy, w, h, label, color, fontsize=7.8):
    ax.add_patch(mpatches.FancyBboxPatch(
        (cx - w/2, cy - h/2), w, h,
        boxstyle="round,pad=0.08", facecolor=color, edgecolor="white",
        linewidth=1.5, zorder=3,
    ))
    ax.text(cx, cy, label, ha="center", va="center",
            fontsize=fontsize, color="white", fontweight="bold", zorder=4,
            multialignment="center")

def arrow(ax, x1, y1, x2, y2, color="#555", lw=1.4, rad=0.0):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", color=color, lw=lw,
                                mutation_scale=12,
                                connectionstyle=f"arc3,rad={rad}"))

# ── OFFLINE TRAINING boxes ───────────────────────────────────────────────────
box(ax, 1.3,  6.2, 1.5, 0.75, "Real GPS\n590 records", BLUE)
box(ax, 3.15, 6.2, 1.5, 0.75, "Physics\nAugmentation\n+6,000 segs", BLUE)
box(ax, 5.0,  6.2, 1.5, 0.75, "DBSCAN\nZone Clustering\n36 zones", BLUE)
box(ax, 6.85, 6.2, 1.5, 0.75, "Feature\nEngineering\n16 features", BLUE)
box(ax, 8.7,  6.2, 1.65, 0.75, "HistGBM\nTravel-Time\nPredictor", PURPLE)
box(ax, 10.7, 6.2, 1.4, 0.75, "ML Cost\nMatrix", BLUE)

arrow(ax, 2.05, 6.2, 2.4, 6.2,  BLUE)
arrow(ax, 3.9,  6.2, 4.25, 6.2, BLUE)
arrow(ax, 5.75, 6.2, 6.1,  6.2, BLUE)
arrow(ax, 7.6,  6.2, 7.88, 6.2, BLUE)
arrow(ax, 9.52, 6.2, 10.0, 6.2, BLUE)

# ── RUNTIME OPTIMIZATION boxes ───────────────────────────────────────────────
box(ax, 1.3,  3.8, 1.5, 0.75, "Delivery\nOrders\n(stops, TW)", ORANGE)
box(ax, 3.15, 3.8, 1.5, 0.75, "Bellman-Ford\nInitializer\n(neg. weights)", ORANGE)
box(ax, 5.0,  3.8, 1.5, 0.75, "Fleet\nTransfer\n(load balance)", ORANGE)
box(ax, 6.85, 3.8, 1.5, 0.75, "ALNS\n400 iters\nMetropolis", ORANGE)
box(ax, 8.7,  3.8, 1.5, 0.75, "Optimized\nRoutes", ORANGE)

arrow(ax, 2.05, 3.8, 2.4,  3.8, ORANGE)
arrow(ax, 3.9,  3.8, 4.25, 3.8, ORANGE)
arrow(ax, 5.75, 3.8, 6.1,  3.8, ORANGE)
arrow(ax, 7.6,  3.8, 7.95, 3.8, ORANGE)

# ML cost matrix → BF (vertical)
arrow(ax, 10.7, 5.82, 10.7, 4.5, BLUE, lw=1.2)
ax.annotate("", xy=(3.15, 4.18), xytext=(10.7, 4.18),
            arrowprops=dict(arrowstyle="-|>", color=BLUE, lw=1.2,
                            mutation_scale=10,
                            connectionstyle="arc3,rad=0.0"))
ax.text(7.0, 4.25, "ML cost matrix", fontsize=6.5, color=BLUE,
        ha="center", style="italic")

# ── LIVE ADAPTATION boxes ─────────────────────────────────────────────────────
box(ax, 1.3,  1.35, 1.65, 0.75, "OSM Overpass\n+ Google\nDirections API", GREEN)
box(ax, 3.2,  1.35, 1.5, 0.75, "Hazard\nDetection\n& Scoring", GREEN)
box(ax, 5.0,  1.35, 1.5, 0.75, "Delay ≥ 1 min?\nRe-invoke\nALNS (300 iters)", GREEN)
box(ax, 6.85, 1.35, 1.5, 0.75, "XAI Audit\ncounterfactual\nconfidence badge", GREEN)
box(ax, 8.7,  1.35, 1.5, 0.75, "Dispatcher\nAlert +\nRerouted Path", GREEN)

arrow(ax, 2.12, 1.35, 2.45, 1.35, GREEN)
arrow(ax, 3.95, 1.35, 4.25, 1.35, GREEN)
arrow(ax, 5.75, 1.35, 6.1,  1.35, GREEN)
arrow(ax, 7.6,  1.35, 7.95, 1.35, GREEN)

# Optimized routes → hazard layer
arrow(ax, 8.7, 3.42, 8.7, 2.55, GRAY, lw=1.1)
ax.annotate("", xy=(1.3, 1.72), xytext=(1.3, 2.55),
            arrowprops=dict(arrowstyle="-|>", color=GRAY, lw=1.1,
                            mutation_scale=10))

# ── Feedback loop label ───────────────────────────────────────────────────────
ax.annotate("", xy=(1.3, 5.8), xytext=(1.3, 1.72),
            arrowprops=dict(arrowstyle="-|>", color="#90A4AE", lw=1.0,
                            mutation_scale=9, linestyle="dashed",
                            connectionstyle="arc3,rad=-0.7"))
ax.text(0.05, 3.8, "Feedback\nLoop", fontsize=6.5, color="#90A4AE",
        ha="center", style="italic", va="center")

# ── Layer labels (right side) ─────────────────────────────────────────────────
for y, lbl, col in [(6.2, "Layer I\nPrediction", BLUE),
                    (3.8, "Layer II\nOptimization", ORANGE),
                    (1.35, "Layer III\nAdaptation", GREEN)]:
    ax.text(11.82, y, lbl, fontsize=7, color=col, fontweight="bold",
            ha="center", va="center", multialignment="center")

ax.text(6.0, 7.35, "Optimile — Three-Layer Architecture", ha="center",
        fontsize=13, fontweight="bold", color="#1A1A2E")
save("methodology.png")


# ─────────────────────────────────────────────────────────────────────────────
# 2. route_comparison.png — before/after with metrics on figure
# ─────────────────────────────────────────────────────────────────────────────
print("[2] route_comparison.png")
from ml_pipeline.preprocessor import load_raw
df_raw = load_raw(verbose=False)
cairo_mask = df_raw["lat"].between(29.9, 30.2) & df_raw["lng"].between(31.1, 31.4)
cairo = df_raw[cairo_mask]
route_df = (cairo[cairo["driver_id"] == 64]
            .sort_values("datetime")
            .head(12)
            .reset_index(drop=True))
lats = route_df["lat"].values
lngs = route_df["lng"].values
n = len(lats)

def nn_order(lats, lngs):
    v = [0]; rem = list(range(1, len(lats)))
    while rem:
        last = v[-1]
        ds = [((lats[last]-lats[j])**2+(lngs[last]-lngs[j])**2)**0.5 for j in rem]
        best = rem[int(np.argmin(ds))]; v.append(best); rem.remove(best)
    return v

def route_km(order):
    return sum(((lats[order[i]]-lats[order[i+1]])**2
                +(lngs[order[i]]-lngs[order[i+1]])**2)**0.5 * 111
               for i in range(len(order)-1))

naive_order = list(range(n))
opt_order   = nn_order(lats, lngs)
naive_km    = route_km(naive_order)
opt_km      = route_km(opt_order)
pct_saved   = (naive_km - opt_km) / naive_km * 100
# estimate travel time at 4.66 km/h effective speed
naive_min   = naive_km / 4.66 * 60
opt_min     = opt_km   / 4.66 * 60

fig, axes = plt.subplots(1, 2, figsize=(13, 6), facecolor=BG)
fig.subplots_adjust(wspace=0.06)

# count cross-city backtrack legs removed (long legs shortened significantly)
def draw_route_panel(ax, order, lats, lngs, title, arc_color, panel_label,
                     km_val, min_val, highlight_crossings=False):
    ax.set_facecolor("#EEF4FB")
    ax.grid(color="#D5DFE8", zorder=0, linewidth=0.6)

    # identify "backtracking" legs in naive order (long legs that cut back)
    if highlight_crossings:
        leg_lengths = [
            ((lats[order[i]]-lats[order[i+1]])**2
             +(lngs[order[i]]-lngs[order[i+1]])**2)**0.5
            for i in range(len(order)-1)
        ]
        med_len = np.median(leg_lengths)
        long_legs = {i for i, l in enumerate(leg_lengths) if l > 2.5 * med_len}
    else:
        long_legs = set()

    for step in range(len(order) - 1):
        a, b = order[step], order[step+1]
        color = RED if step in long_legs else arc_color
        lw    = 2.4 if step in long_legs else 1.8
        ax.annotate("", xy=(lngs[b], lats[b]), xytext=(lngs[a], lats[a]),
                    arrowprops=dict(arrowstyle="-|>", color=color, lw=lw,
                                   mutation_scale=13,
                                   connectionstyle="arc3,rad=0.10"),
                    zorder=3)

    for step, idx in enumerate(order):
        c = GREEN if step == 0 else ORANGE if step == n-1 else arc_color
        ax.scatter(lngs[idx], lats[idx], s=100, color=c,
                   zorder=5, edgecolors="white", linewidths=1.4)
        ax.text(lngs[idx]+0.0005, lats[idx]+0.0005,
                str(step+1), fontsize=7.5, fontweight="bold",
                color="#1A1A2E", zorder=6)

    ax.set_title(title, fontsize=10.5, fontweight="bold",
                 color="#1A1A2E", pad=8)
    ax.set_xlabel("Longitude", fontsize=9)
    ax.set_ylabel("Latitude", fontsize=9)
    ax.spines[["top","right"]].set_visible(False)

    # metric badge bottom-right
    metric_txt = f"Distance:  {km_val:.1f} km\nEst. time: {min_val:.0f} min"
    ax.text(0.97, 0.04, metric_txt, transform=ax.transAxes,
            ha="right", va="bottom", fontsize=8.5, family="monospace",
            bbox=dict(boxstyle="round,pad=0.35", facecolor="white",
                      edgecolor=arc_color, linewidth=1.3))

    # crossings label for naive
    if highlight_crossings and long_legs:
        ax.text(0.03, 0.04,
                f"{len(long_legs)} backtrack segment(s)\nhighlighted in red",
                transform=ax.transAxes, ha="left", va="bottom",
                fontsize=7.5, color=RED,
                bbox=dict(boxstyle="round,pad=0.3", facecolor="white",
                          edgecolor=RED, linewidth=1.0, alpha=0.9))

draw_route_panel(axes[0], naive_order, lats, lngs,
                 "(a)  Unoptimized — GPS arrival sequence",
                 "#9E9E9E", "before",
                 naive_km, naive_min, highlight_crossings=True)

draw_route_panel(axes[1], opt_order, lats, lngs,
                 f"(b)  ALNS-Optimized  (−{pct_saved:.0f}% distance,  −{naive_min-opt_min:.0f} min)",
                 BLUE, "after",
                 opt_km, opt_min)

legend_els = [
    mpatches.Patch(color=GREEN,  label="Start stop"),
    mpatches.Patch(color=ORANGE, label="Final stop"),
    mpatches.Patch(color=RED,    label="Backtrack leg (removed by ALNS)"),
]
fig.legend(handles=legend_els, loc="lower center", ncol=3,
           fontsize=8.5, framealpha=0.9, bbox_to_anchor=(0.5, -0.01))

fig.suptitle("Before / After Route Optimization — Real 12-Stop Cairo Route (Driver 64)",
             fontsize=12, fontweight="bold", color="#1A1A2E", y=1.02)
save("route_comparison.png")


# ─────────────────────────────────────────────────────────────────────────────
# 3. alns_flow.png — ALNS destroy-repair cycle diagram
# ─────────────────────────────────────────────────────────────────────────────
print("[3] alns_flow.png")
fig, ax = plt.subplots(figsize=(9, 7), facecolor=BG)
ax.set_facecolor(BG)
ax.set_xlim(0, 9)
ax.set_ylim(0, 7)
ax.axis("off")

def fbox(ax, cx, cy, w, h, text, color, fontsize=8.5, text_color="white"):
    ax.add_patch(mpatches.FancyBboxPatch(
        (cx - w/2, cy - h/2), w, h,
        boxstyle="round,pad=0.1", facecolor=color, edgecolor="white",
        linewidth=1.5, zorder=3))
    ax.text(cx, cy, text, ha="center", va="center",
            fontsize=fontsize, color=text_color, fontweight="bold", zorder=4,
            multialignment="center")

def farr(ax, x1, y1, x2, y2, color="#555", lw=1.5, label="", rad=0.0):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", color=color, lw=lw,
                                mutation_scale=13,
                                connectionstyle=f"arc3,rad={rad}"))
    if label:
        mx, my = (x1+x2)/2, (y1+y2)/2
        ax.text(mx+0.08, my, label, fontsize=7, color=color)

def diamond(ax, cx, cy, w, h, text, color):
    dx, dy = w/2, h/2
    xs = [cx, cx+dx, cx, cx-dx, cx]
    ys = [cy+dy, cy, cy-dy, cy, cy+dy]
    ax.fill(xs, ys, color=color, zorder=3, alpha=0.92)
    ax.plot(xs, ys, color="white", lw=1.4, zorder=4)
    ax.text(cx, cy, text, ha="center", va="center",
            fontsize=8, color="white", fontweight="bold", zorder=5,
            multialignment="center")

# Column positions
cx_main = 4.5

# Nodes top to bottom
fbox(ax, cx_main, 6.4, 2.6, 0.6, "BF Initial Route  (constraint-ordered)", ORANGE)
farr(ax, cx_main, 6.1, cx_main, 5.65, GRAY)

fbox(ax, cx_main, 5.3, 2.6, 0.6, "Select Destroy Operator (roulette-wheel)", BLUE)
farr(ax, cx_main, 5.0, cx_main, 4.55, GRAY)

# Destroy options side boxes
fbox(ax, 1.65, 4.2, 1.6, 0.6, "Random\nRemoval", BLUE, fontsize=7.5)
fbox(ax, cx_main, 4.2, 1.6, 0.6, "Worst\nRemoval", BLUE, fontsize=7.5)
fbox(ax, 7.35, 4.2, 1.6, 0.6, "Fragile\nTargeting", BLUE, fontsize=7.5)

ax.annotate("", xy=(1.65, 4.5), xytext=(3.45, 4.65),
            arrowprops=dict(arrowstyle="-|>", color=BLUE, lw=1.0, mutation_scale=9))
ax.annotate("", xy=(cx_main, 4.5), xytext=(cx_main, 4.65),
            arrowprops=dict(arrowstyle="-|>", color=BLUE, lw=1.0, mutation_scale=9))
ax.annotate("", xy=(7.35, 4.5), xytext=(5.55, 4.65),
            arrowprops=dict(arrowstyle="-|>", color=BLUE, lw=1.0, mutation_scale=9))

# Converge to repair select
farr(ax, 1.65, 3.9, cx_main-0.9, 3.55, BLUE)
farr(ax, cx_main, 3.9, cx_main, 3.55, BLUE)
farr(ax, 7.35, 3.9, cx_main+0.9, 3.55, BLUE)

fbox(ax, cx_main, 3.25, 2.6, 0.55, "Select Repair Operator (roulette-wheel)", PURPLE)
farr(ax, cx_main, 2.97, cx_main, 2.65, GRAY)

fbox(ax, 2.5, 2.3, 1.8, 0.6, "Greedy\nInsertion", PURPLE, fontsize=7.5)
fbox(ax, 6.5, 2.3, 1.8, 0.6, "Regret\nInsertion", PURPLE, fontsize=7.5)
ax.annotate("", xy=(2.5, 2.6), xytext=(3.6, 2.75),
            arrowprops=dict(arrowstyle="-|>", color=PURPLE, lw=1.0, mutation_scale=9))
ax.annotate("", xy=(6.5, 2.6), xytext=(5.4, 2.75),
            arrowprops=dict(arrowstyle="-|>", color=PURPLE, lw=1.0, mutation_scale=9))
farr(ax, 2.5, 2.0, 3.65, 1.65, PURPLE)
farr(ax, 6.5, 2.0, 5.35, 1.65, PURPLE)

fbox(ax, cx_main, 1.38, 2.8, 0.55, "Evaluate Cost Δ — Accept / Reject (Metropolis)", ORANGE)
farr(ax, cx_main, 1.10, cx_main, 0.78, GRAY)

fbox(ax, cx_main, 0.5, 2.6, 0.55, "Update Operator Weights  (score decay)", GREEN)

# Loop-back arrow
ax.annotate("", xy=(7.4, 5.3), xytext=(7.4, 0.5),
            arrowprops=dict(arrowstyle="-|>", color="#90A4AE", lw=1.2,
                            mutation_scale=11,
                            connectionstyle="arc3,rad=-0.35"))
ax.text(8.55, 2.9, "400\niterations", fontsize=7.5, color="#90A4AE",
        ha="center", va="center", style="italic")

# Accept badge
ax.text(3.05, 1.38, "Δ<0 → always\naccept", fontsize=6.8, color=ORANGE,
        ha="right", va="center", style="italic")
ax.text(5.95, 1.38, "Δ≥0 → accept\nwith P=e^{-Δ/T}", fontsize=6.8, color=ORANGE,
        ha="left", va="center", style="italic")

ax.text(cx_main, 6.92, "ALNS Destroy-Repair Optimization Cycle",
        ha="center", fontsize=12, fontweight="bold", color="#1A1A2E")
save("alns_flow.png")


# ─────────────────────────────────────────────────────────────────────────────
# 4. rerouting_xai.png — rerouting + XAI decision diagram
# ─────────────────────────────────────────────────────────────────────────────
print("[4] rerouting_xai.png")
fig, ax = plt.subplots(figsize=(10, 6.5), facecolor=BG)
ax.set_facecolor(BG)
ax.set_xlim(0, 10)
ax.set_ylim(0, 6.5)
ax.axis("off")

def rbox(cx, cy, w, h, text, color, fontsize=8.5):
    ax.add_patch(mpatches.FancyBboxPatch(
        (cx - w/2, cy - h/2), w, h,
        boxstyle="round,pad=0.1", facecolor=color, edgecolor="white",
        linewidth=1.5, zorder=3))
    ax.text(cx, cy, text, ha="center", va="center",
            fontsize=fontsize, color="white", fontweight="bold", zorder=4,
            multialignment="center")

def rdiamond(cx, cy, w, h, text):
    dx, dy = w/2, h/2
    xs = [cx, cx+dx, cx, cx-dx, cx]
    ys = [cy+dy, cy, cy-dy, cy, cy+dy]
    ax.fill(xs, ys, color=ORANGE, zorder=3, alpha=0.92)
    ax.plot(xs, ys, color="white", lw=1.4, zorder=4)
    ax.text(cx, cy, text, ha="center", va="center",
            fontsize=8, color="white", fontweight="bold", zorder=5,
            multialignment="center")

def rarr(x1, y1, x2, y2, color="#555", lw=1.5, label="", label_side="right"):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", color=color, lw=lw,
                                mutation_scale=13))
    if label:
        mx, my = (x1+x2)/2, (y1+y2)/2
        off = 0.12 if label_side == "right" else -0.12
        ax.text(mx + off, my, label, fontsize=7.5, color=color,
                ha="left" if label_side == "right" else "right", va="center")

# Left-column: data sources → detection
rbox(1.4, 5.8, 1.9, 0.6, "OSM Overpass API\n(road surfaces, floods)", GREEN)
rbox(4.0, 5.8, 1.9, 0.6, "Google Directions API\n(live duration_in_traffic)", GREEN)
rbox(6.6, 5.8, 1.9, 0.6, "Dispatcher Report\n(manual incident flag)", GREEN)

rarr(1.4, 5.5, 2.7, 4.9, GREEN)
rarr(4.0, 5.5, 4.0, 4.9, GREEN)
rarr(6.6, 5.5, 5.3, 4.9, GREEN)

rbox(4.0, 4.6, 3.2, 0.6, "Hazard Detection & Severity Scoring\nroad_closed +200 min  |  traffic_jam ×35×sev  |  accident ×60×sev", GREEN, fontsize=7.3)

rarr(4.0, 4.3, 4.0, 3.85, GRAY)
rdiamond(4.0, 3.5, 2.6, 0.7, "Estimated delay\n≥ 1.0 min?")

# YES branch
rarr(5.3, 3.5, 6.8, 3.5, ORANGE, label="YES", label_side="right")
rbox(7.9, 3.5, 2.0, 0.65, "Re-invoke ALNS\n300 iters from\ncurrent position", ORANGE)
rarr(7.9, 3.17, 7.9, 2.65, ORANGE)

# NO branch
rarr(4.0, 3.15, 4.0, 2.65, GRAY, label="NO", label_side="right")
rbox(4.0, 2.35, 2.2, 0.55, "Continue on\ncurrent route", GRAY)

# XAI module
rbox(7.9, 2.35, 2.0, 0.65, "XAI Audit Record\ngenerated", PURPLE)
rarr(7.9, 2.02, 7.9, 1.55, PURPLE)

# XAI fields
xai_items = [
    (5.7,  1.15, "counterfactual\n(plain-English\nexplanation)", PURPLE),
    (7.4,  1.15, "confidence\nHIGH / MED / LOW\n(savings threshold)", PURPLE),
    (9.05, 1.15, "event_log\n(per-leg penalties,\ntime-window flags)", PURPLE),
]
for cx, cy, txt, col in xai_items:
    rbox(cx, cy, 1.55, 0.75, txt, col, fontsize=7)
    rarr(7.9, 1.55, cx, 1.52, PURPLE)

# Output: rerouted path
rarr(7.9, 0.52, 4.0, 0.52, ORANGE)
rbox(4.0, 0.25, 2.4, 0.45, "Rerouted Path + XAI Record → Dispatcher", ORANGE, fontsize=7.8)

ax.text(5.0, 6.32, "Live Hazard Detection, Rerouting & XAI Audit Pipeline",
        ha="center", fontsize=12, fontweight="bold", color="#1A1A2E")
save("rerouting_xai.png")

print("\nDone. All four figures saved to Fig/")
