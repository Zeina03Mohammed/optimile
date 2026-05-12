"""
ml_pipeline/model_trainer.py
=============================
Trains and compares multiple regression models for inter-stop time
prediction.  Uses 5-fold cross-validation throughout because the
dataset is small (~800 segments), making a single train/test split
unreliable.

Models compared:
  1. LinearRegression          — interpretable baseline
  2. Ridge (alpha=1.0)         — L2-regularised baseline
  3. RandomForestRegressor     — handles non-linearity, interaction effects
  4. GradientBoostingRegressor — often best on tabular, sequential errors
  5. HistGradientBoosting      — fast GBM variant, handles categoricals natively

Selection criterion: lowest mean CV-MAE (minutes).  MAE is chosen over
RMSE because large outlier gaps (edge of distribution) should not dominate
the metric — we care about *average* prediction error in operational use.

The winner is saved as  ml_pipeline/saved_models/best_model.pkl
"""

import os
import json
import joblib
import warnings
import numpy as np

# Suppress numpy overflow/divide-by-zero that appear during LinearRegression
# fitting when OHE produces near-singular matrices on small datasets
np.seterr(divide="ignore", invalid="ignore", over="ignore")
import pandas as pd

from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import StandardScaler, OneHotEncoder
from sklearn.linear_model import ElasticNet
from sklearn.ensemble import (
    RandomForestRegressor,
    GradientBoostingRegressor,
    HistGradientBoostingRegressor,
)
from sklearn.model_selection import KFold, cross_validate
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

from ml_pipeline.preprocessor import (
    run_preprocessing,
    get_X_y,
    NUMERIC_FEATURES,
    CATEGORICAL_FEATURES,
    TARGET,
)

warnings.filterwarnings("ignore")

MODELS_DIR = os.path.join(os.path.dirname(__file__), "saved_models")
BEST_MODEL_PATH = os.path.join(MODELS_DIR, "best_model.pkl")
RESULTS_PATH = os.path.join(MODELS_DIR, "comparison_results.json")

RANDOM_STATE = 42
N_FOLDS = 5


# ─────────────────────────────────────────────────────────────────────────────
# PREPROCESSING STEP  (shared by all models)
# ─────────────────────────────────────────────────────────────────────────────

def build_preprocessor(cat_features=None):
    if cat_features is None:
        cat_features = CATEGORICAL_FEATURES
    return ColumnTransformer(
        transformers=[
            ("num", StandardScaler(), NUMERIC_FEATURES),
            (
                "cat",
                OneHotEncoder(handle_unknown="ignore", sparse_output=False),
                cat_features,
            ),
        ],
        remainder="drop",
    )


# ─────────────────────────────────────────────────────────────────────────────
# MODEL REGISTRY
# ─────────────────────────────────────────────────────────────────────────────

def get_candidate_models(cat_features=None):
    """
    Returns dict of {name: sklearn estimator}.
    All are wrapped in a Pipeline with the shared preprocessor.
    """
    prep = lambda: build_preprocessor(cat_features)

    candidates = {
        # LinearRegression omitted: numerically unstable with sparse OHE on
        # small datasets (near-singular matrices → scipy LAPACK overflow).
        # Ridge with alpha=1.0 is the regularised baseline that avoids this.
        # ElasticNet: L1+L2 regularised linear baseline. Avoids the LAPACK
        # overflow that Ridge triggers when rare OHE clusters are all-zero
        # in a CV fold; coordinate descent is numerically more stable here.
        "ElasticNet": Pipeline(
            [("prep", prep()), ("model", ElasticNet(alpha=1.0, l1_ratio=0.5, max_iter=2000))]
        ),
        "RandomForest": Pipeline(
            [
                ("prep", prep()),
                (
                    "model",
                    RandomForestRegressor(
                        n_estimators=300,
                        max_depth=12,
                        min_samples_leaf=4,
                        random_state=RANDOM_STATE,
                        n_jobs=-1,
                    ),
                ),
            ]
        ),
        "GradientBoosting": Pipeline(
            [
                ("prep", prep()),
                (
                    "model",
                    GradientBoostingRegressor(
                        n_estimators=300,
                        max_depth=5,
                        learning_rate=0.05,
                        subsample=0.8,
                        random_state=RANDOM_STATE,
                    ),
                ),
            ]
        ),
        # HistGBM handles mixed types natively and is fast on small datasets
        "HistGradientBoosting": Pipeline(
            [
                ("prep", prep()),
                (
                    "model",
                    HistGradientBoostingRegressor(
                        max_iter=300,
                        max_depth=6,
                        learning_rate=0.05,
                        min_samples_leaf=4,
                        random_state=RANDOM_STATE,
                    ),
                ),
            ]
        ),
    }
    return candidates


# ─────────────────────────────────────────────────────────────────────────────
# CROSS-VALIDATION COMPARISON
# ─────────────────────────────────────────────────────────────────────────────

def compare_models(X: pd.DataFrame, y: pd.Series, verbose: bool = True, cat_features=None) -> pd.DataFrame:
    """
    Runs 5-fold CV for every candidate model.
    Returns a results DataFrame sorted by mean CV-MAE (ascending).
    """
    kf = KFold(n_splits=N_FOLDS, shuffle=True, random_state=RANDOM_STATE)
    scoring = ["neg_mean_absolute_error", "neg_root_mean_squared_error", "r2"]

    rows = []
    candidates = get_candidate_models(cat_features)

    if verbose:
        print(f"\n{'─'*60}")
        print(f"  MODEL COMPARISON  ({N_FOLDS}-fold CV, n={len(X)} segments)")
        print(f"{'─'*60}")
        header = f"{'Model':<25} {'MAE':>8} {'RMSE':>8} {'R²':>7}"
        print(header)
        print("─" * len(header))

    for name, pipeline in candidates.items():
        # n_jobs=1 keeps CV in the main process so Python warnings filters
        # apply.  With 590 samples × 5 folds this is still sub-second.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            cv_results = cross_validate(
                pipeline,
                X,
                y,
                cv=kf,
                scoring=scoring,
                return_train_score=False,
                n_jobs=1,
            )

        mae_mean = -cv_results["test_neg_mean_absolute_error"].mean()
        mae_std = cv_results["test_neg_mean_absolute_error"].std()
        rmse_mean = -cv_results["test_neg_root_mean_squared_error"].mean()
        r2_mean = cv_results["test_r2"].mean()

        rows.append(
            {
                "model_name": name,
                "cv_mae_mean": round(mae_mean, 3),
                "cv_mae_std": round(mae_std, 3),
                "cv_rmse_mean": round(rmse_mean, 3),
                "cv_r2_mean": round(r2_mean, 4),
            }
        )

        if verbose:
            print(
                f"  {name:<23} {mae_mean:>6.2f} min  {rmse_mean:>6.2f} min  {r2_mean:>6.3f}"
            )

    results = pd.DataFrame(rows).sort_values("cv_mae_mean").reset_index(drop=True)

    if verbose:
        print(f"{'─'*60}")
        best = results.iloc[0]
        print(f"\n  Best: {best['model_name']}  (CV-MAE = {best['cv_mae_mean']:.2f} ± {best['cv_mae_std']:.2f} min)")

    return results


# ─────────────────────────────────────────────────────────────────────────────
# FINAL FIT + EVALUATION ON HOLD-OUT
# ─────────────────────────────────────────────────────────────────────────────

def train_best_model(X: pd.DataFrame, y: pd.Series, results: pd.DataFrame, verbose: bool = True, cat_features=None):
    """
    Fits the best-ranked model on 80% of data, evaluates on 20% hold-out,
    then re-fits on the FULL dataset before saving.
    This gives an honest hold-out metric AND a production model trained on all data.
    """
    from sklearn.model_selection import train_test_split

    best_name = results.iloc[0]["model_name"]
    candidates = get_candidate_models(cat_features)
    pipeline = candidates[best_name]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.20, random_state=RANDOM_STATE
    )

    pipeline.fit(X_train, y_train)
    y_pred = pipeline.predict(X_test)

    mae = mean_absolute_error(y_test, y_pred)
    rmse = mean_squared_error(y_test, y_pred) ** 0.5
    r2 = r2_score(y_test, y_pred)

    if verbose:
        print(f"\n  Hold-out evaluation  ({best_name})")
        print(f"    MAE   = {mae:.2f} min")
        print(f"    RMSE  = {rmse:.2f} min")
        print(f"    R²    = {r2:.3f}")

    # Re-fit on full data for deployment
    candidates_full = get_candidate_models(cat_features)
    final_pipeline = candidates_full[best_name]
    final_pipeline.fit(X, y)

    # Feature importance (if tree-based)
    _print_feature_importance(final_pipeline, verbose)

    return final_pipeline, {
        "model_name": best_name,
        "holdout_mae": round(mae, 3),
        "holdout_rmse": round(rmse, 3),
        "holdout_r2": round(r2, 4),
        "cv_mae_mean": float(results.iloc[0]["cv_mae_mean"]),
        "cv_mae_std": float(results.iloc[0]["cv_mae_std"]),
        "n_segments": len(X),
        "n_folds": N_FOLDS,
        "feature_names": NUMERIC_FEATURES + CATEGORICAL_FEATURES,
    }


def _print_feature_importance(pipeline, verbose):
    if not verbose:
        return
    estimator = pipeline.named_steps["model"]
    if not hasattr(estimator, "feature_importances_"):
        return

    prep = pipeline.named_steps["prep"]
    num_names = NUMERIC_FEATURES[:]
    try:
        cat_encoder = prep.named_transformers_["cat"]
        cat_names = cat_encoder.get_feature_names_out(CATEGORICAL_FEATURES).tolist()
    except Exception:
        cat_names = []

    feature_names = num_names + cat_names
    importances = estimator.feature_importances_
    n = min(len(feature_names), len(importances), 10)
    top = sorted(zip(feature_names[:n], importances[:n]), key=lambda x: -x[1])

    print(f"\n  Top feature importances:")
    for fname, imp in top[:8]:
        bar = "█" * int(imp * 40)
        print(f"    {fname:<25} {imp:.3f}  {bar}")


# ─────────────────────────────────────────────────────────────────────────────
# SAVE / LOAD
# ─────────────────────────────────────────────────────────────────────────────

def save_model(pipeline, metadata: dict):
    os.makedirs(MODELS_DIR, exist_ok=True)
    joblib.dump(pipeline, BEST_MODEL_PATH)
    with open(RESULTS_PATH, "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"\n  Model saved  →  {BEST_MODEL_PATH}")
    print(f"  Metadata saved →  {RESULTS_PATH}")


def load_best_model():
    """Load the saved best model pipeline (used by predictor.py)."""
    if not os.path.exists(BEST_MODEL_PATH):
        raise FileNotFoundError(
            f"No trained model found at {BEST_MODEL_PATH}. "
            "Run model_trainer.py first."
        )
    return joblib.load(BEST_MODEL_PATH)


# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

def run_training(data_path: str = None, segments_path: str = None, verbose: bool = True):
    """Full training pipeline: preprocess → compare → train best → save.

    Pass segments_path to skip GPS preprocessing and load pre-computed
    segment features directly (e.g. from scripts/augment_data.py output).
    """
    if segments_path:
        if verbose:
            print(f"  Loading pre-computed segments from {segments_path}")
        segments = pd.read_csv(segments_path)
        if verbose:
            print(f"  {len(segments)} segments loaded")
    else:
        kwargs = {"path": data_path} if data_path else {}
        segments = run_preprocessing(verbose=verbose, **kwargs)

    X, y = get_X_y(segments)

    if len(X) < 50:
        raise ValueError(
            f"Only {len(X)} valid segments found after preprocessing. "
            "Cannot train a reliable model with this few samples."
        )

    # Determine which categorical features are actually present in X
    from ml_pipeline.preprocessor import CATEGORICAL_FEATURES
    cat_features = [c for c in CATEGORICAL_FEATURES if c in X.columns]

    results = compare_models(X, y, verbose=verbose, cat_features=cat_features)
    best_pipeline, metadata = train_best_model(X, y, results, verbose=verbose, cat_features=cat_features)

    # Save full comparison table alongside metadata
    results_path_csv = os.path.join(MODELS_DIR, "all_model_results.csv")
    os.makedirs(MODELS_DIR, exist_ok=True)
    results.to_csv(results_path_csv, index=False)
    if verbose:
        print(f"\n  Full comparison saved → {results_path_csv}")

    save_model(best_pipeline, metadata)
    return best_pipeline, metadata, segments


if __name__ == "__main__":
    pipeline, meta, _ = run_training(verbose=True)
    print("\n  Done.")
    print(f"  Model: {meta['model_name']}")
    print(f"  CV-MAE: {meta['cv_mae_mean']:.2f} ± {meta['cv_mae_std']:.2f} min")
    print(f"  Hold-out MAE: {meta['holdout_mae']:.2f} min  |  R²: {meta['holdout_r2']:.3f}")
