#!/usr/bin/env bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repository/third_party/sotto/vendor/whisper.cpp"
revision=371b5a7561823ab2bb32142d2751e35e7534727b
if [[ ! -f "$source_dir/include/whisper.h" ]]; then
  mkdir -p "$source_dir"
  git -C "$source_dir" init --quiet
  git -C "$source_dir" fetch --depth 1 https://github.com/ggml-org/whisper.cpp.git "$revision"
  git -C "$source_dir" checkout --detach FETCH_HEAD
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$revision" ]]; then
  echo 'Whisper source does not match the pinned revision.' >&2
  exit 1
fi
# Xcode does not inherit the interactive shell PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
build_dir="${TEMP_DIR:-$repository/build}/meeting-whisper-native"
cmake -S "$repository/third_party/sotto/Engine" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_NATIVE=OFF
cmake --build "$build_dir" --target sotto-engine --parallel 8
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${CONTENTS_FOLDER_PATH:-}" ]]; then
  contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
  mkdir -p "$contents/Helpers" "$contents/Resources/WhisperLicenses"
  cp "$build_dir/Engine/sotto-engine" "$contents/Helpers/localflow-whisper-engine"
  chmod 755 "$contents/Helpers/localflow-whisper-engine"
  cp "$repository/third_party/sotto/LICENSE" "$contents/Resources/WhisperLicenses/Sotto-LICENSE.txt"
  cp "$source_dir/LICENSE" "$contents/Resources/WhisperLicenses/whisper-LICENSE.txt"
  for name in Whisper-model Silero JSON miniaudio; do
    cp "$repository/third_party/sotto/Resources/$name-LICENSE.txt" "$contents/Resources/WhisperLicenses/"
  done
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime \
      "$contents/Helpers/localflow-whisper-engine"
  fi
fi
