#!/usr/bin/env bash
# Opt-in Go-Swift pairing check (Feature 027). Serves flowd's real serve path from a Go test
# binary on loopback with a temp data dir and a fake Keychain, then runs the Swift client
# against it. Touches no Keychain item, no live LocalFlow and no port but two free loopback
# ones. A built flowd can't run here: it always reads the login Keychain, and adding a way
# round that would be a production hook. The client's device key and credentials are doubles.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/localflow-pair-e2e.XXXXXX")"
info="$work/info.json"
server_pid=""
cleanup() {
  touch "$info.done"
  [[ -z "$server_pid" ]] || wait "$server_pid" || true
  rm -rf "$work"
}
trap cleanup EXIT
(cd server && LOCALFLOW_E2E_INFO="$info" go test -count=1 -run '^TestE2EServe$' ./cmd/flowd) >"$work/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 600); do
  [[ -f "$info" ]] && break
  kill -0 "$server_pid" 2>/dev/null || { cat "$work/server.log" >&2; exit 1; }
  sleep 0.1
done
[[ -f "$info" ]] || { echo "the server did not start" >&2; exit 1; }
TEST_RUNNER_LOCALFLOW_E2E_INFO="$info" \
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  test -only-testing:LocalFlowTests/RemoteEnrollmentTests/testPairAgainstARealServer
echo "Pairing end to end passed against flowd's serve path on loopback."
