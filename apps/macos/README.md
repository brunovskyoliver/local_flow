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

## Development variant (Feature 014)

`make run-dev` (`scripts/dev-macos.sh --dev`) builds `LocalFlow Dev.app` with bundle
identifier `org.localflow.LocalFlow.dev` and installs it at `/Applications/LocalFlow Dev.app`,
beside the everyday app. `AppIdentity` gives it its own Application Support and Logs
folders (`LocalFlow Dev`), Keychain services (`org.localflow.LocalFlow.dev.*`), launch
agents (`org.localflow.LocalFlow.dev.flowd`, `.mtplx`) and ports (MTPLX 18000, flowd
18080). The script refuses to read, replace or quit `/Applications/LocalFlow.app`.
Production builds render byte-identical agents to earlier releases.
`scripts/snapshot-installed-state.sh` prints a content-free snapshot of the installed
app's database, defaults, Keychain item names, agents and models for before/after
comparison. Sign in with Apple needs `LOCALFLOW_PROVISIONING_PROFILE` naming a
profile for the variant's App ID; without it the build signs without that entitlement.

## Remote dictation (Feature 014)

Settings › Remote dictation is off by default. Turning it on shows a consent step that
names the server and what leaves the Mac; nothing connects before it is confirmed. The
app then shows the server's fingerprint to compare with `flowd admin identity`, pins it,
and signs in with Apple or Google (Google appears when `LOCALFLOW_GOOGLE_CLIENT_ID` sets
`LocalFlowGoogleClientID`). A new device waits for approval and dictates locally until
then. An approved device streams audio to the server while the user speaks and assembles
the returned windows with the same code as local dictation; rewrites use the same
channel. Every failure falls back to local recognition, or, without a local model, keeps
the audio in `PendingAudio/` and retries it (History › Waiting for server). History
labels each entry Server, Local, or Local after server failure. Turning remote dictation
off deletes this Mac's tokens, device key and pinned key; history stays.

Feature 018 moved this switch into Settings › Server, the first section; see below.

`Core/Remote/` holds the channel (CryptoKit HPKE), messages, Keychain store, enrollment,
the dictation session, the retry queue and the rewrite transport. The `flowd-speech`
target (`SpeechWorker/`) is the server's speech worker; it compiles the recognition
sources plus `Core/SpeechBoundaries.swift` and `Core/ModelWorkloadBoundaries.swift`, and
`scripts/check-speech-worker-imports.sh` keeps SwiftUI, AppKit and GRDB out of it.
`scripts/add-speech-worker-target.py` created the target;
`scripts/register-xcode-sources.py --target flowd-speech` adds files to it.

## One server (Feature 018)

Settings › Server is the first section. It holds the Remote dictation setup above, and
once the device is approved:

- **Use this server for everything** sends dictation, rewriting, summaries and meetings
  to the server. The Services row says in one line where they run: "Everything on your
  server", or each place with its services ("On your custom server", "On this Mac", or
  "Not offered by this server" when `ready.capabilities` does not list it). While the
  switch applies, the Rewriting section hides its server fields and the Summaries section
  is hidden.
- A device that confirmed the Feature 014 consent sees **Review…** and confirms the
  updated consent before summaries and meetings leave the Mac. Dictation and rewriting
  keep working on the old consent.
- **Check connection**, on the Services row, times one round trip over the channel,
  which all served services share, and shows "Answered in N ms" or "Server unreachable".
  Services on this Mac or a custom server send nothing; Rewriting › Test connection still
  checks a custom rewrite server.
- **Advanced**, collapsed by default:
  - Rewriting: Your server, This Mac (loopback flowd and MTPLX, which may load again)
    or Custom server, with the address, the Keychain secret and the insecure-HTTP
    override.
  - Summaries: Your server, This Mac or Custom server, with the address, model and API
    key. A custom server that fails before any result is retried once on your server
    ("Your server is used if this server fails"); after a partial result it is not.
  - Meetings ("Transcripts, speaker labels and voice matching"): Your server or This Mac.
  - The fallback threshold for dictation, 250–10,000 ms, and the pinned server
    fingerprint.
- An upgrade keeps the old summaries and rewrite servers stored but does not use them;
  picking Custom server in Advanced brings them back.

Settings › Models shows where each model's work runs. Parakeet and the term booster stay
on this Mac for the fallback; Whisper Turbo and Speaker labels read "On your server" once
the server offers meeting jobs. MTPLX stops while the server
serves both rewriting and summaries, and Parakeet is not kept loaded while dictation is
served ("Applies when dictating on this Mac"). Local Load, Unload and Test stay, since
they test the fallback.

`MeetingInferenceRouter` picks the local or the remote runtimes once per run, when the
lease is taken. The remote runtimes send 16 kHz s16le samples on the live and background
channel roles (the pool has three: interactive, live, background; the phone meeting
watch opens a fourth channel of its own) and load no weights on the Mac. When the server is busy, unreachable or has no meeting worker, the run stays
pending and the meeting shows **Waiting for your server**; it retries after 30 s,
doubling up to 10 min, and the wait resets on a network change or a newly opened channel.
Summaries wait the same way. A live preview window the server cannot take becomes a
`server_unavailable` gap and recording carries on. **Run on this Mac**, in the library
row and the meeting detail, runs that meeting's remaining transcript, speaker labels,
identification and summary locally; the choice is stored per meeting and recorded as
`local_after_server_failure` with `server_failure = user_ran_locally`. The detail view
shows where each stage ran. Voice enrollment always runs on this Mac.
