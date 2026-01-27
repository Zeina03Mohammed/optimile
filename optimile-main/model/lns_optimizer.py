import random
import math
import pandas as pd

# =========================
# Geometry
# =========================

def haversine(a, b):
    R = 6371.0
    lat1 = math.radians(a["lat"])
    lon1 = math.radians(a["lng"])
    lat2 = math.radians(b["lat"])
    lon2 = math.radians(b["lng"])

    dlat = lat2 - lat1
    dlon = lon2 - lon1

    h = (
        math.sin(dlat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    )
    return R * 2 * math.asin(math.sqrt(h))


def route_distance(route):
    return sum(haversine(route[i], route[i + 1]) for i in range(len(route) - 1))


# =========================
# ML Cost (SAFE + CACHED)
# =========================

def predict_cost(route, model, context):
    total = 0.0

    for i in range(len(route) - 1):
        a = route[i]
        b = route[i + 1]

        row = {
            "Agent_Age": context["agent_age"],
            "Agent_Rating": context["agent_rating"],
            "Distance_km": haversine(a, b),
            "order_minutes": context["order_minutes"],
            "pickup_delay": context["pickup_delay"],
            "day_of_week": context["day_of_week"],
            "Weather": context["weather"],
            "Traffic": context["traffic"],
            "Vehicle": context["vehicle"],
            "Area": context["area"],
            "Category": context["category"],
        }

        df = pd.DataFrame([row])

        try:
            pred = model.predict(df)[0]
        except:
            pred = row["Distance_km"] * 2.5  # fallback

        total += float(pred)

    return total


# =========================
# FAST GREEDY START
# =========================

def greedy_route(stops):
    if len(stops) <= 2:
        return stops[:]

    unvisited = stops[:]
    route = [unvisited.pop(0)]

    while unvisited:
        last = route[-1]
        next_stop = min(unvisited, key=lambda s: haversine(last, s))
        route.append(next_stop)
        unvisited.remove(next_stop)

    return route


# =========================
# 2-OPT LOCAL IMPROVER
# =========================

def two_opt(route):
    best = route[:]
    best_dist = route_distance(best)

    for i in range(1, len(route) - 2):
        for j in range(i + 1, len(route) - 1):
            new = route[:]
            new[i:j] = reversed(new[i:j])

            d = route_distance(new)
            if d < best_dist:
                best = new
                best_dist = d

    return best


# =========================
# HYBRID OPTIMIZER
# =========================

def lns_optimize(stops, model, context, iterations=30):
    if len(stops) <= 2:
        return stops, 0.0

    # 🔥 Phase 1: Greedy
    base = greedy_route(stops)

    # 🔥 Phase 2: Local Search
    improved = two_opt(base)

    # 🔥 Phase 3: Tiny Random Perturbations
    best = improved[:]
    best_dist = route_distance(best)

    for _ in range(min(iterations, 30)):  # HARD CAP
        cand = best[:]
        i, j = random.sample(range(1, len(cand)), 2)
        cand[i], cand[j] = cand[j], cand[i]

        d = route_distance(cand)
        if d < best_dist:
            best = cand
            best_dist = d

    # 🔥 Phase 4: ML scoring (ONCE)
    try:
        cost = predict_cost(best, model, context)
    except:
        cost = best_dist * 2.5

    return best, round(cost, 2)
