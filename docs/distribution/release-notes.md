# LocalFlow 0.3.2

For Apple Silicon Macs running macOS 14 or later.

This release uses ad-hoc signing and is not Apple-notarized, as requested by the maintainer. In-app updates are disabled. Download and install future versions manually. No Apple credential setup is required to build this version.

## Changes

- The final onboarding microphone test is optional, with a visible Skip test action.
- New Mac setups default to Parakeet Ultra. Existing model choices are preserved.
- Right Control works with Input Monitoring alone; Accessibility remains optional for copy-only dictation. Custom key combinations still require Accessibility.
- Shortcut installation retries after permission changes or a transient failure. Microphone approval refreshes the input-device catalog without restarting the app.
- Failed or cancelled onboarding recordings and speech-model preparation can be retried. Start test prepares the model before arming the shortcut.
- Local AI setup checks background-service approval and resumes after both services are approved. Startup helper-reconciliation failures retry before the next backend request.
- Download errors offer Retry, ongoing local-AI setup remains visible on later steps, and disabled Continue buttons explain what is still needed. Optional speech-booster and meeting-model installation no longer race each other.

## Installation

Download `LocalFlow-0.3.2-arm64.zip`, extract it, quit LocalFlow and move the app into Applications. Keep existing Application Support data and Keychain entries. Models are managed separately inside the app.

macOS may block the first launch because the app is not notarized. If you trust this download, use System Settings > Privacy & Security > Open Anyway after trying to open it. Permission approval may be requested again after replacing an older build.

Server access still requires Google sign-in and administrator approval. This release changes onboarding and local startup only; it does not change the server protocol or deploy a remote server or dashboard.

## Verification and limits

The focused regression run executed 206 tests: 205 passed, one microphone check skipped, zero failures. It includes a real pinned Parakeet Ultra load/decode/release/reload/cancellation probe using synthetic audio. Native rendering passed for all onboarding steps in light and dark appearances.

`make check` passed formatting, shared-package tests, validation and Go tests/vet, then stalled in Xcode's macOS test launcher. The built macOS test bundle passed the focused run directly. Fresh-account permission and background-service approval, real microphone capture, signed upgrades and hardware resource targets remain unverified. No such acceptance is claimed.
