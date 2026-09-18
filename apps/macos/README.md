# macOS client

Open `LocalFlow.xcodeproj`. The LocalFlow scheme builds one native menu-bar app
for Apple Silicon, macOS 14+, and Swift 6. It includes the first dictation path,
private temporary audio, local history, explicit model Download/Import with cancellation and bounded progress, shortcut controls
and a non-activating recording panel. Feature 001 is not acceptance-complete.

`App/` composes services. `Core/` owns capture, model lifecycle, transcription,
insertion and SQLite storage. `Features/Dictation/` coordinates one session.
The Sotto-derived window has Dictation, searchable paged History and Settings.
First-run setup guides local model installation, permissions and a real dictation
test. History and Settings remain accessible during setup, including when storage
is full. Appearance follows System, Light or Dark across native surfaces.

History keeps one 20-row page while a replacement query builds another. The
last-dictation preview is retained only while its screen is visible. Copy keeps
all status; Dismiss recovery keeps the text and quality; Delete requires confirmation.
Explicit insertion reviews the saved text before selecting and confirming a real
external field. Settings Load/Unload goes through the shared lifecycle owner.

FluidAudio 0.15.7 uses empty traits; GRDB.swift is pinned to 7.10.0. Preserve
`Package.resolved` and the notices under `docs/licenses/`. No VoiceInk application
source, server change or additional client runtime is included.

## Local model preparation

No model weights are bundled or automatically downloaded. The pinned quantized
encoder is `Encoder.mlmodelc` from Parakeet v3 revision
`7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`. The manifest contains verified sizes and SHA-256 values for all 21 files.
The pinned assets were downloaded explicitly and verified locally. Obtain the exact revision's Preprocessor, Encoder, Decoder,
JointDecisionv3 compiled directories and `parakeet_vocab.json` separately.

From the repository root, once those files are available:

```sh
python3 scripts/complete-model-manifest.py /absolute/path/to/model-root
```

This checks pinned hashes/Git blob identities and calculates missing SHA-256
values without network access. Rebuild the app, then use Import model to install
a private verified copy. An incomplete manifest or mismatched file fails closed.
No inference or readiness claim is possible until this gate passes.

## Validation

Run `make check` from the repository root. It lints native source/tests,
validates repository artifacts, runs Go checks and executes deterministic
XCTest. It does not record speech, download models or run UI automation.
Building with a macOS 14 deployment target on a newer host does not establish
runtime compatibility on macOS 14.

Run signed platform probes separately with your development signing team:

```sh
xcodebuild -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlowPlatformProbes -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/SignedProbes \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID test
```

The current UI test launches and terminates the app only. Real Fn/Globe,
permission, TextEdit/browser insertion, microphone, accuracy, visual and resource
checks remain separate. See `specs/001-local-dictation/acceptance/` for evidence
and unrun gates. Use a signed development build for permission testing; the
unsigned unit-test host does not establish app TCC behavior.

The setup UI requires Input Monitoring for reliable global Escape under both
Fn and the alternate Carbon binding. Accessibility is optional for Copy-only
dictation. Signed standalone TextEdit insertion passes; Safari and Chrome
confirmation does not. Use `scripts/probe-insertion.swift` with dedicated fixtures
as documented in `specs/001-local-dictation/acceptance/platform-probes.md`.

Real-model compatibility checks are opt-in through
`TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT`; the exact command and results are in
`specs/001-local-dictation/acceptance/dependency-probes.md`. They use generated
silence, never the microphone, and import into temporary private storage.
Ordinary `make check` skips this test and never loads weights.

## Native rendering and local diagnostics

Generate light/dark component renders using synthetic test text, without opening
private history, enabling permissions or loading weights:

```sh
TEST_RUNNER_LOCALFLOW_UI_CAPTURE_DIR=/tmp/localflow-native-review \
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO -only-testing:LocalFlowTests/NativePresentationTests test
```

The command runs from the repository root. These offscreen renders help inspect
layout; they do not establish signed routing, VoiceOver or external-app focus.

For explicit development measurements, launch the built app executable with
`LOCALFLOW_RESOURCE_RECORDING=1`. Content-free phase, lifecycle duration and RSS
samples go to `~/Library/Application Support/LocalFlow/Measurements/`, in two
rotating files capped at 5 MiB each. Each run replaces those diagnostic files.
Queue values are omitted when unavailable. The recorder rejects an acceptance
export if records were lost or overwritten. Closing writes a bounded completion
footer with loss and overwrite counts; a missing footer means an incomplete run.
This sampler is not the planned
20-cycle benchmark driver and does not establish resource acceptance.

## Meetings

The Meetings page (before Transcriptions) records the microphone and system audio as two separate AAC-LC tracks, with pause/resume, notes, a paged library, per-track playback, launch recovery and confirmed deletion. It needs two permissions, requested only from Start Meeting: Microphone and Screen & System Audio Recording (System Settings > Privacy & Security). No model is loaded and nothing leaves the Mac. Dictation is refused while a meeting is active and Start Meeting is refused while a dictation is busy.

- `LOCALFLOW_MEETING_ROOT=/absolute/path` overrides the meeting storage root (for acceptance runs on a disk image); relative values are ignored.
- `--debug-slow-finalize` (debug builds only) sleeps 10 s between the two track finalizations so a force quit can land during `finalizing`.
- Acceptance records live under `specs/004-meeting-capture-foundation/acceptance/` (`codec-recoverability.md`, `baseline.md`, `recovery.md`, `storage-failure.md`, `long-run-memory.md`, `privacy.md`, `fr-028-traceability.md`).
