from __future__ import annotations

"""
Lightweight validation and stress-test utilities for the ALNS optimizer.

These helpers are not part of the live API but are useful for
defending the design:
  - traffic-level sensitivity
  - incident penalties
  - stochastic stability of ALNS
"""

from typing import List, Tuple
import random
import statistics as stats

from .alns_optimizer import optimize_route, route_cost


def _toy_instance() -> Tuple[List[Tuple[float, float]], List[bool], List[Tuple[int, int]]]:
    """Small synthetic VRPTW instance used across tests."""
    coords = [
        (0.0, 0.0),   # depot / start
        (0.01, 0.00),
        (0.02, 0.01),
        (0.03, -0.01),
    ]
    fragile = [False, True, False, True]
    # wide-open windows for simplicity
    windows = [(0, 24 * 60) for _ in coords]
    return coords, fragile, windows


def traffic_stress_test() -> None:
    """Compare the SAME route under different traffic levels."""
    coords, fragile, windows = _toy_instance()
    route = list(range(len(coords)))

    for traffic in ["Low", "Normal", "Medium", "Heavy"]:
        ctx = {"vehicle": "van", "traffic": traffic}
        c = route_cost(route, coords, fragile, windows, start_time_min=8 * 60, context=ctx)
        print(f"[TRAFFIC] level={traffic:6s} cost={c:.3f}")


def incident_stress_test() -> None:
    """Inject different incident types on the same stop."""
    coords, fragile, windows = _toy_instance()
    route = list(range(len(coords)))

    for kind in ["traffic_jam", "accident", "road_closed"]:
        ctx = {
            "vehicle": "van",
            "traffic": "Normal",
            "incident": {"index": 2, "kind": kind, "severity": 1.0},
        }
        c = route_cost(route, coords, fragile, windows, start_time_min=8 * 60, context=ctx)
        print(f"[INCIDENT] kind={kind:11s} cost={c:.3f}")


def stability_check(runs: int = 5) -> None:
    """
    Run ALNS multiple times on the same instance and show that
    results are deterministic when the seed is fixed.
    """
    coords, fragile, windows = _toy_instance()
    ctx = {"vehicle": "scooter", "traffic": "Medium"}

    baseline_order, baseline_cost = optimize_route(
        coords=coords,
        fragile_flags=fragile,
        time_windows=windows,
        context=ctx,
        start_time_min=8 * 60,
        seed=42,
    )
    print(f"[STABILITY] reference order={baseline_order} cost={baseline_cost:.3f}")

    for r in range(1, runs):
        order, cost = optimize_route(
            coords=coords,
            fragile_flags=fragile,
            time_windows=windows,
            context=ctx,
            start_time_min=8 * 60,
            seed=42,
        )
        print(f"[STABILITY] run={r} order={order} cost={cost:.3f}")


def _random_instance(n_stops: int):
    """
    Build a small random VRPTW instance:
      - depot at (0,0)
      - customers in a small box
      - random fragile flags
      - loose time windows around mid-day
    """
    coords = [(0.0, 0.0)]
    fragile = [False]
    windows: List[Tuple[int, int]] = [(8 * 60, 22 * 60)]

    for _ in range(n_stops):
        x = random.uniform(-0.05, 0.05)
        y = random.uniform(-0.05, 0.05)
        coords.append((x, y))

        is_fragile = random.random() < 0.3
        fragile.append(is_fragile)

        start = random.randint(9 * 60, 13 * 60)
        end = start + random.randint(60, 180)
        windows.append((start, end))

    return coords, fragile, windows


def robustness_benchmark() -> None:
    """
    Statistical robustness check across:
      - different numbers of stops
      - multiple vehicles
      - multiple traffic levels
      - multiple random seeds

    Uses the same time-based route_cost as the optimizer,
    and reports mean and std-dev of ETA improvements.
    """
    sizes = [4, 7, 10]
    vehicles = ["motorcycle", "scooter", "van"]
    traffic_levels = ["Low", "Normal", "Medium", "Heavy"]
    seeds = list(range(10))

    print("\n=== ROBUSTNESS BENCHMARK (ETA-based) ===")

    for n in sizes:
        for vehicle in vehicles:
            for traffic in traffic_levels:
                improvements: List[float] = []

                for s in seeds:
                    random.seed(s)
                    coords, fragile, windows = _random_instance(n_stops=n)
                    ctx = {"vehicle": vehicle, "traffic": traffic}

                    base_route = list(range(len(coords)))
                    base_eta = route_cost(
                        base_route,
                        coords,
                        fragile,
                        windows,
                        start_time_min=8 * 60,
                        context=ctx,
                    )

                    order, cost = optimize_route(
                        coords=coords,
                        fragile_flags=fragile,
                        time_windows=windows,
                        context=ctx,
                        start_time_min=8 * 60,
                        seed=s,
                    )

                    improvement = base_eta - cost
                    improvements.append(improvement)

                mean_imp = stats.mean(improvements)
                std_imp = stats.pstdev(improvements)
                min_imp = min(improvements)
                max_imp = max(improvements)

                print(
                    f"[ROBUST] stops={n:2d} veh={vehicle:10s} traf={traffic:6s} "
                    f"mean_imp={mean_imp:6.2f} std={std_imp:5.2f} "
                    f"min={min_imp:6.2f} max={max_imp:6.2f}"
                )


if __name__ == "__main__":
    print("=== Traffic stress test ===")
    traffic_stress_test()
    print("\n=== Incident stress test ===")
    incident_stress_test()
    print("\n=== Stability check ===")
    stability_check()
    robustness_benchmark()

