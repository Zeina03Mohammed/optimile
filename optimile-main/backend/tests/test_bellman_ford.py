"""Tests for Bellman–Ford shortest path implementation."""

import sys
from pathlib import Path

# Add model to path so we can import from optimile-main.model
_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_root))

from model.bellman_ford import bellman_ford, shortest_path


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
