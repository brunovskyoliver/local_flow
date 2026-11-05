#!/usr/bin/env bash
# Packages the Rust desktop client as LocalFlow.app for the Homebrew cask, not notarized (the cask
# clears the download quarantine). Writes the zip, its SHA-256 and localflow.rb to
# build/distribution/VERSION.
#   scripts/package-rust-macos.sh VERSION
# Signed with one fixed certificate, so macOS keeps Microphone, Input Monitoring and Accessibility
# across upgrades: LOCALFLOW_SIGN, else your Apple Development certificate. An ad-hoc signature is
# new on every build and macOS asks again, so it takes LOCALFLOW_SIGN=- on purpose.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/package-rust-macos.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be X.Y.Z" >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "Build on an Apple-silicon Mac" >&2; exit 1; }
output="build/distribution/$version"
app="build/rust-release/LocalFlow.app"
scripts/bundle-rust-app.sh "$app" LocalFlow org.localflow.LocalFlow "$version" "$(git rev-parse --short HEAD)"
identity="${LOCALFLOW_SIGN:-$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Apple Development: $(git config user.email) ([A-Z0-9]*)\)\"/\1/p" | head -1)}"
[[ -n "$identity" ]] || { echo "No Apple Development certificate for $(git config user.email). Set LOCALFLOW_SIGN (- for ad-hoc, and macOS asks for permissions after every upgrade)." >&2; exit 1; }
# Inside out: Mach-O helpers and the resource bundle first, then the app.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then codesign --force --sign "$identity" "$binary"; fi
done < <(find "$app/Contents/Helpers" -type f -print0)
codesign --force --sign "$identity" "$app/Contents/Helpers/FluidAudio_FluidAudio.bundle"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$output"
archive="LocalFlow-$version-arm64.zip"
rm -f "$output/$archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
(cd "$output" && shasum -a 256 "$archive" > "$archive.sha256")
python3 scripts/render-homebrew-cask.py "$version" "$output/$archive" "$output/localflow.rb"
ruby -c "$output/localflow.rb" >/dev/null
printf 'Packaged %s\n' "$output/$archive"
