#!/usr/bin/env bash
# Feature 025: cross-compiles the Windows code from a Mac. It proves the code compiles, nothing more.
# Optional and not in scripts/test.sh: about 6 minutes uncached, and any Rust edit brings back part of that.
#
# x64 checks the whole app and must pass. arm64 checks flow-platform only: `ring`'s aarch64 build script
# runs plain clang with the clang-cl flags cargo-xwin sets in CFLAGS, and clang reads `/imsvc` as a file
# ("no such file or directory"). That's this cross toolchain's problem, not the app's; the CI's
# windows-11-arm job builds natively.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v cargo-xwin >/dev/null; then
  echo "check-windows-cross: cargo-xwin is not installed, skipped"
  exit 0
fi
cargo xwin check -p localflow --target x86_64-pc-windows-msvc
cargo xwin check -p flow-platform --target aarch64-pc-windows-msvc
