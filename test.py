import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.impute import SimpleImputer
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
import random

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

model = GradientBoostingRegressor(
    n_estimators=300,
    learning_rate=0.05,
    max_depth=4,
    random_state=42
)
cost_model = model

model.fit(X_train, y_train)

# ---- Evaluate ----
y_pred = model.predict(X_test)
print("\n=== ML COST MODEL PERFORMANCE ===")
print("MAE:", mean_absolute_error(y_test, y_pred))
print("RMSE:", np.sqrt(mean_squared_error(y_test, y_pred)))
print("R2:", r2_score(y_test, y_pred))

# =========================
# 6. COST FUNCTION FOR A ROUTE LEG
# =========================

def predict_leg_time(row_features):
    """
    row_features = dict with:
    Distance_km, hour, dayofweek, Agent_Rating, Agent_Age,
    Weather, Traffic, Vehicle, Area, Category
    """

    base = {
        "Distance_km": row_features["Distance_km"],
        "hour": row_features["hour"],
        "dayofweek": row_features["dayofweek"],
        "Agent_Rating": row_features["Agent_Rating"],
        "Agent_Age": row_features["Agent_Age"]
    }

    for col in X.columns:
        if col not in base:
            base[col] = 0

    for key, val in row_features.items():
        col_name = f"{key}_{val}"
        if col_name in base:
            base[col_name] = 1

    input_df = pd.DataFrame([base])
    return model.predict(input_df)[0]

# =========================
# 7. ROUTE COST FUNCTION
# =========================

def route_cost(route_df):
    total_cost = 0

    for i in range(len(route_df) - 1):

        stop_a = route_df.iloc[i]
        stop_b = route_df.iloc[i + 1]

        # distance between consecutive stops
        leg_distance = haversine(
            stop_a["Drop_Latitude"], stop_a["Drop_Longitude"],
            stop_b["Drop_Latitude"], stop_b["Drop_Longitude"]
        )

        feature_row = stop_b[feature_cols].copy()
        feature_row["Distance_km"] = leg_distance

        feature_row = pd.DataFrame([feature_row])

        predicted_time = cost_model.predict(feature_row)[0]
        total_cost += predicted_time

    return total_cost



# =========================
# 8. ALNS-STYLE RE-OPTIMIZER
# =========================

def alns_optimize(route_df, iterations=500):
    best_route = route_df.copy()
    best_cost = route_cost(best_route)

    for _ in range(iterations):

        candidate = best_route.copy()

        # ---- Destroy: remove a segment ----
        i = random.randint(0, len(candidate) - 3)
        j = random.randint(i + 1, min(i + 3, len(candidate) - 1))

        segment = candidate.iloc[i:j].copy()
        candidate = candidate.drop(candidate.index[i:j]).reset_index(drop=True)

        # ---- Repair: insert segment elsewhere ----
        k = random.randint(0, len(candidate))
        top = candidate.iloc[:k]
        bottom = candidate.iloc[k:]
        candidate = pd.concat([top, segment, bottom]).reset_index(drop=True)

        cost = route_cost(candidate)

        if cost < best_cost:
            best_route = candidate.copy()
            best_cost = cost

    return best_route, best_cost


# =========================
# 9. DEMO: MULTI-STOP ROUTE
# =========================

# Simulate a driver with 8 stops
sample_route = df.sample(8).copy()

print("\n=== INITIAL ROUTE COST ===")
initial_cost = route_cost(sample_route)
print("Initial Cost:", initial_cost)

best_route, best_cost = alns_optimize(sample_route, iterations=300)

print("\n=== OPTIMIZED ROUTE COST ===")
print("Optimized Cost:", best_cost)

print("\n=== IMPROVEMENT ===")
print("Saved Time (min):", initial_cost - best_cost)
print("\n=== OPTIMIZED STOP ORDER ===")

for i, row in best_route.reset_index(drop=True).iterrows():

    area_label = decode_one_hot("Area_", row)

    print(
        f"Stop {i+1}: "
        f"Order_ID={row['Order_ID']}, "
        f"Lat={row['Drop_Latitude']:.5f}, "
        f"Lon={row['Drop_Longitude']:.5f}, "
        f"Area={area_label}"
    )
