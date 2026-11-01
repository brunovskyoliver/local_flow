//! WASAPI capture for meetings: the default microphone and process loopback, which is everything
//! the PC plays except this app's own process tree. Both ask for 48 kHz, 16-bit stereo. One thread
//! per stream owns the COM objects, waits on the event and hands packets to `on_packet`.
use crate::win::system::{microphone_consent_denied, process_loopback_available};
use crate::win_rules::aac_bytes_per_second;
use crate::{AudioEncoder, AudioEvent, AudioFailure, AudioPacket, AudioStream, MeetingAudio};
use ::windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
use ::windows::Win32::Foundation::{CloseHandle, E_FAIL, HANDLE, WAIT_OBJECT_0};
use ::windows::Win32::Media::Audio::*;
use ::windows::Win32::System::Com::{CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, STGM_READ};
use ::windows::Win32::System::Performance::QueryPerformanceCounter;
use ::windows::Win32::System::Performance::QueryPerformanceFrequency;
use ::windows::Win32::System::Threading::{CreateEventW, GetCurrentProcessId, SetEvent, WaitForSingleObject};
use ::windows::Win32::System::Com::IAgileObject;
use ::windows::core::{Error, HRESULT, Interface, Ref, Result};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use windows_core::implement;

const DEVICE_POLL: Duration = Duration::from_secs(1);
const BUFFER_100NS: i64 = 2_000_000;

pub struct Wasapi;

impl MeetingAudio for Wasapi {
    fn unavailable(&self) -> Option<&'static str> {
        (!process_loopback_available()).then_some("Meeting notes need Windows 11 or Windows Server 2022, which can record system audio without this app's own sounds.")
    }
    fn start(&self, system: bool, on_packet: Box<dyn FnMut(AudioPacket) + Send>, on_event: Box<dyn Fn(AudioEvent) + Send>) -> std::result::Result<Box<dyn AudioStream>, AudioFailure> {
        let stop = Arc::new(AtomicBool::new(false));
        let (ready, is_ready) = sync_channel(1);
        let flag = stop.clone();
        let thread = std::thread::spawn(move || run(system, flag, on_packet, on_event, ready));
        match is_ready.recv() {
            Ok(Ok(device_name)) => Ok(Box::new(Capture { stop, thread, device_name })),
            Ok(Err(reason)) => {
                let _ = thread.join();
                Err(reason)
            }
            Err(_) => Err("stream_stopped"),
        }
    }
    fn encoder(&self, channels: usize, bitrate: i64) -> std::result::Result<Box<dyn AudioEncoder>, AudioFailure> {
        let bytes = aac_bytes_per_second(bitrate).ok_or("encoder_failed")?;
        Ok(Box::new(crate::win::aac::Aac::new(channels, bytes).map_err(|_| "encoder_failed")?))
    }
    /// The encoder's lowest rate, for both tracks. Swift gives the microphone 64 kbit/s, which it lacks.
    fn bitrate(&self, _: bool) -> i64 {
        96_000
    }
}

struct Capture {
    stop: Arc<AtomicBool>,
    thread: JoinHandle<()>,
    device_name: Option<String>,
}
impl AudioStream for Capture {
    fn device_name(&self) -> Option<String> {
        self.device_name.clone()
    }
    fn stop(self: Box<Self>) {
        self.stop.store(true, Ordering::Release);
        let _ = self.thread.join();
    }
}

#[implement(IActivateAudioInterfaceCompletionHandler, IAgileObject)]
struct Activated(HANDLE);
impl IActivateAudioInterfaceCompletionHandler_Impl for Activated_Impl {
    fn ActivateCompleted(&self, _: Ref<IActivateAudioInterfaceAsyncOperation>) -> Result<()> {
        unsafe { SetEvent(self.0) }
    }
}
impl ::windows::Win32::System::Com::IAgileObject_Impl for Activated_Impl {}

/// `PROPVARIANT` holding a `VT_BLOB`, the shape `ActivateAudioInterfaceAsync` reads.
#[repr(C)]
struct BlobVariant {
    vt: u16,
    reserved: [u16; 3],
    size: u32,
    data: *const u8,
}

fn format() -> WAVEFORMATEX {
    WAVEFORMATEX { wFormatTag: 1, nChannels: 2, nSamplesPerSec: 48_000, wBitsPerSample: 16, nBlockAlign: 4, nAvgBytesPerSec: 192_000, cbSize: 0 }
}

unsafe fn process_loopback() -> Result<IAudioClient> {
    unsafe {
        let params = AUDIOCLIENT_ACTIVATION_PARAMS {
            ActivationType: AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
            Anonymous: AUDIOCLIENT_ACTIVATION_PARAMS_0 { ProcessLoopbackParams: AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS { TargetProcessId: GetCurrentProcessId(), ProcessLoopbackMode: PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE } },
        };
        let blob = BlobVariant { vt: 65, reserved: [0; 3], size: size_of_val(&params) as u32, data: (&params as *const AUDIOCLIENT_ACTIVATION_PARAMS).cast() };
        let done = CreateEventW(None, true, false, None)?;
        let handler: IActivateAudioInterfaceCompletionHandler = Activated(done).into();
        let finished = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, &IAudioClient::IID, Some((&blob as *const BlobVariant).cast()), &handler).and_then(|operation| {
            if WaitForSingleObject(done, 10_000) != WAIT_OBJECT_0 {
                return Err(Error::from_hresult(E_FAIL));
            }
            let (mut result, mut client) = (HRESULT(0), None);
            operation.GetActivateResult(&mut result, &mut client)?;
            result.ok()?;
            client.ok_or_else(|| Error::from_hresult(E_FAIL))?.cast()
        });
        let _ = CloseHandle(done);
        finished
    }
}

fn endpoint_id(device: &IMMDevice) -> Result<String> {
    unsafe {
        let id = device.GetId()?;
        let text = id.to_string().unwrap_or_default();
        CoTaskMemFree(Some(id.0 as _));
        Ok(text)
    }
}

fn default_microphone() -> Result<IMMDevice> {
    unsafe {
        let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        enumerator.GetDefaultAudioEndpoint(eCapture, eConsole)
    }
}

/// The classifications `handleSourceFailure` shows.
fn reason_for(error: &Error) -> AudioFailure {
    let code = error.code();
    if code == AUDCLNT_E_DEVICE_INVALIDATED || code == AUDCLNT_E_ENDPOINT_CREATE_FAILED || code.0 as u32 == 0x8007_0490 { "device_lost" } else { "stream_stopped" }
}

struct Opened {
    client: IAudioClient,
    capture: IAudioCaptureClient,
    event: HANDLE,
    device_name: Option<String>,
    endpoint: Option<String>,
}

fn open(system: bool) -> std::result::Result<Opened, AudioFailure> {
    unsafe {
        let (client, flags, device_name, endpoint) = if system {
            (process_loopback().map_err(|e| reason_for(&e))?, AUDCLNT_STREAMFLAGS_LOOPBACK, None, None)
        } else {
            if microphone_consent_denied() {
                return Err("permission_revoked");
            }
            let device = default_microphone().map_err(|_| "device_lost")?;
            let name = device.OpenPropertyStore(STGM_READ).and_then(|s| s.GetValue(&PKEY_Device_FriendlyName)).map(|v| v.to_string()).ok();
            let id = endpoint_id(&device).ok();
            (device.Activate(CLSCTX_ALL, None).map_err(|e| reason_for(&e))?, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, name, id)
        };
        let client: IAudioClient = client;
        let format = format();
        client.Initialize(AUDCLNT_SHAREMODE_SHARED, flags | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, BUFFER_100NS, 0, &format, None).map_err(|e| if e.code() == E_ACCESSDENIED_CODE { "permission_revoked" } else { reason_for(&e) })?;
        let event = CreateEventW(None, false, false, None).map_err(|_| "stream_stopped")?;
        client.SetEventHandle(event).map_err(|e| reason_for(&e))?;
        let capture: IAudioCaptureClient = client.GetService().map_err(|e| reason_for(&e))?;
        client.Start().map_err(|e| reason_for(&e))?;
        Ok(Opened { client, capture, event, device_name, endpoint })
    }
}
const E_ACCESSDENIED_CODE: HRESULT = ::windows::Win32::Foundation::E_ACCESSDENIED;

/// QPC ticks to nanoseconds. `GetBuffer`'s own QPC value is already in 100 ns units.
fn qpc_now_ns() -> Option<u64> {
    let (mut count, mut frequency) = (0i64, 0i64);
    unsafe {
        QueryPerformanceCounter(&mut count).ok()?;
        QueryPerformanceFrequency(&mut frequency).ok()?;
    }
    (frequency > 0).then(|| (count as i128 * 1_000_000_000 / frequency as i128) as u64)
}

/// Sends every queued packet. A silent endpoint delivers nothing at all; `Feed` turns that time
/// into silence from the clock on the next packet, and the final empty packet covers the tail.
fn drain(opened: &Opened, on_packet: &mut dyn FnMut(AudioPacket)) -> Result<()> {
    unsafe {
        while opened.capture.GetNextPacketSize()? > 0 {
            let (mut data, mut frames, mut flags, mut qpc) = (std::ptr::null_mut(), 0u32, 0u32, 0u64);
            opened.capture.GetBuffer(&mut data, &mut frames, &mut flags, None, Some(&mut qpc))?;
            // WASAPI buffers for this format are 16-bit aligned, per the format's block alignment.
            let stereo = std::slice::from_raw_parts(data as *const i16, frames as usize * 2);
            on_packet(AudioPacket { stereo, qpc_ns: Some(qpc.saturating_mul(100)), silent: flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0, discontinuity: flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY.0 as u32 != 0 });
            opened.capture.ReleaseBuffer(frames)?;
        }
    }
    Ok(())
}

fn capture_loop(system: bool, opened: &Opened, stop: &AtomicBool, on_packet: &mut dyn FnMut(AudioPacket), on_event: &dyn Fn(AudioEvent)) {
    let mut polled = Instant::now();
    let mut reported = false;
    while !stop.load(Ordering::Acquire) {
        unsafe { WaitForSingleObject(opened.event, 200) };
        if reported {
            continue; // The recorder is about to stop this stream.
        }
        let mut event = None;
        if let Err(error) = drain(opened, on_packet) {
            event = Some(if error.code() == AUDCLNT_E_DEVICE_INVALIDATED { AudioEvent::DeviceChanged } else { AudioEvent::Failed(reason_for(&error)) });
        } else if polled.elapsed() >= DEVICE_POLL {
            polled = Instant::now();
            // ponytail: polled once a second, no IMMNotificationClient. A switch costs up to a second of the old device.
            if !system {
                if microphone_consent_denied() {
                    event = Some(AudioEvent::Failed("permission_revoked"));
                } else {
                    let current = default_microphone().and_then(|d| endpoint_id(&d)).ok();
                    if current != opened.endpoint {
                        event = Some(AudioEvent::DeviceChanged);
                    }
                }
            }
        }
        if let Some(event) = event {
            reported = true;
            on_event(event);
        }
    }
}

fn run(system: bool, stop: Arc<AtomicBool>, mut on_packet: Box<dyn FnMut(AudioPacket) + Send>, on_event: Box<dyn Fn(AudioEvent) + Send>, ready: SyncSender<std::result::Result<Option<String>, AudioFailure>>) {
    if unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_err() {
        let _ = ready.send(Err("stream_stopped"));
        return;
    }
    match open(system) {
        Err(reason) => {
            let _ = ready.send(Err(reason));
        }
        Ok(opened) => {
            let _ = ready.send(Ok(opened.device_name.clone()));
            capture_loop(system, &opened, &stop, &mut on_packet, &*on_event);
            let _ = unsafe { opened.client.Stop() };
            let _ = drain(&opened, &mut on_packet);
            // The tail: the clock's reading now, so a track that went quiet still ends on time.
            on_packet(AudioPacket { stereo: &[], qpc_ns: qpc_now_ns(), silent: true, discontinuity: false });
            let _ = unsafe { CloseHandle(opened.event) };
            drop(opened);
        }
    }
    unsafe { CoUninitialize() };
}
