# Feature 026: hardware acceptance

Items that need real hardware, a signed install or the owner's screen and microphone. None of them has been run.

| # | Item | Source | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | `flow-speech-win provision` over HTTPS from Hugging Face, including its redirect, on a machine that lets it connect | T004 | All four files verified, `state=verified` | not run |
| 2 | `flow-speech-win serve` on x64 Windows with the installer's DLLs: `LoadLibraryExW`, `onnxruntime.dll` found beside it without `onnxruntime_providers_shared.dll`, a recognition | T004, FR-008 | `ready`, then correct text on a 16 kHz clip | not run |
| 3 | Installer contents on Windows: worker and DLLs in `{app}`, no console window when the worker starts | T005 | Worker spawned by `localflow.exe`, no window | not run |
