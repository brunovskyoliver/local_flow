#!/bin/bash
# Installed beside flowd; launchd owns the process after exec.
set -euo pipefail
set +x
umask 077
if [[ $# -ne 1 || -z "$1" ]]; then
  echo 'A served MTPLX model id is required.' >&2
  exit 64
fi
agent_dir="$(cd "$(dirname "$0")" && pwd)"
LOCALFLOW_REWRITE_TOKEN="$(/usr/bin/security find-generic-password \
  -s org.localflow.LocalFlow.rewrite -a http://127.0.0.1:8080 -w)"
LOCALFLOW_BACKEND_TOKEN="$(cat "$HOME/Library/Application Support/MTPLX/daemon-api-key")"
# Fail closed if Keychain or MTPLX credentials are unavailable at login.
[[ -n "$LOCALFLOW_REWRITE_TOKEN" && -n "$LOCALFLOW_BACKEND_TOKEN" ]]
export LOCALFLOW_REWRITE_TOKEN LOCALFLOW_BACKEND_TOKEN
# flowd caps its own request log (1 MiB + one rotated copy); launchd output
# stays discarded.
log_dir="$HOME/Library/Logs/LocalFlow"
mkdir -p "$log_dir"
exec "$agent_dir/flowd" rewrite --listen 127.0.0.1:8080 \
  --backend http://127.0.0.1:8000/v1 --model "$1" \
  --log-file "$log_dir/flowd.log"
