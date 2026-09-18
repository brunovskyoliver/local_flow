#!/usr/bin/env bash
# Explicit local real-model regression test. Not part of make check.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 3 || $# -gt 4 ]]; then
  printf 'Usage: %s PROVISIONED_MODEL_ROOT FROZEN_CORPUS_ROOT NEW_OUTPUT_ROOT [fresh|sequential]\n' "$0" >&2
  exit 1
fi
model_root="$(cd "$1" && pwd)"
corpus_root="$(cd "$2" && pwd)"
mode="${4:-fresh}"
case "$mode" in
  fresh) fresh=1 ;;
  sequential) fresh=0 ;;
  *) printf 'Expected fresh or sequential.\n' >&2; exit 1 ;;
esac
umask 077
mkdir -m 700 "$3"
output_root="$(cd "$3" && pwd)"
export TEST_RUNNER_LOCALFLOW_EMPTY_TAIL_MODEL="$model_root"
export TEST_RUNNER_LOCALFLOW_EMPTY_TAIL_CORPUS="$corpus_root"
export TEST_RUNNER_LOCALFLOW_EMPTY_TAIL_FRESH="$fresh"
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$output_root/result.xcresult" \
  -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInEmptyTailRecognition test \
  > "$output_root/test.log" 2>&1
