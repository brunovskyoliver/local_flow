#!/usr/bin/env bash
# Feature 013 before/after benchmark through the production runtime. Each clip is
# recognized twice by one loaded runtime: without and with the Dictionary.
# Usage: vocabulary-boost-benchmark.sh MANIFEST.json VOCABULARY.json OUTPUT.jsonl
# Model roots default to the installed app's; override with LOCALFLOW_BOOST_BENCH_MODEL
# and LOCALFLOW_BOOST_BENCH_BOOSTER. Never called by make check.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 3 ]]; then
  printf 'Usage: %s MANIFEST.json VOCABULARY.json OUTPUT.jsonl\n' "$0" >&2
  exit 2
fi
models="$HOME/Library/Application Support/LocalFlow/Models"
absolute() { (cd "$(dirname "$1")" && printf '%s/%s' "$PWD" "$(basename "$1")"); }
export TEST_RUNNER_LOCALFLOW_BOOST_BENCH_MANIFEST="$(absolute "$1")"
export TEST_RUNNER_LOCALFLOW_BOOST_BENCH_VOCABULARY="$(absolute "$2")"
export TEST_RUNNER_LOCALFLOW_BOOST_BENCH_OUTPUT="$(absolute "$3")"
export TEST_RUNNER_LOCALFLOW_BOOST_BENCH_MODEL="${LOCALFLOW_BOOST_BENCH_MODEL:-$models/parakeet-v3}"
export TEST_RUNNER_LOCALFLOW_BOOST_BENCH_BOOSTER="${LOCALFLOW_BOOST_BENCH_BOOSTER:-$models/parakeet-ctc-110m}"
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/BoostBenchDerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  -only-testing:LocalFlowTests/VocabularyBoostBenchmarkHarness test
printf 'hardware=%s os=%s build=%s\n' "$(sysctl -n machdep.cpu.brand_string)" \
  "$(sw_vers -productVersion)" "$(git rev-parse --short HEAD)"
