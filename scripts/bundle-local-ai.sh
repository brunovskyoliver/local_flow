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
# The agents and their launch scripts carry the variant's label, directories and
# ports (Feature 014), so a dev build never replaces the installed app's agents.
bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:-org.localflow.LocalFlow}"
port_base="${LOCALFLOW_PORT_BASE:-8000}"
[[ "$port_base" =~ ^[0-9]+$ ]] || { echo "LOCALFLOW_PORT_BASE must be a number" >&2; exit 64; }
if [[ "$bundle_id" == org.localflow.LocalFlow ]]; then directory=LocalFlow; else directory="LocalFlow Dev"; fi
if [[ "$bundle_id" != org.localflow.LocalFlow && "$port_base" == 8000 ]]; then
  echo "A build with bundle identifier $bundle_id must not use the production ports" >&2
  exit 64
fi
render() {
  sed -e "s|@BUNDLE_ID@|$bundle_id|g" -e "s|@DIRECTORY@|$directory|g" \
    -e "s|@EXECUTABLE@|${EXECUTABLE_NAME:-LocalFlow}|g" \
    -e "s|@MTPLX_PORT@|$port_base|g" -e "s|@FLOWD_PORT@|$((port_base + 80))|g" "$1" >"$2"
  chmod "$3" "$2"
}
render "$source/localflow-mtplx" "$contents/Resources/LocalAI/localflow-mtplx" 755
render "$source/localflow-flowd" "$contents/Resources/LocalAI/localflow-flowd" 755
# A dev name contains a space; a rendering that breaks the shell grammar must fail the build,
# not the agent at run time.
for script in localflow-mtplx localflow-flowd; do sh -n "$contents/Resources/LocalAI/$script"; done
install -m 644 "$source/mtplx-requirements.txt" "$contents/Resources/LocalAI/"
rm -f "$contents"/Library/LaunchAgents/*.plist
render "$source/flowd.plist.template" "$contents/Library/LaunchAgents/$bundle_id.flowd.plist" 644
render "$source/mtplx.plist.template" "$contents/Library/LaunchAgents/$bundle_id.mtplx.plist" 644
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none \
    "$contents/Helpers/flowd"
fi
