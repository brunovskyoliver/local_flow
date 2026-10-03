#include "AudioCaptureRing.h"
#include <stdatomic.h>
#include <stdlib.h>

// Device callbacks are 512 frames by default; larger ones are refused, not truncated.
#define LF_INPUT_MAX_FRAMES 4096u
#define LF_INPUT_MAX_CHANNELS 8u

struct LFAudioInput {
    AudioUnit unit;
    AudioDeviceID device;
    double sampleRate;
    uint32_t channels;
    _Atomic(LFAudioRing *) ring;
    atomic_bool lost;
    bool listening;
    float *samples;
    AudioBufferList *buffers;
};

static const AudioObjectPropertyAddress LFInputWatched[] = {
    {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
};

static OSStatus LFAudioInputRender(void *context, AudioUnitRenderActionFlags *flags,
                                   const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                                   AudioBufferList *unused) {
    (void)unused;
    LFAudioInput *input = context;
    LFAudioRing *ring = atomic_load_explicit(&input->ring, memory_order_acquire);
    if (ring == NULL) return noErr;
    if (frames > LF_INPUT_MAX_FRAMES) {
        LFAudioRingSignalFailure(ring, 2);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    for (uint32_t channel = 0; channel < input->channels; channel++) {
        input->buffers->mBuffers[channel].mDataByteSize = frames * sizeof(float);
    }
    OSStatus status = AudioUnitRender(input->unit, flags, time, bus, frames, input->buffers);
    if (status != noErr) {
        LFAudioRingSignalFailure(ring, 3);
        return status;
    }
    LFAudioRingPush(ring, input->buffers, frames);
    if (time->mFlags & kAudioTimeStampHostTimeValid) {
        uint64_t now = LFAudioHostTicksNow();
        uint64_t late = now > time->mHostTime ? LFAudioHostTicksToNanoseconds(now - time->mHostTime) : 0;
        LFAudioRingRecordDeliveryDelay(ring, late + (uint64_t)((double)frames / input->sampleRate * 1e9));
    }
    return noErr;
}

// The device died or another app changed its rate: the client format no longer fits.
static OSStatus LFAudioInputDeviceChanged(AudioObjectID device, UInt32 count,
                                          const AudioObjectPropertyAddress *addresses, void *context) {
    (void)count;
    (void)addresses;
    LFAudioInput *input = context;
    UInt32 alive = 0;
    Float64 rate = 0;
    UInt32 size = sizeof(alive);
    AudioObjectGetPropertyData(device, &LFInputWatched[0], 0, NULL, &size, &alive);
    size = sizeof(rate);
    AudioObjectGetPropertyData(device, &LFInputWatched[1], 0, NULL, &size, &rate);
    if (!alive || rate != input->sampleRate) atomic_store(&input->lost, true);
    return noErr;
}

static OSStatus LFSet(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                      AudioUnitElement element, const void *value, UInt32 size) {
    return AudioUnitSetProperty(unit, property, scope, element, value, size);
}

LFAudioInput *LFAudioInputCreate(AudioDeviceID device) {
    AudioComponentDescription description = {
        kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    LFAudioInput *input = calloc(1, sizeof(LFAudioInput));
    if (component == NULL || input == NULL) {
        free(input);
        return NULL;
    }
    input->device = device;
    if (AudioComponentInstanceNew(component, &input->unit) != noErr) {
        free(input);
        return NULL;
    }
    UInt32 on = 1, off = 0, maxFrames = LF_INPUT_MAX_FRAMES;
    AudioStreamBasicDescription hardware = {0};
    UInt32 size = sizeof(hardware);
    AURenderCallbackStruct callback = {LFAudioInputRender, input};
    bool ok = LFSet(input->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof(on)) == noErr
        && LFSet(input->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof(off)) == noErr
        && LFSet(input->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device)) == noErr
        && AudioUnitGetProperty(input->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr
        && hardware.mSampleRate > 0 && hardware.mChannelsPerFrame > 0
        && hardware.mChannelsPerFrame <= LF_INPUT_MAX_CHANNELS;
    if (ok) {
        input->sampleRate = hardware.mSampleRate;
        input->channels = hardware.mChannelsPerFrame;
        // The AUHAL input side converts format but not rate, so the client keeps the device rate.
        AudioStreamBasicDescription client = {
            .mSampleRate = hardware.mSampleRate,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            .mBytesPerPacket = sizeof(float),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = sizeof(float),
            .mChannelsPerFrame = input->channels,
            .mBitsPerChannel = 32,
        };
        input->samples = calloc((size_t)input->channels * LF_INPUT_MAX_FRAMES, sizeof(float));
        input->buffers = calloc(1, offsetof(AudioBufferList, mBuffers) + input->channels * sizeof(AudioBuffer));
        ok = input->samples != NULL && input->buffers != NULL
            && LFSet(input->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, sizeof(client)) == noErr
            && LFSet(input->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames)) == noErr
            && LFSet(input->unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback)) == noErr
            && AudioUnitInitialize(input->unit) == noErr;
    }
    if (!ok) {
        AudioComponentInstanceDispose(input->unit);
        free(input->samples);
        free(input->buffers);
        free(input);
        return NULL;
    }
    input->buffers->mNumberBuffers = input->channels;
    for (uint32_t channel = 0; channel < input->channels; channel++) {
        input->buffers->mBuffers[channel].mNumberChannels = 1;
        input->buffers->mBuffers[channel].mData = input->samples + (size_t)channel * LF_INPUT_MAX_FRAMES;
    }
    return input;
}

double LFAudioInputSampleRate(const LFAudioInput *input) { return input->sampleRate; }
uint32_t LFAudioInputChannels(const LFAudioInput *input) { return input->channels; }

OSStatus LFAudioInputStart(LFAudioInput *input, LFAudioRing *ring) {
    atomic_store(&input->lost, false);
    atomic_store_explicit(&input->ring, ring, memory_order_release);
    if (!input->listening) {
        for (size_t i = 0; i < 2; i++) {
            AudioObjectAddPropertyListener(input->device, &LFInputWatched[i], LFAudioInputDeviceChanged, input);
        }
        input->listening = true;
    }
    OSStatus status = AudioOutputUnitStart(input->unit);
    if (status != noErr) LFAudioInputStop(input);
    return status;
}

void LFAudioInputStop(LFAudioInput *input) {
    AudioOutputUnitStop(input->unit);
    atomic_store_explicit(&input->ring, NULL, memory_order_release);
    if (input->listening) {
        for (size_t i = 0; i < 2; i++) {
            AudioObjectRemovePropertyListener(input->device, &LFInputWatched[i], LFAudioInputDeviceChanged, input);
        }
        input->listening = false;
    }
}

bool LFAudioInputIsRunning(const LFAudioInput *input) {
    UInt32 running = 0;
    UInt32 size = sizeof(running);
    AudioUnitGetProperty(input->unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size);
    return running && !atomic_load(&input->lost);
}

void LFAudioInputDestroy(LFAudioInput *input) {
    if (input == NULL) return;
    LFAudioInputStop(input);
    AudioUnitUninitialize(input->unit);
    AudioComponentInstanceDispose(input->unit);
    free(input->samples);
    free(input->buffers);
    free(input);
}
