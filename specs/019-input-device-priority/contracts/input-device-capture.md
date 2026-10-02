# Contract: device catalog, resolver and capture

Internal Swift boundaries in the macOS app. Signatures are the shape the tests are written against; names may change during implementation if the tests change with them. Types are defined in [data-model.md](../data-model.md).

## InputDeviceCataloging

```swift
protocol InputDeviceCataloging: Sendable {
  /// The latest snapshot. Reads memory only; no HAL call.
  func snapshot() -> InputDeviceSnapshot
  /// Yields after each rebuild. Buffering: newest 1.
  func changes() -> AsyncStream<InputDeviceSnapshot>
  /// Name of the device a running engine is bound to, for System default dictations.
  func name(of deviceID: AudioDeviceID) -> String?
}
```

- Live: `CoreAudioInputCatalog` (research R1, R3). Listeners are registered once at app start and removed at quit. A rebuild reads at most 64 devices; more are ignored and logged once.
- The rebuild's bounded logic is a pure function, `InputDeviceSnapshot.build(devices:defaultInput:clamshell:generation:)`, which takes already-read device records, keeps the first 64 inputs and reports whether any were dropped. The change stream's newest-1 buffering is a small type the live catalog and the fake share. Both are unit-tested, so the capacity limits do not depend on hardware (constitution 12).
- Test double: `FakeInputCatalog` with a settable snapshot.

## InputDevicePriorityStore

```swift
@MainActor protocol InputDevicePriorityStoring: AnyObject {
  var entries: [RankedInputEntry] { get }
  func move(fromOffsets: IndexSet, toOffset: Int)
  func add(_ input: ConnectedInput) throws   // .full at 32, .duplicate on same uid
  func remove(id: UUID) throws               // .systemDefaultIsFixed
  func reconcile(with snapshot: InputDeviceSnapshot)  // rules M1–M3, saves on change
}
```

Live store reads and writes `UserDefaults` (data-model "Stored form"); tests inject a suite-scoped `UserDefaults`.

## InputDeviceResolver

```swift
enum InputDeviceResolver {
  static func candidates(
    entries: [RankedInputEntry], snapshot: InputDeviceSnapshot
  ) -> [InputCandidate]
}
```

Pure. Returns available entries in rank order (data-model "Availability"). Empty means "No microphone available".

Required tests:

- ranked USB available → first candidate is USB even when the default is another device (US1.1)
- USB missing → MacBook mic first, USB entry unchanged in the list (US1.2)
- clamshell flag set → built-in skipped (US1.3)
- only System default available → one candidate with nil device ID (US1.4)
- nothing available → empty (US1.5)
- fresh store → `[systemDefault]` (US1.6, FR-016)
- UID changed, unique name/kind/model match → matched and UID updated; two ambiguous matches → neither matched (FR-007)

## AudioCapturing changes

```swift
enum InputBinding: Sendable, Equatable {
  case systemDefault
  case device(AudioDeviceID)
}

struct CaptureStarted: Sendable {
  let boundDevice: AudioDeviceID   // what the engine actually opened
}

protocol AudioCapturing: Sendable {
  func authorize() async -> Bool
  func start(sessionID: UUID, spool: AudioSpool, input: InputBinding) async throws -> CaptureStarted
  /// Waits `tail` (0 when nil) before stopping, then drains as today.
  func stop(sessionID: UUID, tail: Duration?) async throws -> AudioCaptureResult
  func cancel(sessionID: UUID) async throws -> AudioCaptureResult
  func snapshot() async -> AudioCaptureSnapshot?
  func queueOccupancy() async -> QueueOccupancy?
}

struct AudioCaptureSnapshot: Sendable {
  let sessionID: UUID
  let sampleCount: Int
  let level: Float
  let terminalReason: AudioCaptureStopReason?
  let audioFlowingSince: UInt64?      // host ns of the first non-zero buffer (research R4)
  let maxDeliveryDelay: Duration      // session maximum (research R6)
}
```

Rules:

- `start` with `.systemDefault` must run exactly the code path it runs today. `AudioCaptureTests` keeps its current cases unchanged.
- `start` with `.device` sets `kAudioOutputUnitProperty_CurrentDevice` before `prepare()` through an injected binder, `bindInput: @Sendable (AVAudioEngine, AudioDeviceID) throws -> Void`, whose default makes the Core Audio call. Tests inject a throwing binder. A failure to set it or to start throws `deviceLost`; the coordinator treats that candidate as failed and moves on.
- Buffers before `audioFlowingSince` are not spooled and not counted against the 180 s budget, whose start moves to that instant.
- `cancel` on a session that never had flowing audio leaves the spool at zero bytes, so the coordinator can pass it to the next `start`.
- `stop(tail:)` stays idempotent per session. A failure latched during the tail wins over `keyRelease`, as today.
- `AudioCaptureRing.c` gains two atomics written by the producer: first non-zero push host time (set once) and maximum delivery delay. No locks and no allocation on the producer side.

## DictationCoordinator behaviour

Given a fake catalog, fake store and fake capture:

| Case | Expected |
| --- | --- |
| No candidates | State goes `preparing → failed`; status "No microphone available"; no spool left behind; capture never started |
| A candidate's `start` throws | Skipped at once; next candidate starts on the same zero-byte spool |
| First candidate flows at once | `connecting` lasts ≤ one poll, then `recording`; history row has that device's name and kind |
| First candidate silent for 3 s | Cancel it, start the second on the same spool; caption "Using <second>"; dictation continues on the same key-hold |
| All candidates silent | `failed` with "<last tried name> didn't respond"; nothing inserted; spool removed |
| Mac sleeps during `connecting` | Capture cancelled; today's sleep failure; spool removed; nothing inserted |
| Key released during `connecting` | `cancelling → idle`; capture cancelled; nothing inserted; no error beyond the existing too-short handling |
| Device lost after audio flowed | Captured audio transcribed, saved and inserted; `stopReason = .deviceLoss` (FR-013) |
| Max delay 30 ms at release | `stop(tail: nil)` |
| Max delay 320 ms at release | `stop(tail: .milliseconds(345))` |
| Max delay 900 ms at release | `stop(tail: .milliseconds(500))` |
| Fallback twice with same available set | Notice shown once |
| Fallback after the available set changed | Notice shown again |
| Permission denied | Permission message as today, never "No microphone available" |

## MicrophoneMeetingSource changes

```swift
init(
  authorization: ...,
  resolve: @escaping @Sendable () -> [InputCandidate],
  deviceName: @escaping @Sendable (AudioDeviceID) -> String?
)
func currentDeviceName() async -> String?
```

- `probeFormat` and `start` bind to the first candidate.
- On a configuration change, the single restart goes to the first candidate that is not the failed device and whose format matches the ring. None → `deviceLost`.
- A higher-ranked device appearing never triggers a restart.
- `MeetingCoordinator.rollSegment` writes `currentDeviceName()` into the new segment's `input_device_name`.

Tests use a fake engine factory; the existing `MeetingCoordinatorTests` device-change cases keep passing with a resolver that returns `[systemDefault]`.

## Logging

Category `input-device`. One line per dictation at stop:

```text
input kind=<kind> rank=<n> fallbacks=<n> connect_ms=<n> delay_max_ms=<n> tail_ms=<n> name=<private>
```

One line per meeting device switch with the same fields minus the tail. No audio, no transcript text.
