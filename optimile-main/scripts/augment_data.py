"""
scripts/augment_data.py
-----------------------
Synthesizes additional training segments using SDV GaussianCopulaSynthesizer,
operating on CLEAN SEGMENTS (after preprocessing), not raw GPS rows.

This avoids the noise introduced by reconstructing fake GPS rows.

Run:   python3 scripts/augment_data.py
Output: data/segments_augmented.csv  (real + synthetic segments, ready for training)
"""

import os
import sys
import numpy as np
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

OUT = os.path.join(ROOT, "data", "segments_augmented.csv")

# ── Step 1: Get real clean segments from preprocessor ─────────────────────────
print("Running preprocessor to get clean segments...")
from ml_pipeline.preprocessor import run_preprocessing, NUMERIC_FEATURES, CATEGORICAL_FEATURES, TARGET

segments = run_preprocessing(verbose=True)
print(f"\nReal segments: {len(segments)}")

FEATURE_COLS = NUMERIC_FEATURES + CATEGORICAL_FEATURES + [TARGET]
df_real = segments[FEATURE_COLS].copy()

# ── Step 2: SDV synthesis on the segment DataFrame ────────────────────────────
print("\nFitting SDV GaussianCopulaSynthesizer on segment features...")

from sdv.single_table import GaussianCopulaSynthesizer
from sdv.metadata import SingleTableMetadata

metadata = SingleTableMetadata()
metadata.detect_from_dataframe(df_real)

# Ensure correct sdtypes
metadata.update_column("cluster_dest_cat", sdtype="categorical")
metadata.update_column("vehicle_type",     sdtype="categorical")
metadata.update_column("is_same_cluster",  sdtype="numerical")

synthesizer = GaussianCopulaSynthesizer(metadata)
synthesizer.fit(df_real)

TARGET_TOTAL = 3000
n_synthetic  = max(0, TARGET_TOTAL - len(df_real))
print(f"Generating {n_synthetic} synthetic segments...")

synthetic = synthesizer.sample(num_rows=n_synthetic)

# Clamp to valid ranges
synthetic[TARGET]               = synthetic[TARGET].clip(1, 90)
synthetic["distance_km"]        = synthetic["distance_km"].clip(0.05, 50)
synthetic["route_progress"]     = synthetic["route_progress"].clip(0, 1)
synthetic["is_same_cluster"]    = synthetic["is_same_cluster"].round().clip(0, 1).astype(int)
synthetic["stop_index"]         = synthetic["stop_index"].clip(0).round().astype(int)
synthetic["stops_in_route"]     = synthetic["stops_in_route"].clip(2).round().astype(int)
synthetic["stops_remaining"]    = synthetic["stops_remaining"].clip(0).round().astype(int)
synthetic["bearing_deg"]        = synthetic["bearing_deg"].clip(0, 360)
synthetic["vehicle_type"]       = synthetic["vehicle_type"].str.lower().str.strip()
synthetic["vehicle_type"]       = synthetic["vehicle_type"].where(
    synthetic["vehicle_type"].isin(["car", "van", "motorcycle"]), "car"
)

# ── Step 3: Combine and save ───────────────────────────────────────────────────
df_combined = pd.concat([df_real, synthetic], ignore_index=True)
df_combined.to_csv(OUT, index=False)

print(f"\nReal segments:      {len(df_real)}")
print(f"Synthetic segments: {len(synthetic)}")
print(f"Total:              {len(df_combined)}")
print(f"\nVehicle type distribution:")
print(df_combined["vehicle_type"].value_counts())
print(f"\nTarget stats (combined):")
print(df_combined[TARGET].describe().round(2))
print(f"\nOutput: {OUT}")
print("Done.")
