#!/usr/bin/env bash
# Reproducible local build of the pinned updater with bounded transport.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
root="$repository/build/Sparkle"
revision=eef1a539a373c1f1a320624b1130fc5de7b2e100
patch_file="$repository/packaging/sparkle/bounded-downloads.patch"
mkdir -p "$root"
# Concurrent app/test builds share one dependency build, never its live products.
lock="$root/prepare.lock"
for ((attempt=0; attempt<600; attempt++)); do
  if mkdir "$lock" 2>/dev/null; then break; fi
  if ((attempt == 599)); then echo 'Sparkle build lock timed out.' >&2; exit 1; fi
  sleep 1
done
trap 'rmdir "$lock"' EXIT
fingerprint="$(shasum -a 256 "$patch_file" | cut -d ' ' -f 1)-$revision-$(xcodebuild -version | tr '\n' '-')"
if [[ -f "$root/ready" && "$(cat "$root/ready")" == "$fingerprint" && -d "$root/DerivedData/Build/Products/Release/Sparkle.framework" ]]; then exit 0; fi
if [[ ! -d "$root/source/.git" ]]; then
  git clone --no-checkout https://github.com/sparkle-project/Sparkle.git "$root/source"
fi
git -C "$root/source" cat-file -e "$revision^{commit}" || git -C "$root/source" fetch origin "$revision"
# This checkout is generated build output owned by this script.
git -C "$root/source" checkout --detach --force "$revision"
git -C "$root/source" apply --check "$patch_file"
git -C "$root/source" apply "$patch_file"
for scheme in Sparkle sign_update generate_appcast; do
  xcodebuild -quiet -project "$root/source/Sparkle.xcodeproj" -scheme "$scheme" \
    -configuration Release -derivedDataPath "$root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
done
printf '%s' "$fingerprint" > "$root/ready"
