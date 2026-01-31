from __future__ import annotations

import requests
import time
from pprint import pprint

BASE_URL = "http://127.0.0.1:8000"


def build_route():
    """
    Route intentionally constructed so that:
    - Stop A is FAR
    - Stop B and C are CLOSE
    - Under traffic, going to A early becomes expensive
    """
    return {
        "current_lat": 0.0,
        "current_lng": 0.0,
        "remaining_stops": [
            # 🚧 FAR STOP (sensitive to traffic)
            {
                "lat": 0.06,
                "lng": 0.0,
                "is_fragile": False,
                "window_start": 480,
                "window_end": 1320,
            },
            # ✅ CLOSE STOP
            {
                "lat": 0.01,
                "lng": 0.0,
                "is_fragile": False,
                "window_start": 480,
                "window_end": 1320,
            },
            # ✅ CLOSE STOP
            {
                "lat": 0.02,
                "lng": 0.01,
                "is_fragile": False,
                "window_start": 480,
                "window_end": 1320,
            },
        ],
        "vehicle": "van",
        "weather": "Sunny",
    }


def call_reoptimize(payload, label):
    print(f"\n=== {label} ===")
    resp = requests.post(
        f"{BASE_URL}/reoptimize",
        json=payload,
        timeout=5,
    )
    print("HTTP status:", resp.status_code)
    data = resp.json()
    pprint(data)
    return data


def main():
    print("\n=== 🚦 REAL-TIME TRAFFIC REOPTIMIZATION — PURE CASE ===")

    # ------------------------------------------------------------
    # BASELINE — normal traffic, no incident
    # ------------------------------------------------------------
    baseline_payload = build_route()
    baseline_payload.update(
        {
            "traffic": "Normal",
            "reason": "none",
            "severity": 0.0,
        }
    )

    baseline = call_reoptimize(
        baseline_payload,
        "BASELINE (normal traffic)",
    )

    time.sleep(1)

    # ------------------------------------------------------------
    # LIVE INCIDENT — traffic jam on long segment
    # ------------------------------------------------------------
    incident_payload = build_route()
    incident_payload.update(
        {
            "traffic": "Heavy",
            "reason": "traffic_jam",
            "severity": 0.9,
        }
    )

    incident = call_reoptimize(
        incident_payload,
        "LIVE INCIDENT (traffic jam)",
    )

    # ------------------------------------------------------------
    # COMPARISON
    # ------------------------------------------------------------
    print("\n=== ✅ COMPARISON SUMMARY ===")

    print("Baseline rerouted :", baseline.get("rerouted"))
    print("Incident rerouted :", incident.get("rerouted"))

    if not baseline.get("rerouted") and incident.get("rerouted"):
        print("\n🔥 REAL-TIME REOPTIMIZATION CONFIRMED")
        print("Baseline route :", baseline.get("optimized_route", "unchanged"))
        print("Incident route :", incident["optimized_route"])
        print("Incident cost  :", incident["cost"])

    print(
        "\nINTERPRETATION:\n"
        "- Same route submitted twice\n"
        "- Only traffic conditions changed\n"
        "- Long-distance leg becomes expensive under congestion\n"
        "- Optimizer reorders stops in response\n"
        "- rerouted=True proves real-time decision making\n"
        "- No fragility or time-window tricks involved\n"
    )


if __name__ == "__main__":
    main()
