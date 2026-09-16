#!/usr/bin/env bash
set -euo pipefail
pid=${1:-}
samples=${2:-30}
if [[ ! "$pid" =~ ^[1-9][0-9]*$ || ! "$samples" =~ ^[1-9][0-9]*$ || ${#samples} -gt 4 ]] || (( samples > 3600 )); then
  echo "Usage: $0 PID [samples: 1..3600] (one RSS sample/second)" >&2
  exit 2
fi
printf 'timestamp_utc,pid,rss_kib
'
for ((i=0; i<samples; i++)); do
  rss=$(ps -o rss= -p "$pid") || { echo "Process exited; report incomplete" >&2; exit 1; }
  rss=${rss//[[:space:]]/}
  [[ -n "$rss" ]] || exit 1
  printf '%s,%s,%s
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pid" "$rss"
  if (( i + 1 < samples )); then sleep 1; fi
done
