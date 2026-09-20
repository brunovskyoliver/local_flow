# Hardware acceptance status

Not collected. The repair has deterministic and real-code tests, not a new 30-minute physical microphone/system-audio acceptance run.

Required conditions: macOS build, hardware, source formats and device changes; representative CPU/disk/UI load with live transcription; elapsed and independently decoded durations; per-track drop counts and queue peaks; RSS; periodic shared audio markers to measure alignment. The source-frame repair preserves capture overflow intervals, not wall-clock intervals during device disconnect/restart or absent source callbacks. Document those separately.

Existing real recording evidence: microphone loss 199.00 s and system loss 276.34 s, with decoded-plus-dropped duration accounting within 0.19 s. Original files have not been changed. No claim is made that the historic missing audio is recovered or that every overflow cause is eliminated.
