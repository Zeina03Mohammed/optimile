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
    The SAME route will have DIFFERENT cost
    depending on traffic / incidents / time.
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
        # Base travel time
        # -------------------------------------------------
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

def destroy_random(route, k):
    idx = random.sample(range(1, len(route)), min(k, len(route) - 1))
    removed = [route[i] for i in idx]
    remaining = [r for r in route if r not in removed]
    return remaining, removed


def destroy_fragile(route, fragile_flags, k):
    fragile = [i for i in route if fragile_flags[i]]
    if not fragile:
        return destroy_random(route, k)

    removed = random.sample(fragile, min(k, len(fragile)))
    remaining = [r for r in route if r not in removed]
    return remaining, removed


def destroy_worst(route, cost_fn):
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
    def __init__(self, operators):
        self.operators = operators
        self.weights = {k: 1.0 for k in operators}
        self.scores = {k: 0.0 for k in operators}

    def select(self):
        total = sum(self.weights.values())
        r = random.uniform(0, total)
        acc = 0.0

        for op, w in self.weights.items():
            acc += w
            if acc >= r:
                return op

        return random.choice(list(self.operators))

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
):
    n = len(coords)
    best = list(range(n))

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
        "random": lambda r: destroy_random(r, 2),
        "fragile": lambda r: destroy_fragile(r, fragile_flags, 2),
        "worst": lambda r: destroy_worst(r, cost_fn),
    }

    repair_ops = {
        "greedy": repair_greedy,
        "regret": repair_regret,
    }

    destroy_selector = AdaptiveSelector(destroy_ops)
    repair_selector = AdaptiveSelector(repair_ops)

    for _ in range(iters):
        d_op = destroy_selector.select()
        r_op = repair_selector.select()

        remaining, removed = destroy_ops[d_op](best)
        candidate = repair_ops[r_op](remaining, removed, cost_fn)

        candidate_cost = cost_fn(candidate)
        delta = candidate_cost - best_cost

        if delta < 0 or random.random() < math.exp(-delta / max(T, 1e-6)):
            destroy_selector.reward(d_op, delta)
            repair_selector.reward(r_op, delta)
            best = candidate
            best_cost = candidate_cost

        destroy_selector.update()
        repair_selector.update()
        T *= 0.995

    return best, best_cost
