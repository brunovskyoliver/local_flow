# Feature 001 validation guide

The repository includes the local dictation path and prototype-matched Transcriptions, Settings and first-run screens. The deterministic test target covers storage, paging, insertion ownership, model controls and setup gates. Signed native, speech accuracy and resource acceptance remain separate from these checks.

## Prerequisites

Use Apple Silicon macOS 26+ with Xcode and a Swift 6.2+ compiler for package traits (planning machine: Xcode 26.4.1, Swift 6.3.1). Use the M5 / 32 GB machine for resource acceptance. Install Go for existing foundation checks. For real permission tests, select a local signing identity in Xcode and keep a stable bundle identity; unsigned builds are only build validation. Enable the audio-input entitlement for the hardened runtime as needed.

Prepare consented clean-speech fixtures: ten Slovak, ten English and ten mixed-language utterances, with reviewed reference text. Each mixed fixture must switch languages at least once; include switches near decoding seams. Record consent/license and fixture IDs outside content-free app logs. Keep private recordings outside Git. Add a separate 180-second fixture, silence, and seam fixtures with repeated words.

## Foundation validation, available now

From the repository root:

```sh
make check
make macos
open apps/macos/LocalFlow.xcodeproj
```

Expected: JSON/docs/shell checks, Go tests/vet, native build and deterministic XCTest pass. Running the app shows its menu-bar app and first-run guidance. These checks do not prove dictation, permissions, accuracy or memory acceptance. No server is needed for Feature 001.

## Build and deterministic tests

LocalFlowTests is included in the shared scheme:

```sh
xcodebuild -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

Expected: fake-boundary tests pass for session/lifecycle transitions, stale cooldown, cancelled preparation, overflow, duration limits, persistence failures and restart recovery. These tests use no microphone, network or real model. Run signed-app permission and insertion scenarios separately; signing-disabled tests cannot establish TCC behavior.

In Xcode, build/run with the local signing identity and microphone entitlement. Use Release configuration for resource measurements. Resolve the exact dependencies and disabled FluidAudio traits from [research.md](research.md); retain the resolution file and dependency/model notices before accepting the build.

## Provision and prove offline behavior

1. Open model setup. Confirm the app shows source revision, actual download size, license and disk destination. Explicitly Download or Import the selected v3 model.
2. Verify the installed manifest lists every selected file with byte size and SHA-256. Interrupt a second staging operation and restart; the prior verified installation must remain usable and staging must be cleaned.
3. Disable network and keep the Go server stopped. Run all ordinary dictation scenarios. Observe application network activity using local development tracing, saving the observation method and interval. Expected: zero application network requests, not merely successful operation with a disconnected interface.
4. With a test copy of the model directory, remove or corrupt one asset. Expected: actionable local error, no network request and no capture-ready signal. Restore through explicit provisioning.

See [contracts/client-boundaries.md](contracts/client-boundaries.md) for the local-only loading boundary. Do not download models or record speech automatically as part of `make check`.

## Permissions, shortcut and ordinary insertion

1. With microphone denied, hold the shortcut. Expected: no capture, clear guidance, no repeated permission prompt. Grant permission through the system settings and retry.
2. Grant Input Monitoring for Fn/Globe, then deny Accessibility while leaving microphone allowed. Expected: shortcut/capture/transcription work; text is saved for Copy. The preexisting clipboard stays unchanged until Copy.
3. Grant Accessibility. Select an ordinary TextEdit field, hold the configured shortcut, wait for ready, speak, then release before 180 seconds. Expected: one insertion at the captured selection, saved before dispatch; the same history entry remains with confirmed delivery and resolved recovery after acknowledgment.
4. Repeat in a named browser's plain-text field. Record browser and OS versions and the field type. Verify replacement of a selection, insertion at a caret and bounded read-back. Failure to establish safe insertion blocks SC-002 acceptance; successful Copy alone does not pass it.
5. Change focus, terminate the target, use a secure field and use an unsupported target. Expected: no automatic insertion, recoverable text and unchanged clipboard.
6. Confirm Fn/Globe is the default: hold to prepare/record, release to finish. Set the macOS standalone Globe action to Do Nothing and resolve any system Dictation conflict using setup guidance. Check that the app never changes those settings itself. Exercise repeat key-down, release during preparation, conflicting shortcut replacement, sleep and missed release. Expected: no delayed recording, duplicate session or stuck unbounded capture. The previous shortcut remains if replacement fails. Test Fn combined with arrows/function keys: system behavior remains available and the dictation attempt cancels without automatic insertion. Deny/revoke Input Monitoring and disable the tap during a hold: no stuck recording and clear permission guidance. The explicit alternative shortcut addresses Fn conflicts and unsupported keyboards; it also requires Input Monitoring for global Escape. Verify both built-in and available external Apple keyboards; a firmware-only Fn keyboard must produce guidance rather than a false readiness claim.

## Recovery, duration and storage

1. Force insertion failure, restart, select Copy, then restart again. Expected: the same saved transcript and quality warning remain. Wait or alter the test clock; no automatic expiry occurs.
2. Force crashes after text commit, after attempt commit and after target mutation but before acknowledgment. Expected: no automatic reinsertion; a possibly delivered row is shown as uncertain with a duplicate warning before explicit retry.
3. Hold beyond 180 seconds. Expected: visible stop, transcription of retained speech, durable duration-limit label and review actions; no automatic insertion. Release and press again to begin another session. Verify simultaneous key-up/deadline behavior with the fake clock.
4. Exercise the configured queue, text and spool limits. Expected: visible error or incomplete result, no false complete success, no automatic insertion and no audio above documented bounds.
5. Fill history to 10,000 rows and independently to the 32 MiB UTF-8 payload limit using test fixtures. Expected: admission reserves 64 KiB, blocks before capture when either limit would be exceeded, and never evicts existing rows. Dismiss recovery and confirmed insertion do not free capacity. Only confirmed Delete frees space; cancellation or a failed Delete commit preserves the row.
6. Inject disk-full on save, attempt marker and acknowledgment. Expected: unsaved text stays visible, automatic insertion is blocked without a durable commit, existing rows survive, and new capture stays blocked when durability is unresolved.
7. Cancel during preparation, capture and decoding; remove the microphone; revoke permission. Expected: work joins before release, temporary audio is removed and committed text remains. Force quit during recording and relaunch to verify stale-audio cleanup. Cleanup failure must block new capture visibly.

## Prototype UI and native acceptance

Inspect `design/approved-prototype.html`. Follow [ui-contract.md](contracts/ui-contract.md) and [design handoff](design/README.md), including LocalFlow's adapted destinations and local model controls. Compare Light and Dark at matching native window dimensions. Record captures and deviations; a passing build alone is not native visual acceptance.

After explicit local model provisioning, stop every speech/text server and disable network access. Hold/release Fn and verify local transcription, save and eligible insertion, with no connection prompt, server-readiness gate or audio upload. Use the existing offline/privacy acceptance procedure to observe actual requests. Initial provisioning may use the network only after the user's explicit action.

1. Open LocalFlow and Settings… with the main window closed, visible and minimized. Expected: one window, correct destination, restored from minimized; Command-comma follows the same route. Close the window and dictate again; menu-bar operation continues. Quit exits after resolving any unsaved-text warning.
2. Switch System/Light/Dark, restart, and change the system appearance in System mode. Expected: persisted selection across window/menu/indicator, with OS changes followed only in System mode.
3. Inspect sidebar, title/search alignment, full text, date groups, timestamp width, row spacing/separators and settings groups. Resize and test accessibility text settings, long Slovak text and visible keyboard focus. No fake desktop/menu/date, prototype footer, sample data, fabricated destinations or separate Settings window ships.
4. Hold Fn/Globe in a real target. Expected: a small text-free waveform at bottom center of that display, preparation distinguished from actual capture and transcription. No normal timer, recording label or success toast. Success/failure must not activate LocalFlow or navigate the main window. Error/review leaves persistent menu attention.
5. Test Escape, hover Cancel and VoiceOver Cancel while the destination retains focus. Check brief Escape presses during preparation, recording and after key release during transcription under both shortcut bindings. Check keyboard/VoiceOver row actions even without hovering. Reduced motion stops timers/animation and leaves distinct static states. Exercise multiple displays, Dock placement and fullscreen Spaces.
6. Visit Settings unloaded; no model loads automatically. Select Load; show actual preparation/loaded state and release after 30 seconds idle. Select Unload while idle; release through the coordinator. During capture/transcription, controls are disabled and raced requests cannot interrupt ownership. Installed/verified/loaded states and actual size/location are truthful.
7. Reset onboarding in a test profile. Verify local/text-retention explanation, explicit provisioning, separate permission guidance, Fn conflicts and the readiness-gated test. Denial, missing/corrupt assets, interrupted download/import and verification failure offer retry without false readiness. Accessibility denial allows a Copy-only test.

## History and explicit insertion acceptance

1. Produce complete delivered, failed, uncertain, incomplete and duration-limited text, then restart. Expected: every nonempty result remains as one history entry. Silence, cancelled preparation and failure with no text create none. Any produced nonempty partial text remains labeled incomplete.
2. Copy each case, dismiss recovery, and explicitly insert after review. Expected: Copy changes no status; Dismiss recovery changes only recovery; confirmed insertion resolves recovery. Text/timestamp/completeness survive all three. A dismissed uncertain entry still warns of possible duplication before Insert again.
3. Delete one selected entry. Cancel confirmation first, then confirm. Expected: cancel keeps it; confirmed deletion removes only that entry after successful transaction. Inject a failure at commit: entry remains visible. Reject stale revision or active-insertion deletion.
4. Populate dates older than Yesterday, more than two pages, tied timestamps and long full-text entries. Traverse previous/next; search for a phrase only in an unloaded old page, including Slovak diacritics and mixed-case text. Expected: all retained text is searchable with documented literal matching; no duplicate/skipped rows in a stable result set; empty/no-match states are distinct. Date/time-zone changes regroup without changing timestamps.
5. Fill to the designed capacity, rapidly replace search queries, then dictate after explicitly freeing space. Expected: <=20 rows per page, <=40 resident rows plus one selected row, one active query and one replaceable pending request; no stale results replace the latest query and persistence takes priority. Report browsing/search memory and latency; do not silently widen memory requirements.
6. Choose Insert/Insert again: review text/warnings, arm selection, focus a real eligible field and explicitly confirm from the non-activating confirmation surface. Expected: the same target remains focused and is revalidated immediately before one dispatch. Change field/app after selection, close the target or choose a secure field: no insertion, selection invalidated. No automatic clipboard change. Cancel leaves history untouched.
7. Force save failure after transcription. Expected: one explicitly unsaved item with loss warning, Retry save and Copy; no false saved/delivered status or new capture. Copy retains the unsaved item. Successful retry creates one stable-ID history entry, without resetting existing delivery state. Explicit Discard requires acknowledgment of loss.

## Accuracy and resource acceptance

Run all 30 language fixtures offline through the app's actual capture/transcription path. Use reviewed clean playback or a documented direct-audio adapter run plus end-to-end microphone checks. Mark which path each result used. Normalize NFC/lowercase/punctuation/whitespace as defined in [plan.md](plan.md), preserving diacritics. Report aggregate WER <=15% separately for Slovak, English and mixed sets, plus nonempty output and reviewed meaning for every fixture. Do not average a weak language set into another. Preserve seam/repetition failures in the report.

Follow [memory-budget.md](../../docs/performance/memory-budget.md) for the 20 sequential cycles, cold load, 30-second cooldown, rapid reuse and capture-only comparison. The coordinator event driver remains outstanding. Opt-in development phase/RSS logging is available; see the [macOS guide](../../apps/macos/README.md). The existing sampler is runnable against the chosen app PID:

```sh
./scripts/memory-report.sh PID 10
```

Replace `PID` with the numeric LocalFlow process ID. This sampler alone cannot label model phases or prove release. Record all 20 rows with unloaded medians, phase timing, queue peaks, build, OS, M5 hardware and model hashes. Convert RSS to decimal MB. Expected: idle <=150 MB, capture-only overhead <=100 MB and each settled unloaded median within max(20 MB, 10% baseline). Investigate slope >0.5 MB/cycle or late-minus-early medians >10 MB; acceptance requires no unexplained flag. Report ASR working set separately without an invented cap. A release timeout or lost measurement fails the run rather than producing an omitted row.

Repeat unloaded/browsing measurements with near-capacity history and search/page churn; retain bounded pages and report any resource regression.

Inspect local logs for transcript/audio/credential content using consented marker phrases. Verify no runtime-owned model or queued audio remains after release. Save evidence locally with explicit consent for fixture transcripts; never put speech into ordinary telemetry.

## Acceptance record

Record scenario/requirement IDs, build/dependency/model identity, device/OS, fixture consent, commands or manual actions, observed results and pass/fail. Attach the accuracy results, all resource samples, network/log audit and visual/accessibility/window-routing evidence for SC-007 through SC-011. `make check` remains required after changes, but foundation validation and hardware acceptance are reported separately. Unrun scenarios remain unrun.

### Avoid repeated model preparation

Enable Settings > Speech model > Keep model ready. Wait for Ready once at launch.
The app retains the model between successful dictations until you unload it or
quit. Disable the switch to restore the 30-second idle cooldown. Model memory
remains resident while this option is enabled; the microphone runs only during
a dictation. Failure or cancellation may require loading again.
