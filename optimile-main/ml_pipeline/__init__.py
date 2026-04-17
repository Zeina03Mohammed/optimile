"""
ml_pipeline
===========
Data-driven calibration layer for the Optimile route optimizer.

Usage
-----
# 1. Train once (run from project root):
#       python -m ml_pipeline.model_trainer

# 2. Enable ML cost in ALNS:
#       context["use_ml_cost"] = True

# 3. Check model status:
from ml_pipeline.predictor import is_model_available, model_metadata
print(is_model_available())
print(model_metadata())
"""

from ml_pipeline.predictor import (
    predict_leg_time,
    predict_cost_matrix,
    is_model_available,
    model_metadata,
)

__all__ = [
    "predict_leg_time",
    "predict_cost_matrix",
    "is_model_available",
    "model_metadata",
]
