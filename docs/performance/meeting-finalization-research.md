# Meeting finalization: external research

Companion to [post-meeting-pipeline.md](post-meeting-pipeline.md). That file maps
where the time goes in LocalFlow's code; this file records what the upstream
projects document for each candidate lever. Claims cite the owning source.
Numbers a source does not publish are marked **unmeasured upstream**; third-party
benchmarks are marked as such.

Pinned versions: whisper.cpp v1.9.3 (371b5a7561823ab2bb32142d2751e35e7534727b)
via `third_party/sotto` ([LOCALFLOW-UPSTREAM.json](../../third_party/sotto/LOCALFLOW-UPSTREAM.json)),
FluidAudio 0.15.7 ([Package.resolved](../../apps/macos/LocalFlow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)).
Helper configuration as shipped: `flash_attn = true`, beam_size 5,
`temperature_inc` 0.2 fallback with entropy 2.4 / logprob −1.0, internal Silero
VAD (`vad = true`), fresh `whisper_state` per request
(`third_party/sotto/Engine/worker.cpp:403-447, 622`).

## 1. whisper.cpp batch/offline throughput

- **Metal is the whole GPU path**: "On Apple Silicon, the inference runs fully
  on the GPU via Metal" ([README](https://github.com/ggml-org/whisper.cpp)).
  Upstream benchmark tables run Metal at Th=1
  ([v1.7.6 release tables](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.7.6)).
  `n_threads` feeds CPU-side work (mel spectrogram, the CPU VAD context, any
  unoffloaded ops); more threads is not a documented speed lever under Metal.
- **`flash_attn` is already on** (worker.cpp:622). Added in
  [PR #2152](https://github.com/ggerganov/whisper.cpp/pull/2152): measurable
  encoder/decoder gains on Metal and CUDA; on CPU it degrades performance.
- **CoreML/ANE encoder offload still exists upstream**: `WHISPER_COREML=1`
  build plus a separately generated `*-encoder.mlmodelc`
  ([README "Core ML support"](https://github.com/ggml-org/whisper.cpp)).
  The README's ">3x" claim is versus CPU-only execution, not versus the Metal
  GPU encoder — gain over Metal on turbo is **unmeasured upstream**. Caveats:
  `--optimize-ane` is marked "currently broken" in `convert-whisper-to-coreml.py`
  and ANE inference fails on macOS 26.4 beta per
  [issue #3702](https://github.com/ggml-org/whisper.cpp/issues/3702); a
  non-CoreML ANE encoder via ANEForge claims ~2x over the CoreML encoder but is
  an unmerged, env-var-gated research path
  ([PR #3905](https://github.com/ggerganov/whisper.cpp/pull/3905)).
- **beam_size 5 vs greedy**: beam search keeps beam_size candidate sequences
  per decode step ([PR #291](https://github.com/ggerganov/whisper.cpp/pull/291));
  decode cost scales roughly with beam count while encode cost is unchanged.
  The documented reason to keep 5 beams is quality — ggerganov recommends it to
  reduce repetition loops
  ([issue #1507](https://github.com/ggml-org/whisper.cpp/issues/1507)). Greedy
  would buy decode time at a documented repetition risk; no upstream WER table
  for beam-vs-greedy on turbo (**unmeasured upstream**).
- **`temperature_inc` fallback cost**: on entropy/logprob failure the same
  30 s chunk is re-decoded at T+`temperature_inc` steps up to 1.0; above T 0.5
  the greedy path clears prior context (PR #291 mechanism). Each fallback step
  is another decoder pass — the ladder is the price of the anti-loop guarantee.
  `--no-fallback` disables it
  ([examples/server/server.cpp defaults](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/server.cpp)).
- **VAD**: `vad = true` + `vad_model_path` runs Silero inside `whisper_full`,
  extracts only speech segments, and per the README "can significantly speed up
  the transcription process" ([README VAD section](https://github.com/ggml-org/whisper.cpp);
  feature added in [PR #3065](https://github.com/ggml-org/whisper.cpp/pull/3065),
  released v1.7.6). Tunables in `whisper_vad_params` — threshold, min speech/
  silence durations, `speech_pad_ms`, and `samples_overlap` (0.1 s copied
  between consecutive segments) ([include/whisper.h](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h);
  server defaults: threshold 0.5, min speech 250 ms, min silence 100 ms, pad
  30 ms, overlap 0.1 s). Note the helper runs Silero twice per window: the
  standalone pre-check (worker.cpp:353-360) and again inside `whisper_full`
  (worker.cpp:437-439).
- **`audio_ctx`** (`-ac`): truncates encoder context, filed under
  "[EXPERIMENTAL] speed-up techniques ... can significantly reduce the quality
  of the output" (whisper.h). Quality cost **unmeasured upstream** for turbo.
- **`max_len` / `split_on_word` / `max_tokens`**: segment-shape controls —
  "max segment length in characters", "split on word rather than on token (when
  used with max_len)", "max tokens per segment" (whisper.h). They shape output
  text, not throughput.
- **`-dtw` word timestamps**: [EXPERIMENTAL] token-level timestamps via
  cross-attention DTW; requires the model-matched `dtw_aheads_preset`
  ([PR #1485](https://github.com/ggml-org/whisper.cpp/pull/1485),
  [issue #2283](https://github.com/ggml-org/whisper.cpp/issues/2283)). Adds an
  alignment pass per segment; cost on turbo **unmeasured upstream**. Only
  relevant if window-internal word timing must improve.
- **Decoder state across calls**: `whisper_state` holds `result_all` plus
  prompt history `prompt_past0` (carried static prompt) and `prompt_past1`
  (rolling context)
  ([src/whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/master/src/whisper.cpp)).
  `initial_prompt`/`prompt_tokens` are "prepended to any existing text context
  from a previous call" (whisper.h). So the same state with `no_context=false`
  carries previous output into the next call's prompt automatically, and a
  fresh state can still be fed the previous window's tail via `prompt_tokens`
  — capped at `whisper_n_text_ctx()/2` (~224 tokens). The helper creates a
  fresh state per request (worker.cpp:334) and never feeds prior text; that is
  a policy choice, not an engine limitation. `n_max_text_ctx` (`--max-context`)
  caps how much past text enters the prompt.
- **Long-form looping**: the upstream-tracked mitigations are the same levers —
  5 beams, higher `entropy_thold` (2.8 suggested), `--max-context` 64/32/0 with
  0 ≈ `condition_on_previous_text=false`, which "will remove 'forever looping'"
  at some quality cost
  ([issue #1244](https://github.com/ggml-org/whisper.cpp/issues/1244));
  silence-driven loops are the reported dominant cause, motivating VAD (#1507).
  An unshipped proposal adds `context_max_vad_gap_ms` and retry-on-repeat
  without context
  ([issue #3744](https://github.com/ggml-org/whisper.cpp/issues/3744)).
  Long-audio loop reports persist on Metal builds
  ([issue #2755](https://github.com/ggml-org/whisper.cpp/issues/2755)).

## 2. Chunked long-form stitching practice

- **whisper_streaming / LocalAgreement-2** (paper:
  [arXiv 2307.14743](https://arxiv.org/abs/2307.14743), DOI
  10.18653/v1/2023.ijcnlp-demo.3; repo:
  [ufal/whisper_streaming](https://github.com/ufal/whisper_streaming)).
  Decodes the *whole unconfirmed buffer* each update; text agreed by two
  consecutive decodes (longest common prefix) is committed; the unconfirmed
  tail is re-decoded with more audio. No seam dedup is needed because
  unconfirmed text never commits. Buffer is trimmed at confirmed segment ends
  when it exceeds the threshold — default `buffer_trimming=("segment", 15)` in
  [whisper_online.py](https://github.com/ufal/whisper_streaming/blob/main/whisper_online.py);
  a `--offline` flag runs the same policy over a file. Reported latency ~3.3 s
  on an A40 GPU.
- **faster-whisper**: VAD-aligned boundaries, not fixed windows. `vad_filter`
  runs Silero; defaults are conservative — `min_silence_duration_ms=2000`
  (only silence >2 s is removed), `speech_pad_ms=400`, `threshold=0.5`
  ([faster_whisper/vad.py](https://github.com/SYSTRAN/faster-whisper/blob/master/faster_whisper/vad.py),
  [README](https://github.com/SYSTRAN/faster-whisper)). `BatchedInferencePipeline`
  keeps VAD always on, caps speech segments at `chunk_length` (default 30 s),
  drops the temperature fallback and forces `condition_on_previous_text=False`
  ([faster_whisper/transcribe.py](https://github.com/SYSTRAN/faster-whisper/blob/master/faster_whisper/transcribe.py)).
  Seam strategy: cut at detected silence + pad 400 ms; no overlap decode, no
  dedup pass.
- **WhisperKit**: `chunkingStrategy` = `.none` / `.sequential` (seek by last
  predicted timestamp, like whisper.cpp's internal long-form) / `.vad`.
  `VADAudioChunker` splits at the middle of the longest silence in the back
  half of the window and shaves `windowPadding = 16000` samples (1.0 s) to
  prevent end-of-clip hallucination; results are re-offset by seek time
  ([AudioChunker.swift](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Sources/WhisperKit/Core/Audio/AudioChunker.swift),
  [Configurations.swift](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Sources/WhisperKit/Core/Configurations.swift)).
  `concurrentWorkerCount` (CLI default 4) decodes chunks in parallel — a
  documented lever LocalFlow's serial loop does not have.
- **Overlap sizes used in practice**: whisper.cpp VAD copies speech segments
  with 0.1 s overlap; faster-whisper pads VAD segments 400 ms; FluidAudio's
  `SlidingWindowAsrManager` (Parakeet) uses ~15 s chunks with 2 s overlap and
  stitches
  ([ANE_Profiler.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ANE_Profiler.md),
  [Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)).
  whisper_streaming overlaps by re-decoding the unconfirmed tail instead.
  LocalFlow's hard non-overlapping 120 s windows are the outlier; both
  VAD-aligned cuts and overlap+dedup are documented practice, and both need a
  geometry change.

## 3. Alternative ASR engines measured on Apple silicon

- **WhisperKit** (CoreML/ANE): paper
  [arXiv 2507.10860](https://arxiv.org/html/2507.10860) reports 0.46 s streaming
  latency and 2.2 % WER on its comparison set (M3 Max encoder measurements in
  Table 1). Argmax's own eval data: large-v3 2.44 % WER, `large-v3_turbo`
  variant 2.41 % on LibriSpeech test-clean
  ([whisperkit-evals dataset](https://huggingface.co/datasets/argmaxinc/whisperkit-evals_01-30-24)).
  Argmax's docs quote a "~20x" speed factor for large-v3-turbo
  ([Managing Model Files](https://app.argmaxinc.com/docs/guides/managing-models))
  — real-time factor, not RTF detail. No upstream conversational-meeting WER.
- **mlx-whisper** ([ml-explore/mlx-examples/whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper)):
  a port of the OpenAI reference loop — temperature ladder, compression-ratio
  and logprob thresholds, `condition_on_previous_text`, `clip_timestamps`
  ([transcribe.py signature](https://github.com/ml-explore/mlx-examples/blob/main/whisper/mlx_whisper/transcribe.py)).
  No `beam_size` parameter — greedy/best-of sampling only. `benchmark.py`
  exists but publishes no headline numbers. A community PR thread measured
  whisper-turbo at ~12.4x RT sequential on an M2 8 GB, with batching *slower*
  on 8 GB and flash attention ~0.96x because Whisper's sequences are short —
  third-party, memory-bound caveat, not upstream data
  ([issue #1412](https://github.com/ml-explore/mlx-examples/issues/1412)).
- **FluidAudio Parakeet TDT v3** (already shipped for dictation):
  ~120x real-time on M4 Pro per
  [docs.fluidinference.com/asr](https://docs.fluidinference.com/asr/getting-started);
  LibriSpeech test-clean 2.5 % WER at 156x RTFx; FLEURS 25-language average
  14.7 % WER at 210x. Encoder defaults to ANE; GPU placement is an opt-in ~8 %
  RTFx gain, WER-neutral ([PR #659](https://github.com/FluidInference/FluidAudio/pull/659)).
  25 European languages (Slovak included). v2 (English-only) is documented as
  slightly more accurate on long-form English. Trade-off vs whisper.cpp turbo:
  ~7-8x faster on published numbers, on the ANE instead of the GPU; accuracy on
  echo-gated meeting audio is **unmeasured** — Parakeet's published WERs are
  LibriSpeech/FLEURS, not meetings, and it was the live-pass engine whose
  short-window behavior motivated Feature 009.
- **whisper.cpp large-v3-turbo on Metal**: upstream publishes per-op tables
  (Enc./Dec./Bch5/PP per 30 s chunk — v1.7.6 release), not end-to-end RTF.
  Third-party M3 Ultra measurement: 17.7x RT
  ([mundwerk-app/whisper-metal-benchmark](https://github.com/mundwerk-app/whisper-metal-benchmark) —
  third party). LocalFlow's own figure — 447 s for 112 min incl. VAD, retries
  and prompts ≈ 15x RT (spec-009 research) — is the only meeting-realistic
  number.

## 4. On-device diarization

- **OfflineDiarizerManager** (FluidAudio, pyannote community-1 port):
  VoxConverse DER 15.1 % / RTFx 122 at default settings, 13.9 % / 65x at max
  accuracy; reference points: same pipeline on CPU 1.5-2x RTFx, on MPS 20-25x
  ([offline-pipeline](https://docs.fluidinference.com/diarization/offline-pipeline)).
  Device table: M2 Air 150x, M1 iPad 120x, iPhone 14 Pro 80x
  ([diarization getting-started](https://docs.fluidinference.com/diarization/getting-started)).
  Models are ~100 MB ([GettingStarted.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md));
  `StreamingAudioSourceFactory`/`process(audioSource:)` stream disk-backed
  audio so long meetings don't materialize the whole buffer
  ([API.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md)).
  LocalFlow additionally bounds to 10-min windows per spec-007.
- **Diarization during recording is a documented pattern**: pyannoteAI's
  streaming API consumes 100 ms PCM frames over WebSocket at real-time pace
  with ~300 ms internal latency target
  ([docs.pyannote.ai streaming tutorial](https://docs.pyannote.ai/tutorials/streaming-real-time),
  [build post](https://www.pyannote.ai/blog/how-we-built-streaming-diarization) —
  that post also describes DIART's windowed batch-adapted approach and its
  latency limits). NVIDIA **Streaming Sortformer** is the on-device-class
  option: arrival-order speaker cache over overlapping chunks, 4-speaker cap
  ([Interspeech 2025 paper](https://arxiv.org/abs/2507.18446),
  [NeMo docs](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/speaker_diarization/models.html)).
  FluidAudio ships Sortformer too: 31.7 % DER at 30.4 s chunks / 127x, vs its
  own streaming pipeline at 26.2 % DER / 223x and offline at 15.1 % — streaming
  costs roughly double the DER on their numbers.
- **Concurrent diarization + whisper.cpp on one Mac**: no primary source
  addresses it — **unmeasured upstream**. Structurally the pieces use different
  silicon: FluidAudio's pyannote models run on ANE (`.cpuAndNeuralEngine`;
  [ANE_Profiler.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ANE_Profiler.md)),
  whisper.cpp runs on Metal GPU — contention would be memory bandwidth and CPU,
  not the same unit. Sortformer fp16 high-context needs ~2.4 GB RAM vs ~330 MB
  palettized ([Sortformer.md](https://github.com/FluidInference/FluidAudio/blob/HEAD/Documentation/Diarization/Sortformer.md))
  — that is the kind of footprint table to build for the offline pipeline
  before requesting a co-residency exception (ADR 0019's "no parallel heavy
  models" rule).

## 5. Echo handling on macOS

- **AEC at capture exists**: `AUVoiceProcessingIO` /
  `AVAudioIONode.setVoiceProcessingEnabled` applies "signal processing on the
  incoming audio (taking out any of the audio that is played from the device)"
  — the played-through-speakers meeting audio is exactly the cancel target
  ([WWDC19](https://developer.apple.com/videos/play/wwdc2019/510/),
  [AVAudioIONode docs](https://developer.apple.com/documentation/avfaudio/avaudioionode)).
  Voice processing bundles echo cancellation, noise suppression and AGC
  ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/),
  [Audio Unit Hosting Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitHostingGuide_iOS/UsingSpecificAudioUnits/UsingSpecificAudioUnits.html)).
  Documented constraints: both input *and* output nodes must be in voice-
  processing mode; toggling requires the engine stopped; not supported in
  manual rendering mode; input output format must equal output input format;
  AGC on the mic uplink is **enabled by default** (`isVoiceProcessingAGCEnabled`,
  settable); mic modes Standard / Voice Isolation / Wide Spectrum change
  processing; `kAUVoiceIOProperty_BypassVoiceProcessing` exists
  ([VPIO properties](https://developer.apple.com/documentation/audiounit/1534007-voice-processing_i_o_audio_unit_proper)).
- **What that means here**: capture-time AEC would remove speaker echo from the
  mic *permanently in the stored audio*, preserving double-talk (local speech
  under remote speech) that the post-hoc gate must mute — but it also applies
  AGC + noise suppression, changing the levels the EchoGate calibration and the
  level normalizer assume, and it only cancels what the device actually played
  (headphone meetings have no acoustic echo to remove; the gate already fails
  calibration there by design). ScreenCaptureKit's `capturesAudio` /
  `excludesCurrentProcessAudio` deliver the pre-render app audio as the clean
  reference track regardless of playback path
  ([SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)).
- **WebRTC AEC as an offline post-pass**: `AudioProcessing` is frame-based —
  `ProcessReverseStream` feeds the render (far-end) reference,
  `ProcessStream` the mic, `set_stream_delay_ms` supplies the offset, ~10 ms
  frames, "designed for real-time communications software... placed as close to
  the HAL as possible"
  ([api/audio/audio_processing.h](https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h)).
  Nothing file-specific prevents replaying recorded render+capture streams
  through it, but there is no documented offline mode: the render↔capture
  delay must be reconstructed (LocalFlow's gate already estimates ~200 ms lag)
  and clock drift between the mic device and the ScreenCaptureKit timeline
  corrected — AEC3 assumes a live stream relationship. **Unmeasured upstream**
  for batch file cleanup.
- **AEC-at-capture vs post-hoc correlation gating**: gating is cheap
  (energies only), keeps raw audio inspectable and recomputable, and matches
  the observed bimodal levels (echo ≈ −18 dB under system, local ≈ +15 dB —
  spec-007). Its cost: any local speech overlapping remote speech is muted
  with the echo, and it needs a reliable correlation to threshold against.
  Capture-time AEC preserves double-talk and removes echo before it reaches
  any downstream consumer, but couples capture to Apple's VoIP DSP chain,
  permanently alters the recording, and can't help meetings already captured.
  They answer different questions: AEC improves what the mic *records*; gating
  fixes what the pipeline *believes* about existing recordings. No upstream
  source compares the two for ASR/diarization accuracy — **unmeasured**.

## 6. LLM map-reduce latency

- **Concurrent requests on one loaded model are a standard documented
  feature**: llama.cpp server `-np/--parallel N` slots with continuous batching
  on by default ([tools/server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md),
  [llama.app serve docs](https://llama.app/docs/serve)); Ollama
  `OLLAMA_NUM_PARALLEL` — default auto-selects 4 or 1 by memory, context memory
  scales with the parallel count, per-request TPS drops while aggregate rises
  ([Ollama FAQ](https://github.com/ollama/ollama/blob/main/docs/faq.mdx));
  vLLM's unified scheduler serves concurrent requests by design and logs the
  max concurrency the KV cache supports
  ([parallelism docs](https://docs.vllm.ai/en/stable/serving/parallelism_scaling/));
  LM Studio exposes "Max Concurrent Predictions" (default 4) via continuous
  batching — llama.cpp engine only, MLX engine "coming soon"
  ([LM Studio docs](https://lmstudio.ai/docs/app/advanced/parallel-requests)).
  mlx-lm's server batches with `--decode-concurrency`/`--prompt-concurrency`
  and an LRU prompt cache
  ([mlx_lm/server.py](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/server.py)).
- **Raising `requestsInFlight` 1→2 is reasonable iff the backend has ≥2
  slots**; otherwise the extra request queues server-side and burns the
  client's 300 s timeout budget. Slot counts are not always discoverable over
  the API (LM Studio: [lmstudio-bug-tracker #1666](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1666)),
  so admission control has to be configured, not probed. flowd already has the
  server-side gate (`--analysis-concurrency`, handler.go slot machinery); the
  client cap is policy, not a backend limitation.
- **Prefix/prompt-cache reuse makes sequential map steps cheap** — this is the
  documented mechanism the map stage should lean on even at concurrency 1:
  llama.cpp caches prompts per slot and evaluates only the "unseen" suffix of a
  shared prefix (`cache_prompt`, on by default; `--cache-reuse` adds KV-shift
  reuse — server README); vLLM Automatic Prefix Caching is on by default in V1,
  hashes KV blocks by prefix, and "won't change model outputs"
  ([APC docs](https://docs.vllm.ai/en/latest/features/automatic_prefix_caching/));
  mlx-lm ships `mlx_lm.cache_prompt` + prompt caches for exactly the
  shared-system-prompt case ([mlx-lm README](https://github.com/ml-explore/mlx-lm)).
  Consequence: keeping the system prompt + schema byte-identical across chunk
  requests turns each map step's prefill into a cache hit on the shared part —
  larger win than parallelism for this workload shape. Caveat: llama.cpp's
  RAM prompt cache has an open correctness issue where unrelated content can
  be restored into a fresh slot under concurrent load
  ([issue #27148](https://github.com/ggml-org/llama.cpp/issues/27148)) — pin a
  version and test cache behavior before relying on it.
- flowd's backend is any OpenAI-compatible endpoint
  (`--backend`, default model `mtplx-qwen35-9b-optimized-speed`,
  `server/cmd/flowd/main.go:42-43`), so this section's backend docs apply
  verbatim; the 60 s first-token timeout already anticipates prefill-heavy
  chunks (`analysis/limits.go:29-33`).
