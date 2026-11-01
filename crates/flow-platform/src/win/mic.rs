//! Dictation's microphone over the WASAPI capture Feature 025 built: 48 kHz, 16-bit stereo packets on
//! the stream's thread, turned into f32 for the same ring the Mac uses.
use crate::{AudioEvent, AudioPacket, AudioStream};
use flow_core::dictation::ring::{Failure, Ring, SLOT_FRAMES};
use flow_core::dictation::session::{Candidate, Input, Mic};
use flow_core::settings::InputEntry;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering::*};
use std::time::Instant;

struct Running {
    ring: Arc<Ring>,
    stream: Box<dyn AudioStream>,
    lost: Arc<AtomicBool>,
    revoked: Arc<AtomicBool>,
}

impl Input for Running {
    fn ring(&self) -> &Arc<Ring> {
        &self.ring
    }
    fn running(&self) -> bool {
        !self.lost.load(SeqCst)
    }
    fn authorized(&self) -> bool {
        !self.revoked.load(SeqCst) && !crate::win::system::microphone_consent_denied()
    }
    fn device_name(&self) -> Option<String> {
        self.stream.device_name()
    }
    fn stop(self: Box<Self>) {
        self.stream.stop();
    }
}

pub struct WinMic;

impl Mic for WinMic {
    fn authorize(&self) -> bool {
        !crate::win::system::microphone_consent_denied()
    }
    fn candidates(&self, entries: &[InputEntry]) -> Vec<Candidate> {
        crate::win::system::input_catalog().map_or(Vec::new(), |catalog| crate::ranked_candidates(entries, &catalog))
    }
    fn start(&self, candidate: &Candidate) -> Result<Box<dyn Input>, Failure> {
        let ring = Arc::new(Ring::new(48_000, 2).ok_or(Failure::Unsupported)?);
        let (lost, revoked) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false)));
        let feed = ring.clone();
        let began = Instant::now();
        let mut buffer = Vec::with_capacity(SLOT_FRAMES * 2);
        let on_packet = Box::new(move |packet: AudioPacket| {
            let now = began.elapsed().as_nanos() as i64;
            for part in packet.stereo.chunks(SLOT_FRAMES * 2) {
                buffer.clear();
                // A silent packet's buffer holds no meaningful samples.
                buffer.extend(part.iter().map(|s| if packet.silent { 0. } else { *s as f32 / 32_768. }));
                feed.push(&buffer, now, 0);
            }
        });
        let (gone, denied) = (lost.clone(), revoked.clone());
        let on_event = Box::new(move |event| match event {
            AudioEvent::Failed("permission_revoked") => denied.store(true, SeqCst),
            AudioEvent::Failed(_) | AudioEvent::DeviceChanged => gone.store(true, SeqCst),
        });
        // Only a ranked entry pins its endpoint; System default follows Windows' choice.
        let stream = crate::win::wasapi::start_microphone(candidate.uid.clone(), on_packet, on_event).map_err(|_| Failure::DeviceLost)?;
        Ok(Box::new(Running { ring, stream, lost, revoked }))
    }
}
