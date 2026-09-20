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
