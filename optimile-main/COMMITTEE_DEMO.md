# Optimile – Committee Demo Guide

This document explains how to demonstrate the system's **real-time adaptation** to traffic and incidents for your graduation project committee.

---

## Proof Strategy (3 Parts)

| Part | What to show | Where |
|------|--------------|-------|
| **A. Backend statistics** | ALNS improves ETA; traffic/incidents change costs | Terminal (Python) |
| **B. Live app demo** | Simulate button triggers reroute; map updates | Flutter app |
| **C. Evidence document** | Run validation, capture output for report | `committee_stats.txt` |

---

## Part A: Backend Statistics (Run First)

On your laptop, open a terminal:

```bash
cd /Users/mariamshaddad/Documents/GitHub/optimile/optimile-main

# 1. Traffic sensitivity – same route, different traffic levels
python3 demo_alns_scenario.py --mode alns

# 2. Reoptimize with fake traffic incident
python3 demo_alns_scenario.py --mode api

# 3. Full validation (traffic, incidents, stability, robustness)
python3 -m model.alns_validation
```

**What the committee sees:**
- **Traffic**: Cost increases as traffic level goes Low → Normal → Medium → Heavy
- **Incidents**: Cost jumps for traffic_jam, accident, road_closed
- **Reoptimize API**: Backend returns a new stop order when given a traffic event
- **Robustness**: Mean improvement, std-dev, min/max across seeds/vehicles/traffic

**Save output for your report:**

```bash
python3 -m model.alns_validation 2>&1 | tee committee_stats.txt
python3 demo_alns_scenario.py --mode alns 2>&1 | tee -a committee_stats.txt
python3 demo_alns_scenario.py --mode api 2>&1 | tee -a committee_stats.txt
```

---

## Part B: Live App Demo

### Option 1 – With backend (full integration)

1. **Start backend** (Terminal 1):

   ```bash
   cd /Users/mariamshaddad/Documents/GitHub/optimile/optimile-main
   export TOMTOM_API_KEY="O7cPomKqp5eMsZpM95FmZJ3JDnqM7Y42"
   uvicorn backend.main:app --reload --host 0.0.0.0
   ```

2. **Set backend URL in `env.dart`**:
   - **iOS Simulator** (app and backend on same Mac): `http://127.0.0.1:8000`
   - **Real iPhone** (phone and Mac on same Wi‑Fi): `http://YOUR_MAC_IP:8000` (e.g. `http://192.168.1.x:8000`)

3. **Run app** (Terminal 2):

   ```bash
   cd optimile-main/flutter_application_1
   flutter run
   ```

4. **Demo flow:**
   - Add 2–3 stops (tap map, set fragile + time window for at least one)
   - Choose vehicle (e.g. Van)
   - Tap **Start** (optimizes route and starts navigation)
   - Tap **Simulate traffic** → SnackBar: "✓ Route updated (X% faster)" or "⚠ Incident ahead…"
   - Map polyline and stop order update

### Option 2 – Offline demo (no backend)

If the backend is not running or unreachable:

1. Run the app as above (no backend needed)
2. Add 2+ stops, tap **Start**
3. Tap **Simulate traffic** → SnackBar: "✓ Demo: Route adapted (incident simulated, offline)"
4. The map will reorder the next two stops to show adaptation

The committee sees the app respond to a simulated incident; the full ALNS proof is in Part A.

---

## Part C: Key Statistics to Quote

After running `python3 -m model.alns_validation`, you can use:

| Claim | Evidence |
|-------|----------|
| Same route has different cost under different traffic | `[TRAFFIC] level=Low cost=X` vs `level=Heavy cost=Y` (Y > X) |
| Incidents increase route cost | `[INCIDENT] kind=traffic_jam cost=X` vs `kind=road_closed cost=Y` (Y >> X) |
| ALNS improves over baseline | `[ROBUST] mean_imp=...` (positive = improvement) |
| Deterministic under same inputs | `[STABILITY]` same order/cost across runs with same seed |
| Reoptimize returns new order | API demo: `rerouted: true`, `optimized_route` differs from input |

---

## Checklist for Committee Day

- [ ] Run `python3 -m model.alns_validation` and save `committee_stats.txt`
- [ ] Have backend running if you want full Simulate flow
- [ ] Use `http://127.0.0.1:8000` in `env.dart` if demo is on simulator
- [ ] Add 2–3 stops, one fragile, one with early deadline
- [ ] Tap Start → then Simulate traffic
- [ ] Explain: "The system detected a traffic event and reordered stops to reduce ETA"

---

## If Simulate Does Nothing

1. **Offline demo**: Backend is optional. Simulate will fall back to offline reroute and show "Demo: Route adapted (incident simulated, offline)".
2. **Backend URL**: Ensure `Env.backendBaseUrl` matches your setup (127.0.0.1 for simulator, Mac IP for real device).
3. **Backend running**: In the terminal, you should see `Uvicorn running on http://0.0.0.0:8000`.
