# Quickstart: Feature 025

```sh
cargo test --workspace
python3 scripts/check-windows-installer.py
scripts/check-windows-cross.sh   # needs cargo-xwin; compiles only
```

The Windows client and installer build on Windows CI (`.github/workflows/windows-desktop.yml`, not run here). Real-hardware steps: [acceptance/hardware.md](acceptance/hardware.md).
