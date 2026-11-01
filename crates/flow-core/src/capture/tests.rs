use super::*;
use crate::meetings::{adts_header, adts_scan, reconcile_launch};

fn frames_of(pcm: &[i16], channels: usize) -> Vec<Vec<i16>> {
    pcm.chunks(channels).map(|c| c.to_vec()).collect()
}

#[test]
fn a_full_ring_drops_the_incoming_packet_and_counts_it() {
    let ring = Ring::new(1);
    let two_seconds = vec![1i16; 96_000];
    assert!(ring.push(&two_seconds));
    assert!(!ring.push(&[2; 480]), "bounded at two seconds");
    assert_eq!(ring.dropped_frames(), 480);
    let mut out = vec![];
    assert_eq!(ring.pop(&mut out, 96_480), 96_480);
    assert_eq!(out.len(), 96_480, "the drop plays as silence");
    assert!(out[..96_000].iter().all(|s| *s == 1) && out[96_000..].iter().all(|s| *s == 0));
    assert_eq!(ring.pop(&mut out, 10), 0);
}

#[test]
fn silence_lands_where_the_audio_was_lost_and_pops_stop_at_max() {
    let ring = Ring::new(2);
    ring.push(&[1, 1, 2, 2]);
    ring.gap(3, true);
    ring.gap(1, true);
    ring.push(&[3, 3]);
    let mut out = vec![];
    assert_eq!(ring.pop(&mut out, 3), 3);
    assert_eq!(frames_of(&out, 2), vec![vec![1, 1], vec![2, 2], vec![0, 0]]);
    out.clear();
    assert_eq!(ring.pop(&mut out, 100), 4);
    assert_eq!(frames_of(&out, 2), vec![vec![0, 0], vec![0, 0], vec![0, 0], vec![3, 3]]);
    assert_eq!(ring.dropped_frames(), 4);
}

#[test]
fn gap_entries_are_bounded_and_keep_their_frames() {
    let ring = Ring::new(1);
    for _ in 0..MAX_GAP_ENTRIES * 3 {
        ring.push(&[1]);
        ring.gap(2, true);
    }
    assert!(ring.inner.lock().unwrap().gaps.len() <= MAX_GAP_ENTRIES);
    let mut out = vec![];
    assert_eq!(ring.pop(&mut out, 100_000), MAX_GAP_ENTRIES * 9, "the total length survives merging");
}

#[test]
fn feed_downmixes_blanks_silent_packets_and_keeps_tracks_on_the_clock() {
    let ring = Arc::new(Ring::new(1));
    let host = Arc::new(AtomicU64::new(0));
    let mut feed = Feed::new(ring.clone(), host.clone());
    let at = |ms: u64| Some(5_000_000_000 + ms * 1_000_000);
    feed.push(&Packet { stereo: &[100, 300, -32768, -32768], qpc_ns: at(0), silent: false, discontinuity: false });
    feed.push(&Packet { stereo: &[7, 7], qpc_ns: at(50), silent: true, discontinuity: false });
    let mut out = vec![];
    ring.pop(&mut out, 100);
    assert_eq!(out, vec![200, -32768, 0], "50 ms late is jitter");
    assert_eq!(host.load(Ordering::Relaxed), 5_000_000_000, "the first packet's clock");

    feed.push(&Packet { stereo: &[10, 20], qpc_ns: at(1000), silent: false, discontinuity: false });
    out.clear();
    assert_eq!(ring.pop(&mut out, 100_000), 47_998, "the clock's second is all there");
    assert_eq!(*out.last().unwrap(), 15);
    assert_eq!(ring.dropped_frames(), 0, "a quiet device lost nothing");

    feed.push(&Packet { stereo: &[10, 20], qpc_ns: at(2000), silent: false, discontinuity: true });
    assert_eq!(ring.dropped_frames(), 47_999, "a reported glitch is a loss");

    feed.push(&Packet { stereo: &[], qpc_ns: at(3000), silent: true, discontinuity: false });
    out.clear();
    assert_eq!(ring.pop(&mut out, 200_000), 96_000 - 1, "an empty last packet covers the quiet tail");

    feed.push(&Packet { stereo: &[], qpc_ns: Some(u64::MAX), silent: true, discontinuity: false });
    assert!(ring.inner.lock().unwrap().gaps.back().unwrap().1 <= MAX_GAP_FRAMES, "a wild clock is capped");
}

#[test]
fn stereo_passes_through() {
    let ring = Arc::new(Ring::new(2));
    let mut feed = Feed::new(ring.clone(), Arc::default());
    feed.push(&Packet { stereo: &[1, 2, 3, 4], qpc_ns: None, silent: false, discontinuity: false });
    let mut out = vec![];
    ring.pop(&mut out, 2);
    assert_eq!(out, vec![1, 2, 3, 4]);
}

#[test]
fn adts_headers_read_back_through_the_reconciler_validator() {
    for (channels, payload) in [(1usize, 200usize), (2, 1536), (2, 1), (1, MAX_ADTS_FRAME - 7)] {
        let header = adts_frame_header(channels, payload).unwrap();
        assert_eq!(adts_header(&header), Some(((payload + 7) as u64, 48_000, channels as i64)));
    }
    assert_eq!(adts_frame_header(2, MAX_ADTS_FRAME - 6), None);
}

/// A test source: the test pushes packets, and the encoder may be told to stall or fail.
#[derive(Default)]
struct Fake {
    feeds: Mutex<Vec<(Kind, Feed, Arc<dyn Fn(SourceEvent) + Send + Sync>)>>,
    refuse: Mutex<Vec<(Kind, Reason)>>,
    refuse_encoder: Mutex<Option<Reason>>,
    fail_after: Mutex<Option<(usize, Reason)>>,
    stall: Arc<AtomicBool>,
    stopped: AtomicU64,
}
struct FakeStream(Arc<Fake>);
impl Stream for FakeStream {
    fn device_name(&self) -> Option<String> {
        Some("Test input".into())
    }
    fn stop(self: Box<Self>) {
        self.0.stopped.fetch_add(1, Ordering::Relaxed);
    }
}
struct FakeEncoder(Arc<AtomicBool>, Option<(usize, Reason)>);
impl Encoder for FakeEncoder {
    fn encode(&mut self, pcm: &[i16], out: &mut dyn FnMut(&[u8]) -> Result<(), Reason>) -> Result<(), Reason> {
        assert!(pcm.len() % AAC_FRAME == 0, "whole frames only");
        while self.0.load(Ordering::Acquire) {
            std::thread::sleep(Duration::from_millis(5));
        }
        if let Some((left, reason)) = &mut self.1 {
            if *left == 0 {
                return Err(reason);
            }
            *left -= 1;
        }
        out(&[0x21; 20])
    }
    fn drain(&mut self, out: &mut dyn FnMut(&[u8]) -> Result<(), Reason>) -> Result<(), Reason> {
        out(&[0x22; 10])
    }
}
struct Shared(Arc<Fake>);
impl Backend for Shared {
    fn start(&self, kind: Kind, feed: Feed, events: Box<dyn Fn(SourceEvent) + Send>) -> Result<Box<dyn Stream>, Reason> {
        if let Some((_, reason)) = self.0.refuse.lock().unwrap().iter().find(|(k, _)| *k == kind) {
            return Err(reason);
        }
        let events = Arc::new(Mutex::new(events));
        self.0.feeds.lock().unwrap().push((kind, feed, Arc::new(move |e| (events.lock().unwrap())(e))));
        Ok(Box::new(FakeStream(self.0.clone())))
    }
    fn encoder(&self, _: Kind) -> Result<Box<dyn Encoder>, Reason> {
        if let Some(reason) = *self.0.refuse_encoder.lock().unwrap() {
            return Err(reason);
        }
        Ok(Box::new(FakeEncoder(self.0.stall.clone(), *self.0.fail_after.lock().unwrap())))
    }
    fn bitrate(&self, kind: Kind) -> i64 {
        if kind == Kind::Microphone { 64_000 } else { 96_000 }
    }
}
impl Fake {
    fn push(&self, kind: Kind, frames: usize) {
        let stereo = vec![1000i16; frames * 2];
        let mut feeds = self.feeds.lock().unwrap();
        let (_, feed, _) = feeds.iter_mut().rev().find(|f| f.0 == kind).unwrap();
        feed.push(&Packet { stereo: &stereo, qpc_ns: Some(77), silent: false, discontinuity: false });
    }
    fn event(&self, kind: Kind, event: SourceEvent) {
        let feeds = self.feeds.lock().unwrap();
        (feeds.iter().rev().find(|f| f.0 == kind).unwrap().2)(event);
    }
}

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
struct Rig {
    _dir: TempDir,
    root: PathBuf,
    db_path: PathBuf,
    fake: Arc<Fake>,
}
const ID: &str = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
fn rig() -> Rig {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = TempDir(std::env::temp_dir().join(format!("flow-capture-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))));
    let root = dir.0.join("Meetings");
    std::fs::create_dir_all(&root).unwrap();
    let db_path = dir.0.join("history.sqlite");
    Db::open_or_create(&db_path).unwrap();
    Rig { root, db_path, _dir: dir, fake: Arc::default() }
}
impl Rig {
    fn start(&self) -> Recorder {
        Recorder::start(self.db(), &self.root, Arc::new(Shared(self.fake.clone())), ID).unwrap()
    }
    fn db(&self) -> Db {
        Db::open(&self.db_path).unwrap()
    }
    fn one(&self, sql: &str) -> String {
        self.db().conn.query_row(sql, [], |r| r.get::<_, rusqlite::types::Value>(0)).map(|v| format!("{v:?}")).unwrap()
    }
    fn segments(&self, kind: &str) -> Vec<(i64, String, String, i64, i64, String, Option<String>)> {
        let db = self.db();
        let mut q = db.conn.prepare("SELECT s.sequence,s.relative_path,s.state,s.start_offset_ms,s.duration_ms,s.open_reason,s.close_reason FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id WHERE t.type=?1 ORDER BY s.sequence").unwrap();
        q.query_map([kind], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?))).unwrap().map(Result::unwrap).collect()
    }
    fn scan(&self, relative: &str) -> crate::meetings::AdtsScan {
        adts_scan(&self.root.join(relative)).unwrap()
    }
}

#[test]
fn start_pause_resume_stop_writes_swifts_rows_and_valid_files() {
    let rig = rig();
    let mut r = rig.start();
    assert_eq!(r.state(), "recording");
    assert_eq!(rig.one("SELECT state FROM meeting_transcriptions"), "Text(\"not_requested\")");
    assert_eq!(rig.one("SELECT channel_count FROM meeting_tracks WHERE type='microphone'"), "Integer(1)");
    assert_eq!(rig.one("SELECT bitrate FROM meeting_tracks WHERE type='system'"), "Integer(96000)");
    assert_eq!(rig.one("SELECT host_start_ns FROM meeting_segments LIMIT 1"), "Integer(0)");
    assert!(rig.root.join(ID).join("mic-0001.aac.part").exists());

    rig.fake.push(Kind::Microphone, 2048);
    rig.fake.push(Kind::System, 1500);
    std::thread::sleep(Duration::from_millis(10));
    r.pause("user");
    assert_eq!(r.state(), "paused");
    assert_eq!(rig.one("SELECT reason FROM meeting_pauses"), "Text(\"user\")");
    let mic = rig.segments("microphone");
    assert_eq!(mic[0].1, format!("{ID}/mic-0001.aac"));
    assert_eq!(mic[0].6.as_deref(), Some("pause"));
    let scan = rig.scan(&mic[0].1);
    assert_eq!((scan.frames, scan.channels, scan.sample_rate, scan.trailing), (3, 1, 48_000, 0), "two frames and the drain");
    assert_eq!(mic[0].4, 64, "3 frames of 1024 at 48 kHz");
    assert_eq!(rig.scan(&rig.segments("system")[0].1).frames, 3, "a padded partial frame and the drain");

    r.resume();
    assert_eq!(r.state(), "recording");
    assert_eq!(rig.one("SELECT closed_by FROM meeting_pauses"), "Text(\"resume\")");
    let mic = rig.segments("microphone");
    assert_eq!((mic[1].0, mic[1].3, mic[1].5.as_str()), (2, 64, "resume"), "continues at the first segment's end");
    rig.fake.push(Kind::Microphone, 1024);
    r.stop();
    assert_eq!(r.state(), "completed");
    let mic = rig.segments("microphone");
    assert_eq!(mic[1].2, "finalized");
    assert_eq!(mic[1].6.as_deref(), Some("stop"));
    assert_eq!(rig.one("SELECT finalization_stage FROM meetings"), "Text(\"both\")");
    assert_eq!(rig.one("SELECT health FROM meeting_tracks WHERE type='system'"), "Text(\"finalized\")");
    assert_eq!(rig.one("SELECT host_start_ns FROM meeting_segments WHERE sequence=1 LIMIT 1"), "Integer(77)");
    assert_ne!(rig.one("SELECT completed_at FROM meetings"), "Null");
    assert_eq!(rig.fake.stopped.load(Ordering::Relaxed), 4);
    let s = r.snapshot();
    assert_eq!((s.state.as_str(), s.microphone.as_str(), s.dropped_frames), ("completed", "finalized", 0));
    assert!(crate::meetings::reconcile_launch(&rig.db(), &rig.root, now_ms()).unwrap().notices().is_empty(), "nothing left to recover");
}

#[test]
fn a_second_meeting_is_refused_while_one_is_active() {
    let rig = rig();
    let mut first = rig.start();
    let second = Recorder::start(rig.db(), &rig.root, Arc::new(Shared(rig.fake.clone())), "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB");
    assert_eq!(second.err().as_deref(), Some("Meeting is busy"));
    first.stop();
}

#[test]
fn overload_counts_drops_warns_and_keeps_the_timeline() {
    let rig = rig();
    let mut r = rig.start();
    rig.fake.stall.store(true, Ordering::Release);
    rig.fake.push(Kind::Microphone, 1024);
    std::thread::sleep(Duration::from_millis(120));
    for _ in 0..3 {
        rig.fake.push(Kind::Microphone, 48_000);
    }
    assert_eq!(r.snapshot().dropped_frames, 48_000, "the third second doesn't fit in two");
    rig.fake.stall.store(false, Ordering::Release);
    r.stop();
    assert_eq!(r.state(), "completed");
    let mic = rig.segments("microphone");
    let total = 1024 + 3 * 48_000;
    assert_eq!(rig.scan(&mic[0].1).frames, (total as i64 + 1023) / 1024 + 1, "silence kept the length; the drain adds one");
    assert_eq!(rig.one("SELECT dropped_frames FROM meeting_tracks WHERE type='microphone'"), "Integer(48000)");
    assert_eq!(rig.one("SELECT duration_warning FROM meeting_tracks WHERE type='microphone'"), "Integer(1)");
}

#[test]
fn device_change_rolls_to_a_new_sequence_on_a_new_source() {
    let rig = rig();
    let mut r = rig.start();
    rig.fake.push(Kind::System, 1024);
    let stale = rig.fake.feeds.lock().unwrap().iter().rev().find(|f| f.0 == Kind::System).unwrap().2.clone();
    stale(SourceEvent::DeviceChanged);
    r.tick();
    let system = rig.segments("system");
    assert_eq!(system.len(), 2);
    assert_eq!(system[0].6.as_deref(), Some("device_changed"));
    assert_eq!((system[1].5.as_str(), system[1].2.as_str(), system[1].3), ("device_changed", "open", system[0].4));
    assert_eq!(rig.segments("microphone").len(), 1, "the other track goes on");
    stale(SourceEvent::Failed("device_lost"));
    r.tick();
    assert_eq!(r.snapshot().system, "capturing", "an ended source can't fail its successor");
    r.stop();
    assert_eq!(r.state(), "completed");
}

#[test]
fn a_failed_source_ends_its_track_and_the_second_ends_the_meeting() {
    let rig = rig();
    let mut r = rig.start();
    rig.fake.push(Kind::Microphone, 1024);
    rig.fake.event(Kind::Microphone, SourceEvent::Failed("device_lost"));
    r.tick();
    assert_eq!(r.state(), "recording");
    assert_eq!(r.snapshot().microphone, "failed: device lost");
    assert!(r.snapshot().notice.is_some());
    assert_eq!(rig.one("SELECT failure_reason FROM meeting_tracks WHERE type='microphone'"), "Text(\"device_lost\")");
    assert_eq!(rig.segments("microphone")[0].6.as_deref(), Some("source_failed"));
    assert_eq!(rig.segments("microphone")[0].2, "finalized", "what was written stays");
    r.pause("user");
    r.resume();
    assert_eq!(rig.segments("microphone").len(), 1, "a failed track stays down after a resume");
    rig.fake.event(Kind::System, SourceEvent::Failed("stream_stopped"));
    r.tick();
    assert_eq!(r.state(), "interrupted");
    assert_eq!(rig.one("SELECT failure_reason FROM meetings"), "Text(\"both_sources_failed\")");
}

#[test]
fn one_source_refusing_at_start_records_the_other_and_both_fail_the_meeting() {
    let rig = self::rig();
    rig.fake.refuse.lock().unwrap().push((Kind::System, "permission_revoked"));
    let mut r = rig.start();
    assert_eq!(r.state(), "recording");
    assert!(r.snapshot().system.starts_with("failed"));
    assert!(!rig.root.join(ID).join("system-0001.aac.part").exists());
    r.stop();
    assert_eq!(r.state(), "completed");
    assert_eq!(rig.one("SELECT health FROM meeting_tracks WHERE type='system'"), "Text(\"failed\")");

    let rig = self::rig();
    *rig.fake.refuse_encoder.lock().unwrap() = Some("encoder_failed");
    let r = rig.start();
    assert_eq!(r.state(), "failed");
    assert_eq!(rig.one("SELECT failure_reason FROM meetings"), "Text(\"both_sources_failed\")");
    assert_eq!(rig.one("SELECT failure_reason FROM meeting_tracks WHERE type='system'"), "Text(\"encoder_failed\")");
}

#[test]
fn an_encoder_failing_midway_keeps_whole_frames_and_the_other_track() {
    let rig = rig();
    *rig.fake.fail_after.lock().unwrap() = Some((2, "encoder_failed"));
    let mut r = rig.start();
    rig.fake.push(Kind::Microphone, 5 * 1024);
    let by = Instant::now() + Duration::from_secs(5);
    while r.snapshot().microphone == "capturing" && Instant::now() < by {
        std::thread::sleep(Duration::from_millis(10));
        r.tick();
    }
    assert_eq!(r.snapshot().microphone, "failed: encoder failed");
    let mic = rig.segments("microphone");
    assert_eq!(mic[0].2, "finalized");
    assert_eq!(rig.scan(&mic[0].1).frames, 2);
    assert_eq!(mic[0].6.as_deref(), Some("source_failed"));
    assert_eq!(r.state(), "recording");
    r.stop();
    assert_eq!(r.state(), "completed");
}

#[test]
fn a_crash_leaves_a_part_the_launch_reconciler_recovers() {
    let rig = rig();
    let mut r = rig.start();
    rig.fake.push(Kind::Microphone, 3 * 1024);
    let by = Instant::now() + Duration::from_secs(5);
    while r.tracks[0].live.as_ref().unwrap().stats.frames.load(Ordering::Acquire) < 3 && Instant::now() < by {
        std::thread::sleep(Duration::from_millis(5));
    }
    // The process dies here: the threads go, no row is updated, and the last write was torn.
    for track in &mut r.tracks {
        let live = track.live.take().unwrap();
        live.stop.store(true, Ordering::Release);
        drop(live.worker.join());
        std::mem::forget(live.stream);
    }
    std::mem::forget(r);
    let part = rig.root.join(ID).join("mic-0001.aac.part");
    let sound = std::fs::metadata(&part).unwrap().len();
    std::fs::OpenOptions::new().append(true).open(&part).unwrap().write_all(&[0xFF, 0xF1, 0x4C]).unwrap();

    let db = rig.db();
    let recovery = reconcile_launch(&db, &rig.root, now_ms()).unwrap();
    assert!(!recovery.notices().is_empty());
    assert_eq!(rig.one("SELECT state FROM meetings"), "Text(\"interrupted\")");
    let mic = rig.segments("microphone");
    assert_eq!(mic[0].1, format!("{ID}/mic-0001.aac"));
    assert_eq!(mic[0].6.as_deref(), Some("recovered"));
    assert_eq!(std::fs::metadata(rig.root.join(&mic[0].1)).unwrap().len(), sound, "torn bytes gone, whole frames kept");
    assert!(!part.exists());
}

#[test]
fn the_handle_runs_a_meeting_on_its_thread_and_stops_for_quit() {
    let rig = rig();
    let handle = Handle::start(&rig.db_path, &rig.root, Arc::new(Shared(rig.fake.clone())), true).unwrap();
    assert_eq!(rig.one("SELECT count(*) FROM meetings"), "Integer(1)", "the rows exist on return");
    assert_eq!(rig.one("SELECT count(*) FROM meeting_transcriptions WHERE state='pending'"), "Integer(1)", "the handoff owes it a transcript");
    let second = Handle::start(&rig.db_path, &rig.root, Arc::new(Shared(rig.fake.clone())), true);
    assert_eq!(second.err().as_deref(), Some("Meeting is busy"));
    assert!(!handle.snapshot().id.is_empty());
    let wait = |state: &str| {
        let by = Instant::now() + Duration::from_secs(5);
        while handle.snapshot().state != state && Instant::now() < by {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(handle.snapshot().state, state);
    };
    wait("recording");
    handle.pause();
    wait("paused");
    assert_eq!(handle.snapshot().pause_reason, Some("user"));
    handle.resume();
    wait("recording");
    assert!(handle.stop_and_wait(Duration::from_secs(10)));
    assert!(crate::meetings::is_terminal(&handle.snapshot().state));
}
