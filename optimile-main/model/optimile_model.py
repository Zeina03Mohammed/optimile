import pandas as pd
import numpy as np
import joblib

from math import radians, sin, cos, sqrt, atan2
from sklearn.model_selection import train_test_split
from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import r2_score, mean_absolute_error, mean_squared_error

# ===============================
# CONFIG
# ===============================

DATA_PATH = "../data/amazon_delivery.csv"
MODEL_OUT = "optimize_model.pkl"

FRAGILE_CATEGORIES = {
    "electronics",
    "jewelry",
    "cosmetics",
    "home",
    "kitchen",
    "furniture",
}

RANDOM_STATE = 42

# ===============================
# GEO
# ===============================

def haversine(lat1, lon1, lat2, lon2):
    R = 6371.0
    lat1, lon1, lat2, lon2 = map(radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = (
        sin(dlat / 2) ** 2
        + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
    )
    c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return R * c


# ===============================
# TRAIN
# ===============================

def train_and_save():

    print("📥 Loading dataset...")
    df = pd.read_csv(DATA_PATH)

    # -------- Time features --------
    df["Order_Time"] = pd.to_datetime(df["Order_Time"], errors="coerce")
    df["Pickup_Time"] = pd.to_datetime(df["Pickup_Time"], errors="coerce")

    df["order_minutes"] = (
        df["Order_Time"].dt.hour * 60 + df["Order_Time"].dt.minute
    )
    df["day_of_week"] = df["Order_Time"].dt.dayofweek

    df["pickup_delay"] = (
        df["Pickup_Time"] - df["Order_Time"]
    ).dt.total_seconds() / 60
    df["pickup_delay"] = df["pickup_delay"].fillna(10)

    # -------- Distance --------
    df["distance_km"] = df.apply(
        lambda r: haversine(
            r["Store_Latitude"],
            r["Store_Longitude"],
            r["Drop_Latitude"],
            r["Drop_Longitude"],
        ),
        axis=1,
    )

    # -------- Fragility --------
    df["category"] = df["Category"].str.lower()
    df["fragile_flag"] = df["category"].isin(FRAGILE_CATEGORIES).astype(int)

    # -------- Target --------
    y = df["Delivery_Time"]

    # -------- Features --------
    X = df[
        [
            "Agent_Age",
            "Agent_Rating",
            "order_minutes",
            "pickup_delay",
            "day_of_week",
            "distance_km",
            "Weather",
            "Traffic",
            "Vehicle",
            "Area",
            "Category",
            "fragile_flag",
        ]
    ].rename(
        columns={
            "Agent_Age": "agent_age",
            "Agent_Rating": "agent_rating",
            "Weather": "weather",
            "Traffic": "traffic",
            "Vehicle": "vehicle",
            "Area": "area",
            "Category": "category",
        }
    )

    # -------- Clean --------
    X = X.replace([np.inf, -np.inf], np.nan).dropna()
    y = y.loc[X.index]

    # -------- Split --------
    X_train, X_test, y_train, y_test = train_test_split(
        X,
        y,
        test_size=0.2,
        random_state=RANDOM_STATE,
    )

    # -------- Preprocessing --------
    num_features = [
        "agent_age",
        "agent_rating",
        "order_minutes",
        "pickup_delay",
        "day_of_week",
        "distance_km",
        "fragile_flag",
    ]

    cat_features = [
        "weather",
        "traffic",
        "vehicle",
        "area",
        "category",
    ]

    preprocessor = ColumnTransformer(
        transformers=[
            ("num", StandardScaler(), num_features),
            ("cat", OneHotEncoder(handle_unknown="ignore"), cat_features),
        ]
    )

    # -------- Model (BEST FOR YOUR DATA) --------
    model = RandomForestRegressor(
        n_estimators=400,
        max_depth=18,
        min_samples_leaf=5,
        random_state=RANDOM_STATE,
        n_jobs=-1,
    )

    pipeline = Pipeline(
        steps=[
            ("prep", preprocessor),
            ("model", model),
        ]
    )

    # -------- Train --------
    print("🧠 Training model...")
    pipeline.fit(X_train, y_train)

    # -------- Evaluate --------
    y_pred = pipeline.predict(X_test)

    r2 = r2_score(y_test, y_pred)
    mae = mean_absolute_error(y_test, y_pred)
    rmse = mean_squared_error(y_test, y_pred)

    print("\n📊 MODEL PERFORMANCE")
    print(f"R² Score : {r2:.3f}")
    print(f"MAE      : {mae:.2f} minutes")
    print(f"RMSE     : {rmse:.2f} minutes")

    # -------- Save --------
    joblib.dump(pipeline, MODEL_OUT)
    print(f"\n💾 Model saved to ⁠ {MODEL_OUT} ⁠")


# ===============================
# ENTRY
# ===============================

if __name__ == "__main__":
    train_and_save()