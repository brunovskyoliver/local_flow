# Validation

Run isolated `MeetingSampleRingTests`, `MeetingTrackWorkerTests`, and `MeetingStoreTests` through the LocalFlow Xcode scheme. Test stalled progress with more callbacks than ring capacity, signal/gap/signal ordering, terminal drops, no-drop compatibility, encoded duration, and delayed progress after finalization. Run `make check` afterward.

For hardware acceptance, record both sources for at least 30 minutes with live transcription and representative CPU/disk/UI load. Record hardware/build, source rates, elapsed and decoded durations, drop counts, queue peaks, RSS and periodic shared timing markers. Review marker alignment and any warning. Do not mark this acceptance complete without collecting those measurements. Do not overwrite the original September 19 recording.
