# Capture contract

- Producer never waits for the consumer, allocates, or writes to disk. Overflow drops and counts the whole callback.
- Timeline-preserving pop emits at most 4096 frames. Silence is emitted before the next retained source frame, never at an arbitrary later boundary. Trailing loss may be emitted only after producer admission closes and in-flight callbacks join.
- Ordinary pop retains the existing contract. A ring has one consumer, and callers must not switch pop modes midstream.
- Worker progress permits one delivery task and one pending newest snapshot. A recipient does not own recording cadence. Finalization does not wait on UI/store delivery; persisted terminal state wins over late progress.
- Gaps are silence, not recovered speech. Loss remains visible even with matching file/timer durations. Old media is never rewritten.

Cancellation requests recipient cancellation; it cannot forcibly terminate an arbitrary injected callback. Bounds are per worker. In production, store and MainActor progress use the same dependencies required for subsequent worker creation, preventing unchecked creation of stalled deliveries.
