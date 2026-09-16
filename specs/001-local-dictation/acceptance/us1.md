# US1 implementation and acceptance

Updated 2026-09-16 for the setup, foundations and US1 implementation run.
The user authorized proceeding with the unchecked requirements checklist; its
15 checked and 4 unchecked markers remain unchanged. This run downloaded no
model assets or audio and changed no dependency pins. Separate provisioning
changes appeared concurrently; their existing record is preserved below.

## Implemented and verified without speech assets

- T009/T011/T012: SQLite disk-full rollback and retry, failed migration rollback,
  stable-ID and capacity enforcement, app/spool lock exclusion, restart cleanup,
  spool ceiling and cleanup-failure lock retention; exclusive model preparation,
  cancellation of cooperative factories, uninterruptible inference joins and
  acquisition racing release. Active leases reject model replacement.
- T015: coordinator admission establishes one session/generation in the 32-event
  mailbox. Stop, cancel and terminal flags live outside the queue. One session
  consumer processes at most 32 events per batch, with one replaceable level
  snapshot. Early release cancels preparation; stale callbacks cannot affect a
  newer session. Overflow stops visibly and prohibits automatic insertion.
- T016–T018: denied microphone, repeated starts, early release, Fn combinations,
  brief Escape, tap loss, cancellation during capture startup and decoding,
  stale capture events, silence, duration-limit priority, incomplete outcomes,
  persistence-before-dispatch and late stop flags around database writes.
  Decoder tests cover small-tail padding, timestamp clamping, repetitions,
  uncertain language seams, text/token limits and retained valid prefixes.
  Capture tests exercise fixed raw slots, oversized callbacks, synchronous
  bounded normalization/spool writes and the sample/deadline ceilings.
  Provisioning and insertion failures use synthetic files and injected adapters.
- T020: explicit Download/Import/Cancel controls display pinned revision, license,
  manifest-listed size, destination and progress. A lifecycle installation lease
  covers each operation. Files stream directly into one private staging set;
  accepted download callbacks and import/hash reads are at most 1 MiB. The serial
  HTTP delegate writes synchronously, rejects excess bytes and joins cancellation
  before closing staging files. There is no application chunk queue, URL cache or
  extra download copy. Manifest validation precedes network requests; size/hash
  verification precedes atomic promotion, preserving the prior set on failure.
  One progress snapshot is sampled at 10 Hz, with no per-chunk tasks or history.

Escape is observed through a listen-only event tap under both Fn and Carbon
bindings, including after key release while transcription runs. Repeats coalesce
and cancelled holds require release before rearming. Both bindings now need Input
Monitoring for global Escape; Accessibility remains optional for Copy-only
operation. Events pass unchanged. The alternative binding addresses Fn conflicts
and unsupported keyboards, not Input Monitoring denial.

The indicator refuses key/main focus. Its bounded observer set tracks screen,
Space and wake changes while visible and is removed when hidden. Terminal
announcements precede hiding. Reduced Motion uses distinct static forms and
stops/restarts the single recording animation task as the setting changes.
Signed keyboard, VoiceOver and display behavior still need acceptance.

## Deterministic evidence

`make check`: **113 XCTest tests passed, zero failed, zero skipped**, arm64
macOS 26.6.2 (25G83), Xcode 26.4.1 / Swift 6.3.1. Native format lint, repository
artifact/link validation, plist checks, Go tests and Go vet passed. The run used
synthetic PCM, temporary SQLite databases, fake runtimes and URLProtocol HTTP
fixtures. It recorded no microphone audio and loaded no speech model.

Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.16_14-30-34-+0200.xcresult`.
Local summary: `build/acceptance-us1/test-summary.json`. These results establish
implementation behavior at injected boundaries, not speech accuracy or RSS.
The initial missing-stop regression failed before implementation. An HTTP
cancellation test initially assumed tiny response bytes would flush immediately;
it now synchronizes on request admission and shutdown. Final runs pass.

## Signed insertion evidence

The ad-hoc signed standalone harness uses the actual production AX adapter and
only dedicated synthetic fixtures. TextEdit 1.20 caret and selection insertion
both returned confirmed, with unchanged clipboard. Safari 26.6.2 caret/selection
and Chrome 153.0.8010.48 caret returned uncertain; Chrome selection setup was
blocked before dispatch. Browser readback did not match the requested text.
No fallback or automatic retry was added. See [platform probes](platform-probes.md)
for commands, source hashes, device identity, diagnostics and exact limitations.

These are standalone signed-process probes. They do not establish production-app
TCC, end-to-end dictation or required browser support. SC-002 browser acceptance
remains failed; T004/T024 stay unchecked.

## Remaining gates and explicitly unrun checks

- T002: exact dependency pins and local notices are retained. The concurrently
  supplied model card has CC-BY-4.0 metadata but an Apache-2.0 footer; selected
  artifact license interpretation remains unresolved. T002 stays unchecked.
- T019: the separate provisioning record below supersedes the previously missing
  hashes. Its task marker and manifest changes were preserved. This implementation
  run did not download those assets or independently rerun their full-file audit.
- T003/T023: real CoreML construction, nil-language recognition, real decoder
  seams, cooperative/uninterruptible runtime cancellation and asynchronous
  cleanup are unrun. Synthetic joins do not prove CoreML release or memory use.
- T021/T026: physical Apple-keyboard Fn transitions, real brief Escape under both
  bindings, Input Monitoring with Accessibility denied, permission revocation,
  VoiceOver Cancel/announcements, Dock/display/fullscreen and visual acceptance
  remain unrun. Implementation tests do not close these signed acceptance gates.
- T028: consented Slovak, English and mixed microphone examples, the 30-fixture
  accuracy gate, offline application-network observation with server stopped,
  180-second hardware capture and signed end-to-end insertion remain unrun.
- macOS 14 execution and M5 RSS/load/unload/latency/resource checks remain unrun.
  The probe host is an M5; merely using that host is not a resource measurement.
  URLSession/CoreML internal allocations have not been measured.

US1 is not acceptance-complete. No US2–US5 work was added.

## Constitution check

One native macOS app; unchanged separate Go server and wire schemas. Runtime
creation remains under the lifecycle authority. Control delivery, transfer IO,
progress, capture, decoder windows, text and history admission have explicit
bounds. SQLite transactions preserve completed text; insertion requires durable
save and attempt markers plus a fresh eligibility check. Cancellation and failures
never trigger clipboard substitution, global typing or automatic retry. Private
staging/audio cleanup stays local. No VoiceInk source, telemetry, new dependency
or architecture exception was introduced. Remaining runtime, browser and hardware
gates prevent a claim of complete feature acceptance.

No `.specify/extensions.yml` exists; there were no pre/post implementation hooks.

## Subsequent authorized model download

The user subsequently authorized downloads. All 21 pinned files (483,105,645
bytes) were downloaded to `build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/`.
Each file passed its pinned LFS SHA-256 or Git blob check. The manifest now
contains every SHA-256 and is marked complete. This supersedes the missing-model
and incomplete-manifest status above. The pinned model card is retained under
`docs/licenses/`. Model loading, speech accuracy and hardware checks remain
unrun; consented speech recordings have not been supplied.

## Runtime follow-up after user supplied the assets

The opt-in real-model probe now passes: 21 pinned files verified/imported,
local CoreML construction, language:nil silence decoding at short/full window
sizes, ordinary release, reload and a cancellation race. Two runtime tests
passed without downloading files or using recorded speech. Temporary imported
assets were cleaned up. See [dependency probes](dependency-probes.md) for the
exact command, result bundle, observed timings and SDK cache-release limitation.
This supersedes the earlier statement that all real runtime checks were unrun.

Full asynchronous SDK cache cleanup remains unverified because the pinned SDK
launches its internal clear task without a public completion barrier. T003/T023
remain open for that evidence, macOS 14 and real language/seam checks. Browser,
keyboard, speech-accuracy and resource acceptance remain unchanged. The latest
ordinary `make check` passes 113 tests with 1 explicit model-probe skip; the
separate opt-in run passes 2 tests with no skips. Requirements checklist markers
and dependency pins remain unchanged.

## Licensed speech-fixture follow-up (2026-09-16)

The user authorized downloading the remaining fixtures. Twenty natural FLEURS
recordings (ten Slovak, ten English) and their reference/license metadata are now
available in `build/speech-fixtures/`; ten synthetic mixed stress clips were
prepared from those recordings. This supersedes earlier missing-fixture statements.
All thirty ran through the actual local adapter. WER was 10.58% Slovak, 7.18%
English and 23.87% synthetic mixed, with six mixed results marked incomplete.
Meaning review, authentic mixed fixtures and live microphone checks remain open.
See [accuracy evidence](accuracy.md) for per-fixture scores, provenance and commands.

## US1 closure continuation, 2026-09-16

The implementation checkpoint remains complete; **US1 MVP acceptance is open**.
No US2-US5 work was started and no existing task/checklist gate was closed.

- The 30-fixture real-model rerun exactly reproduced prior text, sample counts
  and quality flags. Mixed WER remains 23.87%, with six incomplete results.
  Evaluation-only bounded window traces now distinguish model omissions from
  missing seam anchors. See [accuracy investigation](accuracy.md).
- The supplied audio directory and manifest were confirmed by the user as
  permitted for use. Their mixed clips remain synthetic concatenations, so
  authentic mixed-speech acceptance is still missing. A private hash-bound
  meaning-review worksheet is prepared, without invented human verdicts.
- Safari caret/selection probes reproduce successful AX setter status with no
  confirmed replacement, including a two-second delayed read. Browser insertion
  remains unresolved. See [platform evidence](platform-probes.md).
- An Apple Development-signed production-app launch/termination test passed on
  the M5: one UI test, zero failures/skips. Microphone, physical Fn/Escape, focus,
  permission transitions and offline dictation require their separate scenarios.
- The user explicitly requested testing on this machine and **no macOS 14
  testing**. macOS 14 execution is therefore unrun, not passed or waived.
- Source review reconfirmed the pinned SDK has no public cache-clear completion
  barrier. Runtime cleanup acceptance remains open. The model-license review
  found upstream CC BY metadata but no resolution of the pinned converter card's
  inconsistent footer; T002 remains open.

Constitution check: production runtime ownership, source boundaries and insertion
safeguards are unchanged. Test-only traces stay in the opted-in private evaluation
JSON, with bounded windows/tokens/text and no retained PCM. No model/dependency
pins, acceptance thresholds, clipboard behavior or architecture exceptions changed.

Interactive setup imported the pinned model into the app's private model directory.
A system-triggered relaunch selected `build/DerivedData/.../LocalFlow.app`, whose
signature inspection showed ad-hoc signing with no TeamIdentifier, instead of the
Apple Development-signed acceptance build. This was detected before accepting
microphone/permission results. Those results must identify the running executable,
not just its display name or bundle ID.

An attempted `nettop` observation of the original signed PID produced no rows;
that process exited during setup. Privileged packet tracing was unavailable
without a password. Neither observation establishes zero application requests,
and offline-network acceptance remains open.

## Supported platform correction (2026-09-16)

The owner confirmed that macOS 14 is not a targeted device: this development
machine and macOS 26 or later are. The macOS 14 execution item recorded above as
unrun is therefore withdrawn as an acceptance requirement, not passed. Every
measurement and host record above stands exactly as it was taken, including the
macOS 14 deployment target in force at the time. Remaining T003/T023 gates are
unchanged: real language and seam behavior, and the SDK's asynchronous cache
clear. See ADR 0001's amendment.
## Owner acceptance, 2026-09-16

The owner exercised the signed development build on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. Recorded as given; the
measurements and probe results above are unchanged.

- Holding the shortcut and speaking inserted text at the caret in **both TextEdit
  and a browser**, including replacing a selection. This supersedes the earlier
  Safari probe result above, which reported a successful AX setter with no
  confirmed replacement. The probe finding is retained as the record of what that
  standalone harness observed; the owner's run is the acceptance observation.
- Slovak and English dictation both work. Output needs correction in ordinary
  use; see the accuracy record for the language-quality position.
- Several shortcut bindings were used, including the Fn/Globe default and
  recorded alternatives, and all drove a session correctly.
- The recording indicator behaves correctly: it appears during recording without
  taking focus, and Escape and the Cancel control both end the session.
