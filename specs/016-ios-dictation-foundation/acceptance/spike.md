# Spike run (T004, quickstart §2)

Device: iPhone 16 Pro (iPhone17,1), UDID 00008140-001203D12402201C. Build: Debug, `016-ios-dictation-foundation` at 2fb9101 plus the uncommitted fixes below. Signing started on the free personal team `QUB47S3XTF` with prefix `com.oliverbrunovsky` (the NOOP refresh agent's values) and moved to the paid team `944A459UC3` with prefix `com.brunovsky`; see the sections below. The result is from the paid team.

## 2026-10-01: signing, install and model download

| Check | Result |
| --- | --- |
| Free team signs app and keyboard | Yes. `xcodebuild -allowProvisioningUpdates` from the command line, no Xcode GUI |
| App Group entitlement on both | Yes. `group.com.oliverbrunovsky.LocalFlow` in the signed entitlements of `LocalFlow.app` and `LocalFlowKeyboard.appex` |
| Install over USB | Yes. `xcrun devicectl device install app` |
| Model download on cellular | Yes, after two fixes (below). State reached `ready` |
| Download progress shown | No on this run (0% throughout). Fixed afterwards; not yet seen on the device, because the model is already downloaded |

Free-team budget after this run: 6 of 10 App IDs per 7 days (NOOP 4, LocalFlow 2); 2 of 3 sideloaded apps on the phone.

### Defects found on the device

1. **`symlinkNotAllowed` on every download.** The download never started, and the UI showed "Paused". Two causes, found from the device log:
   - iOS hands out the container as `/var/...`, and `/var` is a symlink to `/private/var`. Fix: `PhoneServices.physical` resolves the path with `realpath` (`URL.resolvingSymlinksInPath` strips `/private` again).
   - The iOS sandbox refuses `open("/private")` with EPERM (errno 1). `ModelProvisioner.openDirectory` walked every path from `/` and reported any non-ENOENT failure as `symlinkNotAllowed`. Fix: `ModelProvisioner(descriptor:rootURL:trustedBase:)`. The walk starts at the trusted base, and components below it are still opened with `O_NOFOLLOW`. The phone passes its resolved models folder; the Mac passes nothing and is unchanged.
2. **Progress stuck at 0%.** The async `URLSession.download(from:delegate:)` never delivers `didWriteData`. Fix: a download task with a session-level delegate in `ResumableModelDownloadTransport`.

Tests added:
- `ModelProvisionerTests.testTrustedBaseDownloadsAndStillRefusesSymlinksBelowIt` and `testTrustedBaseMustContainTheRoot` (Mac).
- `ModelProvisioningTests.testDownloadSucceedsUnderASymlinkedContainerOnceResolved` and `testTransportReportsProgressWhileDownloading` (phone).

Verified with scoped runs: Mac `ModelProvisionerTests` 30/30, phone `LocalFlowPhoneTests` 61/61. Full `make check` later the same day: exit 0, after `swift format` fixed four lint errors in the new code.

That build was reinstalled on the phone with `xcodebuild -allowProvisioningUpdates` and `devicectl device install app`. At that point the App Group container had no `Handoff/` folder: the keyboard had not yet run with Full Access.

## 2026-10-01: moved to the paid team

Signing is now on the paid team `944A459UC3` with the prefix `com.brunovsky`. The free team still owns `group.com.oliverbrunovsky.LocalFlow`, and Apple refused it to the new team ("is not available"). The prefix had to change.

| Check | Result |
| --- | --- |
| Device registered with the paid team | Yes, with `-allowProvisioningDeviceRegistration` |
| App and keyboard signed | Yes: `944A459UC3.com.brunovsky.LocalFlow` and `.LocalFlow.Keyboard` |
| App Group on both | Yes: `group.com.brunovsky.LocalFlow` |
| Install over USB | Yes, bundle `com.brunovsky.LocalFlow` |

The new bundle ID gets a new container, so the speech model has to be downloaded again. The old `com.oliverbrunovsky.LocalFlow` app is still on the phone and can be deleted; it holds a free-team sideload slot. The download-progress fix can be checked on the device during this download.

### Defect: the app crashed when dictation started

All four LocalFlow crash reports from 2026-10-01 (two from each bundle ID) show the same `EXC_BREAKPOINT` in `_dispatch_assert_queue_fail`, raised from the input tap block in `PhoneAudioCapture.startEngine()` on the AVFAudio realtime thread. The block was created inside a `@MainActor` method. With `@preconcurrency import AVFAudio` it inherited main-actor isolation, and Swift's runtime isolation check trapped on the audio thread. The drain timer's event handler had the same problem on the worker queue.

Fix: both blocks are marked `@Sendable`, so neither is main-actor-isolated. Reports were pulled with `pymobiledevice3 crash pull`; `devicectl device copy from --domain-type systemCrashLogs` hung. Not covered by a unit test: the simulator has no dependable microphone input, so this is checked on the device.

## 2026-10-01: result

Closed on the owner's call after a working dictation on the device, paid team `944A459UC3`.

| Check | Result |
| --- | --- |
| App Group round trip | Yes: a dictation started from the keyboard came back through `group.com.brunovsky.LocalFlow`. Seen on the paid team only; the free team got as far as signing the group |
| Opening the app from the keyboard | Yes: the dictation was started from the keyboard |
| Dictation end to end | Yes, after the `@Sendable` fix above |
| Doorbell round-trip time, median of 10 | Not measured |
| App still answers after 2 minutes in the background | Not checked |
| Orange indicator; music with `.mixWithOthers` | Not checked |
| Keyboard footprint at rest | Not measured. `keyboard-status.json` is in the group container, which `devicectl` does not list beyond `Library/`, and the app does not show it yet |

Decisions:
- R4: keep the App Group channel; no fallback.
- R7: keep `[.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]`. The background check moves to the US1 device acceptance (T059, quickstart §5); drop `.mixWithOthers` there if background input dies.
- R11: keep the SwiftUI keyboard. The footprint is measured in T059 (SC-004); switch to UIKit if it is above 30 MB at rest.
- R10: signing moved to the paid team with the prefix `com.brunovsky`.
