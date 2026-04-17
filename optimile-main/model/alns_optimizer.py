import random
import math
from functools import lru_cache

# ML predictor is optional — imported lazily so ALNS works even when
# the model has not been trained yet.
try:
    from ml_pipeline.predictor import predict_leg_time as _ml_predict_leg_time
    _ML_AVAILABLE = True
except ImportError:
    _ML_AVAILABLE = False
    _ml_predict_leg_time = None

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
        # ML-HYBRID PATH: use the data-driven inter-stop time predictor
        # when a trained model is available and the coordinates are real
        # (lat/lng), falling back to the formula-based estimate otherwise.
        #
        # ML prediction already captures historical speed patterns for
        # Egyptian delivery routes.  Traffic multiplier is applied on top
        # with a 50 % weight so we don't double-count: the model saw real
        # traffic implicitly; we only nudge for current deviations.
        leg_dist = dist(a, b)
        formula_time = (leg_dist / speed) * traffic_multiplier

        # ML-HYBRID PATH:
        # The pre-computed N×N matrix (built once per request in main.py)
        # is looked up here in O(1) — no model call inside the hot loop.
        # If the matrix was not pre-computed, fall back to the formula.
        ml_time = None
        ml_matrix = context.get("ml_cost_matrix")
        if ml_matrix is not None:
            from_idx = route[i]
            to_idx   = route[i + 1]
            val = ml_matrix[from_idx][to_idx]
            if 0.5 <= val <= 90.0:
                ml_time = val

        if ml_time is not None:
            traffic_delta = traffic_multiplier - 1.0
            travel_time = ml_time * (1.0 + traffic_delta * 0.5)
        else:
            travel_time = formula_time

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
    initial_route=None,
    explain: bool = False,
):
    n = len(coords)
    # Guard: nothing to optimize for 0 or 1 stops
    if n <= 1:
        return list(range(n)), 0.0

    if initial_route is not None and len(initial_route) == n and set(initial_route) == set(range(n)):
        best = list(initial_route)
    else:
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
        formula_travel = (leg_dist / speed) * traffic_multiplier

        # ML hybrid (mirrors route_cost logic — O(1) matrix lookup)
        ml_travel = None
        ml_matrix = context.get("ml_cost_matrix")
        if ml_matrix is not None:
            val = ml_matrix[from_idx][to_idx]
            if 0.5 <= val <= 90.0:
                ml_travel = val
        if ml_travel is not None:
            traffic_delta = traffic_multiplier - 1.0
            base_travel = ml_travel * (1.0 + traffic_delta * 0.5)
        else:
            base_travel = formula_travel

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


# =====================================================
# FLEET-AWARE OPTIMIZATION
# =====================================================

def optimize_fleet(
    vehicle_coords,       # list of (lat, lng) for each vehicle's current position
    vehicle_stops,        # list of lists: vehicle_stops[v] = list of (lat, lng) for that vehicle's remaining stops
    vehicle_fragile,      # list of lists: fragile flags per vehicle's stops
    vehicle_windows,      # list of lists: time windows per vehicle's stops
    vehicle_contexts,     # list of context dicts per vehicle (vehicle type, traffic, weather)
    start_time_min,       # minutes from midnight
    iters=300,
):
    """
    Fleet-aware route optimizer.

    Finds the optimal assignment of stops across multiple vehicles,
    then runs ALNS on each vehicle's route independently.

    Algorithm:
      1. Start with the current assignment (vehicle_stops as given).
      2. Evaluate total fleet cost under the current assignment.
      3. Try transferring each stop from the heaviest-cost vehicle
         to every other vehicle; accept transfers that reduce total cost.
      4. Run ALNS on each vehicle's final assignment.
      5. Return routes, costs, and transfer log.
    """
    num_vehicles = len(vehicle_coords)

    # -----------------------------------------------------------------
    # Helper: build coords/flags/windows arrays for a single vehicle
    # and evaluate its optimized cost.
    # -----------------------------------------------------------------
    def _build_single(v_idx, stops, fragile, windows):
        """Return (coords, fragile_flags, time_windows) for one vehicle.

        coords[0] = vehicle position, coords[1..] = stops.
        """
        coords = [vehicle_coords[v_idx]] + list(stops)
        f_flags = [False] + list(fragile)
        t_wins = [(None, None)] + list(windows)
        return coords, f_flags, t_wins

    def _evaluate_vehicle(v_idx, stops, fragile, windows):
        """Run ALNS on one vehicle and return (route, cost)."""
        if not stops:
            return [], 0.0
        coords, f_flags, t_wins = _build_single(v_idx, stops, fragile, windows)
        route, cost = optimize_route(
            coords,
            f_flags,
            t_wins,
            vehicle_contexts[v_idx],
            start_time_min,
            iters=iters,
        )
        return route, cost

    def _quick_cost(v_idx, stops, fragile, windows):
        """Evaluate route cost with a greedy nearest-neighbor route (no ALNS).

        This is much faster and used during the transfer search phase.
        """
        if not stops:
            return 0.0
        coords, f_flags, t_wins = _build_single(v_idx, stops, fragile, windows)
        n = len(coords)

        # Greedy nearest-neighbor starting from depot (index 0)
        visited = [False] * n
        visited[0] = True
        route = [0]
        current = 0
        for _ in range(n - 1):
            best_next = None
            best_d = float("inf")
            for j in range(1, n):
                if not visited[j]:
                    d = dist(coords[current], coords[j])
                    if d < best_d:
                        best_d = d
                        best_next = j
            if best_next is None:
                break
            visited[best_next] = True
            route.append(best_next)
            current = best_next

        return route_cost(route, coords, f_flags, t_wins, start_time_min,
                          vehicle_contexts[v_idx])

    # -----------------------------------------------------------------
    # Working copies of the assignments (mutable lists)
    # -----------------------------------------------------------------
    current_stops = [list(s) for s in vehicle_stops]
    current_fragile = [list(f) for f in vehicle_fragile]
    current_windows = [list(w) for w in vehicle_windows]

    # -----------------------------------------------------------------
    # Compute original total cost (quick greedy evaluation)
    # -----------------------------------------------------------------
    original_costs = [
        _quick_cost(v, current_stops[v], current_fragile[v], current_windows[v])
        for v in range(num_vehicles)
    ]
    original_total = sum(original_costs)

    # -----------------------------------------------------------------
    # Transfer phase: try moving stops from the most expensive vehicle
    # to cheaper ones.
    # -----------------------------------------------------------------
    transfers = []
    improved = True
    while improved:
        improved = False

        # Recompute costs after any previous transfer
        costs = [
            _quick_cost(v, current_stops[v], current_fragile[v], current_windows[v])
            for v in range(num_vehicles)
        ]
        total_before = sum(costs)

        # Pick the most expensive vehicle as the donor
        donor = max(range(num_vehicles), key=lambda v: costs[v])

        # Try transferring each of the donor's stops
        for s_idx in range(len(current_stops[donor]) - 1, -1, -1):
            stop = current_stops[donor][s_idx]
            frag = current_fragile[donor][s_idx]
            win = current_windows[donor][s_idx]

            best_receiver = None
            best_new_total = total_before

            for rv in range(num_vehicles):
                if rv == donor:
                    continue

                # Tentatively move the stop
                trial_donor_stops = current_stops[donor][:s_idx] + current_stops[donor][s_idx + 1:]
                trial_donor_frag = current_fragile[donor][:s_idx] + current_fragile[donor][s_idx + 1:]
                trial_donor_wins = current_windows[donor][:s_idx] + current_windows[donor][s_idx + 1:]

                trial_recv_stops = current_stops[rv] + [stop]
                trial_recv_frag = current_fragile[rv] + [frag]
                trial_recv_wins = current_windows[rv] + [win]

                new_donor_cost = _quick_cost(donor, trial_donor_stops,
                                             trial_donor_frag, trial_donor_wins)
                new_recv_cost = _quick_cost(rv, trial_recv_stops,
                                            trial_recv_frag, trial_recv_wins)

                new_total = (total_before
                             - costs[donor] - costs[rv]
                             + new_donor_cost + new_recv_cost)

                if new_total < best_new_total - 1e-6:
                    best_new_total = new_total
                    best_receiver = rv

            if best_receiver is not None:
                # Accept the transfer
                stop_coord = current_stops[donor][s_idx]
                transfers.append({
                    "stop_idx": s_idx,
                    "from_vehicle": donor,
                    "to_vehicle": best_receiver,
                    "stop_lat": stop_coord[0],
                    "stop_lng": stop_coord[1],
                })

                current_stops[best_receiver].append(current_stops[donor].pop(s_idx))
                current_fragile[best_receiver].append(current_fragile[donor].pop(s_idx))
                current_windows[best_receiver].append(current_windows[donor].pop(s_idx))

                improved = True
                break  # restart the while loop with updated costs

    # -----------------------------------------------------------------
    # Final ALNS optimization for each vehicle's route
    # -----------------------------------------------------------------
    vehicle_routes = []
    vehicle_costs = []

    for v in range(num_vehicles):
        route, cost = _evaluate_vehicle(
            v, current_stops[v], current_fragile[v], current_windows[v],
        )
        vehicle_routes.append(route)
        vehicle_costs.append(cost)

    return {
        "vehicle_routes": vehicle_routes,
        "vehicle_costs": vehicle_costs,
        "total_cost": sum(vehicle_costs),
        "transfers": transfers,
        "original_total_cost": original_total,
    }
