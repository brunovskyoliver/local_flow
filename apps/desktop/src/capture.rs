//! The Rust recorder (`flow_core::capture`) over the platform's `MeetingAudio`. Where a platform has
//! none, as on the Mac until the cutover, everything here reports unavailable and the callers keep
//! using `Services`.
use crate::core::Core;
use crate::shell::{MeetingState, MeetingStatus, Session, update_session};
use flow_core::capture::{Backend, Encoder, Feed, Handle, Kind, Packet, Reason, Snapshot, SourceEvent, Stream};
use flow_platform::{AudioEncoder, AudioEvent, AudioStream, MeetingAudio, SessionCommand};
use flow_ui::prelude::*;
use std::sync::Arc;
use std::time::Duration;

const QUIT_WAIT: Duration = Duration::from_secs(10);

struct Adapter(Arc<dyn MeetingAudio>);
struct Running(Box<dyn AudioStream>);
struct Encoding(Box<dyn AudioEncoder>);

impl Stream for Running {
    fn device_name(&self) -> Option<String> {
        self.0.device_name()
    }
    fn stop(self: Box<Self>) {
        self.0.stop();
    }
}
impl Encoder for Encoding {
    fn encode(&mut self, pcm: &[i16], out: &mut dyn FnMut(&[u8]) -> Result<(), Reason>) -> Result<(), Reason> {
        self.0.encode(pcm, out)
    }
    fn drain(&mut self, out: &mut dyn FnMut(&[u8]) -> Result<(), Reason>) -> Result<(), Reason> {
        self.0.drain(out)
    }
}
impl Backend for Adapter {
    fn start(&self, kind: Kind, mut feed: Feed, events: Box<dyn Fn(SourceEvent) + Send>) -> Result<Box<dyn Stream>, Reason> {
        let on_packet = Box::new(move |p: flow_platform::AudioPacket| feed.push(&Packet { stereo: p.stereo, qpc_ns: p.qpc_ns, silent: p.silent, discontinuity: p.discontinuity }));
        let on_event = Box::new(move |e| {
            events(match e {
                AudioEvent::Failed(reason) => SourceEvent::Failed(reason),
                AudioEvent::DeviceChanged => SourceEvent::DeviceChanged,
            })
        });
        Ok(Box::new(Running(self.0.start(kind == Kind::System, on_packet, on_event)?)))
    }
    fn encoder(&self, kind: Kind) -> Result<Box<dyn Encoder>, Reason> {
        Ok(Box::new(Encoding(self.0.encoder(kind.channels(), self.bitrate(kind))?)))
    }
    fn bitrate(&self, kind: Kind) -> i64 {
        self.0.bitrate(kind == Kind::System)
    }
}

pub fn available(cx: &App) -> bool {
    cx.global::<Core>().services.meeting_audio().is_some()
}

pub fn snapshot(cx: &App) -> Option<Snapshot> {
    cx.global::<Core>().recorder.as_ref().map(Handle::snapshot)
}

fn state_of(state: &str) -> Option<MeetingState> {
    Some(match state {
        "created" => MeetingState::Created,
        "preparing" => MeetingState::Preparing,
        "recording" => MeetingState::Recording,
        "paused" => MeetingState::Paused,
        "finalizing" => MeetingState::Finalizing,
        _ => return None,
    })
}

/// Starts recording in `preparing`, and keeps `Session` current for the sidebar and the tray even
/// with the Notetaker page closed. `Err` is the refusal to show.
pub fn start(cx: &mut App) -> Result<Snapshot, String> {
    let core = cx.global::<Core>();
    let audio = core.services.meeting_audio().ok_or("Meeting recording isn't available in this version yet.")?;
    if let Some(reason) = audio.unavailable() {
        return Err(reason.into());
    }
    let (database, root) = (core.paths.database(), core.paths.root.join("Meetings"));
    // `serverOnly` routing queues the handoff; without a server route this client makes no transcript.
    let prefs = &core.prefs;
    let transcribe = prefs.bool_or("meetingTranscriptionEnabled", true) && flow_core::remote::handoff::route(prefs) != flow_core::remote::handoff::Route::Off;
    let handle = Handle::start(&database, &root, Arc::new(Adapter(audio)), transcribe)?;
    let first = handle.snapshot();
    cx.global_mut::<Core>().recorder = Some(handle);
    sync(cx);
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(Duration::from_millis(250)).await;
            if !cx.update(sync) {
                break;
            }
        }
    })
    .detach();
    Ok(first)
}

/// Publishes the recorder's state to `Session`. False once the meeting has ended.
pub(crate) fn sync(cx: &mut App) -> bool {
    let Some(snapshot) = snapshot(cx) else { return false };
    let state = state_of(&snapshot.state);
    if cx.has_global::<Session>() {
        let title = cx.global::<Core>().db.as_ref().and_then(|db| flow_core::meetings::meeting(db, &snapshot.id).ok().flatten()).and_then(|m| m.title);
        update_session(cx, |s| {
            s.meeting = state.map(|state| MeetingStatus { id: snapshot.id.clone(), title, state, elapsed_ms: snapshot.elapsed_ms });
            s.can_start_meeting = state.is_none();
        });
    }
    state.is_some()
}

/// A session command for the recorder. False when this platform doesn't have one, so `Services` gets it.
pub fn command(command: SessionCommand, cx: &mut App) -> bool {
    if !available(cx) {
        return false;
    }
    let recorder = cx.global::<Core>().recorder.as_ref();
    match command {
        SessionCommand::PauseMeeting => recorder.into_iter().for_each(Handle::pause),
        SessionCommand::ResumeMeeting => recorder.into_iter().for_each(Handle::resume),
        SessionCommand::StopMeeting => recorder.into_iter().for_each(Handle::stop),
        SessionCommand::StartMeeting => update_session(cx, |s| s.start_requested = true),
        _ => return false,
    }
    true
}

/// Quit waits for the files. Past the limit, a segment stays `.part` and the next launch recovers it.
pub fn stop_for_quit(cx: &mut App) -> bool {
    match cx.global::<Core>().recorder.as_ref() {
        Some(recorder) => {
            recorder.stop_and_wait(QUIT_WAIT);
            true
        }
        None => false,
    }
}
