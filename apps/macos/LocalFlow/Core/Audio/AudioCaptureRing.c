#include "AudioCaptureRing.h"
#include <math.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define LF_SLOTS 32u
#define LF_FRAMES 4096u
#define LF_CHANNELS 8u
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Capture requires lock-free atomics");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Capture positions require lock-free atomics");

struct LFSlot {
    uint32_t frames;
    uint64_t sourceStart;
    float *samples; // channels × LF_FRAMES, planar, inside the ring's storage.
};
struct LFAudioRing {
    _Atomic unsigned head;
    _Atomic unsigned tail;
    _Atomic unsigned copying;
    _Atomic unsigned high;
    _Atomic unsigned accepting;
    _Atomic int failure;
    _Atomic int dropOnOverflow;
    _Atomic uint64_t dropped;
    _Atomic uint64_t sourceFrames;
    uint64_t consumedThrough; // Single consumer, never accessed by the producer.
    uint32_t channels;
    struct LFSlot slots[LF_SLOTS];
    float storage[]; // LF_SLOTS × channels × LF_FRAMES, sized at creation.
};

static inline float *channelSamples(const struct LFSlot *slot, uint32_t channel) {
    return slot->samples + (size_t)channel * LF_FRAMES;
}

LFAudioRing *LFAudioRingCreate(uint32_t channels, double sampleRate) {
    if (!channels || channels > LF_CHANNELS || !isfinite(sampleRate) ||
        sampleRate <= 0 || sampleRate > 192000) return NULL;
    // Sized by the actual channel count: one channel is 512 KiB of samples, not
    // the 4 MiB an eight-channel layout needs.
    size_t slotSamples = (size_t)channels * LF_FRAMES;
    size_t size = sizeof(struct LFAudioRing) + (size_t)LF_SLOTS * slotSamples * sizeof(float);
    LFAudioRing *ring = calloc(1, size);
    if (!ring) return NULL;
    // calloc may hand back untouched zero pages. Touch every page now, not on the
    // audio callback's first copy; volatile keeps these stores from being elided.
    volatile unsigned char *bytes = (volatile unsigned char *)ring;
    for (size_t i = 0; i < size; i += 4096) bytes[i] = 0;
    bytes[size - 1] = 0;
    for (unsigned slot = 0; slot < LF_SLOTS; ++slot)
        ring->slots[slot].samples = ring->storage + slot * slotSamples;
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    atomic_init(&ring->copying, 0);
    atomic_init(&ring->high, 0);
    atomic_init(&ring->accepting, 1);
    atomic_init(&ring->failure, 0);
    atomic_init(&ring->dropOnOverflow, 0);
    atomic_init(&ring->dropped, 0);
    atomic_init(&ring->sourceFrames, 0);
    ring->channels = channels;
    return ring;
}

static bool fail(LFAudioRing *ring, int code) {
    int expected = 0;
    atomic_compare_exchange_strong(&ring->failure, &expected, code);
    atomic_store(&ring->accepting, 0);
    return false;
}

static bool valid(const AudioBufferList *buffers, uint32_t channels, uint32_t frames) {
    if (!buffers || !frames || frames > LF_FRAMES * LF_SLOTS) return false;
    if (buffers->mNumberBuffers == 1 && buffers->mBuffers[0].mNumberChannels == channels) {
        return buffers->mBuffers[0].mData &&
            buffers->mBuffers[0].mDataByteSize >= frames * channels * sizeof(float);
    }
    if (buffers->mNumberBuffers != channels) return false;
    for (uint32_t channel = 0; channel < channels; ++channel) {
        const AudioBuffer *buffer = &buffers->mBuffers[channel];
        if (buffer->mNumberChannels != 1 || !buffer->mData ||
            buffer->mDataByteSize < frames * sizeof(float)) return false;
    }
    return true;
}

bool LFAudioRingPush(LFAudioRing *ring, const AudioBufferList *buffers, uint32_t frames) {
    atomic_fetch_add(&ring->copying, 1);
    bool accepted = false;
    if (!atomic_load(&ring->accepting)) goto done;
    if (!valid(buffers, ring->channels, frames)) { fail(ring, 2); goto done; }
    uint64_t sourceStart = atomic_fetch_add_explicit(&ring->sourceFrames, frames, memory_order_relaxed);
    unsigned head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    // AVAudioEngine may deliver more than the requested tap buffer size.
    // Reserve every required slot before copying, then publish the whole callback.
    // Memory and work remain bounded by the preallocated ring; never truncate audio.
    unsigned needed = (frames + LF_FRAMES - 1) / LF_FRAMES;
    if (needed > LF_SLOTS - (head - tail)) {
        if (atomic_load_explicit(&ring->dropOnOverflow, memory_order_relaxed)) {
            // Drop the whole callback and count it; the latch is untouched.
            atomic_fetch_add_explicit(&ring->dropped, frames, memory_order_relaxed);
            goto done;
        }
        fail(ring, 1);
        goto done;
    }
    for (unsigned index = 0, offset = 0; index < needed; ++index) {
        uint32_t count = frames - offset;
        if (count > LF_FRAMES) count = LF_FRAMES;
        struct LFSlot *slot = &ring->slots[(head + index) % LF_SLOTS];
        if (buffers->mNumberBuffers == 1) {
            const float *source = buffers->mBuffers[0].mData;
            for (uint32_t channel = 0; channel < ring->channels; ++channel)
                for (uint32_t frame = 0; frame < count; ++frame)
                    channelSamples(slot, channel)[frame] = source[(offset + frame) * ring->channels + channel];
        } else {
            for (uint32_t channel = 0; channel < ring->channels; ++channel) {
                const float *source = buffers->mBuffers[channel].mData;
                memcpy(channelSamples(slot, channel), source + offset, count * sizeof(float));
            }
        }
        slot->frames = count;
        slot->sourceStart = sourceStart + offset;
        offset += count;
    }
    // One relaxed store keeps the peak without making the callback wait.
    unsigned depth = head + needed - tail;
    if (depth > atomic_load_explicit(&ring->high, memory_order_relaxed))
        atomic_store_explicit(&ring->high, depth, memory_order_relaxed);
    atomic_store_explicit(&ring->head, head + needed, memory_order_release);
    accepted = true;
done:
    atomic_fetch_sub(&ring->copying, 1);
    return accepted;
}

uint32_t LFAudioRingPop(LFAudioRing *ring, AudioBufferList *buffers) {
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    unsigned head = atomic_load_explicit(&ring->head, memory_order_acquire);
    if (head == tail) return 0;
    struct LFSlot *slot = &ring->slots[tail % LF_SLOTS];
    if (!valid(buffers, ring->channels, slot->frames)) return 0;
    if (buffers->mNumberBuffers == 1) {
        float *destination = buffers->mBuffers[0].mData;
        for (uint32_t frame = 0; frame < slot->frames; ++frame)
            for (uint32_t channel = 0; channel < ring->channels; ++channel)
                destination[frame * ring->channels + channel] = channelSamples(slot, channel)[frame];
    } else {
        for (uint32_t channel = 0; channel < ring->channels; ++channel)
            memcpy(buffers->mBuffers[channel].mData, channelSamples(slot, channel), slot->frames * sizeof(float));
    }
    uint32_t frames = slot->frames;
    ring->consumedThrough = slot->sourceStart + frames;
    atomic_store_explicit(&ring->tail, tail + 1, memory_order_release);
    return frames;
}

uint32_t LFAudioRingPopPreservingTimeline(LFAudioRing *ring, AudioBufferList *buffers) {
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    unsigned head = atomic_load_explicit(&ring->head, memory_order_acquire);
    uint64_t next;
    if (head == tail) {
        // While admission is open the producer may be preparing a retained slot.
        // Only a closed, joined producer makes the final source position safe.
        if (atomic_load(&ring->accepting) || atomic_load(&ring->copying)) return 0;
        // Re-read after observing quiescence: the last callback may have published
        // a slot since the first head load. Never cover that audio with silence.
        head = atomic_load_explicit(&ring->head, memory_order_acquire);
        next = head == tail ? atomic_load(&ring->sourceFrames)
                            : ring->slots[tail % LF_SLOTS].sourceStart;
    } else {
        next = ring->slots[tail % LF_SLOTS].sourceStart;
    }
    if (next > ring->consumedThrough) {
        uint64_t gap = next - ring->consumedThrough;
        uint32_t frames = gap > LF_FRAMES ? LF_FRAMES : (uint32_t)gap;
        if (!valid(buffers, ring->channels, frames)) return 0;
        if (buffers->mNumberBuffers == 1) {
            memset(buffers->mBuffers[0].mData, 0, frames * ring->channels * sizeof(float));
        } else {
            for (uint32_t channel = 0; channel < ring->channels; ++channel)
                memset(buffers->mBuffers[channel].mData, 0, frames * sizeof(float));
        }
        ring->consumedThrough += frames;
        return frames;
    }
    return head == tail ? 0 : LFAudioRingPop(ring, buffers);
}

void LFAudioRingCloseAndJoin(LFAudioRing *ring) {
    atomic_store(&ring->accepting, 0);
    while (atomic_load(&ring->copying)) sched_yield();
}
void LFAudioRingDestroy(LFAudioRing *ring) {
    if (ring) { LFAudioRingCloseAndJoin(ring); free(ring); }
}
void LFAudioRingSignalFailure(LFAudioRing *ring, int32_t failure) { fail(ring, failure); }
int32_t LFAudioRingFailure(const LFAudioRing *ring) { return atomic_load(&ring->failure); }
uint64_t LFAudioCaptureNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }

uint32_t LFAudioRingCapacity(void) { return LF_SLOTS; }

uint32_t LFAudioRingHighWater(const LFAudioRing *ring) {
    if (!ring) return 0;
    return (uint32_t)atomic_load_explicit(&ring->high, memory_order_relaxed);
}

void LFAudioRingSetDropOnOverflow(LFAudioRing *ring, bool enabled) {
    if (ring) atomic_store(&ring->dropOnOverflow, enabled ? 1 : 0);
}

uint64_t LFAudioRingDroppedFrames(const LFAudioRing *ring) {
    if (!ring) return 0;
    return atomic_load_explicit(&ring->dropped, memory_order_relaxed);
}

uint32_t LFAudioRingOccupancy(const LFAudioRing *ring) {
    if (!ring) return 0;
    unsigned head = atomic_load_explicit(&ring->head, memory_order_acquire);
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    return (uint32_t)(head - tail);
}
