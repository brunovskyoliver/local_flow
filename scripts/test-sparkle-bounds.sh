#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-sparkle.sh
source="$PWD/build/Sparkle/source"
clang -fobjc-arc -fblocks -DLOCALFLOW_UPDATER_TEST_TRANSPORT=1 -DSPU_OBJC_DIRECT= -DSPU_OBJC_DIRECT_MEMBERS= \
  -I "$source" -I "$source/Downloader" -I "$source/Sparkle" -I "$source/Configurations" \
  packaging/sparkle/BoundedDownloaderTests.m "$source/Sparkle/SPUDownloadData.m" \
  -framework Foundation -o build/Sparkle/bounds-tests
python3 packaging/sparkle/run-bounds-tests.py
