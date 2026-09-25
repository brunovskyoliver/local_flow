#!/usr/bin/env bash
# Xcode build phase: builds flowd into the app and bundles the local AI login
# services, so a shipped LocalFlow.app needs no Go toolchain or repository.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" ]]; then
  echo 'Run from the Xcode build.' >&2
  exit 64
fi
# Xcode does not inherit the interactive shell PATH.
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$PATH"
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
source="$repository/apps/macos/LocalFlow/Resources/LocalAI"
mkdir -p "$contents/Helpers" "$contents/Resources/LocalAI" "$contents/Library/LaunchAgents"
(cd "$repository/server" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
  go build -trimpath -buildvcs=false -ldflags=-s -o "$contents/Helpers/flowd" ./cmd/flowd)
install -m 755 "$source/localflow-mtplx" "$source/localflow-flowd" "$contents/Resources/LocalAI/"
install -m 644 "$source/mtplx-requirements.txt" "$contents/Resources/LocalAI/"
install -m 644 "$source"/org.localflow.LocalFlow.*.plist "$contents/Library/LaunchAgents/"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none \
    "$contents/Helpers/flowd"
fi
