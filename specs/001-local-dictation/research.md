# Feature 001 research

Reviewed 2026-09-16. Design questions are resolved below. Runtime compatibility, accuracy, insertion support and resource acceptance still require implementation evidence; none was measured in this planning run.

## Runtime and model

Decision: pin FluidAudio v0.15.7, commit `41540ea237350afe5117a082b5c28eda642d0612`, with Swift package traits disabled (`traits: []`). Use the installed Swift 6.3.1 compiler in Swift 6 language mode, macOS 26+, and Parakeet TDT v3. Keep one native app and the existing source boundaries.

Rationale: the package supports macOS 14 and later, well below the supported floor, and the multilingual model includes Slovak and English. Disabling unused traits avoids unrelated runtime components. Package version, model revision and licenses are separate records. Sources: [pinned package](https://github.com/FluidInference/FluidAudio/tree/41540ea237350afe5117a082b5c28eda642d0612), [model repository](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe).

Alternatives considered: English-only streaming models fail FR-004. Whisper remains an alternative if this candidate fails acceptance, requiring a documented plan revision rather than an automatic runtime fallback.

## Offline provisioning and ownership

Decision: explicitly download or import one selected model manifest at the immutable revision above. Select Preprocessor.mlmodelc, Encoder.mlmodelc (pinned quantized encoder), Decoder.mlmodelc, JointDecisionv3.mlmodelc and parakeet_vocab.json. Record each path, byte count and SHA-256, license and attribution; verify before atomic installation. Construct CoreML models from verified local URLs and inject them through the public AsrModels initializer. Only ModelLifecycleCoordinator may create or retain the heavy runtime. Do not invoke download-capable convenience loaders during dictation.

Rationale: convenience loading can fetch missing assets. Local construction makes a missing or corrupt model an actionable offline error. SDK code is Apache-2.0; the selected CoreML repository declares CC-BY-4.0. Review the exact selected artifact notices before adding dependencies or distributing weights. Sources: [pinned source and licenses](https://github.com/FluidInference/FluidAudio/tree/41540ea237350afe5117a082b5c28eda642d0612), [model card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/blob/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/README.md).

The selected Swift 6.2 manifest supports disabling the unused NeMo trait. Retain the bundled fastcluster BSD-style notice as well as the SDK and model notices. SDK cleanup can start asynchronous cache clearing; joining inference and calling cleanup alone does not prove settled RSS. Sources: [trait manifest](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/Package@swift-6.2.swift), [cleanup implementation](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift), [fastcluster notice](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/ThirdPartyLicenses/fastcluster-LICENSE.md).

Alternatives considered: an implicit first-use download violates explicit provisioning; shipping every model variant wastes storage. Artifact hashes must be calculated or obtained from immutable file metadata during implementation, never invented in a design document.

## Bounded multilingual decoding

Decision: spool normalized audio incrementally and decode after recording ends using 14.96-second windows (239,360 samples), two seconds of overlap (32,000 samples) and at most two resident PCM windows. Use fresh per-window decoder state and no language hint. Merge overlap using timestamped tokens; ambiguous seams mark the result incomplete and require review. Include language switches and repeated words at seams in fixtures.

Rationale: bounded array transcription lets the app own audio memory and cancellation points. The pinned runtime caps a single model input at 240,000 samples. The chosen frame-aligned windows stay below that cap and avoid nested SDK chunking. Pad a nonempty tail shorter than 0.3 seconds, then clamp timestamps to real audio; skip empty audio. Declared language coverage does not establish mixed-language WER. Sources: [ASR implementation](https://github.com/FluidInference/FluidAudio/tree/41540ea237350afe5117a082b5c28eda642d0612/Sources/FluidAudio/ASR), [input limits](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/Sources/FluidAudio/Shared/ASRConstants.swift).

Alternatives considered: full-session PCM accumulation, the English-only streaming path and an unbounded whole-file decoder. A failed seam or accuracy probe blocks this adapter's acceptance.

## Shortcut and permission boundaries

Decision: use Fn/Globe alone as the user-confirmed default. Observe flagsChanged transitions and maskSecondaryFn through one listen-only CoreGraphics event tap. Check/request listen-event access contextually and explain Input Monitoring. Accessibility remains the permission for insertion; verify Fn observation with Input Monitoring granted and Accessibility denied. Carbon RegisterEventHotKey remains the adapter for explicit alternative key combinations, requiring Command or Control for those combinations only.

Rationale: Fn alone is a modifier transition, so the earlier registered-key design does not cover the requested default. Pass events unchanged; inspect other key-down events only to cancel a hold used as an Fn combination, without retaining or logging key content. Cancel on tap loss/revocation and require a fresh press after release. Real Fn press/release delivery and permission behavior are implementation gates, not measured facts. Sources: [modifier events](https://developer.apple.com/documentation/coregraphics/cgeventtype/flagschanged), [Fn flag](https://developer.apple.com/documentation/coregraphics/cgeventflags/masksecondaryfn), [listen-only tap](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/listenonly), [listen-event access](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess%28%29).

Setup explains the macOS Keyboard setting for the Fn/Globe action, recommends Do Nothing and checks for a system Dictation shortcut conflict through user guidance. Do not silently change system preferences or suppress system events. Some external keyboards handle Fn entirely in firmware; offer an explicit configurable alternative if no event is exposed. Source: [Apple Keyboard settings](https://support.apple.com/guide/mac-help/keyboard-settings-kbdm162/mac).

Alternatives considered: Carbon alone cannot represent the chosen modifier-only design; NSEvent global keyboard monitoring brings Accessibility coupling; an active event tap that suppresses keys adds unnecessary interference. The listen-only approach adds a contextual Input Monitoring permission. It stays within the native/privacy constitution because observation is limited to shortcut state, with no key-content retention or transmission.

## Safe insertion

Decision: operate on the captured AX element and process only. Probe whether selected-text mutation is settable; support it only where real TextEdit/browser tests establish safe replacement and bounded read-back. Recheck focus, selection, process identity and secure-field status immediately before dispatch. Confirm the resulting inserted range; otherwise retain the result as uncertain. No synthesized paste, automatic clipboard writes, whole-field rewriting or automatic retry.

Rationale: AX attributes differ across applications and a successful API call alone is not proof of delivery. AX mutation and SQLite delivery acknowledgment cannot be one transaction. Restart therefore offers recovery without automatic insertion. If no safe path meets required TextEdit/browser acceptance, stop and revise the insertion design explicitly. Sources: [AXUIElementIsAttributeSettable](https://developer.apple.com/documentation/applicationservices/axuielementisattributesettable(_:_:_:)), [AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/axuielementsetattributevalue(_:_:_:)).

Alternatives considered: AXValue read/modify/write risks clobbering concurrent edits and reading an arbitrarily large field; clipboard fallback violates FR-006 unless the user selects Copy.

## Durable history and recovery

Decision: pin GRDB.swift 7.10.0, use one DatabaseQueue with explicit migrations and transactions. Use DELETE rollback journaling, synchronous FULL and macOS fullfsync; verify applied PRAGMA values. Reserve one result slot and 64 KiB before capture, within 10,000 rows and 32 MiB total text payload. Persist an insertion-attempt marker before dispatch. Copy never deletes an entry.

Rationale: a bounded serialized history store does not need a read pool or a growing WAL. Bound the database separately from transcript payload and reserve journal space. The selected GRDB release requires Swift 6.1+, satisfied by the verified local compiler, and uses MIT licensing. Sources: [GRDB 7.10.0](https://github.com/groue/GRDB.swift/tree/v7.10.0), [SQLite PRAGMAs](https://www.sqlite.org/pragma.html).

Alternatives considered: UserDefaults is unsuitable for transactional recovery; a volatile outbox cannot survive restart; WAL adds checkpoint management without a current reader-concurrency need.

## Validation decisions

Decision: use fake boundaries and a controllable clock for races and failure paths, then a signed local build for TCC, hotkeys and real insertion. Follow the spec's accepted WER and memory thresholds without widening them. Record dependency/model identity, fixture consent, build and M5 conditions alongside all results.

Rationale: unit tests cannot establish language accuracy, macOS permission behavior or CoreML memory release. The existing shell build is foundation evidence only.

Alternatives considered: inferred memory caps for models, claimed offline behavior without network observation, and accepting only English fixtures. All leave explicit requirements untested.

## Implementation evidence still required

Record exact downloaded-file hashes and sizes, retained license notices, dependency resolution, actual model construction APIs, timestamp stitching, device callback sizes, real target insertion, cancellation and model release behavior. These are implementation and acceptance gates with selected approaches above, not unresolved product requirements. If a probe fails, update the affected design and assess the constitution before proceeding. No architecture exception is proposed.

## Sotto native presentation reuse

Decision: reuse selected SwiftUI/AppKit views and theme source from [Sotto commit c1d5f0b](https://github.com/davis7dotsh/sotto/tree/c1d5f0bbaff19a1559621943dff49ba89b4a96a0), while retaining LocalFlow's local speech, lifecycle, storage and insertion services. Preserve the upstream MIT copyright notice in `third_party/sotto/LICENSE`. The historical HTML reference is superseded for appearance.

Rationale: `Sources/Sotto/Views/SottoWindowView.swift` provides a native split view, `SottoTheme.swift` supplies adaptive warm/light and blue-gray/dark colors and native controls, and `HistoryPage.swift` supplies reusable presentation. The upstream window binds to `SottoController` and exposes server preferences/status. `ServerClient.swift` sends audio to the server. These connections must be replaced at the presentation boundary, rather than importing the upstream application wholesale. The user explicitly chose offline speech on the Mac.

Alternatives considered: running unmodified Sotto would make speech depend on a server; porting its speech server to Go would preserve that dependency; keeping the HTML design would disregard the requested UI reuse. The selected approach keeps FluidAudio and all existing bounded local protocols. Sotto's Swift server, C++ worker and backend dependencies remain reference source outside the LocalFlow build. Optional Go text processing is specified separately and must not gate capture or erase local originals.

License review: the inspected root license is MIT, copyright 2026 Davis. Retain it with copied source and record modifications/provenance in third-party notices. No VoiceInk application source is copied. Inspect new upstream files and dependency licenses before adopting additional code; the snapshot itself is not a runtime dependency.


## History capacity and search

Decision: allow 10,000 rows and 32 MiB original UTF-8 payload, with 64 KiB reserved before capture. Use a 128 MiB SQLite page cap and a separate 129 MiB rollback-journal allowance. These replace the old 20-row/1-MiB recovery limits; there is no second recovery quota. Page 20 full-text rows at a time, retaining at most two pages (40 rows, <=2.5 MiB original text), plus one <=64 KiB selected entry. Previous/next navigation makes all older entries accessible while evicting only in-memory pages.

Search is literal Unicode NFC, case-insensitive and diacritic-preserving over every retained entry, with the same newest-first keyset pagination. Register a bounded native SQLite comparison function; normalize one row at a time with <=512 KiB scratch, not a duplicate full-history index. Cap input at 256 Unicode scalars/1 KiB, debounce 250 ms, and allow one executing query plus one replaceable pending query. Cancel stale searches and prioritize persistence before starting another query. Use query generations to ignore stale responses.

Rationale: the explicit storage limit permits bounded incremental scans without introducing an FTS index for this slice. A single connection keeps transaction ownership simple. Benchmark near-capacity search and save contention; slow scans must be investigated without increasing resident history size. Aggregate text bytes and row count are maintained transactionally. Dismiss/Copy/Insert do not free storage; only confirmed Delete does. Page cache and rollback-journal limits are separate from application payload limits.

Alternatives considered: loading all rows into a Swift array grows with history; the old recovery cap makes daily history impractical; automatic pruning violates retention; semantic search is out of scope.

## Presentation state and lifecycle controls

Decision: store appearance and setup completion in UserDefaults; derive permission, installation and runtime status from their owners. Manual Load prepares through ModelLifecycleCoordinator and starts the same 30-second cooldown once ready. Manual Unload is permitted only when no session owns the runtime. Opening Settings never loads a model. Resolve command races in the lifecycle actor, not just by disabling controls.

Rationale: displayed model state must reflect real ownership and an explicit Load cannot defeat idle release. First-run guidance belongs in the same window and must explain durable text retention, explicit deletion, permission denial and actual verified model information.

Alternatives considered: a settings-local runtime, indefinite manual pinning, hard-coded model sizes and a separate Settings scene violate the approved contract or lifecycle requirements.

## Native window and panel APIs

Decision: use SwiftUI's single Window scene, a shared route and an AppKit restore bridge as needed. The indicator panel uses nonactivatingPanel and also refuses key/main status; show it without making it key. Anchor to the captured target display's visibleFrame, with pointer display fallback. VoiceOver and Escape provide cancellation without requiring the panel to own keyboard focus.

Rationale: nonactivation by itself does not prohibit receiving key input. Keep dictation ownership outside window lifetime, and use distinct static shapes for reduced motion. Sources: [SwiftUI Window](https://developer.apple.com/documentation/swiftui/window), [non-activating panel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel), [visible frame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe), [reduced motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion). These are design choices inferred from the APIs and approved requirements; focus behavior needs signed-app validation.

Alternatives considered: WindowGroup can create unwanted extra windows; a Settings scene contradicts the single destination; making the waveform key breaks original-target delivery. The browser's fabricated destinations cannot authorize an AX operation.

## Implementation correction, 2026-09-16

The user approved the pinned quantized `Encoder.mlmodelc` after implementation
inspection found that the prior FP16 description was incorrect. FluidAudio
0.15.7 `ModelNames.swift` identifies this as the original LUT-palettized encoder
selected by its `int8` option. The immutable model revision and all accuracy,
memory and local-only requirements remain unchanged. This is a model-description
correction, not a constitution exception. No model files were downloaded.

## HTML fidelity revision

Decision: translate the existing approved HTML into native SwiftUI, retaining the menu-bar router and local services. The latest user request supersedes the Sotto appearance decision above. The prototype supplies all colors and geometry; no external design research or dependency is needed. A fixed two-item sidebar avoids native split-view chrome changing the reference layout. Compact settings rows replace Form; the full shortcut editor lives in a sheet. The alternative of embedding HTML conflicts with the native-client constitution. Existing state, persistence and model protocols remain applicable.

## Recorded shortcut priority

Use CoreGraphics active session event taps at head insertion, consuming matched down/repeat/up events by returning nil. Apple documents head insertion as precedence over existing taps at the same location; this does not establish universal priority. Recorder input uses a separate temporary head tap, limited to one chord and 30 seconds, with focus/navigation cancellation. Carbon registration cannot provide the requested unrestricted binding and priority behavior. Keep a passive Fn-only fallback without Accessibility and label permission failures directly. See acceptance/compact-settings.md for sources and verified scope.
