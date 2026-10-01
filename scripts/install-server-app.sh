#!/bin/bash
# Builds LocalFlow Server (ADR 0032) on this Mac, which has Xcode, copies it to
# /Applications on the server Mac over SSH and opens it there. The server Mac needs
# only an SSH login as the account that runs the server agents.
#
#   scripts/install-server-app.sh <ssh-host> [--snapshot DIR]
#
# --snapshot DIR opens the app with LOCALFLOW_SERVER_SNAPSHOT_DIR so it renders its
# views to PNG files and quits, then copies them into DIR on this Mac.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: scripts/install-server-app.sh <ssh-host> [--snapshot DIR]" >&2; exit 1; }
host="$1"
snapshot=""
if [ "${2:-}" = "--snapshot" ]; then
  [ $# -ge 3 ] || { echo "error: --snapshot needs a directory" >&2; exit 1; }
  snapshot="$3"
fi
repository="$(cd "$(dirname "$0")/.." && pwd)"
products="$repository/build/DerivedData/Build/Products/Release"

xcodebuild -quiet -project "$repository/apps/macos/LocalFlow.xcodeproj" -scheme LocalFlowServer \
  -configuration Release -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$repository/build/DerivedData" build

# shellcheck disable=SC2029 # the remote commands are fixed strings
ssh "$host" 'pkill -x "LocalFlow Server" || true; rm -rf "/Applications/LocalFlow Server.app"'
tar -C "$products" -cf - "LocalFlow Server.app" | ssh "$host" 'tar -C /Applications -xf -'

if [ -z "$snapshot" ]; then
  ssh "$host" 'open "/Applications/LocalFlow Server.app"'
  echo "Installed and opened LocalFlow Server on $host."
  exit 0
fi
remote_dir="/tmp/localflow-server-snapshot"
ssh "$host" "rm -rf $remote_dir && open -W --env LOCALFLOW_SERVER_SNAPSHOT_DIR=$remote_dir '/Applications/LocalFlow Server.app' && open '/Applications/LocalFlow Server.app'"
mkdir -p "$snapshot"
scp -q "$host:$remote_dir/*.png" "$snapshot/"
echo "Installed LocalFlow Server on $host; snapshots in $snapshot."
