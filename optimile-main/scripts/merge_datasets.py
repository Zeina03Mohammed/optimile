"""
merge_datasets.py
-----------------
Merges the real driver movement CSV with the fake orders CSV to produce:
  - unified_orders.csv   (1200 orders with real driver IDs, names, lat/lng)
  - drivers.json         (8 driver profiles with areas + centroids)

Outputs go to: optimile-main/backend/
"""

import csv
import json
import os
import statistics

# ── Paths ──────────────────────────────────────────────────────────────────────
REAL_CSV  = r"C:\Users\Lenovo\Downloads\drivers_movements.csv"
FAKE_CSV  = r"C:\Users\Lenovo\Downloads\cairo_delivery_dataset_fragile_1200.csv"
OUT_DIR   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "backend")
OUT_CSV   = os.path.join(OUT_DIR, "unified_orders.csv")
OUT_JSON  = os.path.join(OUT_DIR, "drivers.json")

# ── Driver mapping: top 8 real drivers -> Cairo areas ──────────────────────────
# Selected based on record count and geographic cluster analysis
DRIVER_PROFILES = [
    {"id": 28,  "name": "Ali Edris",              "areas": ["Downtown"],              "vehicle": "Car"},
    {"id": 29,  "name": "Hassan Hossny",           "areas": ["Maadi"],                 "vehicle": "Van"},
    {"id": 64,  "name": "Mohamed Samir",           "areas": ["New Cairo", "Obour"],    "vehicle": "Van"},
    {"id": 57,  "name": "Abd El Rahman Mostafa",   "areas": ["Nasr City", "Heliopolis"], "vehicle": "Car"},
    {"id": 31,  "name": "Ahmed Hossam",            "areas": ["Shubra"],                "vehicle": "Car"},
    {"id": 62,  "name": "Ayman Hamad",             "areas": ["Heliopolis"],            "vehicle": "Car"},
    {"id": 72,  "name": "Basma Saber",             "areas": ["Nasr City"],             "vehicle": "Car"},
    {"id": 40,  "name": "Abdeen",                  "areas": ["Downtown", "Shubra"],    "vehicle": "Van"},
]

# Area -> primary driver ID lookup
AREA_TO_DRIVER = {}
for dp in DRIVER_PROFILES:
    for area in dp["areas"]:
        if area not in AREA_TO_DRIVER:          # first listed driver wins
            AREA_TO_DRIVER[area] = dp["id"]

# ── Step 1: Read real dataset, compute centroid per driver ─────────────────────
print("Reading real driver movements...")
driver_coords = {}   # driver_id -> list of (lat, lng)
driver_names  = {}   # driver_id -> canonical name

with open(REAL_CSV, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        did  = int(row["Driver ID"].strip())
        name = row["Driver Name"].strip().title()
        try:
            lat = float(row["Lat"].strip())
            lng = float(row["Lng"].strip())
        except ValueError:
            continue
        driver_coords.setdefault(did, []).append((lat, lng))
        driver_names[did] = name

# Compute centroids
driver_centroids = {}
for did, coords in driver_coords.items():
    lats = [c[0] for c in coords]
    lngs = [c[1] for c in coords]
    driver_centroids[did] = (
        round(statistics.mean(lats), 6),
        round(statistics.mean(lngs), 6),
    )

print(f"  -> {len(driver_centroids)} drivers with centroids computed")

# ── Step 2: Build area centroid lookup from real coordinates ───────────────────
# Map each driver's centroid to their assigned areas
area_centroid = {}
for dp in DRIVER_PROFILES:
    did = dp["id"]
    if did in driver_centroids:
        clat, clng = driver_centroids[did]
        for area in dp["areas"]:
            if area not in area_centroid:
                area_centroid[area] = (clat, clng)

# Fallback centroids for Cairo areas (in case driver not in real data)
FALLBACK_CENTROIDS = {
    "Downtown":   (30.0444,  31.2357),
    "Maadi":      (29.9600,  31.2500),
    "New Cairo":  (30.0300,  31.4700),
    "Nasr City":  (30.0600,  31.3300),
    "Heliopolis": (30.0900,  31.3200),
    "Obour":      (30.2100,  31.4700),
    "Shubra":     (30.1000,  31.2400),
}
for area, coords in FALLBACK_CENTROIDS.items():
    area_centroid.setdefault(area, coords)

print(f"  -> Centroids ready for {len(area_centroid)} areas")

# ── Step 3: Build driver_id -> profile lookup ───────────────────────────────────
driver_lookup = {dp["id"]: dp for dp in DRIVER_PROFILES}

# ── Step 4: Read & enrich fake orders ─────────────────────────────────────────
print("Reading fake orders and enriching...")
unified_rows = []

with open(FAKE_CSV, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        area = row["area"].strip()

        # Assign driver based on area
        did  = AREA_TO_DRIVER.get(area, 28)      # default to Ali Edris
        dp   = driver_lookup[did]

        # Get area centroid for lat/lng
        clat, clng = area_centroid.get(area, (30.0444, 31.2357))

        # Add small jitter so stops don't all pile on the exact centroid
        import random
        random.seed(int(row["order_id"]))
        lat = round(clat + random.uniform(-0.02, 0.02), 6)
        lng = round(clng + random.uniform(-0.02, 0.02), 6)

        unified_rows.append({
            "order_id":        row["order_id"].strip(),
            "driver_id":       did,
            "driver_name":     dp["name"],
            "customer_name":   row["customer_name"].strip(),
            "phone":           row["phone"].strip(),
            "address":         row["address"].strip(),
            "area":            area,
            "lat":             lat,
            "lng":             lng,
            "fragile":         row["fragile"].strip(),
            "package_size":    row["package_size"].strip(),
            "vehicle_required": row["vehicle_required"].strip(),
            "status":          "pending",
        })

print(f"  -> {len(unified_rows)} orders enriched")

# ── Step 5: Write unified_orders.csv ──────────────────────────────────────────
os.makedirs(OUT_DIR, exist_ok=True)

fieldnames = [
    "order_id", "driver_id", "driver_name", "customer_name", "phone",
    "address", "area", "lat", "lng", "fragile", "package_size",
    "vehicle_required", "status",
]

with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(unified_rows)

print(f"  -> Written: {OUT_CSV}")

# ── Step 6: Write drivers.json ────────────────────────────────────────────────
drivers_out = []
for dp in DRIVER_PROFILES:
    did = dp["id"]
    clat, clng = driver_centroids.get(did, (30.0444, 31.2357))
    drivers_out.append({
        "id":            did,
        "name":          dp["name"],
        "areas_served":  dp["areas"],
        "vehicle":       dp["vehicle"],
        "centroid_lat":  clat,
        "centroid_lng":  clng,
        "deliveries_today": 0,
        "delivered_count":  0,
        "status":           "available",
    })

with open(OUT_JSON, "w", encoding="utf-8") as f:
    json.dump(drivers_out, f, indent=2, ensure_ascii=False)

print(f"  -> Written: {OUT_JSON}")
print("\nDone! Summary:")
print(f"  Orders: {len(unified_rows)}")
print(f"  Drivers: {len(drivers_out)}")
for dp in drivers_out:
    count = sum(1 for r in unified_rows if r["driver_id"] == dp["id"])
    print(f"    Driver {dp['id']} ({dp['name']}) -> {count} orders in {dp['areas_served']}")
