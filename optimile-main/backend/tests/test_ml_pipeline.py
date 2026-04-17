"""
ML pipeline unit tests — ml_pipeline/ package.

Tests cover:
  - preprocessor.py: load_raw(), assign_clusters(), run_preprocessing()
  - predictor.py: is_model_available(), predict_leg_time(), predict_cost_matrix()

Because the model may not be trained in the test environment, the predictor
tests verify GRACEFUL FALLBACK (None return) rather than actual predictions.
When the model IS available, the tests also verify prediction plausibility.
"""

import sys
from pathlib import Path
import pytest
import pandas as pd
import numpy as np

_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))

DATA_PATH = _root / "data" / "drivers_movements.csv"


# ─────────────────────────────────────────────────────────────────────────────
# PREPROCESSOR
# ─────────────────────────────────────────────────────────────────────────────

class TestPreprocessorLoadRaw:
    def test_load_raw_returns_dataframe(self):
        from ml_pipeline.preprocessor import load_raw
        df = load_raw(str(DATA_PATH), verbose=False)
        assert isinstance(df, pd.DataFrame)

    def test_load_raw_has_expected_columns(self):
        from ml_pipeline.preprocessor import load_raw
        df = load_raw(str(DATA_PATH), verbose=False)
        required = {"driver_id", "lat", "lng"}
        assert required.issubset(set(df.columns))

    def test_load_raw_no_nan_in_lat_lng(self):
        from ml_pipeline.preprocessor import load_raw
        df = load_raw(str(DATA_PATH), verbose=False)
        assert df["lat"].isna().sum() == 0
        assert df["lng"].isna().sum() == 0

    def test_load_raw_lat_lng_in_egypt_range(self):
        """All coordinates must fall in the valid Egyptian bounding box."""
        from ml_pipeline.preprocessor import load_raw
        df = load_raw(str(DATA_PATH), verbose=False)
        assert df["lat"].between(20.0, 35.0).all(), "lat outside Egypt bounding box"
        assert df["lng"].between(24.0, 40.0).all(), "lng outside Egypt bounding box"

    def test_load_raw_row_count_reasonable(self):
        from ml_pipeline.preprocessor import load_raw
        df = load_raw(str(DATA_PATH), verbose=False)
        assert len(df) >= 100   # at least 100 clean rows expected


class TestPreprocessorAssignClusters:
    def test_assign_clusters_adds_cluster_id_column(self):
        from ml_pipeline.preprocessor import load_raw, assign_clusters
        df = load_raw(str(DATA_PATH), verbose=False)
        df = assign_clusters(df, verbose=False)
        assert "cluster_id" in df.columns

    def test_cluster_id_is_integer(self):
        from ml_pipeline.preprocessor import load_raw, assign_clusters
        df = load_raw(str(DATA_PATH), verbose=False)
        df = assign_clusters(df, verbose=False)
        assert pd.api.types.is_integer_dtype(df["cluster_id"])

    def test_cluster_id_has_noise_label(self):
        """DBSCAN uses -1 for noise points; some noise is expected."""
        from ml_pipeline.preprocessor import load_raw, assign_clusters
        df = load_raw(str(DATA_PATH), verbose=False)
        df = assign_clusters(df, verbose=False)
        assert -1 in df["cluster_id"].values

    def test_at_least_one_real_cluster(self):
        from ml_pipeline.preprocessor import load_raw, assign_clusters
        df = load_raw(str(DATA_PATH), verbose=False)
        df = assign_clusters(df, verbose=False)
        real_clusters = df[df["cluster_id"] != -1]["cluster_id"].nunique()
        assert real_clusters >= 1


class TestPreprocessorRunPipeline:
    def test_run_preprocessing_returns_dataframe(self):
        from ml_pipeline.preprocessor import run_preprocessing
        df = run_preprocessing(str(DATA_PATH), verbose=False)
        assert isinstance(df, pd.DataFrame)

    def test_run_preprocessing_has_target_column(self):
        from ml_pipeline.preprocessor import run_preprocessing
        df = run_preprocessing(str(DATA_PATH), verbose=False)
        assert "time_to_next_stop_min" in df.columns

    def test_run_preprocessing_target_in_valid_range(self):
        """Target variable must be positive and within the allowed 1–90 min range."""
        from ml_pipeline.preprocessor import run_preprocessing
        df = run_preprocessing(str(DATA_PATH), verbose=False)
        assert (df["time_to_next_stop_min"] >= 1.0).all()
        assert (df["time_to_next_stop_min"] <= 90.0).all()

    def test_run_preprocessing_no_nan_features(self):
        from ml_pipeline.preprocessor import run_preprocessing, get_X_y
        df   = run_preprocessing(str(DATA_PATH), verbose=False)
        X, y = get_X_y(df)
        # Only check numeric columns for NaN (object/category cols are not float-castable)
        numeric_X = X.select_dtypes(include=[np.number])
        assert not np.isnan(numeric_X.to_numpy()).any()
        assert not np.isnan(y.to_numpy().astype(float)).any()

    def test_feature_names_match_expected_set(self):
        from ml_pipeline.preprocessor import run_preprocessing, get_X_y, NUMERIC_FEATURES
        df   = run_preprocessing(str(DATA_PATH), verbose=False)
        X, _ = get_X_y(df)
        for feat in NUMERIC_FEATURES:
            assert feat in X.columns, f"Missing feature: {feat}"


# ─────────────────────────────────────────────────────────────────────────────
# PREDICTOR  (graceful-fallback tests always run; value tests only when model exists)
# ─────────────────────────────────────────────────────────────────────────────

class TestPredictorAvailability:
    def test_is_model_available_returns_bool(self):
        from ml_pipeline.predictor import is_model_available
        assert isinstance(is_model_available(), bool)


class TestPredictLegTimeFallback:
    """These tests pass regardless of whether the model file exists."""

    def test_returns_none_or_float(self):
        from ml_pipeline.predictor import predict_leg_time
        result = predict_leg_time(30.0444, 31.2357, 30.0626, 31.2497, 480.0)
        assert result is None or isinstance(result, float)

    def test_no_exception_on_valid_inputs(self):
        from ml_pipeline.predictor import predict_leg_time
        # Must not raise
        predict_leg_time(30.0, 31.0, 30.1, 31.1, 600.0, stop_index=0, stops_in_route=5)

    def test_no_exception_on_edge_coords(self):
        from ml_pipeline.predictor import predict_leg_time
        predict_leg_time(0.0, 0.0, 0.0, 0.0, 0.0)


class TestPredictCostMatrixFallback:
    def test_returns_none_or_ndarray(self):
        from ml_pipeline.predictor import predict_cost_matrix
        import numpy as np
        coords = [(30.0444, 31.2357), (30.0626, 31.2497), (30.0131, 31.2089)]
        result = predict_cost_matrix(coords, 480.0)
        assert result is None or isinstance(result, np.ndarray)

    def test_no_exception_on_single_coord(self):
        from ml_pipeline.predictor import predict_cost_matrix
        predict_cost_matrix([(30.0, 31.0)], 480.0)

    def test_no_exception_on_empty_coords(self):
        from ml_pipeline.predictor import predict_cost_matrix
        predict_cost_matrix([], 480.0)


@pytest.mark.skipif(
    not Path(_root / "ml_pipeline" / "saved_models" / "best_model.pkl").exists(),
    reason="Trained model not present — skipping value tests"
)
class TestPredictorWithModel:
    def test_predict_leg_time_returns_float(self):
        from ml_pipeline.predictor import predict_leg_time
        result = predict_leg_time(30.0444, 31.2357, 30.0626, 31.2497, 480.0)
        assert isinstance(result, float)

    def test_predict_leg_time_in_plausible_range(self):
        from ml_pipeline.predictor import predict_leg_time
        result = predict_leg_time(30.0444, 31.2357, 30.0626, 31.2497, 480.0)
        assert 0.5 <= result <= 90.0

    def test_predict_cost_matrix_shape(self):
        from ml_pipeline.predictor import predict_cost_matrix
        import numpy as np
        coords = [(30.0444, 31.2357), (30.0626, 31.2497), (30.0131, 31.2089)]
        matrix = predict_cost_matrix(coords, 480.0)
        assert matrix is not None
        assert matrix.shape == (3, 3)

    def test_predict_cost_matrix_diagonal_zero(self):
        """Cost from a stop to itself must be zero."""
        from ml_pipeline.predictor import predict_cost_matrix
        import numpy as np
        coords = [(30.0444, 31.2357), (30.0626, 31.2497), (30.0131, 31.2089)]
        matrix = predict_cost_matrix(coords, 480.0)
        assert matrix is not None
        for i in range(len(coords)):
            assert matrix[i][i] == pytest.approx(0.0)

    def test_metadata_returns_dict(self):
        from ml_pipeline.predictor import model_metadata
        meta = model_metadata()
        assert isinstance(meta, dict)
