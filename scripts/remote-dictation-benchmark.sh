#!/usr/bin/env bash
# Feature 014 (T086): runs the remote dictation replay in a Debug LocalFlow Dev build
# against the enrolled, approved server and prints median and p95 added time after key
# release (SC-001), fallback time with an unreachable server (SC-003), transcript
# differences with boosting on and off (SC-005) and, with --users K, per-user added wait
# for K concurrent sessions (SC-002). It records what was measured; nothing is estimated.
#   scripts/remote-dictation-benchmark.sh --server https://host --recordings DIR --runs N [--users K] [--output DIR]
set -euo pipefail
cd "$(dirname "$0")/.."
app=${LOCALFLOW_APP:-"/Applications/LocalFlow Dev.app"}
server="" recordings="" runs=20 users=1 outdir=build/remote-benchmark
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) server="$2"; shift 2 ;;
    --recordings) recordings="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --users) users="$2"; shift 2 ;;
    --output) outdir="$2"; shift 2 ;;
    *) echo "usage: $0 --server URL --recordings DIR --runs N [--users K] [--output DIR]" >&2; exit 64 ;;
  esac
done
[[ "$server" == https://* && -d "$recordings" ]] || { echo "--server https://… and --recordings DIR are required" >&2; exit 64; }
[[ "$runs" =~ ^[1-9][0-9]{0,2}$ && "$users" =~ ^[1-9]$ ]] || { echo "--runs 1..999, --users 1..9" >&2; exit 64; }
[[ -d "$app" ]] || { echo "No Debug dev build at $app. Run 'make run-dev' first." >&2; exit 1; }
if pgrep -x "LocalFlow Dev" >/dev/null; then
  echo "LocalFlow Dev is running. Quit it so the run starts from a known state." >&2
  exit 1
fi
mkdir -p "$outdir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
converted="$(mktemp -d "${TMPDIR:-/tmp}/localflow-replay.XXXXXX")"
trap 'rm -rf "$converted"' EXIT
# The replay reads 16 kHz mono Float32; convert every recording once.
count=0
for file in "$recordings"/*.wav "$recordings"/*.m4a "$recordings"/*.caf; do
  [[ -f "$file" ]] || continue
  afconvert -f WAVE -d LEF32@16000 -c 1 "$file" "$converted/$(basename "${file%.*}").wav"
  count=$((count + 1))
done
(( count > 0 )) || { echo "No .wav, .m4a or .caf recordings in $recordings" >&2; exit 1; }
# The app writes the result, so the path must be absolute whatever --output was.
result="$(cd "$outdir" && pwd)/remote-benchmark-$stamp.json"
meta="$outdir/conditions-$stamp.txt"
{
  printf 'utc=%s\n' "$stamp"
  printf 'client_hardware=%s\n' "$(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string)"
  printf 'os=%s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
  printf 'app_version=%s\n' "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")"
  printf 'server=%s recordings=%s runs=%s users=%s\n' "$server" "$count" "$runs" "$users"
  printf 'network=%s\n' "${LOCALFLOW_NETWORK_LABEL:-unlabelled (set LOCALFLOW_NETWORK_LABEL, e.g. home-wifi or lte)}"
} >"$meta"
open -W \
  --env LOCALFLOW_REMOTE_REPLAY=1 \
  --env LOCALFLOW_REMOTE_REPLAY_SERVER="$server" \
  --env LOCALFLOW_REMOTE_REPLAY_RECORDINGS="$converted" \
  --env LOCALFLOW_REMOTE_REPLAY_RUNS="$runs" \
  --env LOCALFLOW_REMOTE_REPLAY_USERS="$users" \
  --env LOCALFLOW_REMOTE_REPLAY_OUTPUT="$result" \
  "$app"
[[ -s "$result" ]] || { echo "No result was written; the run is incomplete. Do not record it." >&2; exit 1; }
if grep -q '"status" *: *"failed"' "$result"; then
  echo "Replay failed (is remote dictation on, this device approved, and --server the enrolled server?):" >&2
  cat "$result" >&2
  exit 1
fi
python3 - "$result" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
by = {(s["mode"], s["boost"]): s for s in report["summaries"]}
for boost in (False, True):
    remote, local = by.get(("remote", boost)), by.get(("local", boost))
    if remote and local:
        print(f"boost={boost}: remote median {remote['medianMilliseconds']:.0f} ms p95 {remote['p95Milliseconds']:.0f} ms; "
              f"local median {local['medianMilliseconds']:.0f} ms p95 {local['p95Milliseconds']:.0f} ms; "
              f"added median {remote['medianMilliseconds'] - local['medianMilliseconds']:.0f} ms")
    fallback = by.get(("fallback", boost))
    if fallback:
        print(f"boost={boost}: fallback median {fallback['medianMilliseconds']:.0f} ms p95 {fallback['p95Milliseconds']:.0f} ms")
    concurrent = by.get(("concurrent", boost))
    if concurrent and remote:
        print(f"boost={boost}: concurrent median {concurrent['medianMilliseconds']:.0f} ms, "
              f"added wait {concurrent['medianMilliseconds'] - remote['medianMilliseconds']:.0f} ms per user")
# A row that succeeded has no "failure" key.
failures = [r for r in report["rows"] if r.get("failure") and r["mode"] != "fallback"]
print(f"rows={len(report['rows'])} remote_failures={len(failures)} transcript_differences={len(report['transcriptDifferences'])}")
for name in report["transcriptDifferences"]:
    print(f"  differs: {name}")
PY
printf 'Result: %s\nConditions: %s\n' "$result" "$meta"
