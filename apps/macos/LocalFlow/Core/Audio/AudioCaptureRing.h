#ifndef LOCALFLOW_AUDIO_CAPTURE_RING_H
#define LOCALFLOW_AUDIO_CAPTURE_RING_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct LFAudioRing LFAudioRing;
// SPSC: one serialized device callback, one serial worker. Capacity is 32 full
// 4096-frame, 8-channel slots (4 MiB sample payload), allocated before capture.
LFAudioRing *LFAudioRingCreate(uint32_t channels, double sampleRate);
void LFAudioRingDestroy(LFAudioRing *ring);
// Larger device callbacks use multiple slots, admitted as one bounded batch.
bool LFAudioRingPush(LFAudioRing *ring, const AudioBufferList *buffers, uint32_t frames);
uint32_t LFAudioRingPop(LFAudioRing *ring, AudioBufferList *buffers);
// Closes admission and joins in-progress copies; call only off realtime thread.
void LFAudioRingCloseAndJoin(LFAudioRing *ring);
// 0 = no failure, 1 = overflow, 2 = invalid/oversized format.
void LFAudioRingSignalFailure(LFAudioRing *ring, int32_t failure);
int32_t LFAudioRingFailure(const LFAudioRing *ring);
// Bounded occupancy measurements for local resource records. Reading them never
// blocks the realtime producer and never reveals audio content.
uint32_t LFAudioRingCapacity(void);
uint32_t LFAudioRingHighWater(const LFAudioRing *ring);
// Meeting mode (Feature 004): a push that does not fit is dropped whole and
// counted instead of latching overflow, so admission stays open. Default off;
// the dictation ring keeps its latch-and-stop behaviour.
void LFAudioRingSetDropOnOverflow(LFAudioRing *ring, bool enabled);
uint64_t LFAudioRingDroppedFrames(const LFAudioRing *ring);
// Slots currently queued (head - tail); a bounded measurement, never blocking.
uint32_t LFAudioRingOccupancy(const LFAudioRing *ring);
uint64_t LFAudioCaptureNow(void);
#endif
