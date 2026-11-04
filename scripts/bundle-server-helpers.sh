#!/usr/bin/env bash
# Xcode build phase (Feature 027): copies flowd-speech, its FluidAudio resource bundle and
# flowd-meeting (the meeting handoff processor, Feature 028) into Contents/Helpers beside flowd
# and the Whisper helper, for server mode to install under the server's data directory. The app
# itself never runs them.
set -euo pipefail
if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" || -z "${BUILT_PRODUCTS_DIR:-}" ]]; then
  echo 'Run from the Xcode build.' >&2
  exit 64
fi
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers"
install -m 755 "$BUILT_PRODUCTS_DIR/flowd-speech" "$helpers/flowd-speech"
install -m 755 "$BUILT_PRODUCTS_DIR/flowd-meeting" "$helpers/flowd-meeting"
rm -rf "$helpers/FluidAudio_FluidAudio.bundle"
ditto "$BUILT_PRODUCTS_DIR/FluidAudio_FluidAudio.bundle" "$helpers/FluidAudio_FluidAudio.bundle"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  timestamp=(--timestamp=none)
  if [[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == 'Developer ID Application:'* ]]; then timestamp=(--timestamp); fi
  # Contents/Helpers holds nested code, so an unsigned bundle there fails the app's signature.
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "${timestamp[@]}" \
    "$helpers/flowd-speech" "$helpers/flowd-meeting" "$helpers/FluidAudio_FluidAudio.bundle"
fi
