"""
Bellman–Ford single-source shortest path algorithm.

Use when the graph may have negative edge weights. Detects negative cycles.
Useful for routing with penalties, time-window costs, or reward-based edges.
"""

from __future__ import annotations

from math import atan2, cos, radians, sin, sqrt
from typing import Dict, List, Optional, Tuple, Union

# Type for list of (lat, lng) coordinates
Coords = List[Tuple[float, float]]


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distance in km between two WGS84 points."""
    R = 6371.0
    lat1, lon1, lat2, lon2 = map(radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
    c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return R * c


def route_order_from_locations(
    coords: Coords,
    start_index: int = 0,
) -> Tuple[List[int], bool]:
    """
    Build a graph from locations (haversine distances) and return a visit order
    using Bellman–Ford: from start_index, order nodes by shortest distance.

    Args:
        coords: List of (lat, lng) – e.g. [current_position, stop1, stop2, ...]
                or just [stop1, stop2, ...] with start_index=0.
        start_index: Index of the start node (0 = first coord).

    Returns:
        (order, has_negative_cycle): order is list of indices to visit
        (start first, then by increasing distance). has_negative_cycle is
        always False for haversine weights but returned for API consistency.
    """
    n = len(coords)
    if n == 0:
        return [], False
    if n == 1:
        return [0], False

    # Full graph: each node i -> each j with weight = haversine(i, j)
    graph: Graph = {}
    for i in range(n):
        graph[i] = []
        for j in range(n):
            if i == j:
                continue
            lat1, lon1 = coords[i][0], coords[i][1]
            lat2, lon2 = coords[j][0], coords[j][1]
            w = _haversine_km(lat1, lon1, lat2, lon2)
            graph[i].append((j, w))

    dist, _, has_negative_cycle = bellman_ford(graph, start_index, n_nodes=n)

    # Order: start_index first, then rest sorted by distance from start
    others = [i for i in range(n) if i != start_index]
    others.sort(key=lambda i: (dist[i], i))
    order = [start_index] + others
    return order, has_negative_cycle

# Graph as adjacency list: node_id -> list of (neighbor_id, edge_weight)
# node_id can be any hashable type (int, str, etc.)
Graph = Dict[Union[int, str], List[Tuple[Union[int, str], float]]]


def bellman_ford(
    graph: Graph,
    source: Union[int, str],
    n_nodes: Optional[int] = None,
) -> Tuple[Dict[Union[int, str], float], Dict[Union[int, str], Optional[Union[int, str]]], bool]:
    """
    Run Bellman–Ford from `source`. Returns distances, predecessors, and negative-cycle flag.

    Args:
        graph: Adjacency list. Keys are node ids; values are lists of (neighbor, weight).
        source: Start node id.
        n_nodes: If given, only the first n_nodes (when nodes are 0..n_nodes-1) are
                 considered; otherwise all nodes that appear in graph (as key or neighbor).

    Returns:
        (dist, pred, has_negative_cycle):
        - dist: node_id -> shortest distance from source (float('inf') if unreachable).
        - pred: node_id -> previous node on shortest path (None for source/unreachable).
        - has_negative_cycle: True if a negative cycle reachable from source exists.

    Example:
        >>> g = {0: [(1, 4), (2, 1)], 1: [(2, 2), (3, 1)], 2: [(1, 1)], 3: []}
        >>> dist, pred, neg = bellman_ford(g, 0)
        >>> dist[3]
        6.0
    """
    # Collect all nodes
    nodes = set(graph.keys())
    for neighbors in graph.values():
        for (v, _) in neighbors:
            nodes.add(v)
    if n_nodes is not None:
        nodes = {i for i in nodes if isinstance(i, int) and 0 <= i < n_nodes}
    nodes = sorted(nodes, key=lambda x: (isinstance(x, str), x))

    dist: Dict[Union[int, str], float] = {v: float("inf") for v in nodes}
    pred: Dict[Union[int, str], Optional[Union[int, str]]] = {v: None for v in nodes}
    dist[source] = 0.0

    # Relax edges (n_nodes or len(nodes)) times
    n = len(nodes)
    for _ in range(n - 1):
        for u in graph:
            if u not in nodes or dist[u] == float("inf"):
                continue
            for (v, w) in graph.get(u, []):
                if v not in nodes:
                    continue
                new_dist = dist[u] + w
                if new_dist < dist[v]:
                    dist[v] = new_dist
                    pred[v] = u

    # Detect negative cycle: one more relaxation pass
    has_negative_cycle = False
    for u in graph:
        if u not in nodes or dist[u] == float("inf"):
            continue
        for (v, w) in graph.get(u, []):
            if v not in nodes:
                continue
            if dist[u] + w < dist[v]:
                has_negative_cycle = True
                break
        if has_negative_cycle:
            break

    return dist, pred, has_negative_cycle


def shortest_path(
    graph: Graph,
    source: Union[int, str],
    target: Union[int, str],
    n_nodes: Optional[int] = None,
) -> Tuple[Optional[List[Union[int, str]]], float, bool]:
    """
    Get shortest path from source to target and its cost.

    Args:
        graph: Adjacency list (node -> [(neighbor, weight), ...]).
        source: Start node.
        target: End node.
        n_nodes: Optional node count for 0..n_nodes-1 graphs.

    Returns:
        (path, cost, has_negative_cycle):
        - path: List of nodes from source to target, or None if no path or negative cycle.
        - cost: Shortest distance (float('inf') if unreachable).
        - has_negative_cycle: True if a negative cycle reachable from source exists.
    """
    dist, pred, has_negative_cycle = bellman_ford(graph, source, n_nodes)

    if has_negative_cycle or dist.get(target, float("inf")) == float("inf"):
        return None, dist.get(target, float("inf")), has_negative_cycle

    path: List[Union[int, str]] = []
    cur: Optional[Union[int, str]] = target
    while cur is not None:
        path.append(cur)
        cur = pred.get(cur)
    path.reverse()
    return path, dist[target], has_negative_cycle
