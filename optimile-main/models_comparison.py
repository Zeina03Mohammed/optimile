import pandas as pd
import numpy as np
import joblib

from sklearn.model_selection import train_test_split
from sklearn.ensemble import GradientBoostingRegressor, RandomForestRegressor, ExtraTreesRegressor
from sklearn.impute import SimpleImputer
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import Pipeline
from sklearn.neighbors import KNeighborsRegressor
from sklearn.linear_model import Ridge

# =========================
# 1. LOAD DATA
# =========================

df = pd.read_csv("amazon_delivery.csv")

# =========================
# 2. FEATURE ENGINEERING
# =========================

# ---- Parse dates & times ----
df["Order_Date"] = pd.to_datetime(df["Order_Date"])
df["Order_Time"] = pd.to_datetime(df["Order_Time"], errors="coerce")
df["hour"] = df["Order_Time"].dt.hour
# Drop rows where time could not be parsed
df = df.dropna(subset=["hour"])
df["dayofweek"] = df["Order_Date"].dt.dayofweek

# ---- Haversine Distance ----
def haversine(lat1, lon1, lat2, lon2):
    R = 6371
    phi1 = np.radians(lat1)
    phi2 = np.radians(lat2)
    dphi = np.radians(lat2 - lat1)
    dlambda = np.radians(lon2 - lon1)
    a = np.sin(dphi/2)**2 + np.cos(phi1)*np.cos(phi2)*np.sin(dlambda/2)**2
    return 2 * R * np.arcsin(np.sqrt(a))

df["Distance_km"] = haversine(
    df["Store_Latitude"], df["Store_Longitude"],
    df["Drop_Latitude"], df["Drop_Longitude"]
)

# =========================
# 3. PRE-PROCESSING
# =========================

num_cols = ["Distance_km", "hour", "dayofweek", "Agent_Rating", "Agent_Age"]
cat_cols = ["Weather", "Traffic", "Vehicle", "Area", "Category"]

# ---- Missing values ----
num_imputer = SimpleImputer(strategy="median")
df[num_cols] = num_imputer.fit_transform(df[num_cols])

cat_imputer = SimpleImputer(strategy="most_frequent")
df[cat_cols] = cat_imputer.fit_transform(df[cat_cols])

# ---- One-hot encode ----
df = pd.get_dummies(df, columns=cat_cols, drop_first=True)
def decode_one_hot(prefix, row):
    cols = [c for c in row.index if c.startswith(prefix)]
    for c in cols:
        if row[c] == 1:
            return c.replace(prefix, "")
    return "Unknown"


# =========================
# 4. BUILD TRAINING SET
# =========================

features = [
    "Distance_km", "hour", "dayofweek",
    "Agent_Rating", "Agent_Age"
] + [c for c in df.columns if c.startswith(
    ("Weather_", "Traffic_", "Vehicle_", "Area_", "Category_")
)]

X = df[features]
y = df["Delivery_Time"]
feature_cols = features

# =========================
# 5. TRAIN ML COST MODEL
# =========================

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42
)

# =========================
# 4. MODELS TO COMPARE
# =========================

models = {
    "Ridge": Pipeline([
        ("scaler", StandardScaler()),
        ("model", Ridge(alpha=1.0))
    ]),

    "KNN": Pipeline([
        ("scaler", StandardScaler()),
        ("model", KNeighborsRegressor(
            n_neighbors=10,
            weights="distance",
            metric="minkowski"
        ))
    ]),

    "GradientBoosting_Tuned": GradientBoostingRegressor(
        n_estimators=600,
        learning_rate=0.03,
        max_depth=5,
        subsample=0.9,
        min_samples_split=4,
        min_samples_leaf=2,
        random_state=42
    ),

    "RandomForest_Tuned": RandomForestRegressor(
        n_estimators=900,
        max_depth=26,
        min_samples_split=3,
        min_samples_leaf=2,
        max_features="sqrt",
        random_state=42,
        n_jobs=-1
    ),

    "ExtraTrees_Tuned": ExtraTreesRegressor(
        n_estimators=1000,
        max_depth=28,
        min_samples_split=2,
        min_samples_leaf=1,
        max_features="sqrt",
        random_state=42,
        n_jobs=-1
    )
}

results = {}
best_model = None
best_r2 = -1

print("\n=== MODEL COMPARISON RESULTS ===")

for name, model in models.items():
    print(f"\nTraining {name}...")
    model.fit(X_train, y_train)
    preds = model.predict(X_test)

    mae = mean_absolute_error(y_test, preds)
    rmse = np.sqrt(mean_squared_error(y_test, preds))
    r2 = r2_score(y_test, preds)

    results[name] = {"MAE": mae, "RMSE": rmse, "R2": r2}

    print("MAE:", mae)
    print("RMSE:", rmse)
    print("R2:", r2)

    if r2 > best_r2:
        best_r2 = r2
        best_model = model
        best_name = name

# =========================
# 5. SAVE BEST MODEL
# =========================

joblib.dump(best_model, "best_cost_model.pkl")
joblib.dump(features, "feature_columns.pkl")

print("\n=== BEST MODEL SELECTED ===")
print("Model:", best_name)
print("Best R2:", best_r2)
print("Saved Files: best_cost_model.pkl, feature_columns.pkl")

# =========================
# 6. SUMMARY TABLE
# =========================

print("\n=== FINAL COMPARISON TABLE ===")
for name, metrics in results.items():
    print(f"{name:25s} | MAE={metrics['MAE']:.2f} | RMSE={metrics['RMSE']:.2f} | R2={metrics['R2']:.4f}")
