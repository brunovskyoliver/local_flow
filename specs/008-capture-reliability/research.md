# Research and decisions

## Established evidence

The private September 19 meeting contains 9,552,000 dropped microphone frames and 13,264,320 dropped system frames at 48 kHz. Complete decode plus dropped counts matches elapsed recording duration within 0.19 seconds. Aggregate counters do not identify the historical trigger.

A minimal production-C-ring reproduction offers 19,200 frames, forces overflow, then drains 15,360 frames with 3,840 counted drops. It exits 1 when asked to preserve the original timeline. This establishes time compression independently of recognition quality.

## Decisions

Use source-frame positions and opt-in silence emission inside the bounded ring consumer. This preserves ordering even when the consumer is far behind; a global dropped counter sampled during draining cannot identify whether a drop precedes or follows queued samples. Keep ordinary pop unchanged for dictation and analysis.

Decouple progress delivery only after the real-worker regression reproduces its coupling. One in-flight delivery plus one replaceable pending snapshot bounds stalled recipients. Launching a new task per update would accumulate work. Increasing the ring alone would only postpone overflow. Reconstructing old gaps from aggregate counters is not possible.

Retain AAC and the existing store. Inserting silence before encoding records gap positions in the durable timeline without a duration-growing side buffer. Drop counts remain evidence of lost content. Store warnings must not be cleared just because silence restores duration.

The real-worker stalled-heartbeat regression failed twice in 0.60/0.47 seconds, offering 40 blocks while heartbeat delivery was gated. Eight blocks (32,768 frames) were dropped and all 32 slots remained occupied. Finalization did not hang. This isolates awaited progress delivery as a reproducible overflow cause; full historical attribution remains unknown.
