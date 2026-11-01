# Windows installer

`localflow.iss` is an Inno Setup 6.3+ script for a per-user install: no administrator prompt, a Start
menu entry and an optional Run-at-login task. Uninstalling removes the program and the Run value and
keeps `%LOCALAPPDATA%\LocalFlow`.

**Builds are unsigned.** `SignTool` isn't configured, and Windows SmartScreen may warn. Signing and
updates are Feature 028's.

Release builds need `fxc.exe` from the Windows SDK, so they're CI only: `.github/workflows/windows-desktop.yml`
builds `build/rust/release/localflow.exe` and uploads the installer. By hand, on Windows:

    cargo build --release -p localflow
    iscc /DAppVersion=0.1.0 packaging\windows\localflow.iss

The Visual C++ runtime is linked in with `+crt-static` (`.cargo/config.toml`), so the installer doesn't
add it. Google sign-in needs `LOCALFLOW_GOOGLE_CLIENT_ID` at build time; CI doesn't set it, so the row
stays hidden.

`scripts/check-windows-installer.py` runs in `scripts/test.sh` and needs no ISCC. `scripts/check-windows-cross.sh`
is an optional cross-compile check on a Mac; see its comments.
