from __future__ import annotations

"""
Impact model for real-time events.

This is intentionally simple and fully explainable:
we map event categories to a proportional delay on top
of a baseline ETA (in minutes).
"""


def estimate_delay(event: str, baseline_eta: float) -> float:
    """
    Estimate additional delay (in minutes) caused by an event.

    Parameters
    ----------
    event:
        High-level event label, e.g. "traffic_jam", "accident",
        "road_closed", "deviation".
    baseline_eta:
        Nominal ETA for the remaining route in minutes.
    """
    if baseline_eta <= 0:
        return 0.0

    # Proportional factors chosen to be conservative but explainable.
    factors = {
        "traffic_jam": 0.30,   # ~30% slower
        "accident": 0.50,      # ~50% slower
        "road_closed": 0.90,   # almost complete re-route
        "deviation": 0.40,     # wrong turn / major detour
    }

    factor = factors.get(event, 0.0)
    delay = baseline_eta * factor

    return max(0.0, float(delay))

