#!/usr/bin/env bash
# Explicit VAD provisioning through LocalFlow's pinned, bounded ModelProvisioner.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 ]]; then
  printf 'Usage: %s NEW_VAD_MODEL_ROOT\n' "$0" >&2
  exit 1
fi
umask 077
parent="$(dirname "$1")"
mkdir -m 700 -p "$parent"
output="$(cd "$parent" && pwd)/$(basename "$1")"
if [[ -e "$output" ]]; then
  printf 'Refusing to replace an existing VAD model root.\n' >&2
  exit 1
fi
export TEST_RUNNER_LOCALFLOW_VAD_PROVISION_OUTPUT="$output"
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInProvisionVADModel test
printf 'Pinned VAD model provisioned and verified.\n'
