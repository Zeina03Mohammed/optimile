"""
fix_pins_by_area.py
-------------------
Repairs unified_orders.csv so that each order's pin, address name, area, and
driver are mutually consistent.

Strategy (chosen after discovering the original addresses are a small random
pool of famous street names that collapse the 7-area structure when geocoded):
  - Treat AREA + DRIVER as the source of truth (keeps the balanced 7-area /
    8-driver demo intact).
  - For each area, geocode a curated list of REAL inland streets ONCE and keep
    only those that validate inside the area's bounding box.
  - Reassign every order to a real street in ITS OWN area, with tiny jitter so
    pins don't perfectly stack. Address name is rewritten to match.

Usage:
  python scripts/fix_pins_by_area.py validate    # geocode + show street table, no writes
  python scripts/fix_pins_by_area.py apply OUT    # generate dataset to OUT path
"""

import csv, os, sys, json, time, hashlib, random
import requests, urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
sys.stdout.reconfigure(encoding="utf-8")

API_KEY = "AIzaSyBf4OnBLeOxsI97IzCRJRJf6mJSquq85Ts"
URL = "https://maps.googleapis.com/maps/api/geocode/json"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORDERS = os.path.join(ROOT, "backend", "unified_orders.csv")
CACHE = os.path.join(ROOT, "scripts", "_street_geocode_cache.json")

# Area centroids + accept radius (degrees) for validation
AREA_CENTROID = {
    "Downtown":   (30.0444, 31.2357),
    "Maadi":      (29.9600, 31.2500),
    "New Cairo":  (30.0300, 31.4700),
    "Nasr City":  (30.0600, 31.3300),
    "Heliopolis": (30.0900, 31.3200),
    "Obour":      (30.2100, 31.4700),
    "Shubra":     (30.1000, 31.2400),
}
ACCEPT_RADIUS = 0.07  # ~7-8 km — keep streets reasonably inside their area

# Hardcoded coordinate anchors for areas the geocoder can't resolve reliably
# (Obour City is a planned satellite city whose district names collide with an
#  unrelated inner-city "El Obour" neighborhood). These sit inside Obour City's
#  real footprint (~30.20-30.25 lat, 31.46-31.50 lng).
AREA_ANCHORS = {
    "Obour": [
        {"name": "Gamal Abdel Nasser Axis", "lat": 30.19381, "lng": 31.46016},
        {"name": "Obour City Club",          "lat": 30.25161, "lng": 31.49692},
        {"name": "First District",            "lat": 30.20500, "lng": 31.46500},
        {"name": "Third District",            "lat": 30.21500, "lng": 31.47000},
        {"name": "Fourth District",           "lat": 30.22000, "lng": 31.47800},
        {"name": "Sixth District",            "lat": 30.22500, "lng": 31.46800},
        {"name": "Eighth District",           "lat": 30.21000, "lng": 31.48500},
        {"name": "Ninth District",            "lat": 30.23000, "lng": 31.48000},
    ],
}

# Curated real, inland streets per area (avoid river-edge / Corniche)
AREA_STREETS = {
    "Downtown": [
        "Talaat Harb Street", "Qasr El Nil Street", "Champollion Street",
        "Mohamed Mahmoud Street", "Sherif Basha Street",
        "Adly Street", "Emad El Din Street",
        "26th of July Street", "Bab El Louk Square", "Falaki Square",
    ],
    "Maadi": [
        "Road 9 Maadi", "Road 200 Maadi", "Road 250 Maadi", "Street 100 Maadi",
        "Road 105 Maadi", "Nasr Street Maadi", "Road 18 Maadi", "Road 233 Maadi",
        "Road 77 Maadi", "Road 151 Maadi",
    ],
    "New Cairo": [
        "90th Street New Cairo", "South 90 Street New Cairo",
        "North 90 Street New Cairo", "El Banafseg New Cairo",
        "El Yasmeen New Cairo", "El Narges New Cairo", "Teseen Street New Cairo",
        "El Lotus New Cairo", "El Choueifat New Cairo", "First Settlement New Cairo",
    ],
    "Nasr City": [
        "Abbas El Akkad Street Nasr City", "Makram Ebeid Street Nasr City",
        "Mostafa El Nahas Street Nasr City", "El Nasr Road Nasr City",
        "Tayaran Street Nasr City", "Hassan El Maamoun Street Nasr City",
        "Youssef Abbas Street Nasr City", "Anwar El Mofty Street Nasr City",
        "Abou Dawoud El Zahery Street Nasr City", "Mohamed Hassanein Heikal Street Nasr City",
    ],
    "Heliopolis": [
        "El Orouba Street Heliopolis", "Othman Ibn Affan Street Heliopolis",
        "Cleopatra Street Heliopolis", "El Higaz Street Heliopolis",
        "Baghdad Street Heliopolis", "El Merghany Street Heliopolis",
        "Nozha Street Heliopolis", "Ibrahim El Lakkany Street Heliopolis",
        "Beirut Street Heliopolis", "El Ahram Street Heliopolis",
    ],
    "Obour": [],  # geocoder unreliable here; uses AREA_ANCHORS instead
    "Shubra": [
        "Shubra Street", "Khalusi Street Shubra", "Ahmed Helmi Street Shubra",
        "Rod El Farag Street", "El Khalafawy Street Shubra", "Masarra Street Shubra",
        "Mosheer Ahmed Ismail Street Shubra", "Bahtim Street Shubra",
        "Shubra El Kheima Street", "El Teraa El Boulaqeya Street",
    ],
}


def load_cache():
    if os.path.exists(CACHE):
        with open(CACHE, encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_cache(c):
    with open(CACHE, "w", encoding="utf-8") as f:
        json.dump(c, f, ensure_ascii=False, indent=2)


def geocode(query, cache):
    if query in cache:
        return cache[query]
    r = requests.get(URL, params={"address": f"{query}, Cairo, Egypt",
                                  "key": API_KEY, "region": "eg"},
                     timeout=10, verify=False)
    d = r.json()
    if d["status"] == "OK":
        loc = d["results"][0]["geometry"]["location"]
        res = {"lat": loc["lat"], "lng": loc["lng"],
               "fmt": d["results"][0]["formatted_address"]}
    else:
        res = {"lat": None, "lng": None, "fmt": d["status"]}
    cache[query] = res
    time.sleep(0.05)
    return res


def build_street_table(cache):
    """Geocode + validate curated streets. Returns {area: [(name, lat, lng), ...]}."""
    table = {}
    for area, streets in AREA_STREETS.items():
        clat, clng = AREA_CENTROID[area]
        kept, dropped = [], []
        for s in streets:
            res = geocode(s, cache)
            if res["lat"] is None:
                dropped.append((s, res["fmt"]))
                continue
            d = ((res["lat"] - clat) ** 2 + (res["lng"] - clng) ** 2) ** 0.5
            if d <= ACCEPT_RADIUS:
                # display name: strip the disambiguation suffix we added
                disp = s.replace(f" {area}", "").replace("El Obour City ", "").strip()
                if not disp:
                    disp = s
                kept.append({"name": disp, "lat": res["lat"], "lng": res["lng"]})
            else:
                dropped.append((s, f"{res['fmt']} (dist={d:.3f})"))
        for a in AREA_ANCHORS.get(area, []):
            kept.append({"name": a["name"], "lat": a["lat"], "lng": a["lng"]})
        table[area] = kept
        print(f"\n{area}: kept {len(kept)} (geocoded {len(streets)}, anchors {len(AREA_ANCHORS.get(area, []))})")
        for k in kept:
            print(f"   OK  {k['name']:38} ({k['lat']:.5f},{k['lng']:.5f})")
        for s, why in dropped:
            print(f"   --  {s:38} REJECT: {why[:60]}")
    return table


def apply(out_path, cache):
    table = build_street_table(cache)
    save_cache(cache)
    for area, streets in table.items():
        if not streets:
            print(f"\nWARNING: no validated streets for {area} — orders there left unchanged.")

    with open(ORDERS, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
        fieldnames = list(rows[0].keys())

    changed = 0
    for r in rows:
        area = r["area"]
        streets = table.get(area)
        if not streets:
            continue
        seed = int(hashlib.md5(r["order_id"].encode()).hexdigest(), 16)
        rnd = random.Random(seed)
        st = streets[seed % len(streets)]
        num = (seed % 90) + 1
        jlat = rnd.uniform(-0.00018, 0.00018)  # ~20m — keep pin on its named street
        jlng = rnd.uniform(-0.00018, 0.00018)
        r["address"] = f"{num} {st['name']}"
        r["lat"] = round(st["lat"] + jlat, 6)
        r["lng"] = round(st["lng"] + jlng, 6)
        changed += 1

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)
    print(f"\nWrote {out_path} — {changed}/{len(rows)} orders repositioned.")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "validate"
    cache = load_cache()
    if mode == "validate":
        build_street_table(cache)
        save_cache(cache)
    elif mode == "apply":
        out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "backend", "unified_orders_preview.csv")
        apply(out, cache)
    else:
        print("usage: fix_pins_by_area.py [validate|apply OUT]")
