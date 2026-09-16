#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_dir="$(dirname -- "$script_dir")"
target="${1:-$project_dir/.build/models/silero-vad.bin}"
revision="9ffd54a1e1ee413ddf265af9913beaf518d1639b"
expected_sha="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
url="https://huggingface.co/ggml-org/whisper-vad/resolve/$revision/ggml-silero-v6.2.0.bin"

if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | awk '{print $1}')" == "$expected_sha" ]]; then
    printf 'Speech detector verified: %s\n' "$target"
    exit 0
fi

mkdir -p -- "$(dirname -- "$target")"
temporary="$(mktemp "$target.download.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
printf 'Downloading the local speech detector (865 KB)…\n'
curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 "$url" --output "$temporary"
actual_sha="$(shasum -a 256 "$temporary" | awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
    printf 'Speech detector checksum did not match. Nothing was installed.\n' >&2
    exit 1
fi
chmod 600 "$temporary"
mv -f -- "$temporary" "$target"
printf 'Speech detector verified: %s\n' "$target"
