# Windows installer

`localflow.iss` is an Inno Setup 6.3+ script for a per-user install: no administrator prompt, a Start
menu entry and an optional Run-at-login task. Uninstalling removes the program and the Run value and
keeps `%LOCALAPPDATA%\LocalFlow`.

**Builds are unsigned.** `SignTool` isn't configured, and Windows SmartScreen may warn. Signing and
updates are Feature 028's.

Release builds need `fxc.exe` from the Windows SDK, so they're CI only: `.github/workflows/windows-desktop.yml`
builds `build/rust/release/localflow.exe` and uploads the installer. By hand, on Windows:

    cargo build --release -p localflow -p flow-speech-win
    iscc /DAppVersion=0.1.0 packaging\windows\localflow.iss

The installer also carries the speech worker `flow-speech-win.exe` and two libraries it takes from the
build input folder `build/sherpa-runtime`: `sherpa-onnx-c-api.dll` and `onnxruntime.dll` from
`sherpa-onnx-v2.0.1-win-x64-shared-MT-Release-no-tts.tar.bz2`, whose `lib` folder they come from. CI
downloads that archive and checks its SHA-256. The worker checks each file against
`crates/flow-speech-win/manifest.json` before loading it and answers `unavailable` on a mismatch. The
speech model isn't installed here; the worker's `provision` downloads it to
`%LOCALAPPDATA%\LocalFlow\Models`.

The Visual C++ runtime is linked in with `+crt-static` (`.cargo/config.toml`), so the installer doesn't
add it. Google sign-in needs `LOCALFLOW_GOOGLE_CLIENT_ID` at build time; CI doesn't set it, so the row
stays hidden.

`scripts/check-windows-installer.py` runs in `scripts/test.sh` and needs no ISCC. `scripts/check-windows-cross.sh`
is an optional cross-compile check on a Mac; see its comments.
