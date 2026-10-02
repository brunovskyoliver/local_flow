# Spike: cold-start control, background clipboard, SwiftUI keys (T004)

Status: **Phase 1 complete (2026-10-01).** R1 and R4 settled (runs 1–3); R7 prototype rejected and the keyboard made dictation-only. Spike code removed in T005; `make check` passes.

## Build

| Item | Value |
| --- | --- |
| Date installed | 2026-10-01 |
| Device | iPhone 16 Pro (iPhone17,1) |
| iOS | 27.0.1 (the plan assumed iOS 26; the deployment target stays 26.0) |
| Base commit | `ab32a5a` plus the uncommitted spike changes (T001–T003) |
| Configuration | Debug, signed for team 944A459UC3, installed with `xcrun devicectl device install app` |
| Widget bundle ID | `com.brunovsky.LocalFlow.Widgets`, App Group `group.com.brunovsky.LocalFlow` |

What the build contains:

- **LocalFlow spike** control (`SpikeToggleIntent`, an `AudioRecordingIntent`). Press 1 requests a Live Activity, opens a one-shot session if none is ready and starts a dictation. Press 2 stops it, which transcribes into History as an in-app note, writes `LocalFlow spike <time>` to the clipboard and ends the Live Activity.
- Every step is logged, with the process that wrote it, to `Library/spike.log` in the App Group container (app state, protected data, session state, Live Activity request or error, clipboard `changeCount`). Read it back with:
  `xcrun devicectl device copy from --device 00008140-001203D12402201C --domain-type appGroupDataContainer --domain-identifier group.com.brunovsky.LocalFlow --source Library/spike.log --destination spike.log`
- The keyboard shows a SwiftUI letter grid under the capsule (Debug only). The number at the bottom left counts the keys that fired.

## Setup on the phone

1. Control Center › edit › add control › LocalFlow › **LocalFlow spike**. Settings › Action Button › Controls › **LocalFlow spike**. Optionally add it to the Lock Screen too.
2. Check Settings › LocalFlow › Live Activities is on.

## R1 run 1 (2026-10-01, owner, intent conforms to `AudioRecordingIntent` only)

Owner report: the control appears in Control Center, the Action Button runs it, and a Live Activity shows. A press turns the mic on for about a second and then off.

`spike.log` (App Group container): every press, with the app killed and with a keyboard session running, ran `perform()` in the widget extension, where no handler exists, so it threw at once:

```text
2026-10-01T10:16:47Z [com.brunovsky.LocalFlow] launch: app=background protectedData=true
2026-10-01T10:17:30Z [com.brunovsky.LocalFlow.Widgets] perform: handler=false
2026-10-01T10:17:38Z [com.brunovsky.LocalFlow.Widgets] perform: handler=false
2026-10-01T10:17:51Z [com.brunovsky.LocalFlow.Widgets] perform: handler=false
2026-10-01T10:17:59Z [com.brunovsky.LocalFlow.Widgets] perform: handler=false
2026-10-01T10:18:26Z [com.brunovsky.LocalFlow.Widgets] perform: handler=false
2026-10-01T10:18:32Z [com.brunovsky.LocalFlow.Widgets] perform: handler=false
2026-10-01T10:18:44Z [com.brunovsky.LocalFlow.Widgets] perform: handler=false
```

Finding: research R2's assumption that an `AudioRecordingIntent` runs in the app process is wrong on iOS 27.0.1. Run 2 adds `LiveActivityIntent` conformance.

## R1 run 2 (2026-10-01, owner, intent conforms to `AudioRecordingIntent` and `LiveActivityIntent`)

```text
2026-10-01T10:20:20Z [com.brunovsky.LocalFlow] launch: app=background protectedData=true
2026-10-01T10:20:20Z [com.brunovsky.LocalFlow] perform: handler=true
2026-10-01T10:20:20Z [com.brunovsky.LocalFlow] toggle: app=background protectedData=true session=none activitiesEnabled=true
2026-10-01T10:20:20Z [com.brunovsky.LocalFlow] activity: requested
2026-10-01T10:20:20Z [com.brunovsky.LocalFlow] start: noSession session=ended end=modelUnavailable
2026-10-01T10:20:20Z [com.brunovsky.LocalFlow] perform: returned Not started: noSession
2026-10-01T10:20:29Z [com.brunovsky.LocalFlow] perform: handler=true
2026-10-01T10:20:29Z [com.brunovsky.LocalFlow] toggle: app=background protectedData=true session=ended activitiesEnabled=true
2026-10-01T10:20:29Z [com.brunovsky.LocalFlow] activity: requested
2026-10-01T10:20:29Z [com.brunovsky.LocalFlow] start: started session=recording end=-
2026-10-01T10:20:29Z [com.brunovsky.LocalFlow] perform: returned Recording
2026-10-01T10:20:43Z [com.brunovsky.LocalFlow] perform: handler=true
2026-10-01T10:20:43Z [com.brunovsky.LocalFlow] toggle: app=background protectedData=true session=recording activitiesEnabled=true
2026-10-01T10:20:43Z [com.brunovsky.LocalFlow] clipboard: changeCount 0 -> 0 hasStrings=false app=background protectedData=true
2026-10-01T10:20:43Z [com.brunovsky.LocalFlow] stopped: session=ended
2026-10-01T10:20:43Z [com.brunovsky.LocalFlow] perform: returned Stopped
2026-10-01T10:20:53Z [com.brunovsky.LocalFlow] perform: handler=true
2026-10-01T10:20:53Z [com.brunovsky.LocalFlow] toggle: app=background protectedData=true session=ended activitiesEnabled=true
2026-10-01T10:20:53Z [com.brunovsky.LocalFlow] activity: requested
2026-10-01T10:20:53Z [com.brunovsky.LocalFlow] start: started session=recording end=-
2026-10-01T10:20:53Z [com.brunovsky.LocalFlow] perform: returned Recording
2026-10-01T10:20:55Z [com.brunovsky.LocalFlow] perform: handler=true
2026-10-01T10:20:55Z [com.brunovsky.LocalFlow] toggle: app=background protectedData=true session=recording activitiesEnabled=true
2026-10-01T10:20:55Z [com.brunovsky.LocalFlow] clipboard: changeCount 0 -> 0 hasStrings=false app=background protectedData=true
2026-10-01T10:20:55Z [com.brunovsky.LocalFlow] stopped: session=ended
2026-10-01T10:20:55Z [com.brunovsky.LocalFlow] perform: returned Stopped
```

Findings so far:

- `perform()` now runs in the app process. The cold press launched LocalFlow in the background (`app=background`), the Live Activity request succeeded from the background, and the second press started a recording with the app still in the background. The cold-start path works without the `openAppWhenRun` fallback, pending the open questions below.
- The first press after a cold launch failed with `modelUnavailable`: `open()` checks `modelReady()` before the launch model check has finished. The real intent must wait for the launch check before opening the session.
- The background clipboard write did not register: `changeCount` stayed 0 and `hasStrings` was false.
- Every toggle saw `session=none` or `ended`, so the "keyboard session running" case is not covered by this run.

Owner report for run 2:

- 10:20:20 and 10:20:29 were Control Center, 10:20:53 the Action Button.
- Live Activity: did not show for the first Control Center press (expected: that press failed and the spike ends the activity). Showed for the second Control Center press. Did not show for the Action Button press, although the log has the request succeeding; that recording lasted 2 s.
- Pasting in Notes did not give the spike text. With `changeCount` unchanged, the background clipboard write is treated as failed (R4).
- History had neither note (10:20:43, 10:20:55). The log did not capture the stop outcome; run 3 logs it.

Run 3 build: the spike waits up to 5 s for the launch model check before opening a session, and logs the outcome and result ID after each stop.

## R1 run 3 (2026-10-01, owner, spike waits for the model check and logs stop outcomes)

The 10:25–10:26 lines in the log came from the run 2 binary (no `model:` line) and are left out. Run 3 lines:

```text
2026-10-01T10:28:43Z launch: app=background protectedData=true
2026-10-01T10:28:43Z toggle: app=background session=none activitiesEnabled=true
2026-10-01T10:28:43Z activity: requested
2026-10-01T10:28:43Z model: ready=true after 0 ms
2026-10-01T10:28:43Z start: started session=recording
2026-10-01T10:28:57Z clipboard: changeCount 0 -> 0 hasStrings=false app=background
2026-10-01T10:28:57Z stopped: session=ended outcome=failed resultID=- savedRequest=false
2026-10-01T10:29:40Z launch: app=background protectedData=true
2026-10-01T10:29:40Z toggle: app=background session=none activitiesEnabled=true
2026-10-01T10:29:40Z start: started session=recording
2026-10-01T10:29:52Z clipboard: changeCount 0 -> 0 hasStrings=false app=background
2026-10-01T10:29:52Z stopped: outcome=- resultID=ADD31467-… savedRequest=true
2026-10-01T10:30:54Z toggle: app=inactive session=ended
2026-10-01T10:31:03Z clipboard: changeCount 86 -> 87 hasStrings=true app=inactive
2026-10-01T10:31:03Z stopped: outcome=- resultID=2BE6D8E1-… savedRequest=true
2026-10-01T10:31:07Z toggle: app=active session=ended
2026-10-01T10:31:13Z clipboard: changeCount 87 -> 88 hasStrings=true app=active
2026-10-01T10:31:13Z stopped: outcome=- resultID=50E017E2-… savedRequest=true
```

Owner report (owner-attested, no figures): Action Button and Control Center both work, the Live Activity shows, and the notes appear in History. "It's perfect."

Findings:

- Cold start from the control works in the background, twice out of two. The app is launched with `app=background`, the Live Activity request succeeds, and recording starts. No `openAppWhenRun` fallback needed.
- 3 of 4 run 3 recordings were saved to History. The first cold-start recording (10:28:43, 13 s) ended `outcome=failed`. Cause not captured; the spike logs no transcription error detail. Risk for SC-008 (9 of 10); to be measured in T071.
- Clipboard: every write while `app=background` was dropped (`changeCount` unchanged); writes while `inactive` or `active` succeeded.
- Not covered: a control press during a running keyboard session. Every toggle saw `session=none` or `ended`. The `ready`-session path is exercised again in T071.

## R1: cold start from the control

Kill LocalFlow from the app switcher before each "no session" row. For "keyboard session running", start a session from the keyboard mic first, then leave the app.

| Where | Starting state | Recording started? | Live Activity? | LocalFlow came forward? | Error text | Press 2 stopped it? |
| --- | --- | --- | --- | --- | --- | --- |
| (a) Locked Lock Screen | no session, app killed | | | | | |
| (b) Control Center over Safari | no session, app killed | | | | | |
| (c) Action Button | no session, app killed | | | | | |
| (a) Locked Lock Screen | keyboard session running | | | | | |
| (b) Control Center over Safari | keyboard session running | | | | | |
| (c) Action Button | keyboard session running | | | | | |

`spike.log` lines for each run:

```text
(paste here)
```

## R4: clipboard from the background and while locked

| Case | `changeCount` went up? | Paste in Notes afterwards shows the spike text? |
| --- | --- | --- |
| Stop from Control Center over Safari (background) | | |
| Stop from the locked Lock Screen | | |

## R7: SwiftUI key grid

Owner report (2026-10-01, owner-attested, no figures): "the keyboard experience is really bad." Lost or doubled keys, counter and footprint not recorded.

| Check | Result |
| --- | --- |
| 2 minutes of fast two-thumb typing in Notes: lost keys | |
| Doubled keys | |
| Counter vs characters typed (same text) | |
| Visible press delay | |
| Footprint at rest (Settings › Diagnostics) | |
| Peak footprint | |

## Decisions

- R1: **background path, no fallback**, with two changes to the design: the intent must also conform to `LiveActivityIntent` (run 1: `AudioRecordingIntent` alone runs `perform()` in the widget extension), and it must wait for the launch model check before opening a session (run 2: the first cold press failed with `modelUnavailable`).
- R4: **fallback.** Every write with the app in the background was dropped (runs 2 and 3); writes while active or inactive worked. Hold one pending write and apply it when LocalFlow becomes active. A Copy button in the Live Activity runs in the background too, so it cannot write the clipboard directly; see research R4.
- R7: SwiftUI key grid **rejected** by the owner, who then chose a dictation-only keyboard over a UIKit key grid or KeyboardKit. User Story 1 removed from the spec, plan and tasks.
