import random
import math
from functools import lru_cache

# =====================================================
# GEOMETRY
# =====================================================

@lru_cache(maxsize=100_000)
def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


# =====================================================
# VEHICLE MODEL
# =====================================================


def vehicle_speed(vehicle: str) -> float:
    return {
        "motorcycle": 0.9,   # fastest
        "scooter": 0.75,
        "van": 0.6,          # slowest
    }.get(vehicle, 0.7)


def route_cost(
    route,
    coords,
    fragile_flags,
    time_windows,
    start_time_min,
    context,
):
    """
    Real-time adaptive route cost function.

    This function returns a *time-based* cost in minutes
    plus explicit penalties. The SAME route will have
    DIFFERENT cost depending on:
      - traffic level (multipliers)
      - vehicle type (speed model)
      - time windows (wait / late penalties)
      - fragile deliveries (extra penalties)
      - route shape (zig-zag smoothness penalties)
      - incidents (traffic jams, accidents, closures)
    """

    time = start_time_min
    cost = 0.0

    vehicle = context.get("vehicle", "van")
    speed = vehicle_speed(vehicle)

    traffic_level = context.get("traffic", "Normal")
    incident = context.get("incident")

    # -------------------------------------------------
    # Traffic multipliers (soft global effect)
    # -------------------------------------------------
    traffic_multiplier = {
        "Low": 0.9,
        "Normal": 1.0,
        "Medium": 1.15,
        "Heavy": 1.35,
    }.get(traffic_level, 1.0)

    for i in range(len(route) - 1):
        a = coords[route[i]]
        b = coords[route[i + 1]]

        # -------------------------------------------------
        # Base travel time (ETA minutes)
        # -------------------------------------------------
        # NOTE: distance here is an intermediate quantity.
        # The *proof* of optimization quality is based on
        # ETA (minutes), not on geometric distance.
        leg_dist = dist(a, b)
        travel_time = (leg_dist / speed) * traffic_multiplier

        time += travel_time
        cost += travel_time

        # -------------------------------------------------
        # INCIDENT REACTION (REAL-TIME ADAPTATION)
        # -------------------------------------------------
        if incident and route[i + 1] == incident["index"]:

            if incident["kind"] == "traffic_jam":
                # soft avoidance
                cost += incident["severity"] * 35

            elif incident["kind"] == "accident":
                # strong avoidance
                cost += incident["severity"] * 60

            elif incident["kind"] == "road_closed":
                # near-infinite penalty
                cost += 200

        # -------------------------------------------------
        # TIME WINDOW CONSTRAINT
        # -------------------------------------------------
        win_start, win_end = time_windows[route[i + 1]]

        if win_start is not None and time < win_start:
            wait = win_start - time
            cost += wait * 0.2
            time = win_start

        if win_end is not None and time > win_end:
            late = time - win_end
            cost += late * 6.0

        # -------------------------------------------------
        # FRAGILE DELIVERY PRIORITY
        # -------------------------------------------------
        if fragile_flags[route[i + 1]]:
            cost += 2.0 * travel_time

        # -------------------------------------------------
        # ROUTE SMOOTHNESS (REALISTIC DRIVING)
        # -------------------------------------------------
        if i >= 2:
            p0 = coords[route[i - 1]]
            p1 = a
            p2 = b

            v1 = (p1[0] - p0[0], p1[1] - p0[1])
            v2 = (p2[0] - p1[0], p2[1] - p1[1])

            dot = v1[0] * v2[0] + v1[1] * v2[1]
            mag = math.hypot(*v1) * math.hypot(*v2)

            if mag > 0:
                angle = math.degrees(math.acos(max(-1, min(1, dot / mag))))
                if angle < 45:
                    cost += 0.3 * leg_dist

    return cost


# =====================================================
# DESTROY OPERATORS
# =====================================================

def destroy_random(route, k, rng):
    idx = rng.sample(range(1, len(route)), min(k, len(route) - 1))
    removed = [route[i] for i in idx]
    remaining = [r for r in route if r not in removed]
    return remaining, removed


def destroy_fragile(route, fragile_flags, k, rng):
    fragile = [i for i in route if fragile_flags[i]]
    if not fragile:
        return destroy_random(route, k, rng)

    removed = rng.sample(fragile, min(k, len(fragile)))
    remaining = [r for r in route if r not in removed]
    return remaining, removed


def destroy_worst(route, cost_fn, rng):
    worst = max(
        route[1:],
        key=lambda i: cost_fn(route[: route.index(i) + 1]),
    )
    remaining = route[:]
    remaining.remove(worst)
    return remaining, [worst]


# =====================================================
# REPAIR OPERATORS
# =====================================================

def repair_greedy(route, removed, cost_fn):
    for r in removed:
        best_pos = 1
        best_cost = float("inf")

        for i in range(1, len(route) + 1):
            candidate = route[:i] + [r] + route[i:]
            c = cost_fn(candidate)
            if c < best_cost:
                best_cost = c
                best_pos = i

        route.insert(best_pos, r)

    return route


def repair_regret(route, removed, cost_fn):
    while removed:
        regrets = []

        for r in removed:
            costs = []
            for i in range(1, len(route) + 1):
                costs.append(cost_fn(route[:i] + [r] + route[i:]))

            costs.sort()
            regret = costs[1] - costs[0] if len(costs) > 1 else costs[0]
            regrets.append((regret, r))

        _, chosen = max(regrets)
        removed.remove(chosen)
        route = repair_greedy(route, [chosen], cost_fn)

    return route


# =====================================================
# ADAPTIVE OPERATOR SELECTION
# =====================================================

class AdaptiveSelector:
    def __init__(self, operators, rng):
        self.operators = operators
        self.weights = {k: 1.0 for k in operators}
        self.scores = {k: 0.0 for k in operators}
        self.rng = rng

    def select(self):
        total = sum(self.weights.values())
        r = self.rng.uniform(0, total)
        acc = 0.0

        for op, w in self.weights.items():
            acc += w
            if acc >= r:
                return op

        return self.rng.choice(list(self.operators))

    def reward(self, op, improvement):
        if improvement < 0:
            self.scores[op] += 5
        elif improvement == 0:
            self.scores[op] += 1

    def update(self, decay=0.8):
        for op in self.weights:
            self.weights[op] = max(
                0.1,
                decay * self.weights[op] + (1 - decay) * self.scores[op],
            )
            self.scores[op] = 0.0


# =====================================================
# ADAPTIVE ALNS OPTIMIZER
# =====================================================

def optimize_route(
    coords,
    fragile_flags,
    time_windows,
    context,
    start_time_min,
    iters=400,
    seed=None,
    explain: bool = False,
):
    n = len(coords)
    best = list(range(n))

    # Deterministic RNG for statistical stability
    rng = random.Random(seed if seed is not None else 42)

    cost_fn = lambda r: route_cost(
        r,
        coords,
        fragile_flags,
        time_windows,
        start_time_min,
        context,
    )

    best_cost = cost_fn(best)
    T = best_cost * 0.15

    destroy_ops = {
        "random": lambda r: destroy_random(r, 2, rng),
        "fragile": lambda r: destroy_fragile(r, fragile_flags, 2, rng),
        "worst": lambda r: destroy_worst(r, cost_fn, rng),
    }

    repair_ops = {
        "greedy": repair_greedy,
        "regret": repair_regret,
    }

    destroy_selector = AdaptiveSelector(destroy_ops, rng)
    repair_selector = AdaptiveSelector(repair_ops, rng)

    last_improving = None  # (destroy_name, repair_name, delta)

    for _ in range(iters):
        d_op = destroy_selector.select()
        r_op = repair_selector.select()

        remaining, removed = destroy_ops[d_op](best)
        candidate = repair_ops[r_op](remaining, removed, cost_fn)

        candidate_cost = cost_fn(candidate)
        delta = candidate_cost - best_cost

        if delta < 0 or rng.random() < math.exp(-delta / max(T, 1e-6)):
            destroy_selector.reward(d_op, delta)
            repair_selector.reward(r_op, delta)
            best = candidate
            best_cost = candidate_cost
            if delta < 0:
                last_improving = (d_op, r_op, delta)

        destroy_selector.update()
        repair_selector.update()
        T *= 0.995

    if explain:
        print(
            "[ALNS] final best_cost={:.3f} iters={} last_improvement={}".format(
                best_cost,
                iters,
                last_improving,
            )
        )
        try:
            explain_route(
                best,
                coords=coords,
                fragile_flags=fragile_flags,
                time_windows=time_windows,
                start_time_min=start_time_min,
                context=context,
            )
        except Exception as exc:  # defensive: never break optimization on logging
            print(f"[ALNS] explain_route failed: {exc}")

    return best, best_cost


def explain_route(
    route,
    coords,
    fragile_flags,
    time_windows,
    start_time_min,
    context,
):
    """
    Explain the cost composition of a given route.

    This mirrors `route_cost` but prints per-leg contributions:
      - base travel time (ETA)
      - waiting and late penalties
      - fragile penalties
      - incident penalties
      - smoothness (angle) penalties
    """

    time = start_time_min
    vehicle = context.get("vehicle", "van")
    speed = vehicle_speed(vehicle)
    traffic_level = context.get("traffic", "Normal")
    incident = context.get("incident")

    traffic_multiplier = {
        "Low": 0.9,
        "Normal": 1.0,
        "Medium": 1.15,
        "Heavy": 1.35,
    }.get(traffic_level, 1.0)

    total_cost = 0.0
    print(
        "[ROUTE EXPLAIN] vehicle={} traffic={} start_time_min={}".format(
            vehicle, traffic_level, start_time_min
        )
    )
    print(
        " idx_from -> idx_to | base(min) wait late fragile incident smooth | cumulative_cost"
    )

    for i in range(len(route) - 1):
        from_idx = route[i]
        to_idx = route[i + 1]
        a = coords[from_idx]
        b = coords[to_idx]

        leg_dist = dist(a, b)
        base_travel = (leg_dist / speed) * traffic_multiplier

        wait_pen = 0.0
        late_pen = 0.0
        fragile_pen = 0.0
        incident_pen = 0.0
        smooth_pen = 0.0

        time += base_travel
        total_cost += base_travel

        # Incident penalty (if any)
        if incident and to_idx == incident.get("index"):
            kind = incident.get("kind")
            severity = float(incident.get("severity", 1.0))
            if kind == "traffic_jam":
                incident_pen += severity * 35
            elif kind == "accident":
                incident_pen += severity * 60
            elif kind == "road_closed":
                incident_pen += 200
            total_cost += incident_pen

        # Time windows
        win_start, win_end = time_windows[to_idx]
        if win_start is not None and time < win_start:
            wait = win_start - time
            wait_pen += wait * 0.2
            total_cost += wait_pen
            time = win_start

        if win_end is not None and time > win_end:
            late = time - win_end
            late_pen += late * 6.0
            total_cost += late_pen

        # Fragile stop penalty
        if fragile_flags[to_idx]:
            fragile_pen += 2.0 * base_travel
            total_cost += fragile_pen

        # Smoothness penalties
        if i >= 2:
            p0 = coords[route[i - 1]]
            p1 = a
            p2 = b
            v1 = (p1[0] - p0[0], p1[1] - p0[1])
            v2 = (p2[0] - p1[0], p2[1] - p1[1])
            dot = v1[0] * v2[0] + v1[1] * v2[1]
            mag = math.hypot(*v1) * math.hypot(*v2)
            if mag > 0:
                angle = math.degrees(math.acos(max(-1, min(1, dot / mag))))
                if angle < 45:
                    smooth_pen += 0.3 * leg_dist
                    total_cost += smooth_pen

        print(
            f" {from_idx:7d} -> {to_idx:6d} | "
            f"{base_travel:8.3f} {wait_pen:4.2f} {late_pen:4.2f} "
            f"{fragile_pen:7.2f} {incident_pen:8.2f} {smooth_pen:6.2f} | "
            f"{total_cost:15.3f}"
        )

    print(f"[ROUTE EXPLAIN] total_cost={total_cost:.3f}")
