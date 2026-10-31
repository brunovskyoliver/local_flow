#!/usr/bin/env bash
# Feature 024: flow-core has no GPUI or OS APIs, GPUI Kit stays behind flow-ui, and page code
# draws text only through `t`/`rich`, because plain strings are invisible to accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
if grep -rnE 'gpui|flow_ui|flow_platform|objc|windows::|std::process::Command|#\[cfg\(target_os' crates/flow-core/src crates/flow-core/Cargo.toml; then
  echo "flow-core uses GPUI or an OS API" >&2; status=1
fi
if grep -rnE 'gpui_kit|gpui_component|::component::' apps/desktop/src crates/flow-platform/src crates/flow-core/src; then
  echo "GPUI Kit used outside flow-ui" >&2; status=1
fi
if grep -nE '^(gpui|gpui-kit)' apps/desktop/Cargo.toml crates/flow-core/Cargo.toml crates/flow-platform/Cargo.toml; then
  echo "A crate other than flow-ui depends on GPUI Kit" >&2; status=1
fi
# Bare strings as children, and `text!`, skip Txt's tracking and exposure.
if grep -rnE '\.child\("|\.child\(format!|\btext!\(' apps/desktop/src crates/flow-ui/src/components.rs; then
  echo "A bare string child is invisible to accessibility; use t() or rich()" >&2; status=1
fi
[[ $status -eq 0 ]] && echo "Rust crate boundaries hold"
exit $status
