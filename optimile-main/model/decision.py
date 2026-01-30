from __future__ import annotations

"""
Decision logic for triggering re-optimization.

This module is deliberately rule-based and transparent:
it never overrides hard constraints and is easy to reason about.
"""


def should_reoptimize(
    delay_minutes: float,
    next_stop_fragile: bool,
    time_window_slack: float,
    last_reopt_seconds: float,
) -> bool:
    """
    Decide whether the current event justifies running ALNS again.

    Parameters
    ----------
    delay_minutes:
        Estimated additional delay caused by the event.
    next_stop_fragile:
        Whether the immediate next stop carries a fragile delivery.
    time_window_slack:
        Remaining slack (in minutes) before time windows become tight.
    last_reopt_seconds:
        Cooldown guardrail from the caller. Currently used only as a
        threshold knob, but kept for explainability.
    """
    if delay_minutes <= 0:
        return False

    # Be more aggressive when the next stop is fragile:
    # we reoptimize when roughly half the slack is consumed.
    fragile_threshold = 0.5 * time_window_slack
    non_fragile_threshold = time_window_slack

    threshold = fragile_threshold if next_stop_fragile else non_fragile_threshold

    # Optional: tie the threshold very slightly to the cooldown horizon.
    # This keeps behavior stable and monotonic without introducing randomness.
    adjusted_threshold = max(0.5 * threshold, min(threshold, last_reopt_seconds / 60.0))

    return delay_minutes >= adjusted_threshold

