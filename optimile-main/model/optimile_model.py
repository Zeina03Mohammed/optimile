import pandas as pd
import joblib
import numpy as np
from math import radians, sin, cos, sqrt, atan2
from sklearn.model_selection import train_test_split
from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.ensemble import GradientBoostingRegressor


def haversine(lat1, lon1, lat2, lon2):
    R = 6371.0
    lat1, lon1, lat2, lon2 = map(radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
    c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return R * c


def train_and_save():
    df = pd.read_csv("../data/amazon_delivery.csv")

    print("📌 Columns found in dataset:")
    print(df.columns.tolist())

    # --- Time features ---
    df["Order_Time"] = pd.to_datetime(df["Order_Time"], errors="coerce")
    df["order_minutes"] = df["Order_Time"].dt.hour * 60 + df["Order_Time"].dt.minute
    df["day_of_week"] = df["Order_Time"].dt.dayofweek

    # --- Distance from coordinates ---
    print("📏 Computing distance_km from coordinates...")
    df["distance_km"] = df.apply(
        lambda r: haversine(
            r["Store_Latitude"],
            r["Store_Longitude"],
            r["Drop_Latitude"],
            r["Drop_Longitude"],
        ),
        axis=1,
    )

    # --- Pickup delay ---
    if "Pickup_Time" in df.columns:
        df["Pickup_Time"] = pd.to_datetime(df["Pickup_Time"], errors="coerce")
        df["pickup_delay"] = (
            df["Pickup_Time"] - df["Order_Time"]
        ).dt.total_seconds() / 60
        df["pickup_delay"] = df["pickup_delay"].fillna(10)
    else:
        print("⚠ No pickup time column found. Synthesizing delay...")
        df["pickup_delay"] = np.random.uniform(5, 25, size=len(df))

    # --- Target ---
    if "Delivery_Time" not in df.columns:
        raise ValueError("❌ Dataset must contain Delivery_Time column")

    y = df["Delivery_Time"]

    # --- Feature set ---
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

    # --- Cleanup ---
    X = X.replace([np.inf, -np.inf], np.nan).dropna()
    y = y.loc[X.index]

    num_features = [
        "agent_age",
        "agent_rating",
        "order_minutes",
        "pickup_delay",
        "day_of_week",
        "distance_km",
    ]

    cat_features = ["weather", "traffic", "vehicle", "area", "category"]

    preprocessor = ColumnTransformer(
        transformers=[
            ("num", StandardScaler(), num_features),
            ("cat", OneHotEncoder(handle_unknown="ignore"), cat_features),
        ]
    )

    model = GradientBoostingRegressor(
        n_estimators=300,
        max_depth=4,
        learning_rate=0.05,
        random_state=42,
    )

    pipeline = Pipeline(
        steps=[
            ("prep", preprocessor),
            ("model", model),
        ]
    )

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )

    pipeline.fit(X_train, y_train)

    joblib.dump(pipeline, "optimize_model.pkl")
    print("✅ Model trained and saved successfully")


if __name__ == "__main__":
    train_and_save()
