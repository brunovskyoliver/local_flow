# Research decisions

## Engine and windows
Choose the locally evaluated whisper.cpp large-v3-turbo conversion. Existing 24-minute evaluation found 120-second context recovered the opening that shorter windows lost, but two long-window outputs looped. Use 120-second main windows with bounded 60-second retry on obvious consecutive loops. This is mitigation, not a hallucination guarantee. Wispr comparison scores measure disagreement, not human gold WER.

## Packaging
Pinned Sotto Engine statically links whisper/ggml and embeds Metal source. Existing binary links only system frameworks/libraries. Build with GGML_NATIVE=OFF and deployment target macOS 14, package nested signed helper. Preserve licenses. Model and VAD are separate verified on-disk assets.

## Ownership and identity
Use an explicit workload, not a global model replacement. This preserves the live/dictation route and makes exclusion auditable. Parameterize final window geometry and engine identity; incompatible previous partial passes restart. Acquire before replacement to preserve previous text when the model is missing.

## Alternatives
Switching the whole app to Turbo would affect dictation without supporting evidence. Merely changing a model path would retain Parakeet geometry and violate assembler bounds. Running the benchmark script in production would add prohibited runtime dependencies. Full large-v3 performed poorly in the supplied excerpts and is excluded.


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

### Native segment timing (2026-09-20)

Every final row of the first full meetings carried `timing_basis = window`: whole
120-second windows as single segments. whisper.cpp segment text keeps the space
before its first token (`" Ahoj."`) while the window text is trimmed on the outside,
so `TranscriptSourceMapper` could not anchor the first token and the segmenter fell
back to window timing for the whole window. A last segment that overran the input by
0.52 s discarded the window's timing in the same way. The adapter now trims each native
segment, joins a segment boundary that falls inside a word, drops whitespace-only
segments and clamps an end within 2 s past the input; timing that starts past the input
still falls back. The text itself is never rebuilt from segments. The segmenter then
cuts at native segment gaps ≥ 0.8 s, sentence punctuation and 40 words as designed,
which is what speaker alignment (Feature 007) needs to label turns inside a window.

### Per-track final pass (2026-09-20)

The mixed stream (`0.5·mic + 0.5·system`) was the weak point of the first full
meetings. On the reference speaker-playback meeting the system track decoded above
full scale (peak 1.36) and 13 dB louder than the microphone, and the microphone
carried the remote voice again 200 ms later, so the remote speaker reached the
recognizer comb-filtered. Its first window came back as 120 s of "Ďakujem za
pozornosť"; each track alone decoded cleanly, and per-track requests cost about the
same as the mixed one (system 4.6 s + microphone 7.9 s against 9.6–11 s per window).

The turbo configuration (`per_track_fixed1920000_turbo_level_v2`) therefore decodes the
two tracks through single-track mixers into one lane each, with one window buffer per
lane. Before recognition a microphone window has the echo-explained spans muted
(`EchoGate.mute`, 10 ms fades; the gate is calibrated once per pass from both tracks
exactly as diarization does, on a stretch-relative timeline) and every window is
levelled by `TrackLevelNormalizer` (`level_p90_m20_v1`: the 90th percentile of
100 ms frame RMS over frames above −60 dBFS moves to −20 dBFS, gain bounded to
[−20, +30] dB, samples clamped). Rows carry `analysis_tracks = mic | system`; the
rows of one window index are merged by start time once every lane has passed that
window, so ordinals stay chronological, and the merged window's progress is the
furthest lane's end so a resume skips it on both tracks. Speaker alignment then
labels a per-track row from that track's turns alone
(`align_dom0.60_ratio2_ovl0.20_bytrack_v3`). The descriptor records
`per_track_16k_v1` / `mixRule = none`; the live pass keeps the mixed stream.

A track on its own carries the other side's silence, which the decoder is happy to
fill. Meeting requests now run whisper.cpp with its VAD mode (`silenceSkipping`: only
speech spans are decoded, timestamps mapped back), the temperature fallback ladder
(0.2 steps, entropy 2.4, log-prob −1.0) and a loop retry: three identical consecutive
native segments are a loop the entropy check misses (timestamp tokens are all
distinct), and the window is decoded again sampled from 0.4 up. The app's split retry
(FR-006) stays as the last resort. The reference meeting's system track opens with a
ringback tone (three decaying bursts, 0–5 s) that the model reads as "Ďakujem za
pozornosť"; that opening stays fragile and is not a silence the VAD removes.

### Meeting language (2026-09-21)

The 56-minute Slovak call of 2026-09-20 (both tracks intact, no capture drops)
scored 24.6 % word disagreement against the Wispr Flow transcript of the same call
and took 12.6 min to finalize. Replaying the pass's exact lane audio (echo gate on,
29.6 of 56 microphone minutes muted; `MeetingLaneDumpHarness`) through the bundled
helper showed where both went: with `language: auto`, 10 of the 28 microphone
windows were decoded as English or Romanian — whisper detects the language on the
first 30 s of a request, and a microphone window whose first 30 s is muted echo
leaves it a few words in silence — and 14 of 28 hit the loop retry, which decodes a
window twice ("Thank you. Thank you. …", "I don't think I'm a good person. …"
over muted spans). Slovak speech came back translated into English ("…a video about
the simulation of the robot sapiens"), or as Romanian.

Two changes. Each meeting gets a **Transcript language** (picker next to the title while
recording and in the transcript header afterwards: Default, Automatic, Slovak, Czech,
English), with Settings' **Meeting language** as the default; the choice is read when a
final pass loads the runtime and
recorded in the pass identity as `lang_<code>_prompt_v1`, so a pass interrupted under one
language is never resumed under another. A fixed language goes to the helper as its
code; whisper then skips detection and the encoder passes it costs.

Automatic no longer lets whisper detect on whatever fills a window. The helper
decides the language before decoding on the window's first 30 s of *speech* (the
Silero spans concatenated) and hands `whisper_full` a fixed language: a detection at
probability ≥ 0.9 is used as is; below that the request's `fallbackLanguage` decides,
which `WhisperMeetingRuntime` sets to the helper's last confident detection of the
pass (`languageDecision = detected`); without one, whisper detects as before. Nothing
is pinned for good: a later window that is confidently another language still
decodes in it, so a call that switches language keeps working. The decision is
reported per request (`languageDecision`: fixed, detected, fallback, whisper).

Replays of the same lanes (`build/wispr-compare-20260921`, word disagreement against
the Wispr transcript after the app's energy filter; helper seconds for 2 × 56 min):

| Request | Disagreement | Helper time | Stock filler rows | Wrong-language windows |
| --- | ---: | ---: | ---: | ---: |
| `auto`, old helper (the app's pass) | 26.6 % | 447 s | 9 | 17 of 58 |
| `sk` fixed | 23.8 % | 376 s | 34 | 0 |
| `auto`, speech detection + fallback | 23.6 % | 412 s | 29 | 1 (8 words) |
| `sk` + the four Dictionary terms as prompt | 21.4 % | 365 s | 18 | 0 |
| `sk` + a Slovak context sentence + Dictionary | 20.3 % | 369 s | 6 | 0 |

The remaining disagreement is mostly substitutions, and the largest single class is
English terms inside Slovak speech written as heard ("rag" → "rak", "case" → "casy",
"browser" → "bráuseri") where Wispr keeps the English spelling. The meeting request
therefore also carries the enabled Dictionary terms (`vocabularyTerms`, canonical
spellings, at most 256) and one context sentence per language (`languageContext`);
the helper puts the sentence for the window's decoded language in front of the
terms as whisper's carried initial prompt. The sentence never appeared in the
output. Terms the Dictionary does not know stay as heard: the Dictionary is the way
to teach the final pass a project's vocabulary.

Not changed: whisper large-v3-turbo itself, beam 5 and the 120 s windows. The pass
still decodes both tracks in full (echo gate on, VAD skipping the muted spans), and
the loop retry still decodes about a third of the windows twice; those are the
next levers for time.
