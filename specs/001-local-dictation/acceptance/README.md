# Feature 001 evidence matrix

Behavioral acceptance is recorded on owner attestation, 2026-09-16 (see the
per-story records). Resource acceptance remains open: no measurement has been
taken. Mixed-language accuracy remains a recorded failure, deferred by the owner
to a later feature rather than met.

| Requirements / criteria | Implementation evidence | Outstanding acceptance |
|---|---|---|
| FR-001, FR-016; SC-009, SC-010 | Sotto native window, bounded nonactivating waveform, static reduced-motion shapes; AppConfigurationTests and opt-in NativePresentationTests | Full-window visual comparison, VoiceOver, focus, keyboard, multiple displays |
| FR-002, FR-003; SC-006 | ShortcutControllerTests, permission-specific Settings and setup | Actual Fn/Globe transitions, TCC denial/revocation and physical keyboards |
| FR-004; SC-001 | Local pinned FluidAudio adapter, runtime and fixture records | Authentic mixed speech, meaning review, mixed WER failure, asynchronous SDK cache clear |
| FR-005, FR-018; SC-002 | TextInsertionTests, ExplicitInsertionTests, durable attempt and target revalidation | Signed TextEdit/browser confirmation and accessible nonactivating controls |
| FR-006, FR-012, FR-013; SC-005, SC-007, SC-011 | Store/coordinator/recovery tests, capacity admission, unsaved notice, persisted attempts and no automatic replay | Signed crash/clipboard/disk-full and restart matrix |
| FR-007, FR-008 | AudioSpoolTests, AudioCaptureTests, bounded audio, duration review and terminal cleanup | Real microphone/device loss/sleep/180-second acceptance |
| FR-009, FR-010; SC-003, SC-004 | Ownership/cooldown/lifecycle tests, SettingsTests, bounded ResourceRecorder, DictationBenchmark driver and queue instrumentation | M5 Release measurements; the driver has not been run on hardware |
| FR-011, FR-017 | ModelProvisionerTests, explicit integrity-checked installation, Verify files, truthful metadata and readiness test | Signed first-run/download/import/permission retry matrix |
| FR-014; SC-007 | HistoryQueryTests, HistoryViewModelTests row actions, bounded search/paging, independent labels and confirmed deletion | Near-capacity latency/RSS, native action/restart scenarios |
| FR-015; SC-008 | MainWindowRouterTests including minimized restore and close-versus-route, AppPreferencesTests appearance mapping, one Window scene and same-window Settings | Signed closed/visible/minimized, close-vs-quit and system appearance changes |

Existing records: [US1](us1.md), [dependency probes](dependency-probes.md),
[platform probes](platform-probes.md), [accuracy](accuracy.md),
[initial Sotto reuse](sotto-reuse.md), [Sotto rework](sotto-rework.md).

The rework adds 20-row searchable history, explicit destination confirmation,
settings/model ownership controls, live-readiness setup and optional bounded
local diagnostics. See T068–T071 for the remaining full-feature work. No
hardware or resource thresholds have been marked achieved by this rework.

## Rework validation, 2026-09-16

`TEST_RUNNER_LOCALFLOW_UI_CAPTURE_DIR=/tmp/localflow-native-review make check`
passed: **155 XCTest tests, zero failures, two opt-in model/fixture skips**.
This includes the native render test enabled by that environment variable.
Strict Swift formatting, shell syntax, JSON/documentation links, seven Python
accuracy-tool tests, plist checks, Go tests/vet and the unsigned native build
also passed. Ordinary `make check` skips the render test as well.

Final test host: macOS 26.6.2 (25G83), arm64; deployment target macOS 14.
No real-model, microphone, browser, network-observation or M5 benchmark run
was performed during this rework. Native light/dark component artifacts were
inspected using synthetic text only.

Convergence assessed FR-001–FR-018, SC-001–SC-011 and the constitution against
the app, storage/lifecycle boundaries and current evidence. Four high-priority
remaining-work groups were appended as T068–T071 (one missing benchmark driver
group and three partial acceptance groups). No architecture exception or new
server/protocol change was found. No Spec Kit extension hooks are registered.

## Deterministic follow-up, 2026-09-16

`make check` passed: **196 XCTest tests, three opt-in skips, zero failures**.
This run added the cooldown boundary, terminal-cleanup, unsaved-result,
history row-action and routing/appearance suites, and the opt-in 20-cycle
benchmark driver with control-queue and audio-ring occupancy accessors.

No hardware, microphone, browser, network-observation or M5 benchmark run was
performed. The benchmark driver exists and is exercised deterministically with
fakes; it has produced no measurements. T041, T061 and T070 remain open.

## Supported platform correction, 2026-09-16

macOS 14 execution is no longer an acceptance item: the owner confirmed the
supported platform is macOS 26+ on this class of machine. Host records above
keep the deployment target in force when they were measured. See ADR 0001.

## Owner acceptance, 2026-09-16

The owner exercised the signed build on the M5 and reported dictation,
insertion into TextEdit and a browser, shortcuts, indicator, history, routing,
Settings, permissions, failure handling and network behavior as working. Those
records are attestations, not itemized logs or captures; each names what it does
not establish. `make check`: 210 tests, three opt-in skips, zero failures.

Outstanding: T002 model-artifact license clarification, and T041/T061/T070
resource measurements, which require running `scripts/dictation-benchmark.sh`.
