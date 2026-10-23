# LocalFlow 0.3.0

For Apple Silicon Macs running macOS 14 or later.

This release uses ad-hoc signing and is not Apple-notarized, as requested by the maintainer. In-app updates are disabled. Download and install future versions manually. No Apple credential setup is required to build this version.

## Changes

- Optional Parakeet Ultra speech recognition.
- Fresh field context for each dictation, preserving existing text and checking for intervening edits. Context remains Experimental.
- Optional per-device usage sharing, with withdrawal and deletion controls. The owner dashboard is prepared separately; hosting is not configured by this release.
- Update infrastructure for a future signed release. Automatic updates are not enabled in this build.

## Installation

Download `LocalFlow-0.3.0-arm64.zip`, extract it, quit LocalFlow and move the app into Applications. Keep existing Application Support data and Keychain entries. Models are managed separately inside the app.

macOS may block the first launch because the app is not notarized. If you trust this download, use System Settings > Privacy & Security > Open Anyway after trying to open it. Permission approval may be requested again after replacing an older build.

Server access still requires Google sign-in and administrator approval. New usage-reporting capabilities need an updated server; no remote server or dashboard was deployed with this release.

## Verification and limits

`make check` passed: 2,243 XCTest passes, zero failures and 32 skips. Focused Go race tests and updater transport/signature tests passed. Live context quality, hardware resource targets and signed-upgrade acceptance remain incomplete; no such acceptance is claimed.
