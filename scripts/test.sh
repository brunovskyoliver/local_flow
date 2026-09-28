#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .specify/feature.json && -z "${SPECIFY_FEATURE_DIRECTORY:-}" ]]; then
  export SPECIFY_FEATURE_DIRECTORY="$PWD/specs/001-local-dictation"
fi
swift format lint --strict --recursive apps/macos/LocalFlow apps/macos/LocalFlowTests apps/macos/LocalFlowUITests
for script in scripts/*.sh .specify/scripts/bash/*.sh; do bash -n "$script"; done
./scripts/check-transcript-imports.sh
./scripts/check-identification-imports.sh
./scripts/check-intelligence-imports.sh
./scripts/check-speech-worker-imports.sh
python3 scripts/validate-foundation.py
python3 scripts/test-dictation-accuracy.py
python3 scripts/test-transcription-quality.py
python3 scripts/test-acquire-quality-corpus.py
python3 scripts/test-rewrite-quality.py
python3 scripts/test-analysis-quality.py
python3 scripts/test-context-quality.py
plutil -lint apps/macos/LocalFlow/Info.plist apps/macos/LocalFlow.xcodeproj/project.pbxproj
(cd server && test -z "$(gofmt -l cmd internal)" && go test ./... && go vet ./...)
# Feature 014 SC-009: the remote packages' verbose test logs (flowd and worker lines)
# carry no tokens or content; the app's unified log is scanned after XCTest below.
log_scan_dir="$(mktemp -d "${TMPDIR:-/tmp}/localflow-log-scan.XXXXXX")"
xctest_started="$(date +%s)"
(cd server && go test -count=1 -v ./internal/remote/... ./internal/speech/... ./internal/accounts/... \
  ./internal/oidc/... ./cmd/flowd/...) >"$log_scan_dir/go-remote.log" 2>&1
analysis_eval_dir="$(mktemp -d "${TMPDIR:-/tmp}/localflow-analysis-eval.XXXXXX")"
trap 'rm -rf "$analysis_eval_dir" "$log_scan_dir"' EXIT
TEST_RUNNER_LOCALFLOW_ANALYSIS_EVAL_DIR="$analysis_eval_dir" \
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
python3 scripts/analysis-quality.py "$analysis_eval_dir/analysis-eval.json"
./scripts/check-remote-logs.sh --unified-log "$(( ($(date +%s) - xctest_started) / 60 + 1 ))" \
  "$log_scan_dir/go-remote.log"
# Feature 014: the speech worker target compiles on its own.
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -target flowd-speech -configuration Debug \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/build/SpeechWorker" build
.specify/scripts/bash/check-prerequisites.sh --json
printf 'Repository checks and deterministic XCTest passed. Signed platform, dictation and hardware acceptance are separate.
'
