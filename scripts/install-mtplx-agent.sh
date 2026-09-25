#!/usr/bin/env bash
# Development installer: runs the MTPLX rewrite model headless, without MTPLX.app,
# whose dashboard streams live metrics and keeps the server waking while idle.
# Quit MTPLX.app first; both want 127.0.0.1:8000.
set -euo pipefail
umask 077
if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo 'Usage: scripts/install-mtplx-agent.sh <mtplx-model-directory>' >&2
  exit 64
fi
mtplx="$HOME/Library/Application Support/MTPLX/runtime-venv/bin/mtplx"
key="$HOME/Library/Application Support/MTPLX/daemon-api-key"
[[ -x "$mtplx" && -s "$key" ]] || {
  echo 'MTPLX runtime or API key missing. Set MTPLX up once with MTPLX.app.' >&2
  exit 1
}
agent_plist="$HOME/Library/LaunchAgents/org.localflow.mtplx.plist"
agent_target="gui/$(id -u)/org.localflow.mtplx"
mkdir -p "$(dirname "$agent_plist")"
if launchctl print "$agent_target" >/dev/null 2>&1; then
  launchctl bootout "$agent_target"
fi
# Same serving flags MTPLX.app uses, bound to loopback only. flowd reads the key file.
python3 - "$mtplx" "$1" "$key" "$agent_plist" <<'PY'
import os, plistlib, sys
mtplx, model, key, destination = sys.argv[1:]
payload = {
    'Label': 'org.localflow.mtplx',
    'ProgramArguments': [
        mtplx, 'serve', '--host', '127.0.0.1', '--port', '8000', '--model', model,
        '--profile', 'sustained', '--scheduler-mode', 'serial',
        '--batching-preset', 'latency', '--depth', '3', '--ssd-session-cache', 'off',
        '--context-window', '32768', '--api-key-file', key, '--fan-mode', 'smart',
        '--unsafe-force-unverified', '--yes', '--reasoning', 'off',
        '--adaptive-policy', 'expected_value', '--no-stats-footer',
    ],
    'RunAtLoad': True,
    'KeepAlive': True,
    'ThrottleInterval': 30,
    'LimitLoadToSessionType': 'Aqua',
    'StandardOutPath': '/dev/null',
    'StandardErrorPath': '/dev/null',
}
staging = destination + '.next'
with open(staging, 'wb') as output:
    plistlib.dump(payload, output)
os.chmod(staging, 0o600)
os.replace(staging, destination)
PY
plutil -lint "$agent_plist"
launchctl enable "$agent_target"
launchctl bootstrap "gui/$(id -u)" "$agent_plist"
printf 'Installed login service: %s\n' "$agent_target"
