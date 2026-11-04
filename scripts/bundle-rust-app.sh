#!/usr/bin/env bash
# Builds the Rust desktop client into an unsigned app bundle. Shared by install-rust-dev-app.sh
# ("LocalFlow Dev" on this Mac) and package-rust-macos.sh (the Homebrew release).
#   scripts/bundle-rust-app.sh STAGING_APP NAME BUNDLE_ID SHORT_VERSION BUILD_VERSION
set -euo pipefail
cd "$(dirname "$0")/.."
staging="$1" name="$2" bundle_id="$3" short_version="$4" build_version="$5"

cargo build --release -j 4 -p localflow
# flowd-meeting is the meeting handoff processor server mode passes to flowd (research R8).
for helper in flowd-speech flowd-meeting; do
  xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -target "$helper" -configuration Release \
    CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO SYMROOT="$PWD/build/SpeechWorker" build
done

rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Helpers"
install -m 755 build/rust/release/localflow "$staging/Contents/MacOS/LocalFlow"
install -m 755 build/SpeechWorker/Release/flowd-speech "$staging/Contents/Helpers/flowd-speech"
install -m 755 build/SpeechWorker/Release/flowd-meeting "$staging/Contents/Helpers/flowd-meeting"
ditto build/SpeechWorker/Release/FluidAudio_FluidAudio.bundle "$staging/Contents/Helpers/FluidAudio_FluidAudio.bundle"
# The Whisper helper for meeting transcripts, with its licences in Resources/WhisperLicenses, as in
# the Swift app.
TARGET_BUILD_DIR="$PWD/$(dirname "$staging")" CONTENTS_FOLDER_PATH="$(basename "$staging")/Contents" \
  CODE_SIGNING_ALLOWED=NO scripts/build-meeting-whisper.sh
# The app icon, drawn by scripts/make-app-icon.py.
mkdir -p "$staging/Contents/Resources"
install -m 644 apps/desktop/resources/AppIcon.icns "$staging/Contents/Resources/AppIcon.icns"
# The pinned descriptors the worker is pointed at. Code signing refuses them in Helpers.
models="apps/macos/LocalFlow/Resources/Models"
mkdir -p "$staging/Contents/Resources/Models"
install -m 644 "$models/parakeet-v3.json" "$models/parakeet-ultra.json" "$models/parakeet-ctc-110m.json" \
  "$models/whisper-large-v3-turbo.json" "$models/speaker-diarization-offline.json" "$staging/Contents/Resources/Models/"
# The on-device AI services, under the labels, folder and ports the Swift app uses: where Swift has set
# them up the app reuses them, and otherwise it registers these.
ai="apps/macos/LocalFlow/Resources/LocalAI"
mkdir -p "$staging/Contents/Resources/LocalAI" "$staging/Contents/Library/LaunchAgents"
(cd server && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags=-s -o "../$staging/Contents/Helpers/flowd" ./cmd/flowd)
render() {
  sed -e "s|@BUNDLE_ID@|org.localflow.LocalFlow|g" -e "s|@DIRECTORY@|LocalFlow|g" -e "s|@EXECUTABLE@|LocalFlow|g" \
    -e "s|@MTPLX_PORT@|8000|g" -e "s|@FLOWD_PORT@|8080|g" \
    -e "/AssociatedBundleIdentifiers/,/<\/array>/s|org.localflow.LocalFlow|$bundle_id|" "$1" >"$2"
  chmod "$3" "$2"
}
render "$ai/localflow-mtplx" "$staging/Contents/Resources/LocalAI/localflow-mtplx" 755
render "$ai/localflow-flowd" "$staging/Contents/Resources/LocalAI/localflow-flowd" 755
install -m 644 "$ai/mtplx-requirements.txt" "$staging/Contents/Resources/LocalAI/"
render "$ai/flowd.plist.template" "$staging/Contents/Library/LaunchAgents/org.localflow.LocalFlow.flowd.plist" 644
render "$ai/mtplx.plist.template" "$staging/Contents/Library/LaunchAgents/org.localflow.LocalFlow.mtplx.plist" 644
cat > "$staging/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleExecutable</key><string>LocalFlow</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$short_version</string>
<key>CFBundleVersion</key><string>$build_version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>$name uses the microphone for dictation and meeting notes.</string>
<key>NSLocalNetworkUsageDescription</key><string>$name connects to your own LocalFlow server when its address is on your local network.</string>
</dict></plist>
PLIST
