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
// Durable meeting consumer only: emit bounded silence for overflow intervals,
// then retained audio at its original source position. Terminal silence is
// available after CloseAndJoin. Do not mix pop modes on the same ring.
uint32_t LFAudioRingPopPreservingTimeline(LFAudioRing *ring, AudioBufferList *buffers);
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
// Feature 019, producer side, lock- and allocation-free. The first push holding a
// non-zero sample records LFAudioCaptureNow() once; 0 means no audio has flowed.
uint64_t LFAudioRingFirstAudioNanoseconds(const LFAudioRing *ring);
// Keeps the session maximum of the per-callback delivery delay the producer reports.
void LFAudioRingRecordDeliveryDelay(LFAudioRing *ring, uint64_t nanoseconds);
uint64_t LFAudioRingMaxDeliveryDelayNanoseconds(const LFAudioRing *ring);
// Host-time ticks (AVAudioTime.hostTime, mach_absolute_time) to nanoseconds.
uint64_t LFAudioHostTicksToNanoseconds(uint64_t ticks);
uint64_t LFAudioHostTicksNow(void);
// Feature 019: an input-only AUHAL unit on one device. AVAudioEngine cannot keep a
// non-default input (macOS swaps it for its default-device aggregate at start), so a
// ranked device is captured here and pushed into the same ring as the engine tap.
typedef struct LFAudioInput LFAudioInput;
// NULL when the device cannot be opened for input. The client format is Float32,
// non-interleaved, at the device rate and channel count (1-8).
LFAudioInput *LFAudioInputCreate(AudioDeviceID device);
double LFAudioInputSampleRate(const LFAudioInput *input);
uint32_t LFAudioInputChannels(const LFAudioInput *input);
// Pushes every device callback into `ring` until stopped; the ring must outlive it.
OSStatus LFAudioInputStart(LFAudioInput *input, LFAudioRing *ring);
void LFAudioInputStop(LFAudioInput *input);
// False once stopped, the device died or its sample rate changed.
bool LFAudioInputIsRunning(const LFAudioInput *input);
void LFAudioInputDestroy(LFAudioInput *input);
#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Runs `block` and returns the reason of an Objective-C exception it raised, or nil.
// AVAudioNode.installTap raises instead of throwing when the format is rejected.
NSString *LFCatchException(void (NS_NOESCAPE ^block)(void));
#endif
#endif
