#!/usr/bin/env bash
# Builds "LocalFlow Dev", the Rust desktop client as an app on this Mac, beside the Swift app. It has
# its own bundle ID, data folder and Keychain service. Signed with your Apple Development certificate
# so macOS keeps its permissions across rebuilds; set LOCALFLOW_DEV_SIGN to use another identity. Without
# a certificate it's ad-hoc signed and macOS asks again after each rebuild. Quit the Swift app before dictating, or give the two different shortcuts.
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-/Applications/LocalFlow Dev.app}"
staging="build/rust-dev/LocalFlow Dev.app"

sha="$(git rev-parse --short HEAD)"
scripts/bundle-rust-app.sh "$staging" "LocalFlow Dev" org.localflow.LocalFlow.rust-dev 0.0.0-dev "$sha"
identity="${LOCALFLOW_DEV_SIGN:-$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Apple Development: $(git config user.email) ([A-Z0-9]*)\)\"/\1/p" | head -1)}"
if [[ -z "$identity" ]]; then
  echo "No Apple Development certificate for $(git config user.email): ad-hoc signing, so macOS will ask for permissions again." >&2
  identity=-
fi
codesign --force --sign "$identity" "$staging/Contents/Helpers/flowd" "$staging/Contents/Helpers/flowd-speech" \
  "$staging/Contents/Helpers/flowd-meeting" "$staging/Contents/Helpers/localflow-whisper-engine" \
  "$staging/Contents/Helpers/FluidAudio_FluidAudio.bundle"
codesign --force --sign "$identity" "$staging"
rm -rf "$target"
ditto "$staging" "$target"
echo "Installed $target ($sha)"
