//! `AudioInputUnit.c` and `AudioCaptureService`'s device side: AUHAL input into a fixed ring. The
//! callback renders into memory allocated up front and never locks or allocates.
use crate::macos::mic_granted;
use flow_core::dictation::ring::{Failure, Ring, SLOT_FRAMES};
use flow_core::dictation::session::{Candidate, Input, Mic};
use flow_core::settings::InputEntry;
use std::ffi::c_void;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicPtr, Ordering::*};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const fn code(s: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*s)
}
const OUTPUT: u32 = code(b"auou");
const HAL: u32 = code(b"ahal");
const APPLE: u32 = code(b"appl");
const FORMAT_FLAGS_FLOAT_PACKED: u32 = 1 | 8;
const LPCM: u32 = code(b"lpcm");
const SCOPE_GLOBAL: u32 = 0;
const SCOPE_INPUT: u32 = 1;
const SCOPE_OUTPUT: u32 = 2;
const STREAM_FORMAT: u32 = 8;
const MAX_FRAMES: u32 = 14;
const ENABLE_IO: u32 = 2003;
const CURRENT_DEVICE: u32 = 2000;
const IS_RUNNING: u32 = 2001;
const SET_INPUT_CALLBACK: u32 = 2005;
const HAL_GLOBAL: u32 = code(b"glob");

#[repr(C)]
struct ComponentDescription {
    kind: u32,
    subtype: u32,
    manufacturer: u32,
    flags: u32,
    mask: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
struct StreamFormat {
    rate: f64,
    format: u32,
    flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels: u32,
    bits: u32,
    reserved: u32,
}
#[repr(C)]
struct TimeStamp {
    sample_time: f64,
    host_time: u64,
    rate_scalar: f64,
    word_clock: u64,
    smpte: [u8; 24],
    flags: u32,
    reserved: u32,
}
#[repr(C)]
struct Buffer {
    channels: u32,
    bytes: u32,
    data: *mut c_void,
}
#[repr(C)]
struct BufferList {
    count: u32,
    buffer: Buffer,
}
#[repr(C)]
struct Address {
    selector: u32,
    scope: u32,
    element: u32,
}
type Render = unsafe extern "C" fn(*mut c_void, *mut u32, *const TimeStamp, u32, u32, *mut BufferList) -> i32;
#[repr(C)]
struct Callback {
    render: Render,
    context: *mut c_void,
}
type Listener = unsafe extern "C" fn(u32, u32, *const Address, *mut c_void) -> i32;

#[link(name = "AudioToolbox", kind = "framework")]
unsafe extern "C" {
    fn AudioComponentFindNext(after: *mut c_void, description: *const ComponentDescription) -> *mut c_void;
    fn AudioComponentInstanceNew(component: *mut c_void, unit: *mut *mut c_void) -> i32;
    fn AudioComponentInstanceDispose(unit: *mut c_void) -> i32;
    fn AudioUnitSetProperty(unit: *mut c_void, id: u32, scope: u32, element: u32, data: *const c_void, size: u32) -> i32;
    fn AudioUnitGetProperty(unit: *mut c_void, id: u32, scope: u32, element: u32, data: *mut c_void, size: *mut u32) -> i32;
    fn AudioUnitInitialize(unit: *mut c_void) -> i32;
    fn AudioUnitUninitialize(unit: *mut c_void) -> i32;
    fn AudioUnitRender(unit: *mut c_void, flags: *mut u32, time: *const TimeStamp, bus: u32, frames: u32, data: *mut BufferList) -> i32;
    fn AudioOutputUnitStart(unit: *mut c_void) -> i32;
    fn AudioOutputUnitStop(unit: *mut c_void) -> i32;
}
#[link(name = "CoreAudio", kind = "framework")]
unsafe extern "C" {
    fn AudioObjectAddPropertyListener(object: u32, address: *const Address, listener: Listener, context: *mut c_void) -> i32;
    fn AudioObjectRemovePropertyListener(object: u32, address: *const Address, listener: Listener, context: *mut c_void) -> i32;
    fn AudioObjectGetPropertyData(object: u32, address: *const Address, qualifier_size: u32, qualifier: *const c_void, size: *mut u32, data: *mut c_void) -> i32;
    fn AudioGetCurrentHostTime() -> u64;
    fn AudioConvertHostTimeToNanos(time: u64) -> u64;
}

/// What the callback touches. Lives in a `Box` until after the unit is disposed.
struct Shared {
    ring: Arc<Ring>,
    unit: AtomicPtr<c_void>,
    lost: AtomicBool,
    channels: usize,
    rate: f64,
    samples: *mut f32,
    capacity: usize,
}
unsafe impl Send for Shared {}
unsafe impl Sync for Shared {}

unsafe extern "C" fn render(context: *mut c_void, flags: *mut u32, time: *const TimeStamp, _bus: u32, frames: u32, _data: *mut BufferList) -> i32 {
    // SAFETY: `context` is the Box this unit was started with, freed only after the unit is gone.
    let shared = unsafe { &*(context as *const Shared) };
    if frames as usize > SLOT_FRAMES {
        shared.ring.fail(Failure::Unsupported);
        return 0;
    }
    let bytes = frames * shared.channels as u32 * 4;
    let mut list = BufferList { count: 1, buffer: Buffer { channels: shared.channels as u32, bytes, data: shared.samples.cast() } };
    // SAFETY: the buffer holds SLOT_FRAMES frames and `frames` was checked; only this callback writes it.
    let status = unsafe { AudioUnitRender(shared.unit.load(Relaxed), flags, time, 1, frames, &mut list) };
    if status != 0 {
        shared.ring.fail(Failure::DeviceLost);
        return 0;
    }
    // SAFETY: AudioUnitRender filled this many samples of our buffer; the host clock calls never block.
    unsafe {
        let samples = std::slice::from_raw_parts(shared.samples, frames as usize * shared.channels);
        let now = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime());
        let captured = AudioConvertHostTimeToNanos((*time).host_time);
        let delay = now.saturating_sub(captured) + (frames as f64 / shared.rate * 1e9) as u64;
        shared.ring.push(samples, now as i64, delay);
    }
    0
}

unsafe extern "C" fn device_changed(_object: u32, _count: u32, _addresses: *const Address, context: *mut c_void) -> i32 {
    // SAFETY: the Box outlives the listener, which `stop` removes first.
    unsafe { &*(context as *const Shared) }.lost.store(true, SeqCst);
    0
}

const WATCHED: [u32; 2] = [code(b"livn"), code(b"nsrt")];

fn default_input() -> Option<u32> {
    let address = Address { selector: code(b"dIn "), scope: HAL_GLOBAL, element: 0 };
    let (mut value, mut size) = (0u32, 4u32);
    // SAFETY: value and size describe a live u32. Reading the default device opens nothing.
    let status = unsafe { AudioObjectGetPropertyData(1, &address, 0, std::ptr::null(), &mut size, (&raw mut value).cast()) };
    (status == 0 && value != 0).then_some(value)
}

/// Float, interleaved at the device's own rate, so AUHAL does no rate conversion and the ring keeps
/// the C ring's channel count limit.
fn client_format(device: &StreamFormat) -> Option<StreamFormat> {
    let channels = device.channels;
    if !(8_000.0..=192_000.0).contains(&device.rate) || !(1..=8).contains(&channels) {
        return None;
    }
    Some(StreamFormat { rate: device.rate, format: LPCM, flags: FORMAT_FLAGS_FLOAT_PACKED, bytes_per_packet: 4 * channels, frames_per_packet: 1, bytes_per_frame: 4 * channels, channels, bits: 32, reserved: 0 })
}

struct Running {
    ring: Arc<Ring>,
    unit: *mut c_void,
    device: u32,
    shared: *mut Shared,
    samples: Box<[f32]>,
    last_wall_ms: AtomicI64,
    last_mono_ms: AtomicI64,
    started: Instant,
}
unsafe impl Send for Running {}

fn wall_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64)
}

/// The monotonic clock stops during sleep and the wall clock doesn't.
fn slept(wall_gap_ms: i64, mono_gap_ms: i64) -> bool {
    wall_gap_ms - mono_gap_ms > 5_000
}

impl Input for Running {
    fn ring(&self) -> &Arc<Ring> {
        &self.ring
    }
    fn running(&self) -> bool {
        // ponytail: sleep seen by a clock gap once awake, not NSWorkspace's will-sleep. The session
        // gets the same reason a poll late; an observer needs a run loop this thread doesn't have.
        let (wall, mono) = (wall_ms(), self.started.elapsed().as_millis() as i64);
        let (wall_gap, mono_gap) = (wall - self.last_wall_ms.swap(wall, Relaxed), mono - self.last_mono_ms.swap(mono, Relaxed));
        if slept(wall_gap, mono_gap) {
            self.ring.fail(Failure::Sleep);
        }
        let (mut on, mut size) = (0u32, 4u32);
        // SAFETY: the unit lives until `stop` consumes self; value and size describe a u32.
        let status = unsafe { AudioUnitGetProperty(self.unit, IS_RUNNING, SCOPE_GLOBAL, 0, (&raw mut on).cast(), &mut size) };
        // SAFETY: the Box lives until `stop`.
        status == 0 && on != 0 && !unsafe { &*self.shared }.lost.load(SeqCst)
    }
    fn authorized(&self) -> bool {
        mic_granted()
    }
    fn device_name(&self) -> Option<String> {
        crate::macos::input_device_name(self.device)
    }
    fn stop(self: Box<Self>) {
        // SAFETY: stop and dispose join the callback, then nothing reads the Box or the samples.
        unsafe {
            for selector in WATCHED {
                let address = Address { selector, scope: HAL_GLOBAL, element: 0 };
                AudioObjectRemovePropertyListener(self.device, &address, device_changed, self.shared.cast());
            }
            AudioOutputUnitStop(self.unit);
            AudioUnitUninitialize(self.unit);
            AudioComponentInstanceDispose(self.unit);
            drop(Box::from_raw(self.shared));
        }
        drop(self.samples);
    }
}

fn start(device: u32) -> Result<Running, Failure> {
    // SAFETY: each pointer passed is live and sized as stated; a failure disposes what was made.
    unsafe {
        let description = ComponentDescription { kind: OUTPUT, subtype: HAL, manufacturer: APPLE, flags: 0, mask: 0 };
        let component = AudioComponentFindNext(std::ptr::null_mut(), &description);
        if component.is_null() {
            return Err(Failure::DeviceLost);
        }
        let mut unit = std::ptr::null_mut();
        if AudioComponentInstanceNew(component, &mut unit) != 0 {
            return Err(Failure::DeviceLost);
        }
        let fail = |e| {
            AudioComponentInstanceDispose(unit);
            Err(e)
        };
        let (on, off) = (1u32, 0u32);
        if AudioUnitSetProperty(unit, ENABLE_IO, SCOPE_INPUT, 1, (&raw const on).cast(), 4) != 0 || AudioUnitSetProperty(unit, ENABLE_IO, SCOPE_OUTPUT, 0, (&raw const off).cast(), 4) != 0 || AudioUnitSetProperty(unit, CURRENT_DEVICE, SCOPE_GLOBAL, 0, (&raw const device).cast(), 4) != 0 {
            return fail(Failure::DeviceLost);
        }
        let mut format = StreamFormat::default();
        let mut size = size_of::<StreamFormat>() as u32;
        if AudioUnitGetProperty(unit, STREAM_FORMAT, SCOPE_INPUT, 1, (&raw mut format).cast(), &mut size) != 0 {
            return fail(Failure::DeviceLost);
        }
        let Some(client) = client_format(&format) else { return fail(Failure::Unsupported) };
        let Some(ring) = Ring::new(client.rate as u32, client.channels as usize) else { return fail(Failure::Unsupported) };
        let max = SLOT_FRAMES as u32;
        if AudioUnitSetProperty(unit, STREAM_FORMAT, SCOPE_OUTPUT, 1, (&raw const client).cast(), size_of::<StreamFormat>() as u32) != 0 || AudioUnitSetProperty(unit, MAX_FRAMES, SCOPE_GLOBAL, 0, (&raw const max).cast(), 4) != 0 {
            return fail(Failure::Unsupported);
        }
        let ring = Arc::new(ring);
        let mut samples = vec![0f32; SLOT_FRAMES * client.channels as usize].into_boxed_slice();
        let shared = Box::into_raw(Box::new(Shared { ring: ring.clone(), unit: AtomicPtr::new(unit), lost: AtomicBool::new(false), channels: client.channels as usize, rate: client.rate, samples: samples.as_mut_ptr(), capacity: samples.len() }));
        let callback = Callback { render, context: shared.cast() };
        if AudioUnitSetProperty(unit, SET_INPUT_CALLBACK, SCOPE_GLOBAL, 0, (&raw const callback).cast(), size_of::<Callback>() as u32) != 0 || AudioUnitInitialize(unit) != 0 {
            AudioComponentInstanceDispose(unit);
            drop(Box::from_raw(shared));
            return Err(Failure::DeviceLost);
        }
        for selector in WATCHED {
            let address = Address { selector, scope: HAL_GLOBAL, element: 0 };
            AudioObjectAddPropertyListener(device, &address, device_changed, shared.cast());
        }
        let running = Running { ring, unit, device, shared, samples, last_wall_ms: AtomicI64::new(wall_ms()), last_mono_ms: AtomicI64::new(0), started: Instant::now() };
        if AudioOutputUnitStart(unit) != 0 {
            Box::new(running).stop();
            return Err(Failure::DeviceLost);
        }
        let _ = (*shared).capacity;
        Ok(running)
    }
}

pub struct MacMic;

impl Mic for MacMic {
    fn authorize(&self) -> bool {
        mic_granted()
    }
    fn candidates(&self, entries: &[InputEntry]) -> Vec<Candidate> {
        crate::ranked_candidates(entries, &crate::macos::catalog())
    }
    fn start(&self, candidate: &Candidate) -> Result<Box<dyn Input>, Failure> {
        let device = candidate.device_id.or_else(default_input).ok_or(Failure::DeviceLost)?;
        Ok(Box::new(start(device)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layouts_match_the_headers() {
        assert_eq!(size_of::<StreamFormat>(), 40);
        assert_eq!(size_of::<TimeStamp>(), 64);
        assert_eq!(size_of::<ComponentDescription>(), 20);
        assert_eq!(size_of::<Callback>(), 16);
        assert_eq!(size_of::<BufferList>(), 24);
        assert_eq!(std::mem::offset_of!(TimeStamp, host_time), 8);
    }

    #[test]
    fn the_client_format_is_the_device_rate_as_interleaved_float() {
        let device = StreamFormat { rate: 44_100., channels: 2, ..Default::default() };
        let client = client_format(&device).unwrap();
        assert_eq!((client.rate, client.channels, client.bytes_per_frame, client.bits, client.flags), (44_100., 2, 8, 32, 9));
        assert_eq!(client_format(&StreamFormat { rate: 4_000., channels: 2, ..Default::default() }), None);
        assert_eq!(client_format(&StreamFormat { rate: 48_000., channels: 9, ..Default::default() }), None);
    }

    #[test]
    fn only_a_wall_clock_jump_is_sleep() {
        assert!(!slept(30, 30));
        assert!(!slept(5_000, 1));
        assert!(slept(60_000, 25));
    }
}
