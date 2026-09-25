# Native meeting runtime contract

Launch one bundled helper under the lifecycle lease with verified Turbo and VAD paths. Await ready before accepting one transcription request. Request includes unique ID, bounded WAV path, the meeting language from Settings (`auto`, `en` or `sk`) and explicit production meeting mode; under `auto` it also carries `fallbackLanguage` (`en` or `sk`), the helper's last confident detection of the pass, once there is one. The helper decides a meeting window's language on its first 30 s of speech before decoding. Only English and Slovak compete: the reported probability is the winner's share of p(en) + p(sk). A share ≥ 0.9 pins it; otherwise the fallback; otherwise the larger share; with no usable speech, the fallback or else `sk`. `auto` never reaches `whisper_full`. The helper reports `languageDecision` (`fixed`, `detected`, `fallback`, `default`). Progress does not contain transcript text. Result ID must match; parse capped text and native timestamp segments. No text/audio is logged.

Automatic detection policy `speech_language_v3` (v2 plus the English/Slovak constraint) requires at least 3 seconds of VAD speech as well as probability ≥ 0.9. `languageSpeechSeconds` reports the detection sample duration, capped at 30 seconds. Inconclusive or failed detection retains `fallbackLanguage` when present. Swift accepts a new fallback only from a structurally valid, nonempty, nonrepetitive result after silence filtering, with finite probability in [0.9, 1] and speech duration in [3, min(30, input duration)]. Results without this evidence still retain their text but do not change the fallback. Fixed-language requests remain unchanged.

Audio: mono 16 kHz, at most 120 seconds. Main request can retry once as two at-most-60-second windows on consecutive repetition. Reject malformed/oversized output. Silence is a valid empty result. On cancellation, startup failure, timeout or process failure, terminate/join and remove temporary audio before returning. Existing helper protocol bounds also apply. No cloud fallback.


### Recovery refinement from the full meeting replay

The first full run encountered a loop at 600 seconds into the second recording
stretch. Both the 120-second request and a 60-second retry repeated a stock phrase;
a 30-second request also lost speech. Isolated 15-second requests recovered spoken
content. Recovery now has two bounded levels: split the main request in half,
then split only a still-repeating half into four pieces. With a 120-second main
window, final pieces are at most 15 seconds. Maximum work is 11 requests and
360 seconds of input including retries. Reject repetition in both pieces and
the combined result. The main window geometry and persisted resume boundaries
remain unchanged, so already successful windows can resume safely.


### Timing evidence

Finite native timestamps outside the audio window invalidate timing evidence,
not otherwise valid text. Return no timing tokens in that case so downstream
assembly uses the known window interval. Never turn these timestamps into
invented word onsets. Structural protocol validation and byte limits remain strict.
