//! One dictation streamed to the server, `RemoteDictationSession.swift` and
//! `specs/014-remote-dictation-server/contracts/remote-channel.md`. A detached thread owns the
//! blocking channel, so a stalled socket can't hold up whoever waits: `Stream::poll` watches the
//! threshold from outside, and an abandoned thread ends at its next socket timeout.
use super::normalize::Vocabulary;
use super::session::{Feed, RecognizeFailure, Recognizer, Streamed, WINDOW};
use super::spool::{MAX_SAMPLES, Reader};
use super::worker::{Boost, BoostTerm, ModelIdentity};
use crate::remote::channel::{Channel, ChannelError, ServerMessage};
use crate::remote::enrollment::Enrollment;
use crate::remote::pool::{Pool, Role};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::*};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const FRAME_SAMPLES: usize = 16_000;
const PUMP: Duration = Duration::from_millis(200);
const TURN: Duration = Duration::from_millis(5);
/// `RemoteDictationRouter.retryThreshold`: nobody waits on a retry, so it gets `RemoteChannel`'s stall timeout.
pub const RETRY_THRESHOLD: Duration = Duration::from_secs(15);

/// What the server finished with. The channel is free for the next op.
pub struct Completed {
    pub windows: Vec<(usize, usize, String)>,
    pub recognition_seconds: f64,
    pub model: ModelIdentity,
    pub channel: Channel,
    pub next_op: i64,
}

/// `RemoteErrorCode.failureReason`.
pub fn failure_reason(code: &str) -> &'static str {
    match code {
        "unauthorized" | "token_expired" | "pairing_token_invalid" => "unauthorized",
        "not_approved" => "not_approved",
        "revoked" => "revoked",
        "busy" => "busy",
        "limit_exceeded" => "limit_exceeded",
        "worker_unavailable" => "worker_unavailable",
        _ => "protocol_error",
    }
}

fn channel_reason(error: &ChannelError) -> &'static str {
    match error {
        ChannelError::PinMismatch => "pin_mismatch",
        ChannelError::Unreachable | ChannelError::Closed => "unreachable",
        ChannelError::Timeout => "timeout",
        ChannelError::Protocol => "protocol_error",
        ChannelError::Server(code) => failure_reason(code),
    }
}

#[derive(Default)]
struct Link {
    recorded: AtomicUsize,
    total: AtomicUsize,
    released: AtomicBool,
    /// Nobody waits any more: stop, and send nothing.
    abandoned: AtomicBool,
    cancelled: AtomicBool,
    last_frame: Mutex<Option<Instant>>,
}

impl Link {
    fn touch(&self) {
        *self.last_frame.lock().unwrap() = Some(Instant::now());
    }
    fn released(&self) -> bool {
        self.released.load(SeqCst)
    }
}

enum Attempt {
    Done(Completed),
    Abandoned,
    /// `token_expired` at operation start.
    TokenExpired,
    /// The channel failed; a restart from sample 0 may help.
    Channel(&'static str),
    /// Restarting can't help.
    Final(&'static str),
}

pub struct Stream {
    link: Arc<Link>,
    results: Receiver<Result<Completed, &'static str>>,
    threshold: Duration,
}

impl Stream {
    /// Opens the channel and starts streaming what `recorded` says has been recorded.
    pub fn start(enrollment: Arc<Enrollment>, reader: Reader, boost: Option<Boost>, threshold: Duration) -> Stream {
        let link = Arc::new(Link::default());
        let (sender, results) = channel();
        let shared = link.clone();
        let spawned = std::thread::Builder::new().name("remote-dictation".into()).spawn(move || {
            let outcome = drive(&shared, &enrollment, reader, boost);
            if let Some(outcome) = outcome {
                let _ = sender.send(outcome);
            }
        });
        if spawned.is_err() {
            link.abandoned.store(true, SeqCst);
        }
        Stream { link, results, threshold }
    }
    pub fn recorded(&self, samples: usize) {
        self.link.recorded.store(samples, SeqCst);
    }
    /// Key release: the threshold runs from here.
    pub fn release(&self, total: usize) {
        if !self.link.released() {
            self.link.total.store(total, SeqCst);
            self.link.touch();
            self.link.released.store(true, SeqCst);
        }
    }
    pub fn cancel(&self) {
        self.link.cancelled.store(true, SeqCst);
    }
    pub fn abandon(&self) {
        self.link.abandoned.store(true, SeqCst);
    }
    /// The result, once there is one. Past the threshold since the last frame after release, `timeout`.
    pub fn poll(&self, wait: Duration) -> Option<Result<Completed, &'static str>> {
        match self.results.recv_timeout(wait) {
            Ok(outcome) => return Some(outcome),
            Err(RecvTimeoutError::Disconnected) => return Some(Err("unreachable")),
            Err(RecvTimeoutError::Timeout) => {}
        }
        let last = *self.link.last_frame.lock().unwrap();
        if self.link.released() && last.is_some_and(|at| at.elapsed() >= self.threshold) {
            self.abandon();
            return Some(Err("timeout"));
        }
        None
    }
}

/// The attempts. `None` when the stream was abandoned or cancelled.
fn drive(link: &Link, enrollment: &Enrollment, mut reader: Reader, boost: Option<Boost>) -> Option<Result<Completed, &'static str>> {
    let (mut restarted, mut token_retried, mut refresh_first) = (false, false, false);
    loop {
        match attempt(link, enrollment, &mut reader, boost.as_ref(), std::mem::take(&mut refresh_first)) {
            Attempt::Done(completed) => return Some(Ok(completed)),
            Attempt::Abandoned => return None,
            Attempt::Final(reason) => return Some(Err(reason)),
            Attempt::TokenExpired if !token_retried && !link.released() => {
                token_retried = true;
                refresh_first = true;
            }
            Attempt::TokenExpired => {
                enrollment.apply("token_expired");
                return Some(Err("unauthorized"));
            }
            // Before key release it reconnects once and starts again from sample 0.
            Attempt::Channel(_) if !link.released() && !restarted => restarted = true,
            Attempt::Channel(reason) => return Some(Err(reason)),
        }
    }
}

fn attempt(link: &Link, enrollment: &Enrollment, reader: &mut Reader, boost: Option<&Boost>, refresh_first: bool) -> Attempt {
    let token = if refresh_first { enrollment.access_token_expired() } else { enrollment.access_token() };
    if token.is_none() {
        return Attempt::Final("unauthorized");
    }
    let mut channel = match enrollment.session_channel() {
        Ok(channel) => channel,
        // Enrollment has already applied what these mean.
        Err(e @ (ChannelError::PinMismatch | ChannelError::Server(_))) => return Attempt::Final(channel_reason(&e)),
        Err(e) => return Attempt::Channel(channel_reason(&e)),
    };
    if link.abandoned.load(SeqCst) || link.cancelled.load(SeqCst) {
        return Attempt::Abandoned;
    }
    let mut start = json!({"type": "dictation_start", "op": 1, "format": "f32le", "sample_rate": 16_000});
    if let Some(boost) = boost {
        start["boost"] = serde_json::to_value(boost).unwrap_or(Value::Null);
    }
    if let Err(e) = channel.send(start) {
        return Attempt::Channel(channel_reason(&e));
    }
    link.touch();
    let mut turn = Turn { channel: Some(channel), model: None, windows: vec![], seconds: 0., sent: 0, end_sent: false, last_pump: None };
    loop {
        if link.abandoned.load(SeqCst) {
            return Attempt::Abandoned;
        }
        if link.cancelled.load(SeqCst) {
            if turn.model.is_some() {
                let _ = turn.channel().send(json!({"type": "dictation_cancel", "op": 1}));
            }
            return Attempt::Abandoned;
        }
        // Turned off: not one more frame, whether a dictation or a retry is listening for the result.
        if enrollment.settings().origin.is_none() {
            return Attempt::Final("unreachable");
        }
        if link.released() && link.total.load(SeqCst) == 0 {
            return Attempt::Final("protocol_error");
        }
        match turn.channel().poll() {
            Ok(Some(message)) => {
                link.touch();
                if let Some(end) = turn.handle(message, link, enrollment) {
                    return end;
                }
                continue;
            }
            Ok(None) => {}
            Err(e) => return Attempt::Channel(channel_reason(&e)),
        }
        match turn.pump(link, enrollment, reader) {
            Ok(()) => {}
            Err(end) => return end,
        }
        std::thread::sleep(TURN);
    }
}

struct Turn {
    channel: Option<Channel>,
    model: Option<ModelIdentity>,
    windows: Vec<(usize, usize, String)>,
    seconds: f64,
    sent: usize,
    end_sent: bool,
    last_pump: Option<Instant>,
}

impl Turn {
    fn channel(&mut self) -> &mut Channel {
        self.channel.as_mut().expect("until the turn ends")
    }

    /// Every recorded sample not yet sent, each 200 ms while recording, then `dictation_end`.
    fn pump(&mut self, link: &Link, enrollment: &Enrollment, reader: &mut Reader) -> Result<(), Attempt> {
        let released = link.released();
        if self.model.is_none() || self.end_sent || (!released && self.last_pump.is_some_and(|at| at.elapsed() < PUMP)) {
            return Ok(());
        }
        self.last_pump = Some(Instant::now());
        let limit = if released { link.total.load(SeqCst) } else { link.recorded.load(SeqCst) };
        while self.sent < limit {
            if link.abandoned.load(SeqCst) {
                return Err(Attempt::Abandoned);
            }
            // The attempt's loop tells the server, once the turn is back there.
            if link.cancelled.load(SeqCst) {
                return Ok(());
            }
            if enrollment.settings().origin.is_none() {
                return Err(Attempt::Final("unreachable"));
            }
            let count = FRAME_SAMPLES.min(limit - self.sent);
            // The spool couldn't be read: the server's copy wouldn't be whole.
            let samples = reader.read(self.sent, count).map_err(|_| Attempt::Final("protocol_error"))?;
            self.channel().send_audio(&samples).map_err(|e| Attempt::Channel(channel_reason(&e)))?;
            link.touch();
            self.sent += count;
        }
        if released && self.sent == limit {
            self.channel().send(json!({"type": "dictation_end", "op": 1, "total_samples": limit})).map_err(|e| Attempt::Channel(channel_reason(&e)))?;
            self.end_sent = true;
            link.touch();
        }
        Ok(())
    }

    fn handle(&mut self, message: ServerMessage, link: &Link, enrollment: &Enrollment) -> Option<Attempt> {
        let bad = Some(Attempt::Final("protocol_error"));
        let m = match message {
            ServerMessage::Error { code } => {
                if code == "token_expired" && self.model.is_none() && !link.released() {
                    return Some(Attempt::TokenExpired);
                }
                enrollment.apply(&code);
                return Some(Attempt::Final(failure_reason(&code)));
            }
            ServerMessage::Other(m) => m,
            _ => return bad,
        };
        if m.get("op").is_some_and(|op| *op != 1) {
            return bad;
        }
        match m["type"].as_str().unwrap_or_default() {
            "dictation_accepted" => {
                if self.model.is_some() || m["window_samples"].as_u64() != Some(WINDOW as u64) {
                    return bad;
                }
                match serde_json::from_value(m["model"].clone()) {
                    Ok(model) => self.model = Some(model),
                    Err(_) => return bad,
                }
                None
            }
            "window_result" => {
                let (index, start, count) = (m["index"].as_u64()? as usize, m["sample_start"].as_u64()? as usize, m["sample_count"].as_u64()? as usize);
                let valid = self.model.is_some() && index == self.windows.len() && start == index * WINDOW && (1..=WINDOW).contains(&count) && start + count <= MAX_SAMPLES;
                let (true, Some(text)) = (valid, m["text"].as_str()) else { return bad };
                self.windows.push((start, count, text.to_string()));
                self.seconds += m["recognition_ms"].as_i64().unwrap_or(0).max(0) as f64 / 1_000.;
                None
            }
            "progress" => None,
            "dictation_complete" => {
                let total = link.total.load(SeqCst);
                let expected = if total == 0 { 0 } else { (total - 1) / WINDOW + 1 };
                let complete = link.released() && self.end_sent && m["windows"].as_u64() == Some(self.windows.len() as u64) && self.windows.len() == expected;
                let (true, Some(model), Some(channel)) = (complete, self.model.take(), self.channel.take()) else { return bad };
                Some(Attempt::Done(Completed { windows: std::mem::take(&mut self.windows), recognition_seconds: self.seconds, model, channel, next_op: 2 }))
            }
            "cancelled" => Some(Attempt::Final("unreachable")),
            _ => bad,
        }
    }
}

/// `Recognizer` for a device that routes to the server: streams first, and falls back to `local`
/// from sample 0, or keeps the audio for a retry when this device has no local model.
pub struct Served<'a> {
    enrollment: Arc<Enrollment>,
    pool: Arc<Pool>,
    threshold: Duration,
    local: &'a mut dyn Recognizer,
    local_allowed: bool,
    failure: Option<&'static str>,
    model: Option<ModelIdentity>,
    using_local: bool,
    switched_off: bool,
    /// The server at the press: a waiting recording goes back only to this one.
    origin: Option<String>,
}

impl<'a> Served<'a> {
    pub fn new(enrollment: Arc<Enrollment>, pool: Arc<Pool>, threshold: Duration, local: &'a mut dyn Recognizer, local_allowed: bool) -> Served<'a> {
        let origin = enrollment.settings().origin;
        Served { enrollment, pool, threshold, local, local_allowed, failure: None, model: None, using_local: false, switched_off: false, origin }
    }

    fn turned_off(&self) -> bool {
        let settings = self.enrollment.settings();
        settings.origin.is_none() || matches!(settings.state.as_str(), "" | "off")
    }

    fn failed(&mut self, reason: &'static str, feed: &Feed) -> Streamed {
        self.failure = Some(reason);
        feed.set_streaming(false);
        Streamed::Here
    }
}

/// `RemoteBoost(VocabularyBoostTerms(snapshot:))`.
pub fn boost_of(vocabulary: &Vocabulary) -> Option<Boost> {
    (!vocabulary.boost.is_empty()).then(|| Boost { terms: vocabulary.boost.iter().map(|(entry_id, canonical)| BoostTerm { entry_id: entry_id.clone(), canonical: canonical.clone() }).collect(), governed: vocabulary.governed.clone() })
}

impl Recognizer for Served<'_> {
    fn stream(&mut self, vocabulary: &Vocabulary, feed: &Feed) -> Streamed {
        let Ok(reader) = feed.reader() else { return self.failed("protocol_error", feed) };
        feed.set_streaming(true);
        let stream = Stream::start(self.enrollment.clone(), reader, boost_of(vocabulary), self.threshold);
        loop {
            stream.recorded(feed.recorded());
            if feed.stopped() {
                stream.cancel();
                feed.set_streaming(false);
                return Streamed::Nothing;
            }
            if feed.asleep() {
                stream.abandon();
                return self.failed("unreachable", feed);
            }
            if let Some(total) = feed.total() {
                // Remote dictation was switched off during the recording: finish locally.
                if self.turned_off() {
                    stream.cancel();
                    self.switched_off = true;
                    if !self.local_allowed {
                        self.failure = Some("unreachable");
                    }
                    feed.set_streaming(false);
                    return Streamed::Here;
                }
                stream.release(total);
            }
            match stream.poll(feed.poll) {
                None => {}
                Some(Ok(completed)) => {
                    self.model = Some(completed.model);
                    self.pool.park(Role::Interactive, completed.channel, completed.next_op);
                    feed.set_streaming(false);
                    return Streamed::Windows(completed.windows, completed.recognition_seconds);
                }
                // Turning off makes the stream stop itself as unreachable: that isn't the server failing.
                Some(Err(_)) if self.turned_off() && self.local_allowed => {
                    self.switched_off = true;
                    feed.set_streaming(false);
                    return Streamed::Here;
                }
                Some(Err(reason)) => return self.failed(reason, feed),
            }
        }
    }
    fn prepare(&mut self, vocabulary: &Vocabulary) -> Result<(), String> {
        if !self.local_allowed {
            return Err(SERVER_ONLY.into());
        }
        self.using_local = true;
        self.local.prepare(vocabulary)
    }
    fn recognize(&mut self, samples: &[f32]) -> Result<Value, RecognizeFailure> {
        self.local.recognize(samples)
    }
    fn model(&self) -> Option<ModelIdentity> {
        self.model.clone().or_else(|| self.local.model())
    }
    fn finish(&mut self) {
        if self.using_local {
            self.local.finish();
        }
    }
    fn path(&self) -> &'static str {
        match (self.failure, self.switched_off) {
            (Some(_), _) => "local_after_server_failure",
            (None, true) => "local",
            (None, false) => "server",
        }
    }
    fn server_failure(&self) -> Option<&'static str> {
        self.failure
    }
    /// None once switched off: consent ended during this recording, so it doesn't retry by itself.
    fn server_origin(&self) -> Option<String> {
        self.origin.clone().filter(|_| !self.switched_off && !self.turned_off())
    }
}

/// `ServerOnlyFailure.serverUnavailable`'s words.
pub const SERVER_ONLY: &str = "Server only is on, but this Mac can't use your server. Check Settings › Server.";

/// Server only with no way to reach the server: the session fails at once and the local model never loads.
pub struct NoServer;

impl Recognizer for NoServer {
    fn prepare(&mut self, _: &Vocabulary) -> Result<(), String> {
        Err(SERVER_ONLY.into())
    }
    fn recognize(&mut self, _: &[f32]) -> Result<Value, RecognizeFailure> {
        Err(RecognizeFailure::Job("failed".into()))
    }
    fn model(&self) -> Option<ModelIdentity> {
        None
    }
    fn finish(&mut self) {}
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use crate::remote::enrollment::{IdentityProvider, Parts, RemoteSettings, SignIn, system_now};
    use crate::remote::scripted::{Counters, Reply, Script};
    use crate::remote::{DeviceKeys, MemoryDeviceKeys, MemorySecrets, Secrets, Unavailable};

    struct NoSignIn;
    impl SignIn for NoSignIn {
        fn sign_in(&self, _: IdentityProvider, _: &str) -> Result<String, Unavailable> {
            Err(Unavailable("no"))
        }
    }

    /// An approved device on a scripted server.
    pub(in crate::dictation) fn enrolled(replies: Vec<Reply>) -> (Arc<Enrollment>, Counters) {
        let script = Script::new(replies);
        let (counters, key) = (script.counters(), script.public_key());
        let secrets = Arc::new(MemorySecrets::default());
        secrets.write("server-key", &key).unwrap();
        secrets.write("refresh-token", b"refresh").unwrap();
        let keys = Arc::new(MemoryDeviceKeys::default());
        let (handle, _) = keys.create().unwrap();
        secrets.write("device-key", &handle).unwrap();
        let e = Enrollment::new(Parts { secrets, keys, sign_in: Arc::new(NoSignIn), identity: Arc::new(crate::remote::enrollment::HttpIdentity), transports: Arc::new(script), now: Box::new(system_now), device_name: "T".into() });
        e.load(RemoteSettings { origin: Some("http://127.0.0.1:9".into()), state: "approved".into(), notice: None });
        (Arc::new(e), counters)
    }

    fn sent(counters: &Counters) -> u64 {
        counters.messages().iter().filter_map(|m| m["audio_samples"].as_u64()).sum()
    }

    fn spool(name: &str, samples: usize) -> (std::path::PathBuf, Reader) {
        let path = std::env::temp_dir().join(format!("flow-remote-{name}-{}.f32", std::process::id()));
        std::fs::write(&path, vec![0u8; samples * 4]).unwrap();
        let reader = Reader::open(&path).unwrap();
        (path, reader)
    }

    /// A turn the server has accepted, with the whole recording released and unsent.
    fn accepted_turn(e: &Enrollment) -> (Turn, Link) {
        let model = ModelIdentity { engine: "e".into(), model_id: "m".into(), model_revision: "1".into(), manifest_hash: "h".into(), sdk: "s".into(), booster: None, worker_build: "b".into() };
        let turn = Turn { channel: Some(e.session_channel().unwrap()), model: Some(model), windows: vec![], seconds: 0., sent: 0, end_sent: false, last_pump: None };
        let link = Link::default();
        link.total.store(40_000, SeqCst);
        link.released.store(true, SeqCst);
        (turn, link)
    }

    const OPENS: fn() -> Vec<Reply> = || vec![Reply::ready(), Reply::tokens("a", "r"), Reply::ready()];

    #[test]
    fn queued_audio_stops_at_a_cancel_and_at_turning_off() {
        let (path, mut reader) = spool("pump", 40_000);

        let (e, counters) = enrolled(OPENS());
        let (mut turn, link) = accepted_turn(&e);
        assert!(turn.pump(&link, &e, &mut reader).is_ok());
        assert_eq!(sent(&counters), 40_000, "nothing in the way: all of it, then the end");
        assert!(counters.messages().iter().any(|m| m["type"] == "dictation_end"));

        let (e, counters) = enrolled(OPENS());
        let (mut turn, link) = accepted_turn(&e);
        link.cancelled.store(true, SeqCst);
        assert!(turn.pump(&link, &e, &mut reader).is_ok());
        assert_eq!(sent(&counters), 0, "Escape: nothing more goes out");
        assert!(!counters.messages().iter().any(|m| m["type"] == "dictation_end"));

        let (e, counters) = enrolled(OPENS());
        let (mut turn, link) = accepted_turn(&e);
        e.turn_off();
        assert!(matches!(turn.pump(&link, &e, &mut reader), Err(Attempt::Final("unreachable"))));
        assert_eq!(sent(&counters), 0, "turned off: nothing more goes out");
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn a_recording_stops_sending_when_turned_off_before_release() {
        let accepted = Reply::Json(json!({"schema_version": 1, "type": "dictation_accepted", "op": 1, "window_samples": WINDOW, "model": {"engine": "e", "model_id": "m", "model_revision": "1", "manifest_hash": "h", "sdk": "s", "worker_build": "b"}}));
        let (e, counters) = enrolled([OPENS(), vec![accepted, Reply::Silent]].concat());
        let (path, reader) = spool("live", 40_000);
        let stream = Stream::start(e.clone(), reader, None, Duration::from_secs(30));
        stream.recorded(20_000);
        let began = Instant::now();
        while sent(&counters) < 20_000 {
            assert!(began.elapsed() < Duration::from_secs(10));
            std::thread::sleep(Duration::from_millis(2));
        }
        // Nothing queued, so only the attempt's own check can end it.
        e.turn_off();
        let result = loop {
            assert!(began.elapsed() < Duration::from_secs(10), "still streaming after turn-off");
            if let Some(result) = stream.poll(Duration::from_millis(10)) {
                break result;
            }
        };
        assert!(matches!(result, Err("unreachable")));
        assert_eq!(sent(&counters), 20_000, "nothing after the turn-off");
        std::fs::remove_file(path).unwrap();
    }
}
