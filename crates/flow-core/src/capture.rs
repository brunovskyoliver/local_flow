//! Meeting capture over `Source`-like `Backend` and `Encoder` traits: `MeetingCoordinator`,
//! `MeetingTrackWorker` and `AudioCaptureRing` in Rust, writing the same rows and files (ADR 0015).
//! A segment owns one source, one ring, one encoder and one writer thread; a pause, a resume or a
//! device change ends them and starts new ones. The capture thread only copies into the ring, so a
//! slow disk costs counted drops, never a blocked callback, and nothing grows past two seconds.
use crate::db::Db;
use crate::history::now_ms;
use crate::meetings::{failure_reason_text, recompute_durations, track_totals, truncate_and_rename};
use rusqlite::params;
use std::collections::VecDeque;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

pub const SAMPLE_RATE: u64 = 48_000;
/// AAC-LC: one frame is 1024 samples per channel.
pub const AAC_FRAME: usize = 1024;
const RING_SECONDS: usize = 2;
/// Lateness on the host clock under this is scheduling jitter, not a gap.
const GAP_TOLERANCE_FRAMES: u64 = SAMPLE_RATE / 10;
/// A clock jump further than this is a broken clock, not a long quiet stretch.
const MAX_GAP_FRAMES: u64 = 24 * 3600 * SAMPLE_RATE;
const MAX_ADTS_FRAME: usize = 8191;
const WORKER_TICK: Duration = Duration::from_millis(40);
const SYNC_EVERY: Duration = Duration::from_secs(5);
const RECORDER_TICK: Duration = Duration::from_millis(250);
const MAX_GAP_ENTRIES: usize = 64;

/// A schema `failure_reason`.
pub type Reason = &'static str;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Microphone,
    System,
}
impl Kind {
    pub const ALL: [Kind; 2] = [Kind::Microphone, Kind::System];
    pub fn name(self) -> &'static str {
        if self == Kind::Microphone { "microphone" } else { "system" }
    }
    fn file_prefix(self) -> &'static str {
        if self == Kind::Microphone { "mic" } else { "system" }
    }
    /// `encodedChannels`: speech is mono, what the computer plays stays stereo.
    pub fn channels(self) -> usize {
        if self == Kind::Microphone { 1 } else { 2 }
    }
}

/// Fixed capacity. A packet that doesn't fit is dropped whole and counted, as `AudioCaptureRing.c`
/// does with `dropOnOverflow`, and `pop` plays silence for it so the track keeps its timeline.
pub struct Ring {
    channels: usize,
    capacity: usize,
    inner: Mutex<RingInner>,
    dropped: AtomicU64,
}
#[derive(Default)]
struct RingInner {
    samples: VecDeque<i16>,
    /// (frame position in the accepted stream, frames lost there), oldest first.
    gaps: VecDeque<(u64, u64)>,
    accepted: u64,
    popped: u64,
}
impl RingInner {
    fn add_gap(&mut self, frames: u64) {
        let full = self.gaps.len() >= MAX_GAP_ENTRIES;
        match self.gaps.back_mut() {
            Some(last) if last.0 == self.accepted || full => last.1 += frames,
            _ => self.gaps.push_back((self.accepted, frames)),
        }
    }
}
impl Ring {
    pub fn new(channels: usize) -> Ring {
        let capacity = SAMPLE_RATE as usize * RING_SECONDS * channels;
        let inner = RingInner { samples: VecDeque::with_capacity(capacity), gaps: VecDeque::with_capacity(MAX_GAP_ENTRIES), ..Default::default() };
        Ring { channels, capacity, inner: Mutex::new(inner), dropped: AtomicU64::new(0) }
    }
    pub fn dropped_frames(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
    /// Interleaved samples, called from the capture thread. False when dropped.
    pub fn push(&self, samples: &[i16]) -> bool {
        let frames = (samples.len() / self.channels) as u64;
        let mut inner = self.inner.lock().unwrap();
        if inner.samples.len() + samples.len() > self.capacity {
            inner.add_gap(frames);
            self.dropped.fetch_add(frames, Ordering::Relaxed);
            return false;
        }
        inner.samples.extend(samples);
        inner.accepted += frames;
        true
    }
    /// Audio the source itself lost. Only that counts as a drop, not a quiet device sending nothing.
    pub fn gap(&self, frames: u64, lost: bool) {
        self.inner.lock().unwrap().add_gap(frames);
        if lost {
            self.dropped.fetch_add(frames, Ordering::Relaxed);
        }
    }
    /// Appends up to `max_frames` of audio and silence, and says how many frames.
    pub fn pop(&self, out: &mut Vec<i16>, max_frames: usize) -> usize {
        let mut inner = self.inner.lock().unwrap();
        let mut left = max_frames as u64;
        while left > 0 {
            let popped = inner.popped;
            if let Some(gap) = inner.gaps.front_mut().filter(|g| g.0 <= popped) {
                let silence = gap.1.min(left);
                gap.1 -= silence;
                left -= silence;
                if gap.1 == 0 {
                    inner.gaps.pop_front();
                }
                out.resize(out.len() + silence as usize * self.channels, 0);
                continue;
            }
            let until_gap = inner.gaps.front().map_or(u64::MAX, |g| g.0 - popped);
            let take = left.min(until_gap).min((inner.samples.len() / self.channels) as u64);
            if take == 0 {
                break;
            }
            out.extend(inner.samples.drain(..take as usize * self.channels));
            inner.popped += take;
            left -= take;
        }
        max_frames - left as usize
    }
}

/// One capture packet: 48 kHz, 16-bit, interleaved stereo.
pub struct Packet<'a> {
    pub stereo: &'a [i16],
    /// When its first sample was captured, on the host clock. An empty packet just marks the time.
    pub qpc_ns: Option<u64>,
    pub silent: bool,
    /// The device reports lost audio before this packet.
    pub discontinuity: bool,
}

/// The capture thread's end of a segment. It holds a track to the host clock: time that passed with
/// no audio, because a device glitched or a quiet endpoint sent nothing, becomes silence. Both
/// tracks stay aligned over hours this way, whatever a device's own frame counter does.
pub struct Feed {
    ring: Arc<Ring>,
    first_ns: Option<u64>,
    produced: u64,
    scratch: Vec<i16>,
    host_start: Arc<AtomicU64>,
}
impl Feed {
    fn new(ring: Arc<Ring>, host_start: Arc<AtomicU64>) -> Feed {
        Feed { ring, first_ns: None, produced: 0, scratch: Vec::with_capacity(SAMPLE_RATE as usize), host_start }
    }
    pub fn push(&mut self, packet: &Packet) {
        let frames = (packet.stereo.len() / 2) as u64;
        if let Some(ns) = packet.qpc_ns {
            let first = *self.first_ns.get_or_insert(ns);
            let _ = self.host_start.compare_exchange(0, ns, Ordering::Relaxed, Ordering::Relaxed);
            let expected = (ns.saturating_sub(first) as u128 * SAMPLE_RATE as u128 / 1_000_000_000) as u64;
            let late = expected.saturating_sub(self.produced);
            if late >= GAP_TOLERANCE_FRAMES {
                let late = late.min(MAX_GAP_FRAMES);
                self.ring.gap(late, packet.discontinuity);
                self.produced += late;
            }
        }
        if frames == 0 {
            return;
        }
        self.produced += frames;
        self.scratch.clear();
        if packet.silent {
            self.scratch.resize(frames as usize * self.ring.channels, 0);
        } else if self.ring.channels == 1 {
            self.scratch.extend(packet.stereo.chunks_exact(2).map(|f| ((f[0] as i32 + f[1] as i32) / 2) as i16));
        } else {
            self.scratch.extend_from_slice(packet.stereo);
        }
        self.ring.push(&self.scratch);
    }
}

/// The seven-byte ADTS header for one AAC-LC frame at 48 kHz. `None` if it can't fit the format.
pub fn adts_frame_header(channels: usize, payload: usize) -> Option<[u8; 7]> {
    let length = 7 + payload;
    if length > MAX_ADTS_FRAME {
        return None;
    }
    let (c, l) = (channels as u8, length);
    Some([0xFF, 0xF1, (1 << 6) | (3 << 2) | ((c >> 2) & 1), ((c & 3) << 6) | ((l >> 11) & 3) as u8, ((l >> 3) & 0xFF) as u8, (((l & 7) << 5) as u8) | 0x1F, 0xFC])
}

/// Appends ADTS frames to `.part`. Only whole frames count, so a failed write can be cut back.
struct SegmentWriter {
    file: std::fs::File,
    channels: usize,
    bytes: u64,
    frames: u64,
    buffer: Vec<u8>,
}
impl SegmentWriter {
    fn create(path: &Path, channels: usize) -> std::io::Result<SegmentWriter> {
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder)?;
        }
        let file = std::fs::OpenOptions::new().append(true).create_new(true).open(path)?;
        Ok(SegmentWriter { file, channels, bytes: 0, frames: 0, buffer: Vec::with_capacity(2048) })
    }
    fn append(&mut self, payload: &[u8]) -> Result<(), Reason> {
        let header = adts_frame_header(self.channels, payload.len()).ok_or("encoder_failed")?;
        self.buffer.clear();
        self.buffer.extend_from_slice(&header);
        self.buffer.extend_from_slice(payload);
        self.file.write_all(&self.buffer).map_err(|_| "storage_write_failed")?;
        self.bytes += self.buffer.len() as u64;
        self.frames += 1;
        Ok(())
    }
}

/// Raw AAC-LC out, one payload per 1024-sample input frame. Runs on the segment's writer thread.
pub trait Encoder {
    fn encode(&mut self, pcm: &[i16], out: &mut dyn FnMut(&[u8]) -> Result<(), Reason>) -> Result<(), Reason>;
    fn drain(&mut self, out: &mut dyn FnMut(&[u8]) -> Result<(), Reason>) -> Result<(), Reason>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceEvent {
    Failed(Reason),
    DeviceChanged,
}
/// A running source. `stop` returns once no callback can run.
pub trait Stream: Send {
    fn device_name(&self) -> Option<String>;
    fn stop(self: Box<Self>);
}
pub trait Backend: Send + Sync {
    fn start(&self, kind: Kind, feed: Feed, events: Box<dyn Fn(SourceEvent) + Send>) -> Result<Box<dyn Stream>, Reason>;
    /// Called on the writer thread, so the encoder never crosses threads.
    fn encoder(&self, kind: Kind) -> Result<Box<dyn Encoder>, Reason>;
    fn bitrate(&self, kind: Kind) -> i64;
}

#[derive(Default)]
struct Stats {
    frames: AtomicU64,
    failure: Mutex<Option<Reason>>,
}

/// The writer thread: ring to encoder to `.part`, fsync every 5 s, flush on `stop`. Failing latches
/// the reason and leaves; the ring goes on counting drops until the recorder closes the segment.
fn run_worker(ring: &Ring, writer: &mut SegmentWriter, encoder: &mut dyn Encoder, stop: &AtomicBool, stats: &Stats) -> Result<(), Reason> {
    let channels = ring.channels;
    let chunk = AAC_FRAME * channels;
    let mut pcm: Vec<i16> = Vec::with_capacity(chunk * 16);
    let mut synced = Instant::now();
    loop {
        let stopping = stop.load(Ordering::Acquire);
        let popped = ring.pop(&mut pcm, AAC_FRAME * 8);
        let whole = pcm.len() / chunk * chunk;
        for frame in pcm[..whole].chunks_exact(chunk) {
            encoder.encode(frame, &mut |payload| {
                writer.append(payload)?;
                stats.frames.store(writer.frames, Ordering::Release);
                Ok(())
            })?;
        }
        pcm.drain(..whole);
        if stopping && popped == 0 {
            break;
        }
        if synced.elapsed() >= SYNC_EVERY {
            writer.file.sync_data().map_err(|_| "storage_write_failed")?;
            synced = Instant::now();
        }
        if popped == 0 {
            std::thread::sleep(WORKER_TICK);
        }
    }
    let mut flush = |payload: &[u8]| {
        writer.append(payload)?;
        stats.frames.store(writer.frames, Ordering::Release);
        Ok(())
    };
    if !pcm.is_empty() {
        pcm.resize(chunk, 0);
        encoder.encode(&pcm, &mut flush)?;
    }
    encoder.drain(&mut flush)
}

struct Live {
    segment: String,
    part: String,
    stream: Box<dyn Stream>,
    stop: Arc<AtomicBool>,
    worker: JoinHandle<SegmentWriter>,
    ring: Arc<Ring>,
    stats: Arc<Stats>,
    host_start: Arc<AtomicU64>,
}
struct Track {
    kind: Kind,
    id: String,
    sequence: i64,
    live: Option<Live>,
    failed: Option<Reason>,
    done: bool,
}

/// What the views show, published by the recorder thread.
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub id: String,
    pub state: String,
    pub elapsed_ms: i64,
    pub pause_reason: Option<&'static str>,
    pub microphone: String,
    pub system: String,
    pub dropped_frames: i64,
    pub notice: Option<String>,
}

fn is_storage(reason: Reason) -> bool {
    matches!(reason, "storage_write_failed" | "storage_unavailable")
}
type Sql<T = ()> = Result<T, rusqlite::Error>;
type Events = (Kind, i64, SourceEvent);

pub struct Recorder {
    /// The meeting's transcript is wanted, so its row starts `pending`.
    transcribe: bool,
    db: Db,
    root: PathBuf,
    backend: Arc<dyn Backend>,
    id: String,
    state: String,
    tracks: Vec<Track>,
    events: (Sender<Events>, Receiver<Events>),
    started_at: i64,
    paused_ms: i64,
    pause: Option<(i64, &'static str)>,
    notice: Option<String>,
    heartbeat: Instant,
}

impl Recorder {
    /// `MeetingCoordinator.start`. A source that won't start fails its track only; with neither
    /// source, or nowhere to record, the meeting ends `failed` and `state` says so.
    pub fn start(db: Db, root: &Path, backend: Arc<dyn Backend>, id: &str) -> Result<Recorder, String> {
        let mut recorder = Recorder::created(db, root, backend, id, false)?;
        recorder.begin();
        Ok(recorder)
    }

    /// The meeting's rows, so a view can open it while the sources start.
    fn created(db: Db, root: &Path, backend: Arc<dyn Backend>, id: &str, transcribe: bool) -> Result<Recorder, String> {
        let mut recorder = Recorder { transcribe, db, root: root.into(), backend, id: id.into(), state: "created".into(), tracks: vec![], events: channel(), started_at: 0, paused_ms: 0, pause: None, notice: None, heartbeat: Instant::now() };
        recorder.create().map_err(|_| "Meeting is busy".to_string())?;
        Ok(recorder)
    }

    fn begin(&mut self) {
        if self.prepare().is_err() {
            self.notice = Some(failure_reason_text("storage_write_failed", None));
        }
    }

    fn create(&mut self) -> Sql {
        let now = now_ms();
        let tx = self.db.conn.unchecked_transaction()?;
        let active: i64 = tx.query_row("SELECT count(*) FROM meetings WHERE state IN ('created','preparing','recording','paused','finalizing')", [], |r| r.get(0))?;
        if active > 0 {
            return Err(rusqlite::Error::QueryReturnedNoRows);
        }
        let id = &self.id;
        tx.execute("INSERT INTO meetings (id,state,created_at,wall_clock_ms,recorded_ms,updated_at,revision,origin) VALUES (?1,'created',?2,0,0,?2,0,'local')", params![id, now])?;
        tx.execute("INSERT INTO meeting_notes (meeting_id,text,author,updated_at,revision) VALUES (?1,'','user',?2,0)", params![id, now])?;
        tx.execute("INSERT INTO meeting_diarization (meeting_id,in_room,updated_at,revision) VALUES (?1,0,?2,0)", params![id, now])?;
        tx.execute("INSERT INTO meeting_identification (meeting_id,updated_at) VALUES (?1,?2)", params![id, now])?;
        tx.execute("INSERT INTO meeting_analysis (meeting_id,updated_at,revision) VALUES (?1,?2,0)", params![id, now])?;
        // `pending`: the handoff takes it when recording ends. There is no live pass on this path.
        tx.execute("INSERT INTO meeting_transcriptions (meeting_id,state,live_requested,updated_at) VALUES (?1,?2,0,?3)", params![id, if self.transcribe { "pending" } else { "not_requested" }, now])?;
        for kind in Kind::ALL {
            let track = crate::meetings::new_id();
            tx.execute(
                "INSERT INTO meeting_tracks (id,meeting_id,type,codec,container,sample_rate,channel_count,bitrate,health) VALUES (?1,?2,?3,'aac_lc','adts',?4,?5,?6,'healthy')",
                params![track, id, kind.name(), SAMPLE_RATE as i64, kind.channels() as i64, self.backend.bitrate(kind)],
            )?;
            self.tracks.push(Track { kind, id: track, sequence: 0, live: None, failed: None, done: false });
        }
        tx.commit()?;
        self.state = "created".into();
        Ok(())
    }

    fn prepare(&mut self) -> Sql {
        self.transition("preparing")?;
        let now = now_ms();
        for i in 0..self.tracks.len() {
            if let Err(reason) = self.open(i, "start", now) {
                self.mark_failed(i, reason, now)?;
                self.notice = Some(failure_reason_text(reason, Some(self.tracks[i].kind.name())));
            }
        }
        if self.tracks.iter().all(|t| t.live.is_none()) {
            let (id, now) = (self.id.clone(), now_ms());
            self.db.conn.execute("UPDATE meetings SET state='failed',failure_reason='both_sources_failed',updated_at=?1,revision=revision+1 WHERE id=?2", params![now, id])?;
            self.state = "failed".into();
            self.notice = Some(failure_reason_text("both_sources_failed", None));
            return Ok(());
        }
        self.started_at = now;
        self.db.conn.execute("UPDATE meetings SET started_at=?1 WHERE id=?2", params![now, self.id])?;
        self.transition("recording")
    }

    fn transition(&mut self, state: &str) -> Sql {
        self.db.conn.execute("UPDATE meetings SET state=?1,updated_at=?2,revision=revision+1 WHERE id=?3", params![state, now_ms(), self.id])?;
        self.state = state.into();
        Ok(())
    }

    /// Opens the track's next segment: `.part`, encoder on its thread, source, row.
    fn open(&mut self, i: usize, reason: &str, now: i64) -> Result<(), Reason> {
        let (kind, track, sequence) = (self.tracks[i].kind, self.tracks[i].id.clone(), self.tracks[i].sequence + 1);
        let part = format!("{}/{}-{sequence:04}.aac.part", self.id, kind.file_prefix());
        let path = self.root.join(&part);
        let writer = SegmentWriter::create(&path, kind.channels()).map_err(|_| "segment_open_failed")?;
        let ring = Arc::new(Ring::new(kind.channels()));
        let (stop, stats, host_start) = (Arc::new(AtomicBool::new(false)), Arc::new(Stats::default()), Arc::new(AtomicU64::new(0)));
        let (ready, is_ready) = sync_channel(1);
        let worker = {
            let (backend, ring, stop, stats) = (self.backend.clone(), ring.clone(), stop.clone(), stats.clone());
            std::thread::spawn(move || {
                let mut writer = writer;
                let mut encoder = match backend.encoder(kind) {
                    Ok(encoder) => {
                        let _ = ready.send(Ok(()));
                        encoder
                    }
                    Err(reason) => {
                        let _ = ready.send(Err(reason));
                        return writer;
                    }
                };
                if let Err(reason) = run_worker(&ring, &mut writer, encoder.as_mut(), &stop, &stats) {
                    *stats.failure.lock().unwrap() = Some(reason);
                }
                let _ = writer.file.sync_data();
                writer
            })
        };
        let discard = |stop: &AtomicBool, worker: JoinHandle<SegmentWriter>, reason: Reason| -> Result<(), Reason> {
            stop.store(true, Ordering::Release);
            let _ = worker.join();
            let _ = std::fs::remove_file(&path);
            Err(reason)
        };
        if let Ok(Err(reason)) | Err(reason) = is_ready.recv().map_err(|_| "encoder_failed") {
            return discard(&stop, worker, reason);
        }
        let events = self.events.0.clone();
        let feed = Feed::new(ring.clone(), host_start.clone());
        let stream = match self.backend.start(kind, feed, Box::new(move |event| {
            let _ = events.send((kind, sequence, event));
        })) {
            Ok(stream) => stream,
            Err(reason) => return discard(&stop, worker, reason),
        };
        let device: Option<String> = stream.device_name().map(|n| n.chars().take(128).collect::<String>()).filter(|n| !n.is_empty());
        let segment = crate::meetings::new_id();
        let offset: i64 = self.db.conn.query_row("SELECT total_duration_ms FROM meeting_tracks WHERE id=?1", [&track], |r| r.get(0)).unwrap_or(0);
        let row = self.db.conn.execute(
            "INSERT INTO meeting_segments (id,track_id,sequence,relative_path,state,start_offset_ms,started_at,host_start_ns,open_reason,input_device_name) VALUES (?1,?2,?3,?4,'open',?5,?6,0,?7,?8)",
            params![segment, track, sequence, part, offset, now, reason, device],
        );
        if row.is_err() {
            stream.stop();
            return discard(&stop, worker, "storage_write_failed");
        }
        self.tracks[i].sequence = sequence;
        self.tracks[i].live = Some(Live { segment, part, stream, stop, worker, ring, stats, host_start });
        Ok(())
    }

    /// `finalizeRuntime`: stops the source, flushes, renames and updates the row. Whole frames stay
    /// whatever went wrong. Returns the failure the segment ended on, if any.
    fn close(&mut self, i: usize, reason: &str) -> Option<Reason> {
        let live = self.tracks[i].live.take()?;
        live.stream.stop();
        live.stop.store(true, Ordering::Release);
        let writer = live.worker.join().ok();
        let mut failure = *live.stats.failure.lock().unwrap();
        let (bytes, frames) = writer.as_ref().map_or((0, 0), |w| (w.bytes, w.frames));
        let lost_track_of_it = writer.is_none(); // The thread panicked: leave the `.part` to the reconciler.
        drop(writer);
        let part = self.root.join(&live.part);
        let final_path = live.part.strip_suffix(".part").unwrap_or(&live.part).to_string();
        let renamed = frames > 0 && truncate_and_rename(&part, &self.root.join(&final_path), bytes).is_ok();
        if frames > 0 && !renamed {
            failure = failure.or(Some("storage_write_failed"));
        }
        let close = match failure {
            Some(r) if is_storage(r) => "storage_failed",
            Some(_) => "source_failed",
            None => reason,
        };
        let c = &self.db.conn;
        let (dropped, host) = (live.ring.dropped_frames() as i64, live.host_start.load(Ordering::Relaxed).min(i64::MAX as u64) as i64);
        let stored = if renamed {
            c.execute(
                "UPDATE meeting_segments SET state='finalized',relative_path=?1,duration_ms=?2,byte_size=?3,close_reason=?4,dropped_frames=?5,host_start_ns=?6 WHERE id=?7",
                params![final_path, frames as i64 * AAC_FRAME as i64 * 1000 / SAMPLE_RATE as i64, bytes as i64, close, dropped, host, live.segment],
            )
        } else {
            if frames == 0 && !lost_track_of_it {
                let _ = std::fs::remove_file(&part);
            }
            let cause = failure.unwrap_or("unrecoverable_media");
            c.execute(
                "UPDATE meeting_segments SET state='unrecoverable',failure_reason=?1,recovery_note=?2,close_reason=?3,dropped_frames=?4,host_start_ns=?5 WHERE id=?6",
                params![cause, format!("frames={frames}"), close, dropped, host, live.segment],
            )
        };
        if stored.and_then(|_| track_totals(c, &self.tracks[i].id).map_err(store_error)).is_err() {
            failure = failure.or(Some("storage_write_failed"));
        }
        failure
    }

    fn mark_failed(&mut self, i: usize, reason: Reason, now: i64) -> Sql {
        self.tracks[i].failed = Some(reason);
        self.db.conn.execute("UPDATE meeting_tracks SET health='failed',failure_reason=?1,failed_at=?2 WHERE id=?3", params![reason, now, self.tracks[i].id])?;
        Ok(())
    }

    fn close_pause(&mut self, closed_by: &str, now: i64) -> Sql {
        if let Some((at, _)) = self.pause.take() {
            self.paused_ms += (now - at).max(0);
        }
        self.db.conn.execute("UPDATE meeting_pauses SET ended_at=max(started_at,?1),closed_by=?2 WHERE meeting_id=?3 AND ended_at IS NULL", params![now, closed_by, self.id])?;
        Ok(())
    }

    /// Stop and `endInterrupted`, which differ in the close reason and the failure they record.
    fn finish(&mut self, close: &str, failure: Option<Reason>) -> Sql {
        let now = now_ms();
        self.close_pause("stop", now)?;
        self.db.conn.execute("UPDATE meetings SET stopped_at=?1 WHERE id=?2", params![now, self.id])?;
        self.transition("finalizing")?;
        let mut failure = failure;
        for i in 0..self.tracks.len() {
            let closed = self.close(i, close);
            if let Some(reason) = closed {
                failure = failure.or(Some(reason));
                self.mark_failed(i, reason, now_ms())?;
            }
            let stage = if self.tracks[i].kind == Kind::Microphone { "mic" } else { "both" };
            self.db.conn.execute("UPDATE meetings SET finalization_stage=?1,updated_at=?2 WHERE id=?3", params![stage, now_ms(), self.id])?;
        }
        let (c, id, now) = (&self.db.conn, &self.id, now_ms());
        recompute_durations(c, id, now).map_err(store_error)?;
        let recorded: i64 = c.query_row("SELECT recorded_ms FROM meetings WHERE id=?1", [id], |r| r.get(0))?;
        c.execute("UPDATE meeting_tracks SET duration_warning=CASE WHEN dropped_frames>0 OR abs(total_duration_ms-?1)>?2 THEN 1 ELSE 0 END WHERE meeting_id=?3", params![recorded, (recorded / 100).max(2000), id])?;
        c.execute("UPDATE meeting_tracks SET health='finalized' WHERE meeting_id=?1 AND health='healthy'", [id])?;
        let terminal = if failure.is_some() { "interrupted" } else { "completed" };
        c.execute("UPDATE meetings SET state=?1,failure_reason=?2,completed_at=?3,finalization_stage='both',updated_at=?3,revision=revision+1 WHERE id=?4", params![terminal, failure, now, id])?;
        self.state = terminal.into();
        self.tracks.iter_mut().for_each(|t| t.done = true);
        if let Some(reason) = failure {
            self.notice = Some(failure_reason_text(reason, None));
        }
        Ok(())
    }

    /// Stores can fail at any step; the state then stays non-terminal in the database, and the
    /// launch reconciler finishes the job from the files.
    fn or_interrupted(&mut self, result: Sql) {
        if result.is_err() {
            self.notice = Some(failure_reason_text("storage_write_failed", None));
            for i in 0..self.tracks.len() {
                self.close(i, "storage_failed");
            }
            self.state = "interrupted".into();
        }
    }

    pub fn pause(&mut self, reason: &'static str) {
        if self.state != "recording" {
            return;
        }
        let close = if reason == "system_sleep" { "system_sleep" } else { "pause" };
        for i in 0..self.tracks.len() {
            if let Some(failure) = self.close(i, close) {
                self.track_failed(i, failure);
            }
        }
        if self.state != "recording" {
            return;
        }
        let now = now_ms();
        let result = self.db.conn.execute("INSERT INTO meeting_pauses (id,meeting_id,started_at,reason) VALUES (?1,?2,?3,?4)", params![crate::meetings::new_id(), self.id, now, reason]).map(|_| ()).and_then(|_| self.transition("paused"));
        self.pause = result.is_ok().then_some((now, reason));
        self.or_interrupted(result);
    }

    pub fn resume(&mut self) {
        if self.state != "paused" {
            return;
        }
        let now = now_ms();
        let result = self.close_pause("resume", now).and_then(|_| self.transition("recording"));
        self.or_interrupted(result);
        for i in 0..self.tracks.len() {
            if self.tracks[i].failed.is_none() {
                if let Err(reason) = self.open(i, "resume", now) {
                    self.track_failed(i, reason);
                }
            }
        }
    }

    pub fn stop(&mut self) {
        if matches!(self.state.as_str(), "recording" | "paused") {
            let result = self.finish("stop", None);
            self.or_interrupted(result);
        }
    }

    /// `handleSourceFailure`: this track ends and the other goes on; losing the disk or the last
    /// track ends the meeting.
    fn track_failed(&mut self, i: usize, reason: Reason) {
        let kind = self.tracks[i].kind.name();
        let closed = self.close(i, "source_failed");
        let reason = closed.unwrap_or(reason);
        let result = self.mark_failed(i, reason, now_ms());
        self.or_interrupted(result);
        self.notice = Some(failure_reason_text(reason, Some(kind)));
        if is_storage(reason) {
            let result = self.finish("storage_failed", Some(reason));
            self.or_interrupted(result);
        } else if self.tracks.iter().all(|t| t.failed.is_some()) {
            let result = self.finish("source_failed", Some("both_sources_failed"));
            self.or_interrupted(result);
        }
    }

    /// `rollSegment`.
    fn roll(&mut self, i: usize) {
        if let Some(failure) = self.close(i, "device_changed") {
            self.track_failed(i, failure);
        } else if let Err(reason) = self.open(i, "device_changed", now_ms()) {
            self.track_failed(i, reason);
        }
    }

    /// One recorder step: source events, writer failures, the 5 s row update.
    pub fn tick(&mut self) {
        while let Ok((kind, sequence, event)) = self.events.1.try_recv() {
            let Some(i) = self.tracks.iter().position(|t| t.kind == kind && t.sequence == sequence && t.live.is_some()) else { continue };
            match event {
                SourceEvent::Failed(reason) => self.track_failed(i, reason),
                SourceEvent::DeviceChanged => self.roll(i),
            }
        }
        for i in 0..self.tracks.len() {
            let failure = self.tracks[i].live.as_ref().and_then(|l| *l.stats.failure.lock().unwrap());
            if let Some(reason) = failure {
                self.track_failed(i, reason);
            }
        }
        if self.heartbeat.elapsed() >= SYNC_EVERY && !crate::meetings::is_terminal(&self.state) {
            self.heartbeat = Instant::now();
            let result = self.store_progress();
            self.or_interrupted(result);
        }
    }

    fn store_progress(&mut self) -> Sql {
        let (c, now) = (&self.db.conn, now_ms());
        for track in &self.tracks {
            if let Some(live) = &track.live {
                let frames = live.stats.frames.load(Ordering::Acquire) as i64;
                c.execute(
                    "UPDATE meeting_segments SET duration_ms=?1,dropped_frames=?2,host_start_ns=?3 WHERE id=?4",
                    params![frames * AAC_FRAME as i64 * 1000 / SAMPLE_RATE as i64, live.ring.dropped_frames() as i64, live.host_start.load(Ordering::Relaxed).min(i64::MAX as u64) as i64, live.segment],
                )?;
            }
        }
        c.execute("UPDATE meetings SET updated_at=?1 WHERE id=?2", params![now, self.id])?;
        recompute_durations(c, &self.id, now).map_err(store_error)
    }

    pub fn state(&self) -> &str {
        &self.state
    }

    pub fn snapshot(&self) -> Snapshot {
        let now = now_ms();
        let paused = self.paused_ms + self.pause.map_or(0, |(at, _)| (now - at).max(0));
        let status = |kind: Kind| {
            let track = self.tracks.iter().find(|t| t.kind == kind);
            match track {
                Some(Track { failed: Some(reason), .. }) => format!("failed: {}", reason.replace('_', " ")),
                Some(Track { live: Some(_), .. }) => "capturing".to_string(),
                Some(Track { done: true, .. }) => "finalized".to_string(),
                Some(_) if self.state == "paused" => "paused".to_string(),
                _ => "not started".to_string(),
            }
        };
        let dropped: u64 = self.tracks.iter().filter_map(|t| t.live.as_ref()).map(|l| l.ring.dropped_frames()).sum();
        let closed: i64 = self.db.conn.query_row("SELECT COALESCE(SUM(dropped_frames),0) FROM meeting_tracks WHERE meeting_id=?1", [&self.id], |r| r.get(0)).unwrap_or(0);
        Snapshot {
            id: self.id.clone(),
            state: self.state.clone(),
            elapsed_ms: if self.started_at > 0 { (now - self.started_at - paused).max(0) } else { 0 },
            pause_reason: self.pause.map(|p| p.1),
            microphone: status(Kind::Microphone),
            system: status(Kind::System),
            dropped_frames: dropped as i64 + closed,
            notice: self.notice.clone(),
        }
    }
}

fn store_error(e: crate::meetings::MeetingError) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(format!("{e:?}"))))
}

enum Command {
    Pause,
    Resume,
    Stop,
}

/// The recorder on its own thread, because finalizing and WASAPI activation can take a while.
/// The UI sends commands and reads `snapshot`; the thread ends with the meeting.
pub struct Handle {
    commands: Sender<Command>,
    snapshot: Arc<Mutex<Snapshot>>,
}
impl Handle {
    /// Returns once the meeting's rows exist, with the sources still starting on the thread, which
    /// opens its own connection to `database`.
    pub fn start(database: &Path, root: &Path, backend: Arc<dyn Backend>, transcribe: bool) -> Result<Handle, String> {
        let id = crate::meetings::new_id();
        let snapshot = Arc::new(Mutex::new(Snapshot { id: id.clone(), state: "preparing".into(), ..Default::default() }));
        let (commands, inbox) = channel();
        let (created, is_created) = sync_channel(1);
        let (published, database, root) = (snapshot.clone(), database.to_path_buf(), root.to_path_buf());
        std::thread::spawn(move || {
            let mut recorder = match Db::open(&database).map_err(|_| "Meeting is busy".to_string()).and_then(|db| Recorder::created(db, &root, backend, &id, transcribe)) {
                Ok(recorder) => {
                    let _ = created.send(Ok(()));
                    recorder
                }
                Err(notice) => {
                    let _ = created.send(Err(notice));
                    return;
                }
            };
            recorder.begin();
            loop {
                *published.lock().unwrap() = recorder.snapshot();
                if crate::meetings::is_terminal(recorder.state()) {
                    return;
                }
                match inbox.recv_timeout(RECORDER_TICK) {
                    Ok(Command::Pause) => recorder.pause("user"),
                    Ok(Command::Resume) => recorder.resume(),
                    Ok(Command::Stop) | Err(RecvTimeoutError::Disconnected) => recorder.stop(),
                    Err(RecvTimeoutError::Timeout) => {}
                }
                recorder.tick();
            }
        });
        is_created.recv().map_err(|_| "Meeting is busy".to_string())??;
        Ok(Handle { commands, snapshot })
    }
    pub fn snapshot(&self) -> Snapshot {
        self.snapshot.lock().unwrap().clone()
    }
    pub fn pause(&self) {
        let _ = self.commands.send(Command::Pause);
    }
    pub fn resume(&self) {
        let _ = self.commands.send(Command::Resume);
    }
    pub fn stop(&self) {
        let _ = self.commands.send(Command::Stop);
    }
    /// For quitting. A segment past the timeout stays `.part`, and the next launch recovers it.
    pub fn stop_and_wait(&self, timeout: Duration) -> bool {
        self.stop();
        let by = Instant::now() + timeout;
        while Instant::now() < by {
            if crate::meetings::is_terminal(&self.snapshot().state) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }
}

#[cfg(test)]
#[path = "capture/tests.rs"]
mod tests;
