# Cross-platform desktop client: GPUI plan

Status: proposed, 2026-10-30. Nothing here is implemented. The decision and its constitution impact are in [ADR 0036](../adr/0036-rust-gpui-desktop-client.md). Each phase below gets its own Spec Kit cycle.

## Goal

- One desktop app for macOS (Apple Silicon) and Windows 11, with its UI written in GPUI and GPUI Kit.
- The same pages, layout, colors, fonts, buttons and copy as today's SwiftUI app.
- A new onboarding path for people who only want meeting notes, including meetings processed on their LocalFlow server.

Out of scope: iOS changes, Linux, server rewrites, new product features other than the onboarding path.

## The main consequence: this is a client rewrite, not a UI rewrite

GPUI is Rust and the client is Swift. The UI can't be swapped alone, because a GPUI window can't hold SwiftUI views and most Swift client code does not run on Windows.

| Code | Lines today | Plan |
| --- | --- | --- |
| `apps/macos/LocalFlow/Features` (views and coordinators) | about 21,700 | Rewrite in Rust |
| `apps/macos/LocalFlow/App`, including the 3,115-line `AppServices` | 3,900 | Rewrite, split up |
| `apps/macos/LocalFlow/Core` (capture, insertion, routing, stores) | about 19,000 | Rewrite in Rust; the two C audio files can stay |
| `packages/LocalFlowCore` | 23,372 | Port the non-ML parts; the package stays for iOS and the workers |
| `apps/macos/LocalFlowTests` | 62,223 | Port the behavior they protect, not line by line |
| `server/`, `protocol/`, `apps/ios`, `apps/macos/LocalFlowServer` | | Unchanged |
| `flowd-speech` and the meeting worker (Swift) | | Unchanged, and reused on the Mac |

Swift on Windows does not fix this. FluidAudio depends on CoreML, and the app depends on AVFoundation, ScreenCaptureKit and AppKit. Only the pure logic would carry over, and it would need a Swift-to-Rust bridge on both platforms.

## Target architecture

```text
apps/desktop (the localflow binary)           windows, pages, composition root
    |            |
    v            v
flow-ui      flow-core                        flow-ui: tokens, fonts, icons, components (GPUI Kit)
                 |                            flow-core: no GPUI, no OS APIs
                 |   coordinators, ModelLifecycleCoordinator, routing, stores,
                 |   remote channel, meeting handoff, analysis validation
                 v
           flow-platform                      traits, plus cfg(macos) and cfg(windows) modules
             |                     |
     macOS implementation    Windows implementation
             |                     |
             v                     v
     flowd-speech (Swift)    flow-speech-win (Rust)      one child-process contract
     FluidAudio / CoreML     sherpa-onnx / ONNX Runtime  (specs/014 speech-worker-ipc)
             |                     |
             +----------+----------+
                        v
             LocalFlow server, optional (unchanged wire protocol)
```

Four crates and one extra binary. No generic plugin layer.

- **`flow-core` never imports GPUI or OS APIs.** A script in `make check` enforces it, as `check-core-imports.sh` does today. GPUI views observe coordinator state through thin entities, which keeps the coordinators testable with no window.
- **Speech runs in a child process on both platforms.** On the Mac this reuses `flowd-speech serve`, `meeting` and `provision`, so FluidAudio, term boosting and the quality baseline stay exactly as they are. Ending the process also releases the model memory. IPC latency for local dictation is unmeasured and is a Phase 0 gate.
- **The local and remote paths stay behind one lifecycle coordinator.** `MeetingInferenceRouter` and `ModelLifecycleCoordinator` move over with the same semantics: a stage picks local or server once, per lease.

## Keeping the look

`flow-ui` is the single place visual decisions live. It holds a direct port of `UI/Appearance.swift`.

| Today | GPUI design |
| --- | --- |
| `SottoPalette` (374 uses, light, dark and high-contrast values) | `Palette` struct with the same names and hex values. `AppearanceContrastTests` is ported. |
| Figtree, EB Garamond, bundled `.ttf` | `include_bytes!` and `add_fonts`, wrapped in `flow_font(size, weight, serif)`. |
| `.font(.flow(...))` (337 uses) | Same sizes and weights through that helper. |
| `PrototypeButtonStyle`, `PrimaryButtonStyle` | `flow_ui::Button` wrapping the GPUI Kit button, with the same padding, 8 pt radius and pressed and disabled states. |
| `PrototypePage` | Same 960 pt column, and 48 or 24 pt padding by window width. |
| `SetupCard`, `SelectableCard`, `DownloadRow`, `Bar`, `ThemeCard` | Moved to `flow-ui` under the same names and reused. |
| `Toggle`, `Menu`, `Picker`, `TextField`, `TextEditor`, `LazyVStack` | GPUI Kit `switch`, `menu`, `select`, `input`, `virtual_list`, restyled by mapping `Palette` onto its theme. |
| Sidebar: Notetaker, Transcriptions, Insights, Dictionary, Settings | Same five pages and order, on GPUI Kit `sidebar`. |
| Insights charts and heat map | GPUI Kit `plot` and `chart`, or drawn directly if they can't match. |
| Reduce Motion, keyboard access, hover-reveal | Kept. GPUI Kit has AccessKit and a `reduce_motion` module. Verified with VoiceOver and Narrator. |

Three things can't stay identical:

1. **Icons.** The app uses about 42 SF Symbols, and Apple licenses them only for Apple platforms. Both platforms move to one bundled SVG set; I recommend Lucide because it is close in weight. This is a visible change on the Mac.
2. **Text rendering.** Windows draws through DirectWrite and has different hinting and gamma, so glyphs won't match pixel for pixel. Metrics should be close and the visual review allows for this.
3. **Window chrome.** The Mac keeps traffic lights. Windows gets native-style caption buttons through GPUI Kit `title_bar`, and copy says "this PC" where it says "this Mac".

Two risks go to Phase 0:

- All three bundled fonts are variable (they contain an `fvar` table). I haven't verified that GPUI selects weights on variable fonts on both platforms. If it doesn't, generate static Regular, Medium, Semibold and Bold instances at build time with fonttools. Both fonts are OFL, which allows that.
- The UI uses `.tracking()` 26 times, including onboarding headlines. A code search of Zed found no `letter_spacing` API, though that search is not conclusive. Without one, headings would need a small GPUI patch or would lose their tracking.

## Platform services

`flow-platform` defines only what the two systems actually differ on.

| Service | macOS today | Windows | Notes |
| --- | --- | --- | --- |
| Microphone | AudioUnit, `AudioCaptureRing.c` | WASAPI, event-driven shared mode | Bounded ring, same overload policy |
| System audio | ScreenCaptureKit | WASAPI process loopback, excluding our own process | Microsoft lists build 20348 as the minimum, so we target Windows 11 |
| AAC segments (ADR 0015) | AudioToolbox | Media Foundation AAC encoder with an ADTS wrapper | The server decodes the same files |
| Hold-to-talk key | Event tap, Carbon | `WH_KEYBOARD_LL` on its own thread | Default Right Control. No fn/Globe preset on Windows |
| Text insertion | Accessibility, paste | UI Automation, `SendInput` paste | Windows blocks input into elevated apps, so those fall back to the existing copy path |
| App context (Feature 012) | Accessibility reader | UI Automation | Ships after dictation |
| Floating pill | `NSPanel` | `WindowKind::PopUp` | Must not take focus; Phase 0 gate on both platforms |
| Tray or menu bar | `MenuBarExtra` | `tray-icon` crate on both | GPUI Kit shows no tray component |
| Secrets | Keychain | Credential Manager with DPAPI | Keep existing Mac item names so no one re-enrolls |
| Device key | Secure Enclave P-256 | TPM 2.0 P-256 through the Platform Crypto Provider | Windows 11 requires TPM 2.0. Constitution text needs amending |
| Sign-in | `ASAuthorization`, Google browser flow | Google loopback flow | See below |
| Launch at login | `SMAppService` | Run registry key | |
| Updates | Sparkle | Velopack (to be confirmed in Feature 028) | Mac keeps its appcast and keys |
| Permissions UI | TCC panes | Mic privacy check only | No Input Monitoring or Screen Recording step on Windows |

**Sign-in on Windows.** `flowd` accepts Apple and Google tokens. Google's desktop flow already opens a browser, so it ports directly. Sign in with Apple on Windows needs Apple's web flow, a Services ID and a hosted HTTPS return URL, and `flowd` has no redirect endpoint for it. Windows v1 ships with Google only, and servers that need Windows clients must set `GoogleClientIDs`. I haven't checked Apple's current web-flow rules.

**Local models on Windows.**

| Function | Mac (unchanged) | Windows candidate | Gate |
| --- | --- | --- | --- |
| Dictation | Parakeet v3, CoreML | Parakeet v3 ONNX through sherpa-onnx | Slovak and English against `fixtures/quality` |
| Term boosting (ADR 0027) | FluidAudio CTC | No equivalent found | Windows may rely on Dictionary post-processing only |
| Meeting transcript | Whisper Turbo through the helper | whisper.cpp | Already pulled in as a submodule of `third_party/sotto`; re-evaluate from there |
| Diarization, voice embeddings | FluidAudio | sherpa-onnx pyannote and embeddings | Voiceprints from different models never mix (principle 10) |
| Rewriting, summaries | MTPLX, Apple Silicon only | None in v1 | Windows uses the server. Summaries are unavailable without one |

A Windows user with no server gets dictation and local meeting transcripts and no AI rewriting. A local LLM on Windows needs its own spec.

## Data compatibility

Cutting the Mac over must not lose anyone's data or force re-enrollment.

- **Same database and file locations on the Mac.** Rust uses `rusqlite` and reads GRDB's `grdb_migrations` table, so an existing database opens as is.
- **One schema across three languages.** iOS and `flowd-meeting` still use the Swift migrator, and `bundle.sqlite` crosses between clients and the server. Swift stays the schema's source of truth until the cutover. A new test generates a database with Swift and asserts the Rust schema is identical, and round-trips a handoff bundle both ways.
- **Same wire protocol.** `protocol/schemas` and `fixtures/remote` become conformance tests for the Rust client. HPKE, ChaCha20-Poly1305 and WebSocket framing are ported and tested against the real `flowd`.
- **Same bundle ID and signing team on the Mac,** so TCC grants, Keychain items and the Secure Enclave key handle survive.
- **Windows data** lives in `%LOCALAPPDATA%\LocalFlow`. There is no sync between devices (ADR 0006).

## Meeting-first onboarding

Today's flow assumes dictation. These are the blockers I found in the code:

- The opening copy only describes dictation.
- `.downloads` requires `modelInstalled`, so a 632 MB speech model is mandatory.
- `readyForTest` requires Input Monitoring and a working shortcut, and it gates `.permissions` and `.personalize`.
- Meeting models are an optional row, and Screen Recording is requested only when the first meeting starts.

Much of the rest exists already: `serverOnly` loads no local models, `MeetingInferenceRouter` routes meeting work to the server, and `canAdvance` already lets a device pending approval continue.

New steps:

```text
introduction -> purpose (Dictation | Meeting notes | Both)
    |
    +-> where it runs (This computer | Your server)
            |
            +-- Meetings + server ---> connect server -> permissions (mic, system audio)
            |                          -> appearance -> done, opens Notetaker
            |
            +-- Meetings + local ----> model picker* -> downloads (Parakeet, Whisper, speakers)
            |                          -> permissions (mic, system audio)
            |                          -> appearance -> done, opens Notetaker
            |
            +-- Dictation or Both ---> today's flow; Both also downloads meeting models
                                       and asks for system audio

* the language model for summaries, skippable; unchanged for Dictation or Both
```

Behavior for meeting notes on a server:

- Sets `serverOnly = true`, so nothing downloads and no local model loads.
- Consent is the existing remote flow. The copy says that meeting audio and text go to the server, and for handoff that the server keeps them until the result is merged, 7 days at most (ADR 0033).
- Recording works while approval is pending or the server is offline. Audio stays on disk and the work waits, as principle 4 requires. The Notetaker page shows "Waiting for your server".
- No shortcut, no Input Monitoring or Accessibility prompt, no dictation test.

New state:

- `AppPreferences.purpose` (`dictation`, `meetings`, `both`). A missing value means `both`, so existing users see no change.
- `Snapshot.readyForMeetings`, which needs storage, the mic and system audio. It needs local models only when not `serverOnly`.
- In `meetings` mode the app opens on Notetaker and leaves the shortcut off. Settings gets a "Set up dictation" card that runs the skipped steps.

The server-only setup doesn't cover one case: a user without a server who picks "This computer" on Windows gets transcripts and speakers but no summaries. That choice must say so.

## Delivery plan

Sizes are rough estimates for one developer working with agents. They are not measurements.

| # | Phase | Work | Exit gate | Size |
| --- | --- | --- | --- | --- |
| 0 | Spike | Throwaway GPUI app with real tokens: onboarding screen, pill, tray, text input with IME and Slovak diacritics; WASAPI loopback to a file; Parakeet ONNX on the quality fixtures | See gates below | 1-2 weeks |
| 1 | Feature 022: meeting-first onboarding in SwiftUI | The section above, in the current app | `make check`, real run on a Mac, tiling check | Days |
| 2 | Feature 023: `flow-core` | Stores, migrations reader, remote channel, enrollment, handoff, routing, analysis validation | Conformance against Swift-made databases and real `flowd` | 6-10 weeks |
| 3 | Feature 024: `flow-ui` and pages | Tokens, components, all five pages and onboarding, on a copy of real data | Side-by-side screenshots of each page, light and dark, approved by you | 6-10 weeks |
| 4 | Feature 025: Windows meeting notes on a server | WASAPI capture, AAC, TPM key, Google sign-in, installer | First public Windows build. Full meeting through `flowd` on real hardware | 3-5 weeks |
| 5 | Feature 026: dictation on both platforms | Hotkey, insertion, pill, worker contract, `flow-speech-win` | Latency and quality measured on both | 6-8 weeks |
| 6 | Feature 027: local meetings on Windows | whisper.cpp, diarization, identification | Attribution measured against the Mac baseline | 4-6 weeks |
| 7 | Feature 028: Mac cutover | Update path, migration test from the shipped version, delete the SwiftUI app | Parity checklist, RSS within budget, upgrade tested on a real install | 2-3 weeks |

The total is roughly 7-11 months. Phase 1 ships value on its own and is the cheapest thing on this list. The SwiftUI Mac app keeps shipping until Phase 7, and `LocalFlow Dev` carries the GPUI build alongside it.

### Phase 0 gates

Any failure stops the plan and returns to the alternatives in the ADR.

1. **Look:** the onboarding screen matches the SwiftUI one side by side, including font weights and tracking, on both platforms.
2. **Memory:** idle RSS with all pages built stays within the 150 MB client target (principle 2). This is unmeasured and is the most likely surprise.
3. **Pill:** it shows above other apps without taking focus and without disturbing the insertion target, including under AeroSpace on the Mac.
4. **Text input:** IME and diacritics work in GPUI Kit `input` on both platforms.
5. **Accessibility:** VoiceOver and Narrator read and operate the onboarding screen.
6. **Audio:** loopback excludes LocalFlow's own output and stays aligned with the mic over a 30-minute capture.
7. **Speech:** Parakeet ONNX on Windows is close enough to the CoreML baseline on Slovak and English, and child-process latency on the Mac adds nothing a user would notice. You set the threshold when the numbers exist.

## Phase 0 results so far (2026-10-30)

Spike source and screenshots: `~/agent-runs/2026-10-30-gpui-spike/`. Tested on an Apple M5 Mac and a Parallels VM running Windows 11 IoT Enterprise LTSC Evaluation for ARM64 (build 26100), with GPUI Kit 0.8.1. Results from the VM are not evidence for x64 hardware.

| Gate | State | Evidence |
| --- | --- | --- |
| 1. Look | Partly passed | Palette, Garamond, italics and layout render on both. No side-by-side with SwiftUI yet |
| Font weights | Passed with a change | GPUI ignores weights on the variable fonts. Static instances from fonttools work; Medium looks light on Windows and needs review |
| Tracking | Failed | GPUI has no letter-spacing API. The 26 uses need a GPUI patch or must be dropped |
| 2. Memory | Early pass | One screen: 76 MB footprint on the Mac, 61 MB working set on Windows, with Windows debug assertions on. All five pages are not built yet |
| 3. Pill | Passed on one test | With `focus: false` and `WindowKind::PopUp`, opened by a running process, Notepad keeps focus on Windows and the frontmost app stays frontmost on the Mac. A freshly launched process does take focus on Windows, so the app must not start for the pill. Not tested under AeroSpace or while typing |
| 4. Text input | Partly passed | Windows: synthetic Unicode input, the Slovak QWERTZ layout and dead keys, and backspace all read back exact. True IME composition did not run because the VM's Pinyin dictionaries weren't ready. Mac typing not run |
| 5. Accessibility | Open, fails as written | Windows UIA and the Mac AX tree expose real buttons and inputs with names, and Invoke, Toggle, SetValue and focus work on Windows. Plain strings, `div`s and Kit `Label` are absent; only `text!` and elements with a role appear. The Mac tree stayed empty until a redraw. Narrator and VoiceOver not run |
| 6. Audio | Half passed, in the VM only | Process loopback excluded the process's own tone (below -97 dBFS against -26 dBFS in the control). The 30-minute mic comparison failed in the VM: mic stream 4.65 s behind, 331 discontinuities, frame counts only. Repeat on real hardware with device timestamps |
| 7. Speech | Measured, threshold not set | Parakeet TDT v3 int8 ONNX, sherpa-onnx, CPU, 10 clips per language. English WER 4.78% against the CoreML baseline's 7.66%. Slovak WER 15.87% against 11.11%. RTF 0.036, 752-830 MB peak per file. DirectML and Mac child-process latency not run |

Decisions (2026-10-30): Slovak WER may be up to 5 points worse than CoreML for now, re-measured on x64. Accessibility and tracking are `flow-ui` work, not stops. Mic alignment is repeated on real hardware before Phase 4.

Details for gates 4-7: `~/agent-runs/2026-10-30-gpui-spike/evidence/phase0-gates-4-7.md`. The VM is not audio hardware or x64 evidence. The baselines come from `mixed-language.md` and were not rerun.

Build facts for Windows:

- Cross-compiling from the Mac works with `cargo xwin` for `aarch64-pc-windows-msvc`.
- Release builds need `fxc.exe`, so shipped binaries must be built on Windows CI. The spike uses debug assertions, which compile shaders at runtime from the build machine's source path.
- A clean Windows install has no Visual C++ runtime. Link with `+crt-static` or the installer must add it.

## Risks

| Risk | Handling |
| --- | --- |
| GPUI is pre-1.0 and GPUI Kit pins a `gpui-pre` snapshot (`=0.3.10`); any bump can break the API | Commit `Cargo.lock`, upgrade on purpose, keep GPUI Kit behind `flow-ui` |
| A bus-factor risk: GPUI's direction follows Zed and GPUI Kit's follows Longbridge | Apache-licensed code can be vendored. License review of GPUI Kit is part of Phase 0 |
| Three implementations of core logic during the transition (Swift Mac, Swift iOS, Rust) | Shared fixtures; freeze new Mac features during Phases 3-7 where possible |
| Long rewrite with no Mac user benefit | Phases 1 and 4 ship user value first |
| Windows signing and hardware not yet available | Decided at Phase 4 (see open items) |
| Port regressions in behavior covered by 62,000 lines of tests | Port tests by feature along with each phase. Recovery, cancellation and capacity tests come first |

## Open items for you

These don't block Phases 0 or 1.

1. An x64 Windows 11 machine is needed before Phase 4. The ARM VM `agent-localflow-win11` covers UI work, but latency and hardware acceptance need real hardware.
2. Windows code signing is paid and needs your approval before Phase 4.
3. The Google client ID on your server must allow the Windows flow.
