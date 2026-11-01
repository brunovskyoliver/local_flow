# Research: Feature 026
## R1 sherpa-onnx
Phase 0 used v2.0.1 and `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` on a VM: English WER 4.78%, Slovak 15.87%, RTF 0.036, 752-830 MB peak per file, not x64 evidence. The Slovak figure is inside the owner's allowance of 5 points worse. A Rust crate would build ONNX Runtime at compile time and break cross-builds; dynamic loading avoids that. Licences: sherpa-onnx Apache-2.0, ONNX Runtime MIT, Parakeet CC-BY-4.0 with attribution in the notices.
## R2 Hashes
Pinned hashes must come from really downloaded files. Record the source and date; never write a hash that wasn't computed here.
Pinned 2026-11-01 from files downloaded here:
- Model: `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2` from the `asr-models` release, SHA-256 `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`. Files extracted from it and hashed. Provisioning fetches them one by one from Hugging Face `csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` at revision `2bda32ec70b097a55adaa07d9a7173915b43cc78`, so no archive code is needed. The three ONNX hashes equal that revision's LFS IDs; `tokens.txt` was also fetched from that revision with curl and hashed the same.
- Runtime: `sherpa-onnx-v2.0.1-win-x64-shared-MT-Release-no-tts.tar.bz2` (`a644dfe2f7944afec9a356d2557c0452380f20ffcf2f8c704653cfce37558596`) and `sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts.tar.bz2` (`4fcc6c77c8d8d2e2f04cfdc17c6fd224c01469b78529370eb9d8e0e5ec97ac79`). Per-file hashes are in `crates/flow-speech-win/manifest.json`.
## R3 What really ran (Mac, not Windows evidence)
`flow-speech-win` on this arm64 Mac with sherpa-onnx v2.0.1's macOS library: `provision` wrote and verified all four files from a loopback server holding the extracted files, and `serve` loaded them through `dlopen`, answered `ready`, and recognized the model's own `en.wav` (resampled to 16 kHz, 61,521 samples) as "Ask not what your country can do for you. Ask what you can do for your country." with 27 timed tokens, `recognition_ms` 89 in one debug-build run with the warmup paid first. That's one sample, not a measurement.
Not run: `provision` over HTTPS against Hugging Face. On this machine new binaries' outbound connections time out (curl's don't), so the Rust download path ran only over loopback. Nothing was run on Windows; the Windows loader and DLLs only compile. Both are in `acceptance/hardware.md`.
The C struct layouts were measured by compiling v2.0.1's own `c-api.h` and are asserted in `sherpa::tests::layout_matches`; the header is the same on both platforms apart from line endings.
## R4 Dependencies
`sha2` 0.10 (MIT or Apache-2.0), direct in `flow-speech-win` only: streaming SHA-256 for a 652 MB file, which `history::sha256_hex` can't do without holding it in memory. Already in the build through `hpke`, so no new code ships.
`flow-platform` now depends on `flow-core`, for the lifecycle's `Launcher` trait and the shortcut logic. The boundary script only forbids the opposite direction.
## R5 serde_json key order
A workspace dependency enables serde_json's `preserve_order`, so the frame encoder sorts keys itself instead of relying on the default map.
## R6 Shortcut sources
Mac: a session tap per job on its own thread and run loop, not the main one as in Swift, so a stalled UI can't time it out. The same `Engine` holds the binding and recorder under a short lock. A jump in the wall clock stands in for `NSWorkspace.willSleepNotification`, so a hold is cancelled on wake.
Windows: the hook callback only queues into a channel of 256, then a second thread does the rest. It therefore can't consume keys, so a chord still reaches the focused app; Windows differs from Swift here. A new hook replaces the old every 30 s, because Windows drops a slow hook silently, and `GetAsyncKeyState` backs up a lost key-up during a hold. `fn_globe` and fn modifiers are refused and Right Control is the default.
The shortcut format stays the Mac's: Windows virtual keys map to Mac key codes and device bits in `win_rules`, with the Windows key in Command's place. `Shortcut::title` therefore names it "Command" and a letter "Key <code>"; nothing on a PC has checked that copy.
`request_permission(Microphone)` blocks its caller for up to a minute waiting for the answer, since the prompt is in another process. It refuses without `NSMicrophoneUsageDescription`, because TCC kills a process that asks without one.

## Phase 5 decisions

- A detached thread owns the blocking channel and `Stream::poll` watches the threshold from outside, so a stalled socket or connect can't hold up the fallback. An abandoned thread ends at its next socket timeout.
- The socket read uses a 1 ms timeout to poll, because the same thread also sends audio.
- Swift's 3 s hotspot threshold isn't ported: there is no path monitor. The setting's threshold applies.
- Live rewrites send v1 only until context capture is ported. Over the channel, History rewrites also stay v1, since the version probe is HTTP.
- `rewrite_timeout` on the channel path excludes connect time.
- Fake speech worker: the Go test overlay of flowd runs itself as `--speech-worker`, so loopback tests go through flowd's real supervisor without building `flow-speech-win`.
- A press during a retrier run cancels the retry. flowd may still hold that dictation for a moment, so the live press can see `busy` and fall back; the row stays due.

## Phase 6 decisions

- Installs run the worker's `provision` and read its stderr lines; the exit status decides. A failure line beats exit 0.
- `speech_model_verified` at launch reads a marker file the install leaves in the models folder, not Swift's size-and-date fingerprint. A model installed only by the Swift app downloads or rehashes once on first install. Test rehashes.
- Meeting pack progress shows the current model's numbers, not the total of the pack.
- `speech::set_models_dir` holds the folder process-wide, so `Services` signatures and `settings_action` stay as the pages call them.
