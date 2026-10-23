#!/usr/bin/env bash
# Exercise actual source-built nested bundles, without touching an installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-sparkle.sh
stage="$(mktemp -d "${TMPDIR:-/tmp}/localflow-sparkle-signing.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Contents/Frameworks"
ditto build/Sparkle/DerivedData/Build/Products/Release/Sparkle.framework \
  "$stage/Contents/Frameworks/Sparkle.framework"
# Unsigned test builds skip signing without requiring Xcode's signing variables.
CODE_SIGNING_ALLOWED=NO ./scripts/sign-embedded-sparkle.sh
for attempt in 1 2; do
  CODE_SIGNING_ALLOWED=YES EXPANDED_CODE_SIGN_IDENTITY=- TARGET_BUILD_DIR="$stage" \
    FRAMEWORKS_FOLDER_PATH=Contents/Frameworks ./scripts/sign-embedded-sparkle.sh
  codesign --verify --deep --strict "$stage/Contents/Frameworks/Sparkle.framework"
done
printf 'Nested Sparkle signing and repeated signing passed.\n'
