#!/bin/bash
# Run this before your committee presentation to capture proof statistics.
# Output: committee_stats.txt

cd "$(dirname "$0")"
OUT=committee_stats.txt

echo "=== Optimile Committee Demo - $(date) ===" | tee "$OUT"
echo "" | tee -a "$OUT"

echo "--- 1. Traffic stress test (same route, different traffic levels) ---" | tee -a "$OUT"
python3 -m model.alns_validation 2>&1 | tee -a "$OUT"
echo "" | tee -a "$OUT"

echo "--- 2. ALNS explanation (penalty breakdown) ---" | tee -a "$OUT"
python3 demo_alns_scenario.py --mode alns 2>&1 | tee -a "$OUT"
echo "" | tee -a "$OUT"

echo "--- 3. Reoptimize API (traffic incident simulation) ---" | tee -a "$OUT"
# Only if backend is running
if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/docs 2>/dev/null | grep -q 200; then
  python3 demo_alns_scenario.py --mode api 2>&1 | tee -a "$OUT"
else
  echo "Backend not running. Start with: uvicorn backend.main:app --reload --host 0.0.0.0" | tee -a "$OUT"
fi

echo "" | tee -a "$OUT"
echo "=== Done. Statistics saved to $OUT ===" | tee -a "$OUT"
