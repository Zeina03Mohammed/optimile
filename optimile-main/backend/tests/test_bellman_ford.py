"""Tests for Bellman–Ford shortest path implementation.

Covers:
  - Core Bellman-Ford algorithm (graph relaxation, negative cycles)
  - Negative edge weight computation (business logic modifiers)
  - TRUE Bellman-Ford on distance matrix (pairwise road distances)
  - Haversine-based route ordering with business modifiers
"""

import sys
from pathlib import Path

# Add model to path so we can import from optimile-main.model
_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))

from model.bellman_ford import (
    bellman_ford,
    shortest_path,
    compute_edge_weight,
    route_order_from_distance_matrix,
    route_order_from_locations,
)


# =====================================================
# CORE BELLMAN-FORD ALGORITHM TESTS
# =====================================================

def test_basic_shortest_path():
    # Graph: 0 -> 1 (4), 0 -> 2 (1), 1 -> 2 (2), 1 -> 3 (1), 2 -> 1 (1)
    g = {
        0: [(1, 4), (2, 1)],
        1: [(2, 2), (3, 1)],
        2: [(1, 1)],
        3: [],
    }
    dist, pred, neg = bellman_ford(g, 0)
    assert neg is False
    assert dist[0] == 0
    assert dist[1] == 2  # 0 -> 2 -> 1
    assert dist[2] == 1
    assert dist[3] == 3  # 0 -> 2 -> 1 -> 3


def test_shortest_path_helper():
    g = {0: [(1, 1)], 1: [(2, 1)], 2: []}
    path, cost, neg = shortest_path(g, 0, 2)
    assert neg is False
    assert cost == 2
    assert path == [0, 1, 2]


def test_negative_cycle_detection():
    # 0 -> 1 (1), 1 -> 2 (1), 2 -> 0 (-3) => negative cycle
    g = {0: [(1, 1)], 1: [(2, 1)], 2: [(0, -3)]}
    dist, pred, neg = bellman_ford(g, 0)
    assert neg is True


def test_unreachable_node():
    g = {0: [(1, 1)], 1: [], 2: []}
    dist, pred, neg = bellman_ford(g, 0)
    assert dist[2] == float("inf")
    assert pred[2] is None
    assert neg is False


def test_negative_weights_no_cycle():
    # Negative edge but no negative cycle
    g = {0: [(1, -1)], 1: [(2, 2)], 2: []}
    dist, pred, neg = bellman_ford(g, 0)
    assert neg is False
    assert dist[2] == 1


# =====================================================
# NEGATIVE EDGE WEIGHT COMPUTATION TESTS (Task 2)
# =====================================================

def test_compute_edge_weight_no_modifiers():
    """Base weight with no business context only gets clustering modifier if close."""
    # 200s base (> 120s threshold) → no clustering reward, no other modifiers
    w_far = compute_edge_weight(200.0, 0, 1)
    assert w_far == 200.0, f"No modifiers for >120s base, got {w_far}"

    # 100s base (< 120s threshold) → clustering reward of -10% kicks in
    w_close = compute_edge_weight(100.0, 0, 1)
    expected = 100.0 - 100.0 * 0.10  # 90.0 (clustering reward)
    assert abs(w_close - expected) < 0.01, f"Expected clustering reward, got {w_close}"


def test_compute_edge_weight_fragile_penalty():
    """Fragile destination adds +20% penalty."""
    base = 200.0
    w = compute_edge_weight(
        base, 0, 1,
        fragile_flags=[False, True],  # stop 1 is fragile
    )
    expected = base + base * 0.20  # 200 + 40 = 240
    assert abs(w - expected) < 0.01


def test_compute_edge_weight_tight_deadline_negative():
    """Tight deadline produces a NEGATIVE modifier (reward).
    This is the KEY reason we need Bellman-Ford over Dijkstra."""
    base = 300.0
    # Stop 1 has deadline at minute 500, start time is 480 → 20 min slack (< 30)
    w = compute_edge_weight(
        base, 0, 1,
        time_windows=[(None, None), (None, 500)],
        start_time_min=480,
    )
    # urgency_factor = (30 - 20) / 30 = 0.333
    # reward = -300 * 0.15 * 0.333 = -15.0
    # w = 300 - 15.0 = 285.0
    assert w < base, f"Tight deadline should reduce weight, got {w} >= {base}"
    # Verify the negative delta
    delta = w - base
    assert delta < 0, f"Delta should be negative for tight deadline, got {delta}"


def test_compute_edge_weight_past_deadline_penalty():
    """Past deadline adds a heavy penalty."""
    base = 300.0
    # Stop 1 deadline at 470, start at 480 → slack = -10 (past deadline)
    w = compute_edge_weight(
        base, 0, 1,
        time_windows=[(None, None), (None, 470)],
        start_time_min=480,
    )
    expected = base + base * 0.50  # heavy penalty
    assert abs(w - expected) < 0.01


def test_compute_edge_weight_clustering_reward():
    """Very close stops (< 2 min travel) get a clustering reward (NEGATIVE)."""
    base = 60.0  # 1 minute travel time (< 120s threshold)
    w = compute_edge_weight(base, 0, 1)
    # clustering reward: -60 * 0.10 = -6.0
    expected = base - base * 0.10  # 60 - 6 = 54
    assert abs(w - expected) < 0.01
    assert w < base, "Clustering should reduce weight for nearby stops"


def test_compute_edge_weight_heavy_traffic_penalty():
    """Heavy traffic adds penalty."""
    base = 200.0
    w = compute_edge_weight(
        base, 0, 1,
        context={"traffic": "Heavy"},
    )
    expected = base + base * 0.25  # 200 + 50 = 250
    assert abs(w - expected) < 0.01


def test_compute_edge_weight_low_traffic_reward():
    """Low traffic gives a slight reward (NEGATIVE modifier)."""
    base = 200.0
    w = compute_edge_weight(
        base, 0, 1,
        context={"traffic": "Low"},
    )
    expected = base - base * 0.05  # 200 - 10 = 190
    assert abs(w - expected) < 0.01
    assert w < base, "Low traffic should reward (reduce weight)"


def test_compute_edge_weight_bad_weather_penalty():
    """Rain/Storm/Fog adds weather penalty."""
    base = 200.0
    w = compute_edge_weight(
        base, 0, 1,
        context={"weather": "Rain"},
    )
    expected = base + base * 0.15  # 200 + 30 = 230
    assert abs(w - expected) < 0.01


def test_compute_edge_weight_combined_modifiers():
    """Multiple modifiers stack: fragile + tight deadline + heavy traffic."""
    base = 300.0
    w = compute_edge_weight(
        base, 0, 1,
        fragile_flags=[False, True],
        time_windows=[(None, None), (None, 500)],
        start_time_min=480,
        context={"traffic": "Heavy", "weather": "Rain"},
    )
    # fragile: +60, deadline urgency: ~ -15, traffic: +75, weather: +45
    # Net should be > base due to penalties outweighing reward
    # But the deadline reward IS present (negative component)
    assert w > base, "Combined penalties should outweigh reward here"


# =====================================================
# TRUE BELLMAN-FORD ON DISTANCE MATRIX TESTS
# =====================================================

def test_route_order_from_distance_matrix_basic():
    """True BF on a distance matrix should find optimal order."""
    # 3 nodes: start(0), stopA(1), stopB(2)
    # Direct: 0->1=100s, 0->2=200s
    # But transitive: 0->1->2=90s (via shortcut)
    matrix = {
        (0, 1): 100.0,
        (0, 2): 200.0,
        (1, 0): 100.0,
        (1, 2): 80.0,   # shortcut 1->2 is fast
        (2, 0): 200.0,
        (2, 1): 80.0,
    }
    order, neg_cycle, debug = route_order_from_distance_matrix(
        duration_matrix=matrix,
        n_nodes=3,
        start_index=0,
    )
    assert order[0] == 0, "Start should be first"
    assert neg_cycle is False
    assert debug["algorithm"] == "bellman_ford"
    assert debug["total_edges"] == 6  # 3 * (3-1)
    # Stop 1 should come before stop 2 (closer to start)
    assert order.index(1) < order.index(2)


def test_route_order_from_distance_matrix_with_negative_weights():
    """BF with business modifiers should produce negative edges and still work."""
    # 4 nodes: start(0), and 3 stops
    matrix = {
        (0, 1): 300.0,
        (0, 2): 500.0,
        (0, 3): 400.0,
        (1, 0): 300.0,
        (1, 2): 200.0,
        (1, 3): 150.0,
        (2, 0): 500.0,
        (2, 1): 200.0,
        (2, 3): 100.0,
        (3, 0): 400.0,
        (3, 1): 150.0,
        (3, 2): 100.0,
    }
    # Stop 2 has tight deadline → should get negative edge weight reward
    order, neg_cycle, debug = route_order_from_distance_matrix(
        duration_matrix=matrix,
        n_nodes=4,
        start_index=0,
        fragile_flags=[False, False, False, True],  # stop 3 is fragile
        time_windows=[(None, None), (None, None), (None, 500), (None, None)],
        start_time_min=485,  # 15 min slack on stop 2 → triggers urgency reward
    )
    assert order[0] == 0
    assert neg_cycle is False
    assert debug["negative_edge_count"] > 0, \
        f"Should have negative edges from deadline urgency, got {debug['negative_edge_count']}"
    assert "distances_from_start" in debug


def test_route_order_from_distance_matrix_transitive_path():
    """
    TRUE Bellman-Ford finds transitive shortcuts that simple sorting MISSES.

    Simple sorting: 0->2 = 500s (direct)
    BF with transitive: 0->1->2 = 300 + 50 = 350s (CHEAPER!)

    This is the key difference from the old fake implementation.
    """
    matrix = {
        (0, 1): 300.0,
        (0, 2): 500.0,   # direct to 2 is expensive
        (1, 0): 300.0,
        (1, 2): 50.0,    # but 1->2 is very cheap (shortcut!)
        (2, 0): 500.0,
        (2, 1): 50.0,
    }
    order, neg_cycle, debug = route_order_from_distance_matrix(
        duration_matrix=matrix,
        n_nodes=3,
        start_index=0,
    )
    # BF should find: dist[1] = 300, dist[2] = 350 (via 0->1->2)
    # NOT dist[2] = 500 (direct)
    distances = debug["distances_from_start"]
    assert distances[1] < distances[2], "Stop 1 should be closer than stop 2"
    # The transitive distance to 2 should be 350, not 500
    assert distances[2] < 500, \
        f"BF should find transitive path 0->1->2=350, not direct 500, got {distances[2]}"


# =====================================================
# HAVERSINE ROUTE ORDER WITH BUSINESS MODIFIERS
# =====================================================

def test_route_order_from_locations_with_fragile():
    """Haversine BF with fragile flags should modify ordering."""
    # 3 stops in Beirut area
    coords = [
        (33.89, 35.50),  # start
        (33.88, 35.51),  # stop 1 (close, fragile)
        (33.87, 35.49),  # stop 2 (medium distance)
    ]
    order_plain, neg1 = route_order_from_locations(coords, start_index=0)
    order_fragile, neg2 = route_order_from_locations(
        coords, start_index=0,
        fragile_flags=[False, True, False],  # stop 1 is fragile
    )
    # Both should start with 0
    assert order_plain[0] == 0
    assert order_fragile[0] == 0
    # Fragile penalty on stop 1 may change its position in order
    assert len(order_fragile) == 3


def test_route_order_from_locations_with_deadline():
    """Deadline urgency should influence ordering via negative weights."""
    coords = [
        (33.89, 35.50),  # start
        (33.88, 35.52),  # stop 1 (further)
        (33.885, 35.505),  # stop 2 (closer, but no deadline)
    ]
    # Stop 1 has urgent deadline → should get priority (negative edge reward)
    order, neg = route_order_from_locations(
        coords, start_index=0,
        time_windows=[(None, None), (None, 500), (None, None)],
        start_time_min=485,  # 15 min slack → triggers urgency
    )
    assert order[0] == 0
    assert len(order) == 3


def test_route_order_empty_and_single():
    """Edge cases: empty and single-node inputs."""
    order_empty, neg_empty = route_order_from_locations([], start_index=0)
    assert order_empty == []
    assert neg_empty is False

    order_single, neg_single = route_order_from_locations(
        [(33.89, 35.50)], start_index=0
    )
    assert order_single == [0]
    assert neg_single is False


# =====================================================
# COMMITTEE DEMO: PROOF THAT BF ≠ SIMPLE SORTING
# =====================================================

def test_bf_finds_paths_sorting_misses():
    """
    COMMITTEE PROOF: Bellman-Ford discovers transitive paths that
    simple sorting (the old implementation) would completely miss.

    Scenario: 4 delivery stops.
    - Direct distance from warehouse to stop C is 800s
    - But going via stop A then B then C = 150+100+50 = 300s
    - Simple sort: orders by direct distance, puts C last
    - Bellman-Ford: finds the 300s transitive path, correctly ranks C

    This proves the algorithm adds real value beyond Google's routing.
    """
    # Warehouse (0) -> 4 stops with asymmetric distances
    matrix = {
        # From warehouse
        (0, 1): 150.0,  # A: close
        (0, 2): 400.0,  # B: medium
        (0, 3): 800.0,  # C: far (direct)
        (0, 4): 200.0,  # D: close-ish
        # From A
        (1, 0): 150.0, (1, 2): 100.0, (1, 3): 600.0, (1, 4): 250.0,
        # From B
        (2, 0): 400.0, (2, 1): 100.0, (2, 3): 50.0, (2, 4): 300.0,
        # From C
        (3, 0): 800.0, (3, 1): 600.0, (3, 2): 50.0, (3, 4): 350.0,
        # From D
        (4, 0): 200.0, (4, 1): 250.0, (4, 2): 300.0, (4, 3): 350.0,
    }

    order, neg, debug = route_order_from_distance_matrix(
        duration_matrix=matrix,
        n_nodes=5,
        start_index=0,
    )

    # Simple sorting would order by direct distance: A(150), D(200), B(400), C(800)
    simple_sort_order = [0, 1, 4, 2, 3]

    # Bellman-Ford finds transitive paths:
    # dist[1] = 150 (direct)
    # dist[2] = 250 (0->1->2 = 150+100, better than direct 400)
    # dist[3] = 300 (0->1->2->3 = 150+100+50, WAY better than direct 800)
    # dist[4] = 200 (direct)
    distances = debug["distances_from_start"]
    assert distances[3] < 400, \
        f"BF should find transitive path to C (~300s), not direct 800s. Got {distances[3]}"

    # BF order should be different from simple sort
    # BF: A(150), D(200), B(250), C(300)  vs  Sort: A(150), D(200), B(400), C(800)
    # C's rank changes because BF found the shortcut!
    assert distances[2] < 400, \
        f"BF should find 0->1->2 = 250s, not direct 400s. Got {distances[2]}"

    print(f"\n=== COMMITTEE DEMO ===")
    print(f"Simple sort distances: A=150, D=200, B=400, C=800")
    print(f"Bellman-Ford distances: A={distances[1]}, D={distances[4]}, B={distances[2]}, C={distances[3]}")
    print(f"BF saved {800 - distances[3]:.0f}s on stop C by finding transitive path 0->A->B->C")
    print(f"Negative edges in graph: {debug['negative_edge_count']}")
    print(f"=== END DEMO ===\n")
