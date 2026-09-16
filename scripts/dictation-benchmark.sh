#!/usr/bin/env bash
# Runs the opt-in 20-cycle resource protocol in docs/performance/memory-budget.md
# against the installed signed app, alongside the bounded RSS sampler. It records
# what was measured; it never synthesizes a missing sample or a missing row.
set -euo pipefail
cd "$(dirname "$0")/.."

app=${LOCALFLOW_APP:-/Applications/LocalFlow.app}
cycles=${LOCALFLOW_BENCHMARK_CYCLES:-20}
hold=${LOCALFLOW_BENCHMARK_HOLD_SECONDS:-5}
capture_only=${LOCALFLOW_BENCHMARK_CAPTURE_ONLY:-0}
outdir=${1:-build/benchmark}

if [[ ! "$cycles" =~ ^[1-9][0-9]{0,2}$ || ! "$hold" =~ ^[1-9][0-9]{0,2}$ ]]; then
  echo "Usage: $0 [OUTPUT_DIR]   (LOCALFLOW_BENCHMARK_CYCLES/HOLD_SECONDS must be 1..999)" >&2
  exit 2
fi
if [[ ! -d "$app" ]]; then
  echo "Signed app not found at $app. Run 'make run' first." >&2
  exit 1
fi
if pgrep -x LocalFlow >/dev/null; then
  echo "LocalFlow is already running. Quit it so the run starts from an unloaded state." >&2
  exit 1
fi

mkdir -p "$outdir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
result="$outdir/benchmark-$stamp.json"
rss="$outdir/rss-$stamp.csv"
meta="$outdir/conditions-$stamp.txt"

# Hardware, OS and build identity belong with the samples, not in a later memory.
{
  printf 'utc=%s\n' "$stamp"
  printf 'hardware=%s\n' "$(sysctl -n hw.model)"
  printf 'os=%s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
  printf 'app_version=%s\n' \
    "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")"
  printf 'cycles=%s hold_seconds=%s capture_only=%s\n' "$cycles" "$hold" "$capture_only"
  printf 'power=%s\n' "$(pmset -g batt | head -n 1)"
} >"$meta"

LOCALFLOW_BENCHMARK=1 \
LOCALFLOW_BENCHMARK_CYCLES="$cycles" \
LOCALFLOW_BENCHMARK_HOLD_SECONDS="$hold" \
LOCALFLOW_BENCHMARK_CAPTURE_ONLY="$capture_only" \
LOCALFLOW_BENCHMARK_OUTPUT="$PWD/$result" \
LOCALFLOW_RESOURCE_RECORDING=1 \
  open -W "$app" &
app_pid=$!

# The app under measurement is the one the protocol reports on; identify it by
# process, not by bundle name, and stop sampling when it exits.
pid=""
for ((attempt = 0; attempt < 120; attempt++)); do
  pid=$(pgrep -x LocalFlow | head -n 1 || true)
  [[ -n "$pid" ]] && break
  sleep 0.5
done
if [[ -z "$pid" ]]; then
  echo "LocalFlow did not start; no samples were collected." >&2
  exit 1
fi

# Each cycle spends the 30-second cooldown plus settling; sample for the whole run.
samples=$(( (hold + 55) * cycles + 120 ))
(( samples > 3600 )) && samples=3600
./scripts/memory-report.sh "$pid" "$samples" >"$rss" 2>/dev/null || true

wait "$app_pid" || true

if [[ ! -s "$result" ]]; then
  echo "No benchmark result was written. The run is incomplete; do not record it." >&2
  exit 1
fi
if grep -q '"status" *: *"failed"' "$result"; then
  echo "Benchmark failed:" >&2
  cat "$result" >&2
  exit 1
fi

rows=$(grep -c '"cycleID"' "$result" || true)
printf 'Result: %s (%s cycle rows)\nRSS samples: %s\nConditions: %s\n' \
  "$result" "$rows" "$rss" "$meta"
printf 'Local measurement records remain in the app Measurements directory.\n'
if [[ "$rows" != "$cycles" && "$capture_only" == "0" ]]; then
  echo "Recorded $rows rows for $cycles cycles; reuse rows are expected, missing rows are not." >&2
fi
