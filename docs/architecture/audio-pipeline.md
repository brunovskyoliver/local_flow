# Audio pipelines

## Dictation (Feature 001)

AVAudioEngine captures the microphone. A nonblocking audio callback feeds a bounded queue; normalization and inference run away from the callback and main actor. The implementation plan sets queue, chunk and duration limits. Overflow must stop capture with a visible recoverable error, never silently drop speech. Multilingual Parakeet is initially a batch/chunk adapter, not assumed to be a multilingual streaming API.

Default audio is ephemeral. Bounded chunks may spill to app-private temporary files; cleanup runs on every exit and at startup. No audio history or backup. Every nonempty transcription is persisted in bounded local history before insertion, including partial results. Confirmed delivery or Dismiss recovery clears recovery status without changing completeness or deleting text. Only confirmed explicit Delete removes history; Copy changes neither text nor recovery status. An uncertain insertion must not trigger automatic retries that duplicate text.

Capture the target application and focused editable element before showing UI. Revalidate the target before insertion; never send text to a newly focused application. Secure fields are ineligible. Unsupported, closed or inaccessible targets leave completed text available for explicit copy. Clipboard modification is user initiated in Feature 001.

## Meetings (future)

ScreenCaptureKit supplies system audio; microphone capture uses its supported microphone API or AVAudioEngine according to the eventual OS baseline. Keep mic.m4a and system.m4a separate with timing metadata. Incrementally encode bounded fragments to disk. Plain unfinished M4A may be unplayable after a crash: Feature 003 must specify independently finalized chunks or another recoverable container strategy, plus a session manifest and startup recovery. Never promise crash safety from a filename alone.

A derived bounded mono stream may feed live STT. Twenty minutes and two hours of recording must have comparable non-model working sets. Disk exhaustion must stop safely and preserve finalized fragments.

On stop: finalize compressed fragments and live transcript; finish ASR and release it; acquire diarization; segment, embed and match with confidence thresholds; persist transcript; release diarization; queue transcript-text summarization. Shared media reads are windowed. Network failure leaves all local artifacts usable.
