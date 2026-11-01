#!/usr/bin/env bash
# Builds "LocalFlow Dev", the Rust desktop client as an app on this Mac, beside the Swift app. It has
# its own bundle ID, data folder and Keychain service. Signed with your Apple Development certificate
# so macOS keeps its permissions across rebuilds; set LOCALFLOW_DEV_SIGN to use another identity. Without
# a certificate it's ad-hoc signed and macOS asks again after each rebuild. Quit the Swift app before dictating, or give the two different shortcuts.
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-/Applications/LocalFlow Dev.app}"
staging="build/rust-dev/LocalFlow Dev.app"

cargo build --release -j 4 -p localflow
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -target flowd-speech -configuration Release \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO SYMROOT="$PWD/build/SpeechWorker" build

rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Helpers"
install -m 755 build/rust/release/localflow "$staging/Contents/MacOS/LocalFlow"
install -m 755 build/SpeechWorker/Release/flowd-speech "$staging/Contents/Helpers/flowd-speech"
ditto build/SpeechWorker/Release/FluidAudio_FluidAudio.bundle "$staging/Contents/Helpers/FluidAudio_FluidAudio.bundle"
# The pinned descriptors the worker is pointed at. Code signing refuses them in Helpers.
mkdir -p "$staging/Contents/Resources/Models"
install -m 644 apps/macos/LocalFlow/Resources/Models/parakeet-v3.json apps/macos/LocalFlow/Resources/Models/parakeet-ctc-110m.json \
  apps/macos/LocalFlow/Resources/Models/whisper-large-v3-turbo.json apps/macos/LocalFlow/Resources/Models/speaker-diarization-offline.json "$staging/Contents/Resources/Models/"
# The on-device AI services, under the labels, folder and ports the Swift app uses: where Swift has set
# them up the app reuses them, and otherwise it registers these.
ai="apps/macos/LocalFlow/Resources/LocalAI"
mkdir -p "$staging/Contents/Resources/LocalAI" "$staging/Contents/Library/LaunchAgents"
(cd server && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags=-s -o "../$staging/Contents/Helpers/flowd" ./cmd/flowd)
render() {
  sed -e "s|@BUNDLE_ID@|org.localflow.LocalFlow|g" -e "s|@DIRECTORY@|LocalFlow|g" -e "s|@EXECUTABLE@|LocalFlow|g" \
    -e "s|@MTPLX_PORT@|8000|g" -e "s|@FLOWD_PORT@|8080|g" \
    -e "/AssociatedBundleIdentifiers/,/<\/array>/s|org.localflow.LocalFlow|org.localflow.LocalFlow.rust-dev|" "$1" >"$2"
  chmod "$3" "$2"
}
render "$ai/localflow-mtplx" "$staging/Contents/Resources/LocalAI/localflow-mtplx" 755
render "$ai/localflow-flowd" "$staging/Contents/Resources/LocalAI/localflow-flowd" 755
install -m 644 "$ai/mtplx-requirements.txt" "$staging/Contents/Resources/LocalAI/"
render "$ai/flowd.plist.template" "$staging/Contents/Library/LaunchAgents/org.localflow.LocalFlow.flowd.plist" 644
render "$ai/mtplx.plist.template" "$staging/Contents/Library/LaunchAgents/org.localflow.LocalFlow.mtplx.plist" 644
sha="$(git rev-parse --short HEAD)"
cat > "$staging/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LocalFlow Dev</string>
<key>CFBundleDisplayName</key><string>LocalFlow Dev</string>
<key>CFBundleExecutable</key><string>LocalFlow</string>
<key>CFBundleIdentifier</key><string>org.localflow.LocalFlow.rust-dev</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0-dev</string>
<key>CFBundleVersion</key><string>$sha</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>LocalFlow Dev uses the microphone for local dictation.</string>
</dict></plist>
PLIST
identity="${LOCALFLOW_DEV_SIGN:-$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Apple Development: $(git config user.email) ([A-Z0-9]*)\)\"/\1/p" | head -1)}"
if [[ -z "$identity" ]]; then
  echo "No Apple Development certificate for $(git config user.email): ad-hoc signing, so macOS will ask for permissions again." >&2
  identity=-
fi
codesign --force --sign "$identity" "$staging/Contents/Helpers/flowd" "$staging/Contents/Helpers/flowd-speech" "$staging/Contents/Helpers/FluidAudio_FluidAudio.bundle"
codesign --force --sign "$identity" "$staging"
rm -rf "$target"
ditto "$staging" "$target"
echo "Installed $target ($sha)"
