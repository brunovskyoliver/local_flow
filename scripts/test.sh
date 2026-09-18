#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .specify/feature.json && -z "${SPECIFY_FEATURE_DIRECTORY:-}" ]]; then
  export SPECIFY_FEATURE_DIRECTORY="$PWD/specs/001-local-dictation"
fi
swift format lint --strict --recursive apps/macos/LocalFlow apps/macos/LocalFlowTests apps/macos/LocalFlowUITests
for script in scripts/*.sh .specify/scripts/bash/*.sh; do bash -n "$script"; done
python3 scripts/validate-foundation.py
python3 scripts/test-dictation-accuracy.py
python3 scripts/test-transcription-quality.py
python3 scripts/test-acquire-quality-corpus.py
python3 scripts/test-rewrite-quality.py
plutil -lint apps/macos/LocalFlow/Info.plist apps/macos/LocalFlow.xcodeproj/project.pbxproj
(cd server && test -z "$(gofmt -l cmd internal)" && go test ./... && go vet ./...)
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
.specify/scripts/bash/check-prerequisites.sh --json
printf 'Repository checks and deterministic XCTest passed. Signed platform, dictation and hardware acceptance are separate.
'
