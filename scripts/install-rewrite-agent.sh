#!/usr/bin/env bash
# Development installer for this Mac's existing loopback MTPLX setup.
set -euo pipefail
umask 077
if [[ $# -ne 1 || -z "$1" ]]; then
  echo 'Usage: scripts/install-rewrite-agent.sh <served-mtplx-model-id>' >&2
  exit 64
fi
cd "$(dirname "$0")/.."
agent_dir="$HOME/Library/Application Support/LocalFlow/RewriteServer"
agent_plist="$HOME/Library/LaunchAgents/org.localflow.flowd.rewrite.plist"
agent_target="gui/$(id -u)/org.localflow.flowd.rewrite"
mkdir -p "$agent_dir" "$(dirname "$agent_plist")"
chmod 700 "$agent_dir"
(cd server && go build -o "$agent_dir/flowd.next" ./cmd/flowd)
install -m 700 scripts/run-rewrite-agent.sh "$agent_dir/run.next"
# Stop only our registered job. An unrelated listener on 8080 is never killed.
if launchctl print "$agent_target" >/dev/null 2>&1; then
  launchctl bootout "$agent_target"
fi
mv "$agent_dir/flowd.next" "$agent_dir/flowd"
mv "$agent_dir/run.next" "$agent_dir/run.sh"
python3 - "$agent_dir" "$agent_plist" "$1" <<'PY'
import os, plistlib, sys
from pathlib import Path
root, destination, model = sys.argv[1:]
payload = {
    'Label': 'org.localflow.flowd.rewrite',
    'ProgramArguments': [str(Path(root) / 'run.sh'), model],
    'RunAtLoad': True,
    'KeepAlive': True,
    'ThrottleInterval': 30,
    'ProcessType': 'Background',
    'LimitLoadToSessionType': 'Aqua',
    # Avoid an unbounded launchd log; flowd writes its own capped request log
    # to ~/Library/Logs/LocalFlow/flowd.log (see run-rewrite-agent.sh).
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
