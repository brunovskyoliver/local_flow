//! `DictationCoordinator` without its UI: one blocking session on the thread that owns the model
//! lifecycle. Microphone, recognizer, rewriter, field and store sit behind traits; the session never
//! touches an OS API. No text reaches a log: there are no logs here.
use super::lifecycle::{Lease, Lifecycle, RecognizeError, Refusal};
use super::normalize::{self, Change, Normalized, Vocabulary};
use super::resample::Converter;
use super::ring::{Failure, Ring};
use super::spool::{self, MAX_SAMPLES, Reader, Spool};
use super::worker::{Boost, BoostTerm, ModelIdentity};
use crate::db::Db;
use crate::history::{self, Outcome, StoreError, sha256_hex};
use crate::settings::InputEntry;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::*};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Contiguous production windows; `ChunkPlanner`'s other profile is benchmark only.
pub const WINDOW: usize = 239_360;
const MIN_PADDED: usize = 4_800;
const ASSEMBLY_VERSION: &str = "contiguous_fixed239360_preserve_v2";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Idle,
    Preparing,
    Connecting,
    Recording,
    Transcribing,
    Persisting,
    Rewriting,
    Inserting,
    Cancelling,
    Recovery,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopReason {
    KeyRelease,
    DurationLimit,
    Cancel,
    Overflow,
    DeviceLoss,
    PermissionRevoked,
    Sleep,
    Failure,
}

impl StopReason {
    pub fn raw(self) -> &'static str {
        match self {
            StopReason::KeyRelease => "key_release",
            StopReason::DurationLimit => "duration_limit",
            StopReason::Cancel => "cancel",
            StopReason::Overflow => "overflow",
            StopReason::DeviceLoss => "device_loss",
            StopReason::PermissionRevoked => "permission_revoked",
            StopReason::Sleep => "sleep",
            StopReason::Failure => "failure",
        }
    }
    /// `DictationErrorMessage.describe` for a capture stop.
    fn describe(self) -> &'static str {
        match self {
            StopReason::PermissionRevoked => "Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone.",
            StopReason::DeviceLoss => "The microphone could not start or disconnected. Check the selected input device.",
            StopReason::Overflow => "Audio capture could not keep up. Try again after reducing system load.",
            StopReason::Sleep => "Recording stopped because the Mac went to sleep.",
            StopReason::Failure => "The selected microphone format is unsupported. Try the built-in microphone.",
            _ => "",
        }
    }
}

// ---- What a field is ----

/// How a captured field takes text: a direct Accessibility write or a pasted Command-V.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertDelivery {
    Accessibility,
    Paste,
}

/// A captured field (Swift's `CapturedTarget`). `token` names what the platform keeps for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapturedTarget {
    pub bundle_id: String,
    pub own_process: bool,
    pub delivery: InsertDelivery,
    pub selection_location: usize,
    pub token: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertOutcome {
    Confirmed,
    NotInserted,
    Uncertain,
}

// ---- Seams ----

/// One microphone to try: `FR` Feature 019's ranked entry against the catalog.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    /// None is the system default.
    pub device_id: Option<u32>,
    pub uid: Option<String>,
    pub name: String,
    pub kind: String,
}

pub trait Mic: Send + Sync {
    /// May block on the system's prompt.
    fn authorize(&self) -> bool;
    /// `entries` is the ranked list as it was at the press.
    fn candidates(&self, entries: &[InputEntry]) -> Vec<Candidate>;
    fn start(&self, candidate: &Candidate) -> Result<Box<dyn Input>, Failure>;
}

pub trait Input: Send {
    fn ring(&self) -> &Arc<Ring>;
    fn running(&self) -> bool;
    fn authorized(&self) -> bool;
    /// What's really recording, for the system default.
    fn device_name(&self) -> Option<String>;
    /// Returns once no callback can run.
    fn stop(self: Box<Self>);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecognizeFailure {
    /// The job failed and the recognizer lives; invalid audio or a model error code.
    Job(String),
    /// The recognizer died with the job: the audio is kept as a waiting dictation.
    Lost,
}

/// What `Recognizer::stream` came back with.
pub enum Streamed {
    /// Recognize the recording here, from sample 0, with `prepare` and `recognize`.
    Here,
    /// The whole recording's windows, in order: start, count, text. And the recognition seconds.
    Windows(Vec<(usize, usize, String)>, f64),
    /// Cancelled or discarded: nothing to deliver.
    Nothing,
}

/// The recording as it grows, for a recognizer that streams it elsewhere.
pub struct Feed<'a> {
    reader: &'a Reader,
    shared: &'a Shared,
    control: &'a Control,
    pub poll: Duration,
}

impl Feed<'_> {
    pub fn reader(&self) -> std::io::Result<Reader> {
        self.reader.reopen()
    }
    pub fn recorded(&self) -> usize {
        self.shared.recorded.load(SeqCst)
    }
    /// The final count, once capture has ended.
    pub fn total(&self) -> Option<usize> {
        self.shared.ended.load(SeqCst).then(|| self.shared.total.load(SeqCst))
    }
    pub fn stopped(&self) -> bool {
        self.shared.discard.load(SeqCst) || self.control.cancelled()
    }
    /// The Mac is going to sleep: nothing more goes out.
    pub fn asleep(&self) -> bool {
        self.shared.asleep.load(SeqCst)
    }
    /// Says where the words are coming from, for the status once capture ends.
    pub fn set_streaming(&self, streaming: bool) {
        self.shared.streaming.store(streaming, SeqCst);
    }
}

/// Speech under a lease, or (`stream`) on the server: `path` and `server_failure` say where the
/// text came from.
pub trait Recognizer: Send {
    /// Lease and model load. Runs beside capture, so recording never waits for it. `Err` is the message.
    fn prepare(&mut self, vocabulary: &Vocabulary) -> Result<(), String>;
    fn recognize(&mut self, samples: &[f32]) -> Result<Value, RecognizeFailure>;
    fn model(&self) -> Option<ModelIdentity>;
    fn finish(&mut self);
    /// Runs first, beside capture. The default recognizes here.
    fn stream(&mut self, _vocabulary: &Vocabulary, _feed: &Feed) -> Streamed {
        Streamed::Here
    }
    fn path(&self) -> &'static str {
        "local"
    }
    fn server_failure(&self) -> Option<&'static str> {
        None
    }
}

pub enum Rewritten {
    NotEligible,
    Text { text: String, attempt: String },
    Notice { message: String, can_retry: bool },
}

/// Admits and runs one rewrite of saved text, blocking. Cancelling sets `cancel`.
pub trait Rewriter: Send {
    fn rewrite(&mut self, id: &str, text: &str, started: &mut dyn FnMut(), cancel: &Arc<AtomicBool>) -> Rewritten;
}

pub trait Inserter: Send + Sync {
    fn capture_target(&self) -> Option<CapturedTarget>;
    fn insert_once(&self, target: &CapturedTarget, text: &str) -> InsertOutcome;
    fn copy(&self, text: &str);
    /// The field's text in a UTF-16 range, for the correction learner. `Err` is a failed read.
    fn read_text(&self, _target: &CapturedTarget, _location: usize, _length: usize) -> Result<String, ()> {
        Err(())
    }
}

/// A dictation about to be saved.
#[derive(Clone, Debug)]
pub struct NewDictation {
    pub id: String,
    pub text: String,
    pub quality: &'static str,
    pub stop_reason: &'static str,
    pub target_bundle_id: Option<String>,
    pub recognition_path: &'static str,
    pub server_failure: Option<&'static str>,
    pub device_name: Option<String>,
    pub device_kind: Option<String>,
    pub detail_json: String,
    pub content_hash: String,
    /// When it was spoken, for one saved later. `None` is now.
    pub created_at: Option<i64>,
}

/// Audio that lost its recognizer.
pub struct Waiting<'a> {
    pub id: &'a str,
    pub audio: &'a Path,
    pub samples: usize,
    pub failure: &'static str,
    pub target_bundle_id: Option<&'a str>,
    pub device_name: Option<&'a str>,
    pub device_kind: Option<&'a str>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum HistoryError {
    Capacity,
    Store,
}

pub trait History {
    fn new_id(&mut self) -> String;
    fn reserve(&mut self) -> Result<(), HistoryError>;
    fn vocabulary(&mut self) -> Result<Vocabulary, String>;
    /// Returns the revision.
    fn commit(&mut self, dictation: &NewDictation) -> Result<i64, HistoryError>;
    /// Returns the attempt and the revision.
    fn begin_attempt(&mut self, id: &str, revision: i64) -> Result<(String, i64), HistoryError>;
    fn record_outcome(&mut self, pending: &PendingOutcome) -> Result<(), HistoryError>;
    fn record_applied(&mut self, id: &str, changes: &[Change]);
    fn keep_waiting(&mut self, waiting: &Waiting) -> Result<(), HistoryError>;
    fn writable(&mut self) -> bool;
}

// ---- Published ----

#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub state: State,
    pub status: String,
    pub busy: bool,
    pub unsaved: Option<String>,
    pub storage_blocked: bool,
    pub capacity_blocked: bool,
    pub cleanup_blocked: bool,
    pub offers_microphones: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Changed(Snapshot),
    Level(f32),
    /// Saved text that didn't land is on the clipboard.
    Clipboard { uncertain: bool },
    /// A rewrite notice for the pill, about this dictation.
    Action { message: String, can_retry: bool, dictation: String },
    Microphone(String),
    HistoryChanged,
    /// A recording no waiting row could take, moved here for the user to save or discard.
    AudioOffered { audio: PathBuf },
    /// Confirmed in this field, for the correction learner.
    Inserted(Inserted),
    /// From the correction learner's thread, on the same channel.
    Note(super::learner::Note),
}

/// Text that landed and where.
#[derive(Clone, Debug, PartialEq)]
pub struct Inserted {
    pub dictation: String,
    pub text: String,
    pub target: CapturedTarget,
    pub changes: Vec<Change>,
}

/// Bounded flags, not a queue: the press's own, so a release can't be lost to the session starting.
#[derive(Default, Debug)]
pub struct Control {
    release: AtomicBool,
    bypass: AtomicBool,
    cancel: AtomicBool,
    cancel_rewrite: Arc<AtomicBool>,
    rewriting: AtomicBool,
}

impl Control {
    pub fn release(&self, bypass_rewrite: bool) {
        if bypass_rewrite {
            self.bypass.store(true, SeqCst);
        }
        self.release.store(true, SeqCst);
    }
    /// Escape: during a rewrite it stops the rewrite only, and the original text goes in.
    pub fn cancel(&self) {
        if self.rewriting.load(SeqCst) {
            self.cancel_rewrite.store(true, SeqCst);
        } else {
            self.cancel.store(true, SeqCst);
        }
    }
    pub fn cancel_rewrite(&self) {
        self.cancel_rewrite.store(true, SeqCst);
    }
    pub fn released(&self) -> bool {
        self.release.load(SeqCst)
    }
    pub fn cancelled(&self) -> bool {
        self.cancel.load(SeqCst)
    }
    pub fn bypassed(&self) -> bool {
        self.bypass.load(SeqCst)
    }
    fn stopped(&self) -> bool {
        self.released() || self.cancelled()
    }
}

pub struct Deps<'a> {
    pub mic: &'a dyn Mic,
    pub inputs: &'a [InputEntry],
    pub recognizer: &'a mut dyn Recognizer,
    /// `None` skips rewriting, as a bypass does.
    pub rewriter: Option<&'a mut dyn Rewriter>,
    pub inserter: &'a dyn Inserter,
    pub history: &'a mut dyn History,
}

pub struct PendingOutcome {
    pub id: String,
    pub revision: i64,
    pub attempt: String,
    pub outcome: Outcome,
    pub rewrite: Option<String>,
}

/// Swift's constants; tests shorten them.
#[derive(Clone, Copy)]
pub struct Timing {
    pub poll: Duration,
    pub connect_limit: Duration,
    pub budget: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Timing { poll: Duration::from_millis(25), connect_limit: Duration::from_secs(3), budget: Duration::from_secs(180) }
    }
}

#[derive(Debug)]
enum Fail {
    Cancelled,
    Denied,
    NoMicrophone,
    DidNotRespond(String),
    Capture(StopReason),
    Disk,
    Capacity,
    Store,
    Model(String),
    /// Text wouldn't save; it's kept in `unsaved`.
    Unsaved,
}

fn describe(fail: &Fail) -> String {
    match fail {
        Fail::Denied => "Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone.".into(),
        Fail::Capture(reason) => reason.describe().into(),
        Fail::Disk => "Temporary audio could not be written. Check available disk space.".into(),
        Fail::Model(message) => message.clone(),
        Fail::Store | Fail::Unsaved | Fail::Capacity => "Check available disk space.".into(),
        Fail::Cancelled => "The operation was cancelled.".into(),
        Fail::NoMicrophone => "No microphone available".into(),
        Fail::DidNotRespond(name) => format!("{name} didn't respond"),
    }
}

pub fn stop_reason_of(failure: Failure) -> StopReason {
    match failure {
        Failure::Overflow => StopReason::Overflow,
        Failure::DeviceLost => StopReason::DeviceLoss,
        Failure::Sleep => StopReason::Sleep,
        Failure::Unsupported => StopReason::Failure,
    }
}

/// `releaseTail`: none at or under 50 ms of delivery delay, else the delay plus one poll, at most 500 ms.
pub fn release_tail(max_delay: Duration) -> Option<Duration> {
    (max_delay > Duration::from_millis(50)).then(|| (max_delay + Duration::from_millis(25)).min(Duration::from_millis(500)))
}

/// A short later window whose whole text is a filler word Parakeet answers near-silence with.
pub fn is_tail_filler(text: &str, start: usize, count: usize) -> bool {
    if start == 0 || count >= 48_000 {
        return false;
    }
    let word = text.to_lowercase();
    matches!(word.trim_matches(|c: char| c.is_whitespace() || c.is_ascii_punctuation()), "yeah" | "yes" | "okay" | "ok")
}

// ---- Recognition beside capture ----

#[derive(Clone, Debug, PartialEq)]
struct Done {
    start: usize,
    count: usize,
    text: String,
}

#[derive(Default)]
struct Recognition {
    windows: Vec<Done>,
    /// code, window
    failure: Option<(&'static str, usize)>,
    prepare_failed: Option<String>,
    lost: bool,
    recognition_seconds: f64,
}

#[derive(Default)]
struct Shared {
    recorded: AtomicUsize,
    /// Capture finished; `total` is final.
    ended: AtomicBool,
    total: AtomicUsize,
    /// Stop now and drop everything.
    discard: AtomicBool,
    /// Stop after the job in flight and keep what's done.
    failed_prepare: Mutex<Option<String>>,
    /// Capture ended because the Mac is going to sleep.
    asleep: AtomicBool,
    /// The recording is going to the server right now.
    streaming: AtomicBool,
}

fn pad(mut samples: Vec<f32>) -> Vec<f32> {
    if samples.len() < MIN_PADDED {
        samples.resize(MIN_PADDED, 0.);
    }
    samples
}

/// `LiveRecognition` and the final pass as one loop. Windows are recognized as they fill; one that
/// fails waits for the end of capture and gets one more try, as the final pass gives it.
// ponytail: a job in flight runs to its end when cancelled, up to the worker's deadline; a kill
// switch on the worker client would cut it short.
fn recognize_loop(recognizer: &mut dyn Recognizer, vocabulary: &Vocabulary, mut reader: Reader, shared: &Shared, control: &Control, poll: Duration) -> Recognition {
    let mut out = Recognition::default();
    match recognizer.stream(vocabulary, &Feed { reader: &reader, shared, control, poll }) {
        Streamed::Here => {}
        Streamed::Windows(windows, recognition_seconds) => {
            out.windows = windows.into_iter().map(|(start, count, text)| Done { start, count, text }).collect();
            out.recognition_seconds = recognition_seconds;
            return out;
        }
        Streamed::Nothing => return out,
    }
    if let Err(message) = recognizer.prepare(vocabulary) {
        // The server failed and there's no model here either: the audio waits for the server.
        if recognizer.server_failure().is_some() {
            out.lost = true;
            return out;
        }
        *shared.failed_prepare.lock().unwrap() = Some(message.clone());
        out.prepare_failed = Some(message);
        return out;
    }
    let (mut start, mut retried) = (0, false);
    loop {
        if shared.discard.load(SeqCst) {
            return Recognition { recognition_seconds: out.recognition_seconds, ..Default::default() };
        }
        let ended = shared.ended.load(SeqCst);
        let recorded = if ended { shared.total.load(SeqCst) } else { shared.recorded.load(SeqCst) };
        if ended && (start >= recorded || control.cancelled()) {
            return out;
        }
        let waiting_to_retry = retried && !ended;
        if waiting_to_retry || (!ended && recorded < start + WINDOW) {
            std::thread::sleep(poll);
            continue;
        }
        let count = WINDOW.min(recorded - start);
        let began = Instant::now();
        let result = reader.read(start, count).map(|s| recognizer.recognize(&pad(s)));
        out.recognition_seconds += began.elapsed().as_secs_f64();
        match result {
            Err(_) => {
                out.failure = Some(("failed", out.windows.len()));
                return out;
            }
            Ok(Ok(window)) => {
                let Some(text) = window["text"].as_str() else {
                    out.failure = Some(("invalid_result", out.windows.len()));
                    return out;
                };
                out.windows.push(Done { start, count, text: text.into() });
                start += count;
                retried = false;
            }
            Ok(Err(RecognizeFailure::Lost)) => {
                out.lost = true;
                return out;
            }
            Ok(Err(RecognizeFailure::Job(code))) => {
                // Prefetch's failure is left to the final pass; the final pass's is final.
                if retried || ended {
                    out.failure = Some((if code == super::worker::CODE_INVALID_AUDIO { "invalid_result" } else { "failed" }, out.windows.len()));
                    return out;
                }
                retried = true;
            }
        }
    }
}

// ---- Assembly and evidence ----

struct Assembled {
    text: String,
    seams: Vec<Value>,
    empty: Vec<usize>,
}

/// `TranscriptAssembler` for contiguous windows: physical adjacency, nothing discarded.
fn assemble(windows: &[Done]) -> Assembled {
    let mut out = Assembled { text: String::new(), seams: Vec::new(), empty: Vec::new() };
    for (i, w) in windows.iter().enumerate() {
        let filler = is_tail_filler(&w.text, w.start, w.count);
        if !filler && w.text.trim().is_empty() {
            out.empty.push(i);
        }
        if i > 0 {
            out.seams.push(json!({"window": i, "discardedPrefixBytes": 0, "decision": "adjacent", "basis": "physical_adjacency", "discardedLexicalWords": 0, "unevidencedLexicalDiscards": 0, "preAnchorLexicalDiscards": 0, "maximumDiscardedOnsetDelta": 0.0}));
        }
        if filler || w.text.is_empty() {
            continue;
        }
        if !out.text.is_empty() && !out.text.ends_with(char::is_whitespace) && !w.text.starts_with(char::is_whitespace) {
            out.text.push(' ');
        }
        out.text.push_str(&w.text);
    }
    out
}

struct Evidence<'a> {
    windows: &'a [Done],
    assembled: &'a Assembled,
    normalized: &'a Normalized,
    vocabulary: &'a Vocabulary,
    model: Option<ModelIdentity>,
    samples: usize,
    reasons: Vec<Value>,
    cancelled: bool,
    recognition_seconds: f64,
    normalization_seconds: f64,
}

fn is_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The `TranscriptionQualityDetail` Swift writes, with keys sorted as its encoder sorts them.
/// Token timings stay out, recorded as unavailable.
fn seal(e: &Evidence) -> Option<(String, String)> {
    let raw: Vec<Value> = e.windows.iter().enumerate().map(|(i, w)| json!({"sequence": i, "sampleStart": w.start, "sampleCount": w.count, "paddedSampleCount": w.count.max(MIN_PADDED), "text": w.text, "textHash": sha256_hex(w.text.as_bytes()), "timingValidation": "unavailable"})).collect();
    let engine = e.model.as_ref().map(|m| m.engine.clone()).unwrap_or_else(|| "unrecorded_runtime".into());
    let mut missing = vec!["artifact_hashes", "dirty", "folding_runtime", "operating_system"];
    let mut provenance = json!({
        "engine": engine, "artifactHashes": {}, "automaticLanguage": true, "sampleRate": 16_000, "channels": 1, "inputSamples": e.samples,
        "inputDurationSeconds": e.samples as f64 / 16_000., "inputSampleFormat": "float32_pcm", "windowSamples": WINDOW, "overlapSamples": 0, "strideSamples": WINDOW, "minimumPaddedSamples": MIN_PADDED,
        "stageDurations": {"recognition": e.recognition_seconds, "assembly": 0.0, "normalization": e.normalization_seconds},
    });
    match &e.model {
        Some(m) => {
            provenance["sdkVersion"] = json!(m.sdk);
            provenance["modelID"] = json!(m.model_id);
            provenance["modelRevision"] = json!(m.model_revision);
            provenance["build"] = json!(m.worker_build);
            if is_hash(&m.manifest_hash) {
                provenance["modelManifestHash"] = json!(m.manifest_hash);
            } else {
                missing.push("model_manifest_hash");
            }
        }
        None => missing.extend(["sdk_version", "model_id", "model_revision", "model_manifest_hash", "build"]),
    }
    provenance["unavailableMetadata"] = Value::Array(missing.iter().map(|f| json!({"field": f, "reason": "not_recorded"})).collect());
    let status = if e.cancelled { "cancelled" } else if e.reasons.is_empty() { "completed" } else { "failed" };
    let mut content = json!({
        "schemaVersion": 1, "serializationVersion": "quality-content-v1", "rawWindows": raw, "assembledText": e.assembled.text, "assembledHash": sha256_hex(e.assembled.text.as_bytes()),
        "normalizedHash": sha256_hex(e.normalized.text.as_bytes()), "assemblyVersion": ASSEMBLY_VERSION, "normalizationVersion": normalize::VERSION, "appliedRuleIDs": e.normalized.rules, "appliedEntryIDs": e.normalized.entries,
        "vocabularyRevision": e.vocabulary.revision, "vocabularyHash": e.vocabulary.hash, "provenance": provenance, "completionReasons": e.reasons,
        "attempts": [{"id": "initial", "engine": engine, "status": status, "duration": e.recognition_seconds}], "selectedAttempt": 0, "seams": e.assembled.seams,
    });
    if !e.normalized.ambiguous.is_empty() {
        content["ambiguousEntryIDs"] = json!(e.normalized.ambiguous);
    }
    let raw = serde_json::to_string(&content).ok()?;
    let hash = sha256_hex(raw.as_bytes());
    let detail = format!("{{\"content\":{raw},\"contentHash\":\"{hash}\"}}");
    (detail.len() <= 262_144).then_some((detail, hash))
}

fn reason(code: &str, window: Option<usize>) -> Value {
    match window {
        Some(w) => json!({"code": code, "window": w}),
        None => json!({"code": code}),
    }
}

// ---- Capture ----

struct Pump {
    input: Option<Box<dyn Input>>,
    ring: Arc<Ring>,
    converter: Converter,
    raw: Vec<f32>,
    converted: Vec<f32>,
    /// The first non-zero sample came; the 180 s budget runs from it.
    audio_since: Option<Instant>,
    level: f32,
    full: bool,
}

impl Pump {
    fn new(input: Box<dyn Input>) -> Pump {
        let ring = input.ring().clone();
        let converter = Converter::new(ring.rate(), ring.channels());
        Pump { input: Some(input), ring, converter, raw: Vec::with_capacity(1 << 18), converted: Vec::with_capacity(1 << 17), audio_since: None, level: 0., full: false }
    }
    fn input(&self) -> &dyn Input {
        self.input.as_deref().expect("running")
    }
    /// Ring to spool. Leading digital silence goes, as the Swift adapter's first-audio gate drops it.
    fn drain(&mut self, spool: &mut Spool, shared: &Shared, last: bool) -> Result<(), Fail> {
        self.raw.clear();
        self.converted.clear();
        self.ring.pop(&mut self.raw);
        let channels = self.ring.channels();
        let mut from = 0;
        if self.audio_since.is_none() {
            match self.raw.chunks_exact(channels).position(|f| f.iter().any(|s| *s != 0.)) {
                Some(frame) => {
                    from = frame * channels;
                    self.audio_since = Some(Instant::now());
                }
                None => from = self.raw.len(),
            }
        }
        let audio = &self.raw[from..];
        self.level = audio.iter().fold(0f32, |m, s| m.max(if s.is_finite() { s.abs() } else { 0. })).min(1.);
        self.converter.push(audio, &mut self.converted);
        if last && self.audio_since.is_some() {
            self.converter.finish(&mut self.converted);
        }
        let wrote = spool.append(&self.converted).map_err(|_| Fail::Disk)?;
        self.full = wrote < self.converted.len() || spool.samples() >= MAX_SAMPLES;
        shared.recorded.store(spool.samples(), SeqCst);
        Ok(())
    }
    fn stop(&mut self) {
        if let Some(input) = self.input.take() {
            input.stop();
        }
        self.ring.close_and_join();
    }
}

impl Drop for Pump {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Captured {
    samples: usize,
    reason: StopReason,
    device: Option<(String, String)>,
}

// ---- The coordinator ----

pub struct Coordinator {
    pub spool_root: PathBuf,
    pub pending_dir: PathBuf,
    pub timing: Timing,
    publish: Box<dyn FnMut(Event) + Send>,
    state: State,
    status: String,
    busy: bool,
    unsaved: Option<NewDictation>,
    pending_outcome: Option<PendingOutcome>,
    storage_blocked: bool,
    capacity_blocked: bool,
    cleanup_blocked: bool,
    offers_microphones: bool,
}

impl Coordinator {
    pub fn new(spool_root: PathBuf, pending_dir: PathBuf, publish: Box<dyn FnMut(Event) + Send>) -> Coordinator {
        let mut c = Coordinator { spool_root, pending_dir, timing: Timing::default(), publish, state: State::Idle, status: "Ready".into(), busy: false, unsaved: None, pending_outcome: None, storage_blocked: false, capacity_blocked: false, cleanup_blocked: false, offers_microphones: false };
        // Anything here is left from a crash. A failure blocks recording until it's checked.
        if spool::remove_stale(&c.spool_root).is_err() {
            c.cleanup_blocked = true;
            c.status = "Temporary audio cleanup failed. Restart after checking storage.".into();
            c.state = State::Failed;
        }
        c
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot { state: self.state, status: self.status.clone(), busy: self.busy, unsaved: self.unsaved.as_ref().map(|u| u.text.clone()), storage_blocked: self.storage_blocked, capacity_blocked: self.capacity_blocked, cleanup_blocked: self.cleanup_blocked, offers_microphones: self.offers_microphones }
    }
    fn emit(&mut self) {
        let snapshot = self.snapshot();
        (self.publish)(Event::Changed(snapshot));
    }
    fn set(&mut self, state: State, status: impl Into<String>) {
        self.state = state;
        self.status = status.into();
        self.emit();
    }
    fn set_state(&mut self, state: State) {
        self.state = state;
        self.emit();
    }

    pub fn can_begin(&self) -> bool {
        !self.busy && self.unsaved.is_none() && !self.cleanup_blocked && !self.storage_blocked && !self.capacity_blocked
    }

    /// `verifyInitialAdmission`, at launch.
    pub fn verify_admission(&mut self, history: &mut dyn History) {
        if self.busy || self.unsaved.is_some() {
            return;
        }
        match history.reserve() {
            Ok(()) => {}
            Err(HistoryError::Capacity) => {
                self.capacity_blocked = true;
                self.set(State::Failed, "History is full. Explicitly delete saved text before recording again.");
            }
            Err(HistoryError::Store) => {
                self.storage_blocked = true;
                self.set(State::Failed, "Storage is unavailable. Check free disk space and Retry storage.");
            }
        }
    }

    /// `deleteOrThrow`'s second half: a deletion may have made room.
    pub fn recheck_capacity(&mut self, history: &mut dyn History) {
        if !self.capacity_blocked || self.busy {
            return;
        }
        if history.reserve().is_ok() {
            self.capacity_blocked = false;
            self.status = "History has space for another recording.".into();
            if !self.storage_blocked && self.unsaved.is_none() && !self.cleanup_blocked {
                self.state = State::Idle;
            }
        } else {
            self.status = "History entry deleted. More space is needed before recording; explicitly delete another entry.".into();
        }
        self.emit();
    }

    pub fn retry_save(&mut self, history: &mut dyn History) -> bool {
        let Some(dictation) = self.unsaved.clone().filter(|_| !self.busy) else { return false };
        match history.commit(&dictation) {
            Ok(_) => {
                self.unsaved = None;
                self.set(State::Recovery, "Text saved for review.");
                (self.publish)(Event::HistoryChanged);
                true
            }
            Err(_) => {
                self.status = "Still unsaved. Check available disk space or Copy the text.".into();
                self.emit();
                false
            }
        }
    }

    pub fn discard_unsaved(&mut self) {
        if !self.busy {
            self.unsaved = None;
            self.status = "Unsaved text discarded.".into();
            self.emit();
        }
    }

    pub fn retry_storage(&mut self, history: &mut dyn History) -> bool {
        if self.busy || !self.storage_blocked {
            return false;
        }
        let done = match &self.pending_outcome {
            Some(pending) => history.record_outcome(pending).is_ok(),
            None => history.writable(),
        };
        if done {
            self.pending_outcome = None;
            self.storage_blocked = false;
            self.status = "Storage available. Saved text remains in history.".into();
            (self.publish)(Event::HistoryChanged);
        } else {
            self.status = "Storage is still unavailable. Existing text remains saved.".into();
        }
        self.emit();
        done
    }

    /// One dictation from key-down to its end. Blocks.
    pub fn run(&mut self, d: &mut Deps, c: &Control) {
        if !self.can_begin() {
            return;
        }
        self.busy = true;
        self.offers_microphones = false;
        let id = d.history.new_id();
        let mut stage = "checking storage";
        let mut spool = None;
        let result = self.session(d, c, &id, &mut stage, &mut spool);
        if let Err(fail) = result {
            self.failed(fail, stage, c);
        }
        if let Some(spool) = spool.take() {
            let spool: Spool = spool;
            if spool.remove().is_err() {
                self.cleanup_blocked = true;
                self.status = "Temporary audio cleanup failed. Restart after checking storage.".into();
                self.state = State::Failed;
            }
        }
        self.busy = false;
        self.emit();
        (self.publish)(Event::Level(0.));
        (self.publish)(Event::HistoryChanged);
    }

    fn failed(&mut self, fail: Fail, stage: &str, c: &Control) {
        let cancelled = c.cancelled() || matches!(fail, Fail::Cancelled);
        self.status = if self.unsaved.is_some() {
            "Text is unsaved. Retry save or Copy before quitting.".into()
        } else if cancelled || c.released() && matches!(fail, Fail::Cancelled) {
            "Cancelled".into()
        } else {
            format!("Failed while {stage}. {}", describe(&fail))
        };
        if matches!(fail, Fail::Capacity) {
            self.capacity_blocked = true;
            self.status = "History is full. Explicitly delete saved entries before recording again. Dismissing recovery does not free space.".into();
        }
        if self.storage_blocked {
            self.status = "Delivery status could not be saved. Retry storage before another dictation.".into();
        }
        if matches!(fail, Fail::NoMicrophone | Fail::DidNotRespond(_)) && !cancelled {
            self.status = describe(&fail);
            self.offers_microphones = true;
            let message = self.status.clone();
            (self.publish)(Event::Microphone(message));
        }
        // swift-note: Swift lands a key release during preparation in `.failed` with "Cancelled"
        // text; nothing reads the difference but the status color, and idle is what a release means.
        self.state = if cancelled && self.unsaved.is_none() { State::Idle } else { State::Failed };
    }

    fn session(&mut self, d: &mut Deps, c: &Control, id: &str, stage: &mut &'static str, spool_slot: &mut Option<Spool>) -> Result<(), Fail> {
        if c.stopped() {
            return Err(Fail::Cancelled);
        }
        let reserved = d.history.reserve();
        self.set(State::Preparing, "Preparing speech model…");
        *stage = "requesting microphone access";
        if !d.mic.authorize() {
            return Err(Fail::Denied);
        }
        if c.stopped() {
            return Err(Fail::Cancelled);
        }
        *stage = "choosing a microphone";
        let candidates = d.mic.candidates(d.inputs);
        if candidates.is_empty() {
            return Err(Fail::NoMicrophone);
        }
        *stage = "creating temporary audio storage";
        let mut spool = Spool::create(&self.spool_root, id).map_err(|_| Fail::Disk)?;
        let reader = spool.reader().map_err(|_| Fail::Disk);
        *stage = "checking storage";
        let reserved = reserved.map_err(|e| if e == HistoryError::Capacity { Fail::Capacity } else { Fail::Store });
        *stage = "loading preferred spellings";
        let vocabulary = d.history.vocabulary().map_err(|_| Fail::Model("Preferred spellings could not be loaded. Repair or delete entries in Settings.".into()));
        if let Err(fail) = reserved.and(reader.as_ref().map(|_| ()).map_err(|_| Fail::Disk)).and(vocabulary.as_ref().map(|_| ()).map_err(|e| Fail::Model(describe(e)))) {
            *spool_slot = Some(spool);
            return Err(fail);
        }
        let (reader, vocabulary) = (reader.expect("checked"), vocabulary.expect("checked"));
        if c.stopped() {
            *spool_slot = Some(spool);
            return Err(Fail::Cancelled);
        }
        *stage = "starting the microphone";
        let target = d.inserter.capture_target();
        let shared = Shared::default();
        let poll = self.timing.poll;
        let recognizer = &mut *d.recognizer;
        let vocabulary_ref = &vocabulary;
        let shared_ref = &shared;
        let spool_ref = &mut spool;
        let mic = d.mic;
        let (captured, recognition) = std::thread::scope(|scope| {
            let helper = scope.spawn(move || recognize_loop(recognizer, vocabulary_ref, reader, shared_ref, c, poll));
            let captured = self.capture(c, mic, &candidates, spool_ref, shared_ref, stage);
            match &captured {
                Ok(captured) if !c.cancelled() => {
                    shared_ref.asleep.store(captured.reason == StopReason::Sleep, SeqCst);
                    shared_ref.total.store(captured.samples, SeqCst);
                }
                _ => shared_ref.discard.store(true, SeqCst),
            }
            shared_ref.ended.store(true, SeqCst);
            let on_server = |shared: &Shared| shared.streaming.load(SeqCst);
            let transcribing = |shared: &Shared| if on_server(shared) { "Transcribing on your server…" } else { "Transcribing locally…" };
            if captured.is_ok() {
                self.set(if c.cancelled() { State::Cancelling } else { State::Transcribing }, if c.cancelled() { "Cancelling…" } else { transcribing(shared_ref) });
            }
            // A cancel from here on keeps the windows done so far: the loop reads it between jobs.
            let mut was_on_server = on_server(shared_ref);
            while !helper.is_finished() {
                if captured.is_ok() && !c.cancelled() && was_on_server != on_server(shared_ref) {
                    was_on_server = on_server(shared_ref);
                    self.set(State::Transcribing, transcribing(shared_ref));
                }
                std::thread::sleep(poll);
            }
            (captured, helper.join().expect("the recognition loop doesn't panic"))
        });
        *spool_slot = Some(spool);
        let captured = match captured {
            Ok(captured) => captured,
            Err(fail) => {
                d.recognizer.finish();
                return Err(fail);
            }
        };
        let spool = spool_slot.as_ref().expect("just set");
        if recognition.lost {
            self.keep_waiting(d, id, spool, &captured, target.as_ref());
            return Ok(());
        }
        if let Some(message) = recognition.prepare_failed {
            *stage = "loading the speech model";
            return Err(if c.cancelled() { Fail::Cancelled } else { Fail::Model(message) });
        }
        *stage = "transcribing audio";
        let model = d.recognizer.model();
        d.recognizer.finish();
        self.deliver(d, c, id, stage, captured, recognition, target, vocabulary, model)
    }

    /// `connectInput`: each entry once, moving on when a start fails or stays silent.
    fn connect(&mut self, c: &Control, mic: &dyn Mic, candidates: &[Candidate]) -> Result<(Pump, usize), Fail> {
        for (i, candidate) in candidates.iter().enumerate() {
            let last = i + 1 == candidates.len();
            let started = Instant::now();
            let input = match mic.start(candidate) {
                Ok(input) => input,
                Err(_) => {
                    if c.stopped() {
                        return Err(Fail::Cancelled);
                    }
                    if last {
                        return Err(Fail::DidNotRespond(candidate.name.clone()));
                    }
                    continue;
                }
            };
            if !c.stopped() {
                self.set(State::Connecting, format!("Connecting to {}…", candidate.name));
            }
            let pump = Pump::new(input);
            loop {
                if c.stopped() {
                    return Err(Fail::Cancelled);
                }
                if pump.ring.audio_flowing() {
                    return Ok((pump, i));
                }
                match pump.ring.failure() {
                    Some(Failure::Sleep) => return Err(Fail::Capture(StopReason::Sleep)),
                    Some(_) => break,
                    None => {}
                }
                if !pump.input().authorized() {
                    return Err(Fail::Capture(StopReason::PermissionRevoked));
                }
                if !pump.input().running() || started.elapsed() >= self.timing.connect_limit {
                    break;
                }
                std::thread::sleep(self.timing.poll);
            }
            drop(pump);
            if last {
                return Err(Fail::DidNotRespond(candidate.name.clone()));
            }
        }
        Err(Fail::NoMicrophone)
    }

    fn capture(&mut self, c: &Control, mic: &dyn Mic, candidates: &[Candidate], spool: &mut Spool, shared: &Shared, stage: &mut &'static str) -> Result<Captured, Fail> {
        let (mut pump, index) = self.connect(c, mic, candidates)?;
        let candidate = &candidates[index];
        let name = if candidate.device_id.is_none() { pump.input().device_name().unwrap_or_else(|| candidate.name.clone()) } else { candidate.name.clone() };
        let device = Some((name, candidate.kind.clone()));
        if !c.stopped() {
            self.set(State::Recording, "Recording");
        }
        let mut reason = None;
        while reason.is_none() {
            *stage = "finishing microphone capture";
            pump.drain(spool, shared, false)?;
            (self.publish)(Event::Level(pump.level));
            if shared.failed_prepare.lock().unwrap().is_some() && !c.cancelled() {
                // The model can't load: nothing recorded could become text.
                *stage = "loading the speech model";
                let message = shared.failed_prepare.lock().unwrap().clone().unwrap_or_default();
                return Err(Fail::Model(message));
            }
            reason = if let Some(failure) = pump.ring.failure() {
                Some(stop_reason_of(failure))
            } else if !pump.input().authorized() {
                Some(StopReason::PermissionRevoked)
            } else if !pump.input().running() {
                Some(StopReason::DeviceLoss)
            } else if pump.full || pump.audio_since.is_some_and(|t| t.elapsed() >= self.timing.budget) {
                Some(StopReason::DurationLimit)
            } else if c.cancelled() {
                Some(StopReason::Cancel)
            } else if c.released() {
                Some(StopReason::KeyRelease)
            } else {
                None
            };
            if reason.is_none() {
                std::thread::sleep(self.timing.poll);
            }
        }
        let reason = reason.expect("the loop's condition");
        // A cancel wins whatever else happened, and never waits for a tail.
        if c.cancelled() {
            pump.stop();
            return Ok(Captured { samples: spool.samples(), reason: StopReason::Cancel, device });
        }
        let delay = Duration::from_nanos(pump.ring.max_delay_ns());
        if reason == StopReason::KeyRelease
            && let Some(tail) = release_tail(delay)
        {
            let end = Instant::now() + tail;
            while Instant::now() < end && !pump.full {
                pump.drain(spool, shared, false)?;
                std::thread::sleep(self.timing.poll);
            }
        }
        pump.stop();
        pump.drain(spool, shared, true)?;
        Ok(Captured { samples: spool.samples(), reason, device })
    }

    fn keep_waiting(&mut self, d: &mut Deps, id: &str, spool: &Spool, captured: &Captured, target: Option<&CapturedTarget>) {
        self.set_state(State::Persisting);
        let device = captured.device.as_ref();
        let server_failure = d.recognizer.server_failure();
        let waiting = Waiting { id, audio: spool.path(), samples: captured.samples, failure: server_failure.unwrap_or("worker_unavailable"), target_bundle_id: target.map(|t| t.bundle_id.as_str()), device_name: device.map(|x| x.0.as_str()), device_kind: device.map(|x| x.1.as_str()) };
        let kept = captured.samples > 0 && d.history.keep_waiting(&waiting).is_ok();
        let status = match (captured.samples == 0, kept, server_failure.is_some()) {
            (true, ..) => "No speech detected.",
            (_, true, true) => "Your server is unavailable. The dictation is waiting in History and will be retried.",
            (_, true, false) => "The speech engine stopped. The dictation is waiting in History.",
            (_, false, server) => {
                // Full or unwritable: the user saves the audio or discards it.
                let offered = self.pending_dir.join(format!("offered-{id}.f32"));
                let moved = std::fs::create_dir_all(&self.pending_dir).and_then(|()| std::fs::rename(spool.path(), &offered));
                if moved.is_ok() {
                    (self.publish)(Event::AudioOffered { audio: offered });
                }
                if server { "This recording could not be kept for your server. Its audio was offered to you." } else { "The speech engine stopped and this recording could not be kept. Its audio was offered to you." }
            }
        };
        self.set(State::Idle, status);
    }

    #[allow(clippy::too_many_arguments)]
    fn deliver(&mut self, d: &mut Deps, c: &Control, id: &str, stage: &mut &'static str, captured: Captured, recognition: Recognition, target: Option<CapturedTarget>, vocabulary: Vocabulary, model: Option<ModelIdentity>) -> Result<(), Fail> {
        let cancelled = || c.cancelled();
        let began = Instant::now();
        let assembled = assemble(&recognition.windows);
        let normalized = normalize::normalize(&assembled.text, &vocabulary);
        let mut reasons = Vec::new();
        if let Some((code, window)) = recognition.failure {
            reasons.push(reason(code, Some(window)));
        }
        if !assembled.text.trim().is_empty() {
            reasons.extend(assembled.empty.iter().map(|w| reason("empty_recognition", Some(*w))));
        }
        let recognized_all = recognition.windows.iter().map(|w| w.count).sum::<usize>() >= captured.samples;
        reasons.extend(normalized.reasons.iter().map(|r| reason(r, None)));
        let incomplete = !reasons.is_empty();
        let mut quality = match captured.reason {
            StopReason::KeyRelease => "complete",
            StopReason::DurationLimit => "duration_limited",
            _ => "incomplete",
        };
        if incomplete || cancelled() || !recognized_all {
            quality = "incomplete";
        }
        let stop = if cancelled() { StopReason::Cancel } else { captured.reason };
        if normalized.text.trim().is_empty() {
            if stop != StopReason::KeyRelease && stop != StopReason::DurationLimit && stop != StopReason::Cancel {
                self.set(State::Failed, format!("Recording stopped. {}", stop.describe()));
            } else if cancelled() {
                self.set(State::Idle, "Cancelled");
            } else if incomplete {
                self.set(State::Failed, "Transcription failed. No text was produced.");
            } else {
                self.set(State::Idle, "No speech detected.");
            }
            return Ok(());
        }
        *stage = "saving the transcription";
        self.set_state(State::Persisting);
        if cancelled() {
            reasons.push(reason("cancelled", None));
        }
        if stop == StopReason::DurationLimit {
            reasons.push(reason("duration_limit", None));
        }
        if !matches!(stop, StopReason::KeyRelease | StopReason::DurationLimit | StopReason::Cancel) {
            reasons.push(reason("capture_failure", None));
        }
        let evidence = Evidence { windows: &recognition.windows, assembled: &assembled, normalized: &normalized, vocabulary: &vocabulary, model, samples: captured.samples, reasons, cancelled: cancelled(), recognition_seconds: recognition.recognition_seconds, normalization_seconds: began.elapsed().as_secs_f64() };
        let (detail_json, content_hash) = seal(&evidence).ok_or_else(|| Fail::Model("The speech model returned an invalid result.".into()))?;
        let device = captured.device.clone();
        let dictation = NewDictation {
            id: id.into(),
            text: normalized.text.clone(),
            quality,
            stop_reason: stop.raw(),
            target_bundle_id: target.as_ref().map(|t| t.bundle_id.clone()),
            recognition_path: d.recognizer.path(),
            server_failure: d.recognizer.server_failure(),
            device_name: device.as_ref().map(|x| x.0.clone()),
            device_kind: device.map(|x| x.1),
            detail_json,
            content_hash,
            created_at: None,
        };
        let revision = match d.history.commit(&dictation) {
            Ok(revision) => revision,
            Err(_) => {
                self.unsaved = Some(dictation);
                return Err(Fail::Unsaved);
            }
        };
        d.history.record_applied(id, &normalized.changes);
        (self.publish)(Event::HistoryChanged);
        // FR-013 (Feature 019): audio already captured from a lost microphone is still inserted.
        let insert = !cancelled() && (quality == "complete" && stop == StopReason::KeyRelease || stop == StopReason::DeviceLoss);
        let Some(target) = target.filter(|_| insert) else {
            self.offer_clipboard(d, &normalized.text, false);
            self.set(State::Idle, "Text saved and copied. Paste it with Command-V.");
            return Ok(());
        };
        let mut text = normalized.text.clone();
        let mut rewrite = None;
        let mut notice = None;
        if !c.bypass.load(SeqCst)
            && let Some(rewriter) = d.rewriter.as_deref_mut()
        {
            *stage = "rewriting saved text";
            let mut started = false;
            c.rewriting.store(true, SeqCst);
            let publish = &mut self.publish;
            let result = {
                let (state, status, busy, unsaved, storage, capacity, cleanup, offers) = (&mut self.state, &mut self.status, self.busy, self.unsaved.as_ref().map(|u| u.text.clone()), self.storage_blocked, self.capacity_blocked, self.cleanup_blocked, self.offers_microphones);
                let mut on_start = || {
                    started = true;
                    *state = State::Rewriting;
                    *status = "Rewriting…".into();
                    publish(Event::Changed(Snapshot { state: *state, status: status.clone(), busy, unsaved: unsaved.clone(), storage_blocked: storage, capacity_blocked: capacity, cleanup_blocked: cleanup, offers_microphones: offers }));
                };
                rewriter.rewrite(id, &text, &mut on_start, &c.cancel_rewrite)
            };
            c.rewriting.store(false, SeqCst);
            match result {
                Rewritten::NotEligible => {}
                Rewritten::Text { text: new, attempt } => {
                    text = new;
                    rewrite = Some(attempt);
                }
                Rewritten::Notice { message, can_retry } => notice = Some((message, can_retry)),
            }
        }
        *stage = "inserting saved text";
        self.set_state(State::Inserting);
        self.storage_blocked = true;
        let (attempt, revision) = d.history.begin_attempt(id, revision).map_err(|_| Fail::Store)?;
        let outcome = if cancelled() { InsertOutcome::NotInserted } else { d.inserter.insert_once(&target, &text) };
        let stored = match outcome {
            InsertOutcome::Confirmed => Outcome::Confirmed,
            InsertOutcome::NotInserted => Outcome::NotInserted,
            InsertOutcome::Uncertain => Outcome::Uncertain,
        };
        let pending = PendingOutcome { id: id.into(), revision, attempt, outcome: stored, rewrite };
        if d.history.record_outcome(&pending).is_err() {
            self.pending_outcome = Some(pending);
            return Err(Fail::Store);
        }
        self.storage_blocked = false;
        if let Some((message, can_retry)) = notice {
            (self.publish)(Event::Action { message, can_retry, dictation: id.into() });
        }
        if outcome == InsertOutcome::Confirmed {
            (self.publish)(Event::Inserted(Inserted { dictation: id.into(), text: text.clone(), target, changes: normalized.changes.clone() }));
            self.set(State::Idle, "Ready");
        } else {
            self.offer_clipboard(d, &text, outcome == InsertOutcome::Uncertain);
            self.set(State::Idle, "Text saved and copied. Paste it with Command-V.");
        }
        Ok(())
    }

    fn offer_clipboard(&mut self, d: &Deps, text: &str, uncertain: bool) {
        if !text.is_empty() {
            d.inserter.copy(text);
            (self.publish)(Event::Clipboard { uncertain });
        }
    }
}

/// A finished recognition for one saved after its moment: `save` in `PendingRemoteRetrier`. Same
/// evidence as a live one. `None` when nothing was said, or the evidence doesn't fit.
pub struct Recovered<'a> {
    pub id: &'a str,
    pub created_at: i64,
    pub samples: usize,
    pub path: &'static str,
    pub server_failure: &'static str,
    pub target_bundle_id: Option<String>,
    pub device_name: Option<String>,
    pub device_kind: Option<String>,
}

pub fn recovered_dictation(r: Recovered, windows: Vec<(usize, usize, String)>, vocabulary: &Vocabulary, model: Option<ModelIdentity>, recognition_seconds: f64) -> Option<NewDictation> {
    let windows: Vec<Done> = windows.into_iter().map(|(start, count, text)| Done { start, count, text }).collect();
    let assembled = assemble(&windows);
    let normalized = normalize::normalize(&assembled.text, vocabulary);
    if normalized.text.trim().is_empty() {
        return None;
    }
    let mut reasons: Vec<Value> = assembled.empty.iter().map(|w| reason("empty_recognition", Some(*w))).collect();
    reasons.extend(normalized.reasons.iter().map(|x| reason(x, None)));
    let quality = if reasons.is_empty() { "complete" } else { "incomplete" };
    let evidence = Evidence { windows: &windows, assembled: &assembled, normalized: &normalized, vocabulary, model, samples: r.samples, reasons, cancelled: false, recognition_seconds, normalization_seconds: 0. };
    let (detail_json, content_hash) = seal(&evidence)?;
    Some(NewDictation { id: r.id.into(), text: normalized.text.clone(), quality, stop_reason: StopReason::KeyRelease.raw(), target_bundle_id: r.target_bundle_id, recognition_path: r.path, server_failure: Some(r.server_failure), device_name: r.device_name, device_kind: r.device_kind, detail_json, content_hash, created_at: Some(r.created_at) })
}

// ---- Real recognizer and store ----

/// The speech worker under one lease.
pub struct Local<'a> {
    pub lifecycle: &'a mut Lifecycle,
    pub lease: Option<Lease>,
    pub boost: Option<Boost>,
}

impl<'a> Local<'a> {
    pub fn new(lifecycle: &'a mut Lifecycle) -> Local<'a> {
        Local { lifecycle, lease: None, boost: None }
    }
}

fn refusal_message(refusal: Refusal) -> String {
    match refusal {
        Refusal::Busy | Refusal::NotHeld => "Another dictation or model operation is still running. Wait for it to finish.".into(),
        Refusal::Restarting(_) | Refusal::Unavailable(_) | Refusal::NotInstalled => "The speech model is unavailable. Verify the local model in Settings.".into(),
    }
}

impl Recognizer for Local<'_> {
    fn prepare(&mut self, vocabulary: &Vocabulary) -> Result<(), String> {
        let lease = self.lifecycle.acquire().map_err(refusal_message)?;
        self.lease = Some(lease);
        let booster = self.lifecycle.ensure_started().map_err(refusal_message)?.booster.is_some();
        if booster && !vocabulary.boost.is_empty() {
            self.boost = Some(Boost { terms: vocabulary.boost.iter().map(|(entry_id, canonical)| BoostTerm { entry_id: entry_id.clone(), canonical: canonical.clone() }).collect(), governed: vocabulary.governed.clone() });
        }
        Ok(())
    }
    fn recognize(&mut self, samples: &[f32]) -> Result<Value, RecognizeFailure> {
        let lease = self.lease.as_ref().ok_or(RecognizeFailure::Job("failed".into()))?;
        match self.lifecycle.recognize(lease, samples, self.boost.clone()) {
            Ok(result) => Ok(result.window),
            Err(RecognizeError::Lost(_)) => Err(RecognizeFailure::Lost),
            Err(RecognizeError::Job(code)) => Err(RecognizeFailure::Job(code)),
            Err(RecognizeError::Invalid) => Err(RecognizeFailure::Job(super::worker::CODE_INVALID_AUDIO.into())),
            Err(RecognizeError::Refused(_)) => Err(RecognizeFailure::Job("failed".into())),
        }
    }
    fn model(&self) -> Option<ModelIdentity> {
        self.lifecycle.model().cloned()
    }
    fn finish(&mut self) {
        if let Some(lease) = self.lease.take() {
            self.lifecycle.finish(lease);
        }
    }
}

/// `History` over the database on the session's thread.
pub struct DbHistory {
    pub db: Db,
    pub pending_dir: PathBuf,
    pub free_bytes: Box<dyn Fn() -> Option<u64> + Send>,
}

fn store_error(error: StoreError) -> HistoryError {
    match error {
        StoreError::Refused("capacity") => HistoryError::Capacity,
        _ => HistoryError::Store,
    }
}

impl History for DbHistory {
    fn new_id(&mut self) -> String {
        history::new_uuid(&self.db)
    }
    fn reserve(&mut self) -> Result<(), HistoryError> {
        if history::has_room(&self.db, (self.free_bytes)()) { Ok(()) } else { Err(HistoryError::Capacity) }
    }
    fn vocabulary(&mut self) -> Result<Vocabulary, String> {
        Vocabulary::load(&self.db)
    }
    fn commit(&mut self, dictation: &NewDictation) -> Result<i64, HistoryError> {
        history::commit_dictation(&self.db, dictation).map_err(store_error)
    }
    fn begin_attempt(&mut self, id: &str, revision: i64) -> Result<(String, i64), HistoryError> {
        history::begin_attempt(&self.db, id, revision).map_err(store_error)
    }
    fn record_outcome(&mut self, p: &PendingOutcome) -> Result<(), HistoryError> {
        history::record_outcome(&self.db, &p.id, p.revision, &p.attempt, p.outcome, p.rewrite.as_deref()).map(|_| ()).map_err(store_error)
    }
    fn record_applied(&mut self, id: &str, changes: &[Change]) {
        let _ = crate::dictionary::record_applied(&self.db, id, changes);
    }
    fn keep_waiting(&mut self, waiting: &Waiting) -> Result<(), HistoryError> {
        history::keep_waiting(&self.db, &self.pending_dir, waiting).map_err(store_error)
    }
    fn writable(&mut self) -> bool {
        self.db.conn.execute("UPDATE history_usage SET row_count=row_count WHERE id=1", []).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicI32;
    use std::thread;

    const QUICK: Timing = Timing { poll: Duration::from_millis(1), connect_limit: Duration::from_millis(40), budget: Duration::from_secs(180) };

    #[derive(Clone, Copy, PartialEq)]
    enum Then {
        /// Keeps running, silent, until stopped.
        Idle,
        Release,
        ReleaseBypass,
        Cancel,
        Lost,
        Revoke,
        Stop(Failure),
    }

    #[derive(Clone)]
    struct Script {
        rate: u32,
        samples: usize,
        then: Then,
        delay_ns: u64,
    }
    fn speak(samples: usize, then: Then) -> Script {
        Script { rate: 16_000, samples, then, delay_ns: 0 }
    }

    struct FakeInput {
        ring: Arc<Ring>,
        stopping: Arc<AtomicBool>,
        running: Arc<AtomicBool>,
        authorized: Arc<AtomicBool>,
        feeder: Option<thread::JoinHandle<()>>,
    }
    impl Input for FakeInput {
        fn ring(&self) -> &Arc<Ring> {
            &self.ring
        }
        fn running(&self) -> bool {
            self.running.load(SeqCst)
        }
        fn authorized(&self) -> bool {
            self.authorized.load(SeqCst)
        }
        fn device_name(&self) -> Option<String> {
            Some("Real device".into())
        }
        fn stop(mut self: Box<Self>) {
            self.stopping.store(true, SeqCst);
            self.feeder.take().unwrap().join().unwrap();
        }
    }

    struct FakeMic {
        authorized: bool,
        candidates: Vec<Candidate>,
        /// Per candidate in order: `Err` fails its start, `None` stays silent.
        scripts: Vec<Result<Option<Script>, Failure>>,
        started: AtomicUsize,
        control: Arc<Control>,
        /// `then` waits for this: what ends the script can be made to follow something else.
        then_gate: Arc<AtomicBool>,
    }
    impl Mic for FakeMic {
        fn authorize(&self) -> bool {
            self.authorized
        }
        fn candidates(&self, _: &[InputEntry]) -> Vec<Candidate> {
            self.candidates.clone()
        }
        fn start(&self, _: &Candidate) -> Result<Box<dyn Input>, Failure> {
            let script = self.scripts[self.started.fetch_add(1, SeqCst)].clone()?;
            let rate = script.as_ref().map_or(16_000, |s| s.rate);
            let ring = Arc::new(Ring::new(rate, 1).unwrap());
            let (stopping, running, authorized) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(true)), Arc::new(AtomicBool::new(true)));
            let (control, gate) = (self.control.clone(), self.then_gate.clone());
            let (feed, stop, run, auth) = (ring.clone(), stopping.clone(), running.clone(), authorized.clone());
            // The first audio is there before `connect` looks, however late the feeder is scheduled.
            let first = script.as_ref().map_or(0, |s| s.samples.min(4096));
            if let Some(script) = &script {
                ring.push(&vec![0.25; first], 1, script.delay_ns);
            }
            let feeder = thread::spawn(move || {
                if let Some(script) = script {
                    let mut left = script.samples - first;
                    while left > 0 && !stop.load(SeqCst) {
                        let n = left.min(4096);
                        if room(&feed) >= n {
                            feed.push(&vec![0.25; n], 1, script.delay_ns);
                            left -= n;
                        } else {
                            thread::sleep(Duration::from_millis(1));
                        }
                    }
                    while room(&feed) < super::super::ring::SLOTS * super::super::ring::SLOT_FRAMES && !stop.load(SeqCst) {
                        thread::sleep(Duration::from_millis(1));
                    }
                    thread::sleep(Duration::from_millis(5));
                    while !gate.load(SeqCst) && !stop.load(SeqCst) {
                        thread::sleep(Duration::from_millis(1));
                    }
                    match script.then {
                        Then::Idle => {}
                        Then::Release => control.release(false),
                        Then::ReleaseBypass => control.release(true),
                        Then::Cancel => control.cancel(),
                        Then::Lost => run.store(false, SeqCst),
                        Then::Revoke => auth.store(false, SeqCst),
                        Then::Stop(failure) => feed.fail(failure),
                    }
                }
                while !stop.load(SeqCst) {
                    thread::sleep(Duration::from_millis(1));
                }
            });
            Ok(Box::new(FakeInput { ring, stopping, running, authorized, feeder: Some(feeder) }))
        }
    }
    fn room(ring: &Ring) -> usize {
        ring.free_frames()
    }
    fn candidate(name: &str) -> Candidate {
        Candidate { device_id: Some(1), uid: None, name: name.into(), kind: "usb".into() }
    }

    #[derive(Default)]
    struct FakeRecognizer {
        prepare: Option<String>,
        /// Answers in order; past the end, "words".
        answers: Vec<Result<&'static str, RecognizeFailure>>,
        calls: Arc<Mutex<Vec<usize>>>,
        /// Holds the first job until capture has ended, then cancels.
        cancel_after_capture: Option<(Arc<Control>, Arc<Mutex<Vec<Event>>>)>,
        /// Opened as the first job starts, so that job is a prefetch.
        first_job_opens: Option<Arc<AtomicBool>>,
        finished: Arc<AtomicI32>,
    }
    impl Recognizer for FakeRecognizer {
        fn prepare(&mut self, _: &Vocabulary) -> Result<(), String> {
            self.prepare.clone().map_or(Ok(()), Err)
        }
        fn recognize(&mut self, samples: &[f32]) -> Result<Value, RecognizeFailure> {
            let n = {
                let mut calls = self.calls.lock().unwrap();
                calls.push(samples.len());
                calls.len() - 1
            };
            if let Some(gate) = self.first_job_opens.take() {
                gate.store(true, SeqCst);
            }
            if let Some((control, events)) = self.cancel_after_capture.take() {
                // Transcribing is published after capture has ended.
                while !events.lock().unwrap().iter().any(|e| matches!(e, Event::Changed(s) if s.state == State::Transcribing)) {
                    thread::sleep(Duration::from_millis(1));
                }
                control.cancel();
            }
            match self.answers.get(n).cloned().unwrap_or(Ok("words")) {
                Ok(text) => Ok(json!({"text": text})),
                Err(e) => Err(e),
            }
        }
        fn model(&self) -> Option<ModelIdentity> {
            Some(ModelIdentity { engine: "fake".into(), model_id: "m".into(), model_revision: "r".into(), manifest_hash: "a".repeat(64), sdk: "s".into(), booster: None, worker_build: "b".into() })
        }
        fn finish(&mut self) {
            self.finished.fetch_add(1, SeqCst);
        }
    }

    struct FakeInserter {
        target: Option<CapturedTarget>,
        outcome: InsertOutcome,
        inserted: Mutex<Vec<String>>,
        copied: Mutex<Vec<String>>,
    }
    impl Inserter for FakeInserter {
        fn capture_target(&self) -> Option<CapturedTarget> {
            self.target.clone()
        }
        fn insert_once(&self, _: &CapturedTarget, text: &str) -> InsertOutcome {
            self.inserted.lock().unwrap().push(text.into());
            self.outcome
        }
        fn copy(&self, text: &str) {
            self.copied.lock().unwrap().push(text.into());
        }
    }
    fn field() -> CapturedTarget {
        CapturedTarget { bundle_id: "com.example".into(), own_process: false, delivery: InsertDelivery::Accessibility, selection_location: 0, token: 1 }
    }

    /// Real history on an in-memory database, so the rows are what the views read.
    fn store(dir: &Path) -> DbHistory {
        DbHistory { db: Db::memory(), pending_dir: dir.join("PendingAudio"), free_bytes: Box::new(|| Some(100 << 30)) }
    }

    struct Rig {
        root: PathBuf,
        control: Arc<Control>,
        mic: FakeMic,
        recognizer: FakeRecognizer,
        inserter: FakeInserter,
        rewriter: Option<Box<dyn Rewriter>>,
        history: DbHistory,
        coordinator: Coordinator,
        events: Arc<Mutex<Vec<Event>>>,
    }

    static NEXT: AtomicUsize = AtomicUsize::new(0);

    fn rig(scripts: Vec<Result<Option<Script>, Failure>>) -> Rig {
        let root = std::env::temp_dir().join(format!("flow-session-{}-{}", std::process::id(), NEXT.fetch_add(1, SeqCst)));
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        let control = Arc::new(Control::default());
        let names: Vec<Candidate> = (0..scripts.len()).map(|i| candidate(&format!("Mic {i}"))).collect();
        let mut coordinator = Coordinator::new(root.join("TemporaryAudio"), root.join("PendingAudio"), Box::new(move |e| sink.lock().unwrap().push(e)));
        coordinator.timing = QUICK;
        Rig {
            history: store(&root),
            mic: FakeMic { authorized: true, candidates: names, scripts, started: AtomicUsize::new(0), control: control.clone(), then_gate: Arc::new(AtomicBool::new(true)) },
            recognizer: FakeRecognizer::default(),
            inserter: FakeInserter { target: Some(field()), outcome: InsertOutcome::Confirmed, inserted: Mutex::default(), copied: Mutex::default() },
            rewriter: None,
            coordinator,
            root,
            control,
            events,
        }
    }

    impl Rig {
        fn run(&mut self) -> Snapshot {
            let control = self.control.clone();
            let mut rewriter = self.rewriter.take();
            let mut deps = Deps { mic: &self.mic, inputs: &[], recognizer: &mut self.recognizer, rewriter: rewriter.as_mut().map(|r| &mut **r as &mut dyn Rewriter), inserter: &self.inserter, history: &mut self.history };
            self.coordinator.run(&mut deps, &control);
            self.rewriter = rewriter;
            self.coordinator.snapshot()
        }
        fn row(&self) -> history::Entry {
            let id: String = self.history.db.conn.query_row("SELECT id FROM transcriptions", [], |r| r.get(0)).expect("one row");
            history::get(&self.history.db, &id).unwrap().unwrap()
        }
        fn rows(&self) -> i64 {
            self.history.db.conn.query_row("SELECT count(*) FROM transcriptions", [], |r| r.get(0)).unwrap()
        }
        fn states(&self) -> Vec<State> {
            let mut out: Vec<State> = Vec::new();
            for e in self.events.lock().unwrap().iter() {
                if let Event::Changed(s) = e
                    && out.last() != Some(&s.state)
                {
                    out.push(s.state);
                }
            }
            out
        }
        fn spool_clean(&self) -> bool {
            std::fs::read_dir(self.root.join("TemporaryAudio")).map(|d| d.count() == 0).unwrap_or(true)
        }
    }
    impl Drop for Rig {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn key_release_saves_and_inserts() {
        let mut r = rig(vec![Ok(Some(speak(32_000, Then::Release)))]);
        let end = r.run();
        assert_eq!((end.state, end.status.as_str(), end.busy), (State::Idle, "Ready", false));
        assert_eq!(r.states(), [State::Preparing, State::Connecting, State::Recording, State::Transcribing, State::Persisting, State::Inserting, State::Idle]);
        let row = r.row();
        assert_eq!((row.text.as_str(), row.quality.as_str(), row.stop_reason.as_str(), row.delivery_state.as_str(), row.recovery_state.as_str()), ("words", "complete", "key_release", "confirmed", "resolved"));
        assert_eq!(row.target_bundle_id.as_deref(), Some("com.example"));
        assert_eq!((row.input_device_name.as_deref(), row.input_device_kind.as_deref(), row.recognition_path.as_str()), (Some("Mic 0"), Some("usb"), "local"));
        assert!(row.has_quality_detail);
        assert_eq!(*r.inserter.inserted.lock().unwrap(), ["words"]);
        assert_eq!(*r.recognizer.calls.lock().unwrap(), [32_000]);
        assert_eq!(r.recognizer.finished.load(SeqCst), 1);
        assert!(r.spool_clean());
    }

    #[test]
    fn the_stored_detail_is_what_the_history_views_decode() {
        let mut r = rig(vec![Ok(Some(speak(32_000, Then::Release)))]);
        r.run();
        let row = r.row();
        let (json, hash): (String, String) = r.history.db.conn.query_row("SELECT detail_json,content_hash FROM transcription_quality", [], |x| Ok((x.get(0)?, x.get(1)?))).unwrap();
        let detail = history::decode_detail_for_test(&json, 1, &hash, &row.text).expect("decodes");
        assert_eq!(detail["rawWindows"][0]["sampleCount"], 32_000);
        assert_eq!(detail["provenance"]["inputSamples"], 32_000);
        assert_eq!(detail["assemblyVersion"], ASSEMBLY_VERSION);
        let usage: (i64, i64) = r.history.db.conn.query_row("SELECT row_count,payload_bytes FROM history_usage", [], |x| Ok((x.get(0)?, x.get(1)?))).unwrap();
        assert_eq!(usage, (1, (row.text.len() + json.len()) as i64));
    }

    #[test]
    fn duration_limit_saves_for_review_without_inserting() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Idle)))]);
        r.coordinator.timing.budget = Duration::from_millis(10);
        let end = r.run();
        assert_eq!(end.status, "Text saved and copied. Paste it with Command-V.");
        let row = r.row();
        assert_eq!((row.quality.as_str(), row.stop_reason.as_str(), row.delivery_state.as_str()), ("duration_limited", "duration_limit", "not_attempted"));
        assert!(r.inserter.inserted.lock().unwrap().is_empty());
        assert_eq!(*r.inserter.copied.lock().unwrap(), ["words"]);
        assert!(r.events.lock().unwrap().contains(&Event::Clipboard { uncertain: false }));
    }

    #[test]
    fn the_spool_limit_also_ends_at_the_duration_limit() {
        let mut r = rig(vec![Ok(Some(speak(MAX_SAMPLES + 8_192, Then::Idle)))]);
        r.run();
        let row = r.row();
        assert_eq!(row.stop_reason, "duration_limit");
        let calls = r.recognizer.calls.lock().unwrap().clone();
        assert_eq!(calls.iter().sum::<usize>(), MAX_SAMPLES);
        assert_eq!(calls[0], WINDOW);
        assert!(calls.len() <= 14);
    }

    #[test]
    fn cancel_while_recording_keeps_nothing() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Cancel)))]);
        let end = r.run();
        assert_eq!((end.state, end.status.as_str()), (State::Idle, "Cancelled"));
        assert_eq!(r.rows(), 0);
        assert!(r.inserter.copied.lock().unwrap().is_empty());
        assert!(r.spool_clean());
    }

    #[test]
    fn cancel_after_stop_keeps_the_windows_done_for_review() {
        let mut r = rig(vec![Ok(Some(speak(WINDOW * 2 + 16_000, Then::Release)))]);
        r.recognizer.cancel_after_capture = Some((r.control.clone(), r.events.clone()));
        let end = r.run();
        assert_eq!(end.state, State::Idle);
        assert_eq!(end.status, "Text saved and copied. Paste it with Command-V.");
        let row = r.row();
        assert_eq!((row.text.as_str(), row.stop_reason.as_str(), row.quality.as_str(), row.delivery_state.as_str()), ("words", "cancel", "incomplete", "not_attempted"));
        assert_eq!(r.recognizer.calls.lock().unwrap().len(), 1, "no job starts after the cancel");
        assert!(r.inserter.inserted.lock().unwrap().is_empty());
    }

    fn capture_failure(then: Then, stop: &str) {
        let mut r = rig(vec![Ok(Some(speak(16_000, then)))]);
        let end = r.run();
        let row = r.row();
        assert_eq!((row.stop_reason.as_str(), row.quality.as_str(), row.text.as_str()), (stop, "incomplete", "words"));
        assert_eq!(end.state, State::Idle);
        assert!(r.spool_clean());
    }

    #[test]
    fn overflow_saves_for_review() {
        capture_failure(Then::Stop(Failure::Overflow), "overflow");
    }
    #[test]
    fn permission_revoked_saves_for_review() {
        capture_failure(Then::Revoke, "permission_revoked");
    }
    #[test]
    fn sleep_saves_for_review() {
        capture_failure(Then::Stop(Failure::Sleep), "sleep");
    }
    #[test]
    fn unsupported_format_is_a_failure_stop() {
        capture_failure(Then::Stop(Failure::Unsupported), "failure");
    }

    #[test]
    fn device_loss_still_inserts_what_was_captured() {
        for then in [Then::Lost, Then::Stop(Failure::DeviceLost)] {
            let mut r = rig(vec![Ok(Some(speak(16_000, then)))]);
            r.run();
            let row = r.row();
            assert_eq!((row.stop_reason.as_str(), row.quality.as_str(), row.delivery_state.as_str()), ("device_loss", "incomplete", "confirmed"));
            assert_eq!(*r.inserter.inserted.lock().unwrap(), ["words"]);
        }
    }

    #[test]
    fn a_capture_failure_with_no_text_says_why() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Stop(Failure::Overflow))))]);
        r.recognizer.answers = vec![Ok("  ")];
        let end = r.run();
        assert_eq!((end.state, end.status.as_str()), (State::Failed, "Recording stopped. Audio capture could not keep up. Try again after reducing system load."));
        assert_eq!(r.rows(), 0);
    }

    #[test]
    fn only_silence_is_no_speech() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
        r.recognizer.answers = vec![Ok("")];
        let end = r.run();
        assert_eq!((end.state, end.status.as_str()), (State::Idle, "No speech detected."));
        assert_eq!(r.rows(), 0);
    }

    #[test]
    fn denied_and_missing_microphones() {
        let mut r = rig(vec![]);
        r.mic.authorized = false;
        let end = r.run();
        assert_eq!(end.state, State::Failed);
        assert!(end.status.starts_with("Failed while requesting microphone access. Microphone access is not allowed."), "{}", end.status);
        assert!(!end.offers_microphones);

        let mut r = rig(vec![]);
        let end = r.run();
        assert_eq!((end.state, end.status.as_str(), end.offers_microphones), (State::Failed, "No microphone available", true));
        assert!(r.events.lock().unwrap().contains(&Event::Microphone("No microphone available".into())));
    }

    #[test]
    fn falls_through_candidates_once_each() {
        let mut r = rig(vec![Err(Failure::DeviceLost), Ok(None), Ok(Some(speak(16_000, Then::Release)))]);
        r.run();
        assert_eq!(r.mic.started.load(SeqCst), 3);
        assert_eq!(r.row().input_device_name.as_deref(), Some("Mic 2"));
    }

    #[test]
    fn none_respond_names_the_last() {
        let mut r = rig(vec![Err(Failure::DeviceLost), Ok(None)]);
        let end = r.run();
        assert_eq!((end.state, end.status.as_str(), end.offers_microphones), (State::Failed, "Mic 1 didn't respond", true));
        assert!(r.spool_clean());
    }

    #[test]
    fn a_release_while_connecting_is_a_cancel() {
        let mut r = rig(vec![Ok(None)]);
        r.coordinator.timing.connect_limit = Duration::from_secs(30);
        let control = r.control.clone();
        let release = thread::spawn(move || {
            thread::sleep(Duration::from_millis(20));
            control.release(false);
        });
        let end = r.run();
        release.join().unwrap();
        assert_eq!((end.state, end.status.as_str()), (State::Idle, "Cancelled"));
        assert_eq!(r.rows(), 0);
    }

    #[test]
    fn the_worker_dying_keeps_the_audio_waiting() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
        r.recognizer.answers = vec![Err(RecognizeFailure::Lost)];
        let end = r.run();
        assert_eq!((end.state, end.status.as_str()), (State::Idle, "The speech engine stopped. The dictation is waiting in History."));
        assert_eq!(r.rows(), 0);
        assert!(r.inserter.inserted.lock().unwrap().is_empty());
        let items = history::pending_items(&r.history.db);
        assert_eq!(items.len(), 1);
        assert_eq!((items[0].sample_count, items[0].last_failure.as_deref()), (16_000, Some("worker_unavailable")));
        assert_eq!(std::fs::metadata(r.root.join("PendingAudio").join(&items[0].audio_file)).unwrap().len(), 64_000);
        assert!(r.spool_clean());
    }

    #[test]
    fn a_failed_prefetch_gets_one_more_try_then_is_reported() {
        let mut r = rig(vec![Ok(Some(speak(WINDOW + 16_000, Then::Release)))]);
        r.recognizer.answers = vec![Err(RecognizeFailure::Job("failed".into()))];
        // The release follows the job's start, so it is a prefetch. Starting after capture would
        // make it the final pass, whose failure is final, as `no_text_from_a_failing_recognizer...`.
        r.mic.then_gate.store(false, SeqCst);
        r.recognizer.first_job_opens = Some(r.mic.then_gate.clone());
        r.run();
        let row = r.row();
        assert_eq!((row.quality.as_str(), row.delivery_state.as_str(), row.text.as_str()), ("complete", "confirmed", "words words"));
        assert_eq!(*r.recognizer.calls.lock().unwrap(), [WINDOW, WINDOW, 16_000]);

        let mut r = rig(vec![Ok(Some(speak(WINDOW + 16_000, Then::Release)))]);
        r.recognizer.answers = vec![Ok("first"), Err(RecognizeFailure::Job("failed".into()))];
        let end = r.run();
        let row = r.row();
        assert_eq!((row.quality.as_str(), row.delivery_state.as_str(), row.text.as_str()), ("incomplete", "not_attempted", "first"));
        assert_eq!(end.status, "Text saved and copied. Paste it with Command-V.");
    }

    #[test]
    fn no_text_from_a_failing_recognizer_is_a_failure() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
        r.recognizer.answers = vec![Err(RecognizeFailure::Job("failed".into()))];
        let end = r.run();
        assert_eq!((end.state, end.status.as_str()), (State::Failed, "Transcription failed. No text was produced."));
    }

    #[test]
    fn a_model_that_cannot_load_stops_recording() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Idle)))]);
        r.recognizer.prepare = Some("The speech model is unavailable. Verify the local model in Settings.".into());
        let end = r.run();
        assert_eq!((end.state, end.status.as_str()), (State::Failed, "Failed while loading the speech model. The speech model is unavailable. Verify the local model in Settings."));
        assert_eq!(r.rows(), 0);
        assert!(r.spool_clean());
    }

    #[test]
    fn a_tail_filler_stays_evidence_only() {
        assert!(is_tail_filler(" Yeah. ", 239_360, 1000));
        assert!(!is_tail_filler("Yeah.", 0, 1000), "the first window is speech");
        assert!(!is_tail_filler("Yeah.", 239_360, 48_000), "three seconds is speech");
        assert!(!is_tail_filler("Yeah right", 239_360, 1000));
        let mut r = rig(vec![Ok(Some(speak(WINDOW + 1000, Then::Release)))]);
        r.recognizer.answers = vec![Ok("Real words"), Ok("Yeah.")];
        r.run();
        assert_eq!(r.row().text, "Real words");
        assert_eq!(*r.recognizer.calls.lock().unwrap(), [WINDOW, 4_800], "the short tail is padded");
    }

    #[test]
    fn insertion_outcomes_reach_history_and_the_clipboard() {
        for (outcome, state, uncertain) in [(InsertOutcome::NotInserted, "not_inserted", false), (InsertOutcome::Uncertain, "uncertain", true)] {
            let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
            r.inserter.outcome = outcome;
            let end = r.run();
            assert_eq!(end.status, "Text saved and copied. Paste it with Command-V.");
            assert_eq!(r.row().delivery_state, state);
            assert_eq!(r.row().recovery_state, "needs_review");
            assert!(r.events.lock().unwrap().contains(&Event::Clipboard { uncertain }));
        }
    }

    #[test]
    fn no_field_means_the_clipboard() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
        r.inserter.target = None;
        r.run();
        assert_eq!(r.row().delivery_state, "not_attempted");
        assert_eq!(*r.inserter.copied.lock().unwrap(), ["words"]);
    }

    struct FakeRewriter(Arc<AtomicUsize>);
    impl Rewriter for FakeRewriter {
        fn rewrite(&mut self, _: &str, text: &str, started: &mut dyn FnMut(), _: &Arc<AtomicBool>) -> Rewritten {
            self.0.fetch_add(1, SeqCst);
            started();
            Rewritten::Notice { message: format!("kept {} bytes", text.len()), can_retry: true }
        }
    }

    #[test]
    fn a_bypass_skips_the_rewriter_and_a_notice_still_inserts() {
        let calls = Arc::new(AtomicUsize::new(0));
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::ReleaseBypass)))]);
        r.rewriter = Some(Box::new(FakeRewriter(calls.clone())));
        r.run();
        assert_eq!(calls.load(SeqCst), 0);

        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
        r.rewriter = Some(Box::new(FakeRewriter(calls.clone())));
        r.run();
        assert_eq!(calls.load(SeqCst), 1);
        assert!(r.states().contains(&State::Rewriting));
        assert_eq!(*r.inserter.inserted.lock().unwrap(), ["words"]);
        assert!(r.events.lock().unwrap().contains(&Event::Action { message: "kept 5 bytes".into(), can_retry: true, dictation: r.row().id }));
    }

    #[test]
    fn a_full_history_blocks_until_there_is_room() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release))), Ok(Some(speak(16_000, Then::Release)))]);
        r.history.free_bytes = Box::new(|| Some(0));
        let end = r.run();
        assert!(end.capacity_blocked);
        assert_eq!(end.state, State::Failed);
        assert!(end.status.starts_with("History is full."));
        assert_eq!(r.mic.started.load(SeqCst), 0, "the microphone never opens");
        assert!(r.spool_clean());
        let (before, _) = (r.mic.started.load(SeqCst), r.run());
        assert_eq!(r.mic.started.load(SeqCst), before, "blocked");
        r.history.free_bytes = Box::new(|| Some(100 << 30));
        r.coordinator.recheck_capacity(&mut r.history);
        assert!(r.coordinator.can_begin());
        assert_eq!(r.coordinator.snapshot().status, "History has space for another recording.");
    }

    /// A store whose writes fail on request.
    struct Flaky {
        inner: DbHistory,
        commit_fails: Arc<AtomicBool>,
        outcome_fails: Arc<AtomicBool>,
    }
    impl History for Flaky {
        fn new_id(&mut self) -> String {
            self.inner.new_id()
        }
        fn reserve(&mut self) -> Result<(), HistoryError> {
            self.inner.reserve()
        }
        fn vocabulary(&mut self) -> Result<Vocabulary, String> {
            self.inner.vocabulary()
        }
        fn commit(&mut self, d: &NewDictation) -> Result<i64, HistoryError> {
            if self.commit_fails.load(SeqCst) { Err(HistoryError::Store) } else { self.inner.commit(d) }
        }
        fn begin_attempt(&mut self, id: &str, revision: i64) -> Result<(String, i64), HistoryError> {
            self.inner.begin_attempt(id, revision)
        }
        fn record_outcome(&mut self, p: &PendingOutcome) -> Result<(), HistoryError> {
            if self.outcome_fails.load(SeqCst) { Err(HistoryError::Store) } else { self.inner.record_outcome(p) }
        }
        fn record_applied(&mut self, id: &str, changes: &[Change]) {
            self.inner.record_applied(id, changes)
        }
        fn keep_waiting(&mut self, w: &Waiting) -> Result<(), HistoryError> {
            self.inner.keep_waiting(w)
        }
        fn writable(&mut self) -> bool {
            self.inner.writable()
        }
    }

    fn flaky_run(r: &mut Rig, flaky: &mut Flaky) -> Snapshot {
        let control = r.control.clone();
        let mut deps = Deps { mic: &r.mic, inputs: &[], recognizer: &mut r.recognizer, rewriter: None, inserter: &r.inserter, history: flaky };
        r.coordinator.run(&mut deps, &control);
        r.coordinator.snapshot()
    }

    #[test]
    fn unsaved_text_blocks_until_retry_save() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
        let (commit, outcome) = (Arc::new(AtomicBool::new(true)), Arc::new(AtomicBool::new(false)));
        let mut flaky = Flaky { inner: store(&r.root), commit_fails: commit.clone(), outcome_fails: outcome };
        let end = flaky_run(&mut r, &mut flaky);
        assert_eq!((end.state, end.unsaved.as_deref(), end.status.as_str()), (State::Failed, Some("words"), "Text is unsaved. Retry save or Copy before quitting."));
        assert!(!r.coordinator.can_begin());
        assert!(!r.coordinator.retry_save(&mut flaky));
        assert_eq!(r.coordinator.snapshot().status, "Still unsaved. Check available disk space or Copy the text.");
        commit.store(false, SeqCst);
        assert!(r.coordinator.retry_save(&mut flaky));
        let end = r.coordinator.snapshot();
        assert_eq!((end.state, end.unsaved, end.status.as_str()), (State::Recovery, None, "Text saved for review."));
        assert!(r.coordinator.can_begin());
    }

    #[test]
    fn discarding_unsaved_text_unblocks() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
        let mut flaky = Flaky { inner: store(&r.root), commit_fails: Arc::new(AtomicBool::new(true)), outcome_fails: Arc::new(AtomicBool::new(false)) };
        flaky_run(&mut r, &mut flaky);
        r.coordinator.discard_unsaved();
        assert_eq!(r.coordinator.snapshot().status, "Unsaved text discarded.");
        assert!(r.coordinator.can_begin());
    }

    #[test]
    fn an_unwritten_outcome_blocks_until_retry_storage() {
        let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
        let outcome = Arc::new(AtomicBool::new(true));
        let mut flaky = Flaky { inner: store(&r.root), commit_fails: Arc::new(AtomicBool::new(false)), outcome_fails: outcome.clone() };
        let end = flaky_run(&mut r, &mut flaky);
        assert!(end.storage_blocked);
        assert_eq!(end.status, "Delivery status could not be saved. Retry storage before another dictation.");
        assert!(!r.coordinator.retry_storage(&mut flaky));
        assert_eq!(r.coordinator.snapshot().status, "Storage is still unavailable. Existing text remains saved.");
        outcome.store(false, SeqCst);
        assert!(r.coordinator.retry_storage(&mut flaky));
        assert_eq!(r.coordinator.snapshot().status, "Storage available. Saved text remains in history.");
        let id: String = flaky.inner.db.conn.query_row("SELECT id FROM transcriptions", [], |x| x.get(0)).unwrap();
        assert_eq!(history::get(&flaky.inner.db, &id).unwrap().unwrap().delivery_state, "confirmed");
    }

    #[test]
    fn a_new_coordinator_removes_what_a_crash_left() {
        let r = rig(vec![]);
        let stale = r.root.join("TemporaryAudio").join("old");
        std::fs::create_dir_all(&stale).unwrap();
        std::fs::write(stale.join("audio.f32"), b"x").unwrap();
        let c = Coordinator::new(r.root.join("TemporaryAudio"), r.root.join("PendingAudio"), Box::new(|_| {}));
        assert!(!stale.exists());
        assert!(c.can_begin());
    }

    #[test]
    fn the_delivery_delay_sets_the_tail() {
        assert_eq!(release_tail(Duration::from_millis(50)), None);
        assert_eq!(release_tail(Duration::from_millis(100)), Some(Duration::from_millis(125)));
        assert_eq!(release_tail(Duration::from_secs(9)), Some(Duration::from_millis(500)));
    }

    #[test]
    fn resampled_devices_reach_16k_in_the_spool() {
        let script = Script { rate: 48_000, samples: 48_000, then: Then::Release, delay_ns: 60_000_000 };
        let mut r = rig(vec![Ok(Some(script))]);
        r.run();
        let n = r.recognizer.calls.lock().unwrap()[0] as i64;
        assert!((n - 16_000).abs() <= 40, "{n}");
    }

    #[test]
    fn stop_reasons_store_swift_raw_values() {
        let all = [StopReason::KeyRelease, StopReason::DurationLimit, StopReason::Cancel, StopReason::Overflow, StopReason::DeviceLoss, StopReason::PermissionRevoked, StopReason::Sleep, StopReason::Failure];
        let raw: Vec<_> = all.iter().map(|r| r.raw()).collect();
        assert_eq!(raw, ["key_release", "duration_limit", "cancel", "overflow", "device_loss", "permission_revoked", "sleep", "failure"]);
    }

    /// Against a real flowd on loopback with a fake speech worker: `dictation::remote` end to end.
    #[cfg(unix)]
    mod remote_dictation {
        use super::super::super::remote::Served;
        use super::super::super::rewrite::{Done, Live, Plan, can_retry, retry};
        use super::super::super::retrier::{Retrier, next_delay_ms, recognize_locally};
        use super::*;
        use crate::remote::enrollment::Enrollment;
        use crate::remote::enrollment::flowd_tests::{client, token};
        use crate::remote::pool::Pool;
        use crate::settings::test_flowd::Flowd;
        use crate::settings::RewriteSettings;

        const SETTLE: Duration = Duration::from_secs(30);

        struct Server {
            flowd: Option<Arc<Flowd>>,
            enrollment: Arc<Enrollment>,
            pool: Arc<Pool>,
        }

        impl Server {
            fn flowd(&self) -> &Arc<Flowd> {
                self.flowd.as_ref().unwrap()
            }
        }

        fn server() -> Server {
            let flowd = Arc::new(Flowd::start());
            let (e, _) = client(&flowd, &flowd.remote);
            e.pair(&token(&flowd)).expect("pairs");
            let enrollment = Arc::new(e);
            wait_for_worker(&enrollment);
            let pool = Arc::new(Enrollment::pool(&enrollment));
            Server { flowd: Some(flowd), enrollment, pool }
        }

        /// flowd listens before its supervisor has the worker's `ready`, and refuses dictations until
        /// then. Also `busy`, until a cancelled dictation's job has ended there.
        fn wait_for_worker(enrollment: &Enrollment) {
            use crate::remote::channel::ServerMessage;
            let began = Instant::now();
            loop {
                let mut channel = enrollment.session_channel().unwrap();
                channel.send(json!({"type": "dictation_start", "op": 1, "format": "f32le", "sample_rate": 16_000})).unwrap();
                match channel.receive().unwrap() {
                    ServerMessage::Other(m) if m["type"] == "dictation_accepted" => {
                        channel.send(json!({"type": "dictation_cancel", "op": 1})).unwrap();
                        // flowd frees the user's one dictation before it answers.
                        let _ = channel.receive().unwrap();
                        return;
                    }
                    ServerMessage::Error { code } if matches!(code.as_str(), "worker_unavailable" | "busy") && began.elapsed() < SETTLE => std::thread::sleep(Duration::from_millis(20)),
                    other => panic!("{other:?}"),
                }
            }
        }

        fn run(r: &mut Rig, s: &Server, threshold: Duration, local_allowed: bool) -> Snapshot {
            let control = r.control.clone();
            let mut rewriter = r.rewriter.take();
            let mut served = Served::new(s.enrollment.clone(), s.pool.clone(), threshold, &mut r.recognizer, local_allowed);
            let mut deps = Deps { mic: &r.mic, inputs: &[], recognizer: &mut served, rewriter: rewriter.as_mut().map(|x| &mut **x as &mut dyn Rewriter), inserter: &r.inserter, history: &mut r.history };
            r.coordinator.run(&mut deps, &control);
            r.coordinator.snapshot()
        }

        /// A store a second connection can open, as the rewriter and the retrier do.
        fn on_disk(mut r: Rig) -> Rig {
            std::fs::create_dir_all(&r.root).unwrap();
            r.history.db = Db::open_or_create(&r.root.join("h.sqlite")).unwrap();
            r
        }

        fn waiting(r: &Rig) -> Vec<history::PendingItem> {
            history::pending_items(&r.history.db)
        }

        fn statuses(r: &Rig) -> Vec<String> {
            r.events.lock().unwrap().iter().filter_map(|e| if let Event::Changed(s) = e { Some(s.status.clone()) } else { None }).collect()
        }

        fn local_calls(r: &Rig) -> usize {
            r.recognizer.calls.lock().unwrap().len()
        }

        /// A second channel holding this user's one dictation open, so the next is refused `busy`.
        fn hold_the_dictation(s: &Server) -> crate::remote::channel::Channel {
            let mut channel = s.enrollment.session_channel().unwrap();
            channel.send(json!({"type": "dictation_start", "op": 1, "format": "f32le", "sample_rate": 16_000})).unwrap();
            match channel.receive().unwrap() {
                crate::remote::channel::ServerMessage::Other(m) => assert_eq!(m["type"], "dictation_accepted"),
                other => panic!("{other:?}"),
            }
            channel
        }

        // parity: HIST-075
        #[test]
        fn windows_stream_to_completion_and_the_channel_is_parked_for_the_rewrite() {
            let s = server();
            // Two whole windows and a tail.
            let mut r = rig(vec![Ok(Some(speak(2 * WINDOW + 5_000, Then::Release)))]);
            let end = run(&mut r, &s, SETTLE, true);
            assert_eq!(end.state, State::Idle, "{}", end.status);
            let row = r.row();
            assert_eq!(row.text, "hello world hello world hello world");
            assert_eq!((row.recognition_path.as_str(), row.server_failure.as_deref()), ("server", None));
            assert_eq!(*r.inserter.inserted.lock().unwrap(), [row.text.clone()]);
            assert_eq!(local_calls(&r), 0, "the local model never ran");
            assert!(statuses(&r).iter().any(|x| x == "Transcribing on your server…"));
            let detail: String = r.history.db.conn.query_row("SELECT detail_json FROM transcription_quality", [], |x| x.get(0)).unwrap();
            assert!(detail.contains("fake-model"), "the server's model is the evidence");
            assert!(r.spool_clean());
            let (_channel, op) = s.pool.lease(crate::remote::pool::Role::Interactive).unwrap();
            assert_eq!(op, 2, "the dictation's channel, next op");
        }

        #[test]
        fn server_busy_falls_back_to_local_from_sample_zero() {
            let s = server();
            let _held = hold_the_dictation(&s);
            let mut r = rig(vec![Ok(Some(speak(WINDOW + 100, Then::Release)))]);
            let end = run(&mut r, &s, SETTLE, true);
            assert_eq!(end.state, State::Idle, "{}", end.status);
            let row = r.row();
            assert_eq!((row.recognition_path.as_str(), row.server_failure.as_deref()), ("local_after_server_failure", Some("busy")));
            assert_eq!(*r.recognizer.calls.lock().unwrap(), [WINDOW, 4_800], "every window, recognized here");
        }

        #[test]
        fn past_the_threshold_it_falls_back_and_the_slow_answer_is_ignored() {
            let s = server();
            s.flowd().worker_delay(3_000);
            let mut r = rig(vec![Ok(Some(speak(20_000, Then::Release)))]);
            let began = Instant::now();
            let end = run(&mut r, &s, Duration::from_millis(400), true);
            assert_eq!(end.state, State::Idle, "{}", end.status);
            assert!(began.elapsed() < Duration::from_millis(2_900), "didn't wait for the worker: {:?}", began.elapsed());
            let row = r.row();
            assert_eq!((row.recognition_path.as_str(), row.server_failure.as_deref()), ("local_after_server_failure", Some("timeout")));
            assert_eq!(local_calls(&r), 1);
        }

        // parity: HIST-075
        #[test]
        fn revoked_with_no_local_model_keeps_the_audio_and_marks_the_device() {
            let s = server();
            s.flowd().revoke_newest_device();
            // The token still in hand is refused only when refresh runs, so spend it first.
            let _ = s.enrollment.access_token_expired();
            let mut r = rig(vec![Ok(Some(speak(20_000, Then::Release)))]);
            run(&mut r, &s, SETTLE, false);
            assert_eq!(r.rows(), 0, "nothing inserted or saved as text");
            let items = waiting(&r);
            assert_eq!(items.len(), 1, "{:?}", statuses(&r));
            assert!(matches!(items[0].last_failure.as_deref(), Some("revoked" | "unauthorized")), "{:?}", items[0].last_failure);
            assert_eq!(s.enrollment.settings().state, "revoked");
            let bytes = std::fs::metadata(r.root.join("PendingAudio").join(&items[0].audio_file)).unwrap().len();
            assert_eq!(bytes, 80_000, "every sample kept");
            assert_eq!(statuses(&r).last().unwrap(), "Your server is unavailable. The dictation is waiting in History and will be retried.");
        }

        #[test]
        fn a_worker_failure_is_a_server_failure_and_a_full_queue_offers_the_audio() {
            let s = server();
            s.flowd().worker_fails(true);
            let mut r = rig(vec![Ok(Some(speak(20_000, Then::Release)))]);
            for i in 0..20 {
                r.history.db.conn.execute("INSERT INTO pending_remote_dictations (id,audio_file,sample_count,created_at,attempts,next_attempt_at) VALUES (?,?,1,1,0,9)", rusqlite::params![format!("x{i}"), format!("x{i}.f32")]).unwrap();
            }
            run(&mut r, &s, SETTLE, false);
            assert_eq!(waiting(&r).len(), 20);
            let offered = r.events.lock().unwrap().iter().find_map(|e| if let Event::AudioOffered { audio } = e { Some(audio.clone()) } else { None }).unwrap_or_else(|| panic!("nothing offered: {:?}", statuses(&r)));
            assert_eq!(std::fs::metadata(offered).unwrap().len(), 80_000, "the recording survives the full queue");
            assert_eq!(statuses(&r).last().unwrap(), "This recording could not be kept for your server. Its audio was offered to you.");
        }

        #[test]
        fn a_cancel_while_the_server_works_saves_nothing_and_a_sleep_abandons() {
            let s = server();
            s.flowd().worker_delay(1_500);
            let mut r = rig(vec![Ok(Some(speak(20_000, Then::Cancel)))]);
            run(&mut r, &s, SETTLE, true);
            assert_eq!((r.rows(), waiting(&r).len()), (0, 0));
            assert!(r.spool_clean());

            s.flowd().worker_delay(0);
            // Otherwise the next dictation can be refused `busy` before it sees the sleep.
            wait_for_worker(&s.enrollment);
            let mut r = rig(vec![Ok(Some(speak(20_000, Then::Stop(Failure::Sleep))))]);
            run(&mut r, &s, SETTLE, false);
            let items = waiting(&r);
            assert_eq!(items.len(), 1, "the audio already captured waits");
            assert_eq!(items[0].last_failure.as_deref(), Some("unreachable"));
        }

        #[test]
        fn switched_off_during_the_recording_finishes_locally() {
            let s = server();
            s.enrollment.turn_off();
            let mut r = rig(vec![Ok(Some(speak(20_000, Then::Release)))]);
            run(&mut r, &s, SETTLE, true);
            let row = r.row();
            assert_eq!(row.recognition_path, "local");
            assert_eq!(local_calls(&r), 1);
        }

        // ---- The retrier ----

        fn retrier(r: &Rig, s: &Server, clock: Arc<std::sync::atomic::AtomicI64>) -> Retrier {
            let db = Db::open_or_create(&r.root.join("h.sqlite")).unwrap();
            let mut retrier = Retrier::new(db, r.root.join("PendingAudio"), s.enrollment.clone(), Arc::new(AtomicBool::new(false)));
            retrier.now = Box::new(move || clock.load(SeqCst));
            retrier.threshold = SETTLE;
            retrier
        }

        /// One kept recording, due now on `clock`.
        fn kept(s: &Server, clock: &Arc<std::sync::atomic::AtomicI64>) -> Rig {
            s.flowd().worker_fails(true);
            let mut r = on_disk(rig(vec![Ok(Some(speak(20_000, Then::Release)))]));
            run(&mut r, s, SETTLE, false);
            s.flowd().worker_fails(false);
            clock.store(waiting(&r)[0].next_attempt_at, SeqCst);
            r
        }

        // parity: HIST-080
        #[test]
        fn the_retrier_backs_off_recovers_for_review_and_yields_to_a_live_dictation() {
            let s = server();
            let clock = Arc::new(std::sync::atomic::AtomicI64::new(0));
            let r = kept(&s, &clock);
            let id = waiting(&r)[0].id.clone();
            let created = waiting(&r)[0].created_at;
            let mut retry = retrier(&r, &s, clock.clone());

            // A live dictation: the row stays due, uncounted.
            retry.live.store(true, SeqCst);
            assert_eq!(retry.run_due(), 0);
            assert_eq!(waiting(&r)[0].attempts, 0);
            retry.live.store(false, SeqCst);

            // A failed try counts, and backs off.
            s.flowd().worker_fails(true);
            let at = clock.load(SeqCst);
            assert_eq!(retry.run_due(), 0);
            assert_eq!(waiting(&r)[0].attempts, 1);
            assert_eq!(waiting(&r)[0].next_attempt_at, at + 30_000);
            assert_eq!(retry.run_due(), 0, "not due");
            assert_eq!(waiting(&r)[0].attempts, 1);
            s.flowd().worker_fails(false);

            clock.fetch_add(30_000, SeqCst);
            assert_eq!(retry.run_due(), 1);
            assert!(waiting(&r).is_empty());
            let row = r.row();
            assert_eq!((row.id.as_str(), row.created_at), (id.as_str(), created));
            assert_eq!((row.recognition_path.as_str(), row.server_failure.as_deref(), row.recovery_state.as_str()), ("server", Some("pending_retry"), "needs_review"));
            assert!(r.inserter.inserted.lock().unwrap().is_empty(), "a retry never inserts");
            assert_eq!(std::fs::read_dir(r.root.join("PendingAudio")).unwrap().count(), 0, "audio removed with its row");
            assert_eq!([next_delay_ms(1), next_delay_ms(2), next_delay_ms(3), next_delay_ms(9)], [30_000, 120_000, 600_000, 600_000]);
        }

        // parity: HIST-078
        #[test]
        fn past_a_day_or_unreadable_a_row_waits_for_the_user_and_recognizes_locally() {
            let s = server();
            let clock = Arc::new(std::sync::atomic::AtomicI64::new(0));
            let mut r = kept(&s, &clock);
            let item = waiting(&r)[0].clone();
            let mut retry = retrier(&r, &s, clock.clone());
            let needed = Arc::new(Mutex::new(vec![]));
            let sink = needed.clone();
            retry.decision_needed = Box::new(move |id| sink.lock().unwrap().push(id.to_string()));
            clock.store(item.created_at + history::PENDING_MAX_AGE_MS, SeqCst);
            assert_eq!(retry.run_due(), 0);
            assert_eq!(waiting(&r)[0].next_attempt_at, i64::MAX);
            assert_eq!(retry.run_due(), 0);
            assert_eq!(*needed.lock().unwrap(), [item.id.clone()], "asked once");

            let dir = r.root.join("PendingAudio");
            assert_eq!(recognize_locally(&r.history.db, &dir, &item.id, &mut r.recognizer), Ok(true));
            assert!(waiting(&r).is_empty());
            let row = r.row();
            assert_eq!(row.recognition_path, "local_after_server_failure");
            assert_eq!(row.created_at, item.created_at);
            assert_eq!(recognize_locally(&r.history.db, &dir, &item.id, &mut r.recognizer), Ok(false), "gone");
        }

        // ---- Rewrites ----

        fn plan(origin: &str, channel: Option<Arc<Pool>>, secret: Option<&str>) -> Plan {
            let settings = if channel.is_some() { RewriteSettings::routed_to_remote(origin.into()) } else { RewriteSettings { origin: origin.into(), credential_present: secret.is_some(), ..Default::default() } };
            Plan { enabled: true, mode: "clean", settings, timeout: Duration::from_secs(10), channel, secret: secret.map(String::from) }
        }

        fn saved_dictation(r: &mut Rig) -> String {
            let mut recognizer = FakeRecognizer::default();
            std::mem::swap(&mut recognizer, &mut r.recognizer);
            r.run();
            r.row().id
        }

        // parity: PILL-088..PILL-091
        #[test]
        fn a_rewrite_answers_over_http_and_over_the_channel_and_each_failure_has_its_words() {
            let s = server();
            let f = s.flowd().clone();
            let run_plan = |plan: Plan| {
                let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
                let id = saved_dictation(&mut r);
                let done = super::super::super::rewrite::run(&r.history.db, &plan, &id, "hello world", &mut || {}, &Arc::new(AtomicBool::new(false)));
                let attempt: Option<(String, Option<String>)> = r.history.db.conn.query_row("SELECT state,failure_category FROM rewrite_attempts", [], |x| Ok((x.get(0)?, x.get(1)?))).ok();
                (done, attempt)
            };
            let (done, attempt) = run_plan(plan(&f.rewrite, None, Some(&f.token)));
            assert!(matches!(done, Done::Text { ref text, .. } if text == "Hello world."));
            assert_eq!(attempt.unwrap().0, "succeeded");
            let (done, attempt) = run_plan(plan(&f.remote, Some(s.pool.clone()), None));
            assert!(matches!(done, Done::Text { ref text, .. } if text == "Hello world."), "over the channel");
            assert_eq!(attempt.unwrap().0, "succeeded");

            let category = |p: Plan| match run_plan(p) {
                (Done::Failed(c), _) => c,
                _ => panic!("expected a failure"),
            };
            assert_eq!(category(plan(&f.down, None, Some(&f.token))), "server_unreachable");
            assert_eq!(category(plan(&f.rewrite, None, Some("wrong"))), "authentication_failed");
            assert_eq!(category(plan(&f.no_backend, None, Some(&f.token))), "backend_unavailable");
            let mut short = plan(&f.remote, Some(s.pool.clone()), None);
            short.timeout = Duration::ZERO;
            assert_eq!(category(short), "timeout");
            assert_eq!(history::live_rewrite_notice("timeout"), "Rewrite took too long. Original text inserted.");
            assert!(!can_retry("attempt_limit") && can_retry("timeout"));
        }

        /// A scripted server for what flowd won't say: each reply maps to its category.
        #[test]
        fn channel_replies_map_to_rewrite_categories() {
            use crate::remote::scripted::{Reply, Script};
            use crate::remote::channel::{Channel, Purpose, Transports};
            use crate::remote::pool::Role;
            // A plain-HTTP server with no stored key is fine over the sealed channel, and not over HTTP.
            let db = Db::memory();
            let routed = RewriteSettings::routed_to_remote("http://10.0.0.1:8080".into());
            let plain = RewriteSettings { via_channel: false, ..routed.clone() };
            assert!(matches!(history::admit_rewrite(&db, "d", "hi", "clean", true, &plain, None), history::Admission::Refused("insecure_endpoint_blocked")));
            assert!(!matches!(history::admit_rewrite(&db, "d", "hi", "clean", true, &routed, None), history::Admission::Refused("insecure_endpoint_blocked" | "missing_credential")));
            let attempt = "a1";
            let request = history::RewriteRequest { dictation: "d".into(), attempt: attempt.into(), mode: "clean", text: "hello".into(), origin: "http://x".into(), context: None };
            let reply = |replies: Vec<Reply>| {
                let script = Arc::new(Script::new([vec![Reply::ready()], replies].concat()));
                let key = script.public_key();
                let opener = script.clone();
                let pool = Pool::new(Box::new(move || {
                    let mut channel = Channel::new(opener.open("ws://x").map_err(|_| crate::remote::channel::ChannelError::Closed)?, &key).map_err(|_| crate::remote::channel::ChannelError::Protocol)?;
                    channel.open(Purpose::Session, None)?;
                    Ok(channel)
                }), Box::new(|| Duration::ZERO));
                let _ = Role::Interactive;
                history::send_rewrite_over_channel(&pool, &request, Duration::from_secs(2), &AtomicBool::new(false))
            };
            let event = |event: Value| Reply::Json(json!({"schema_version": 1, "type": "rewrite_event", "op": 1, "event": event}));
            let result = |text: &str, id: &str| json!({"event": "result", "schema_version": 1, "request_id": id, "mode": "clean", "text": text, "server": {"name": "f", "version": "1"}, "backend": {"kind": "k", "model": "m"}, "prompt_version": 1, "shield": {"version": 1, "placeholders": 0, "restored": 0}, "timing": {}});
            assert_eq!(reply(vec![event(result("Hello.", attempt))]).unwrap().text, "Hello.");
            assert_eq!(reply(vec![event(result("Hello.", "other"))]), Err("request_mismatch"));
            assert_eq!(reply(vec![event(result("  ", attempt))]), Err("empty_response"));
            assert_eq!(reply(vec![event(json!({"event": 1}))]), Err("malformed_response"));
            assert_eq!(reply(vec![Reply::error("busy")]), Err("backend_unavailable"));
            assert_eq!(reply(vec![Reply::error("revoked")]), Err("authentication_failed"));
            assert_eq!(reply(vec![Reply::error("unsupported_version")]), Err("unsupported_schema_version"));
            assert_eq!(reply(vec![Reply::error("invalid_message")]), Err("server_validation_failed"));
            assert_eq!(reply(vec![Reply::Close(1006)]), Err("server_unreachable"));
            assert_eq!(reply(vec![Reply::Garbage]), Err("malformed_response"));
            assert_eq!(reply(vec![Reply::Silent]), Err("timeout"));
        }

        // parity: PILL-092 PILL-093
        #[test]
        fn a_live_rewrite_inserts_its_text_a_failure_inserts_the_original_and_retry_only_stores() {
            let s = server();
            let f = s.flowd().clone();
            let mut r = on_disk(rig(vec![Ok(Some(speak(16_000, Then::Release)))]));
            let db = Db::open_or_create(&r.root.join("h.sqlite")).unwrap();
            r.rewriter = Some(Box::new(Live { db, plan: plan(&f.remote, Some(s.pool.clone()), None) }));
            run(&mut r, &s, SETTLE, false);
            assert_eq!(*r.inserter.inserted.lock().unwrap(), ["Hello world."]);
            assert!(r.states().contains(&State::Rewriting));

            let mut r = on_disk(rig(vec![Ok(Some(speak(16_000, Then::Release)))]));
            let db = Db::open_or_create(&r.root.join("h.sqlite")).unwrap();
            r.rewriter = Some(Box::new(Live { db, plan: plan(&f.down, None, Some(&f.token)) }));
            r.run();
            assert_eq!(*r.inserter.inserted.lock().unwrap(), ["words"], "the original goes in");
            let id = r.row().id;
            assert!(r.events.lock().unwrap().contains(&Event::Action { message: "Rewrite server unreachable. Original text inserted.".into(), can_retry: true, dictation: id.clone() }));

            assert_eq!(retry(&r.history.db, &plan(&f.rewrite, None, Some(&f.token)), &id), None);
            let (state, input): (String, String) = r.history.db.conn.query_row("SELECT state,input_text FROM rewrite_attempts ORDER BY ordinal DESC LIMIT 1", [], |x| Ok((x.get(0)?, x.get(1)?))).unwrap();
            assert_eq!((state.as_str(), input.as_str()), ("succeeded", "words"), "stored from the first attempt's input");
            assert_eq!(r.inserter.inserted.lock().unwrap().len(), 1, "a retry inserts nothing");
            assert_eq!(retry(&r.history.db, &plan(&f.down, None, Some(&f.token)), &id), Some(("Rewrite server unreachable.".into(), true)));
        }

        /// Escape during the rewrite stops the rewrite only.
        #[test]
        fn escape_during_a_rewrite_keeps_the_dictation() {
            struct Waits;
            impl Rewriter for Waits {
                fn rewrite(&mut self, _: &str, _: &str, started: &mut dyn FnMut(), cancel: &Arc<AtomicBool>) -> Rewritten {
                    started();
                    while !cancel.load(SeqCst) {
                        thread::sleep(Duration::from_millis(1));
                    }
                    Rewritten::NotEligible
                }
            }
            let mut r = rig(vec![Ok(Some(speak(16_000, Then::Release)))]);
            r.rewriter = Some(Box::new(Waits));
            let control = r.control.clone();
            let canceller = thread::spawn({
                let events = r.events.clone();
                move || loop {
                    if events.lock().unwrap().iter().any(|e| matches!(e, Event::Changed(s) if s.state == State::Rewriting)) {
                        control.cancel();
                        return;
                    }
                    thread::sleep(Duration::from_millis(1));
                }
            });
            r.run();
            canceller.join().unwrap();
            assert_eq!(*r.inserter.inserted.lock().unwrap(), ["words"]);
            assert!(!r.control.cancelled());
        }

        /// What a scripted server does around the restart rules.
        #[test]
        fn a_lost_channel_restarts_once_from_sample_zero_and_a_stall_times_out() {
            use crate::remote::enrollment::{IdentityProvider, Parts, SignIn, system_now};
            use crate::remote::scripted::{Reply, Script};
            use crate::remote::{MemoryDeviceKeys, MemorySecrets, Secrets, Unavailable};
            struct NoSignIn;
            impl SignIn for NoSignIn {
                fn sign_in(&self, _: IdentityProvider, _: &str) -> Result<String, Unavailable> {
                    Err(Unavailable("no"))
                }
            }
            let accepted = Reply::Json(json!({"schema_version": 1, "type": "dictation_accepted", "op": 1, "window_samples": WINDOW, "model": {"engine": "e", "model_id": "m", "model_revision": "1", "manifest_hash": "h", "sdk": "s", "worker_build": "b"}}));
            let window = Reply::Json(json!({"schema_version": 1, "type": "window_result", "op": 1, "index": 0, "sample_start": 0, "sample_count": 20_000, "text": "from the second try", "tokens": [], "boost_hints": [], "recognition_ms": 1}));
            let complete = Reply::Json(json!({"schema_version": 1, "type": "dictation_complete", "op": 1, "windows": 1}));
            let enrolled = |replies: Vec<Reply>| {
                let script = Script::new(replies);
                let (counters, key) = (script.counters(), script.public_key());
                let secrets = Arc::new(MemorySecrets::default());
                secrets.write("server-key", &key).unwrap();
                secrets.write("refresh-token", b"refresh").unwrap();
                let keys = Arc::new(MemoryDeviceKeys::default());
                let (handle, _) = crate::remote::DeviceKeys::create(&*keys).unwrap();
                secrets.write("device-key", &handle).unwrap();
                let e = Enrollment::new(Parts { secrets, keys, sign_in: Arc::new(NoSignIn), identity: Arc::new(crate::remote::enrollment::HttpIdentity), transports: Arc::new(script), now: Box::new(system_now), device_name: "T".into() });
                e.load(crate::remote::enrollment::RemoteSettings { origin: Some("http://127.0.0.1:9".into()), state: "approved".into(), notice: None });
                let e = Arc::new(e);
                (Server { flowd: None, pool: Arc::new(Enrollment::pool(&e)), enrollment: e }, counters)
            };
            // Lost before key release: it reconnects once and sends everything again from sample 0.
            let (s, counters) = enrolled(vec![Reply::ready(), Reply::tokens("a", "r"), Reply::ready(), Reply::Close(1006), Reply::ready(), accepted.clone(), Reply::After("dictation_end"), window, complete]);
            let spool = std::env::temp_dir().join(format!("flow-stream-{}.f32", std::process::id()));
            std::fs::write(&spool, vec![0u8; 80_000]).unwrap();
            let stream = crate::dictation::remote::Stream::start(s.enrollment.clone(), crate::dictation::spool::Reader::open(&spool).unwrap(), None, SETTLE);
            stream.recorded(20_000);
            let began = Instant::now();
            while counters.opened() < 3 || counters.messages().iter().filter_map(|m| m["audio_samples"].as_u64()).sum::<u64>() < 20_000 {
                assert!(began.elapsed() < SETTLE, "{} opened, {:?}", counters.opened(), counters.messages());
                thread::sleep(Duration::from_millis(2));
            }
            stream.release(20_000);
            let completed = loop {
                if let Some(result) = stream.poll(Duration::from_millis(20)) {
                    break result.ok().expect("completes");
                }
            };
            assert_eq!(completed.windows[0].2, "from the second try");
            assert_eq!(counters.messages().iter().filter(|m| m["type"] == "dictation_end").count(), 1);
            std::fs::remove_file(spool).unwrap();

            let (s, _) = enrolled(vec![Reply::ready(), Reply::tokens("a", "r"), Reply::ready(), accepted.clone(), Reply::Silent]);
            let mut r = rig(vec![Ok(Some(speak(20_000, Then::Release)))]);
            run(&mut r, &s, Duration::from_millis(100), false);
            assert_eq!(waiting(&r)[0].last_failure.as_deref(), Some("timeout"));

            let bad = Reply::Json(json!({"schema_version": 1, "type": "dictation_complete", "op": 1, "windows": 7}));
            let (s, _) = enrolled(vec![Reply::ready(), Reply::tokens("a", "r"), Reply::ready(), accepted, Reply::After("dictation_end"), bad]);
            let mut r = rig(vec![Ok(Some(speak(20_000, Then::Release)))]);
            run(&mut r, &s, SETTLE, false);
            assert_eq!(waiting(&r)[0].last_failure.as_deref(), Some("protocol_error"));
        }
    }
}
