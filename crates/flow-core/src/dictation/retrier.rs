//! `PendingRemoteRetrier`: dictations that lost the server try again, oldest first, and are saved
//! for review; nothing is inserted (ADR 0014). A live dictation goes first.
use super::normalize::Vocabulary;
use super::remote::{self, RETRY_THRESHOLD, Stream};
use super::session::{Recognizer, Recovered, WINDOW, recovered_dictation};
use super::spool::{MAX_SAMPLES, Reader};
use crate::db::Db;
use crate::history::{self, PENDING_MAX_AGE_MS, PendingItem, StoreError};
use crate::remote::enrollment::Enrollment;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering::*};
use std::time::Duration;

/// `backoffMilliseconds`: after the first, second, third and later failed retries.
pub fn next_delay_ms(attempts: i64) -> i64 {
    match attempts {
        ..=1 => 30_000,
        2 => 120_000,
        _ => 600_000,
    }
}

fn check_audio(path: &Path, samples: i64) -> Option<usize> {
    let count = usize::try_from(samples).ok().filter(|c| (1..=MAX_SAMPLES).contains(c))?;
    (std::fs::metadata(path).ok()?.len() == count as u64 * 4).then_some(count)
}

/// Commits the transcript for review, then deletes the row and its audio. An empty transcript only
/// deletes. False when it couldn't save, and the audio stays.
fn save(db: &Db, dir: &Path, item: &PendingItem, windows: Vec<(usize, usize, String)>, samples: usize, vocabulary: &Vocabulary, model: Option<super::worker::ModelIdentity>, seconds: f64, path: &'static str, failure: &'static str) -> bool {
    let recovered = Recovered { id: &item.id, created_at: item.created_at, samples, path, server_failure: failure, target_bundle_id: item.target_bundle_id.clone(), device_name: item.device_name.clone(), device_kind: item.device_kind.clone() };
    if let Some(dictation) = recovered_dictation(recovered, windows, vocabulary, model, seconds) {
        if history::commit_dictation(db, &dictation).is_err() {
            return false;
        }
    }
    history::remove_pending(db, dir, &item.id).is_ok()
}

fn reason_of(item: &PendingItem) -> &'static str {
    match item.last_failure.as_deref() {
        Some("timeout") => "timeout",
        Some("busy") => "busy",
        Some("unauthorized") => "unauthorized",
        Some("not_approved") => "not_approved",
        Some("revoked") => "revoked",
        Some("pin_mismatch") => "pin_mismatch",
        Some("worker_unavailable") => "worker_unavailable",
        Some("protocol_error") => "protocol_error",
        Some("limit_exceeded") => "limit_exceeded",
        _ => "unreachable",
    }
}

pub struct Retrier {
    pub db: Db,
    pub dir: PathBuf,
    pub enrollment: Arc<Enrollment>,
    /// A live dictation is running: the retry stops and the row stays due, uncounted.
    pub live: Arc<AtomicBool>,
    pub now: Box<dyn Fn() -> i64 + Send>,
    pub threshold: Duration,
    /// Each row a retry saved, and each that came to need the user.
    pub recovered: Box<dyn FnMut(&str) + Send>,
    pub decision_needed: Box<dyn FnMut(&str) + Send>,
}

impl Retrier {
    pub fn new(db: Db, dir: PathBuf, enrollment: Arc<Enrollment>, live: Arc<AtomicBool>) -> Retrier {
        Retrier { db, dir, enrollment, live, now: Box::new(crate::history::now_ms), threshold: RETRY_THRESHOLD, recovered: Box::new(|_| {}), decision_needed: Box::new(|_| {}) }
    }

    /// `runDue`: every due row once, oldest first. Returns how many were recovered.
    pub fn run_due(&mut self) -> usize {
        let mut recovered = 0;
        for item in history::pending_items(&self.db) {
            let now = (self.now)();
            if now - item.created_at >= PENDING_MAX_AGE_MS {
                if item.next_attempt_at != i64::MAX {
                    let _ = history::record_pending_attempt(&self.db, &item.id, reason_of(&item), false, i64::MAX);
                    (self.decision_needed)(&item.id);
                }
                continue;
            }
            if item.next_attempt_at > now {
                continue;
            }
            // The row stays due; the next poll checks again.
            if self.live.load(SeqCst) {
                break;
            }
            if self.retry(&item) {
                recovered += 1;
                (self.recovered)(&item.id);
            }
        }
        recovered
    }

    /// `millisecondsUntilNextDue`, capped at the 10 s poll so a row added meanwhile isn't left for 10 min.
    pub fn wait(&self) -> Duration {
        let now = (self.now)();
        let due = history::pending_items(&self.db).iter().filter(|i| now - i.created_at < PENDING_MAX_AGE_MS).map(|i| i.next_attempt_at).min();
        Duration::from_millis((due.unwrap_or(now + 600_000) - now).clamp(1_000, 10_000) as u64)
    }

    fn retry(&mut self, item: &PendingItem) -> bool {
        let opened = history::pending_audio_path(&self.dir, item).and_then(|path| Some((check_audio(&path, item.sample_count)?, Reader::open(&path).ok()?)));
        let Some((samples, reader)) = opened else {
            // Retrying can't fix the file: stop and let the user decide.
            let _ = history::record_pending_attempt(&self.db, &item.id, reason_of(item), false, i64::MAX);
            (self.decision_needed)(&item.id);
            return false;
        };
        // The Dictionary is read again now, not taken from the failed attempt.
        let vocabulary = Vocabulary::load(&self.db).unwrap_or_default();
        let stream = Stream::start(self.enrollment.clone(), reader, remote::boost_of(&vocabulary), self.threshold);
        stream.recorded(samples);
        stream.release(samples);
        let result = loop {
            if self.live.load(SeqCst) {
                stream.cancel();
                return false;
            }
            if let Some(result) = stream.poll(Duration::from_millis(50)) {
                break result;
            }
        };
        let failure = match result {
            Ok(completed) => {
                if save(&self.db, &self.dir, item, completed.windows, samples, &vocabulary, Some(completed.model), completed.recognition_seconds, "server", "pending_retry") {
                    return true;
                }
                "protocol_error"
            }
            Err(reason) => reason,
        };
        if self.live.load(SeqCst) {
            return false;
        }
        let attempts = item.attempts + 1;
        let _ = history::record_pending_attempt(&self.db, &item.id, failure, true, (self.now)() + next_delay_ms(attempts));
        false
    }
}

/// `recognizeLocally`: the model installed since. `Ok(false)` when the row is gone.
pub fn recognize_locally(db: &Db, dir: &Path, id: &str, local: &mut dyn Recognizer) -> Result<bool, StoreError> {
    let refused = || StoreError::Refused("recognize_locally");
    let Some(item) = history::pending_items(db).into_iter().find(|i| i.id == id) else { return Ok(false) };
    let path = history::pending_audio_path(dir, &item).ok_or_else(refused)?;
    let samples = check_audio(&path, item.sample_count).ok_or_else(refused)?;
    let mut reader = Reader::open(&path).map_err(|_| refused())?;
    let vocabulary = Vocabulary::load(db).unwrap_or_default();
    local.prepare(&vocabulary).map_err(|_| refused())?;
    let began = std::time::Instant::now();
    let mut windows = vec![];
    let mut start = 0;
    while start < samples {
        let count = WINDOW.min(samples - start);
        let audio = reader.read(start, count).map_err(|_| refused());
        let window = audio.and_then(|mut a| {
            if a.len() < 4_800 {
                a.resize(4_800, 0.);
            }
            local.recognize(&a).map_err(|_| refused())
        });
        let window = match window {
            Ok(window) => window,
            Err(e) => {
                local.finish();
                return Err(e);
            }
        };
        windows.push((start, count, window["text"].as_str().unwrap_or_default().to_string()));
        start += count;
    }
    let model = local.model();
    local.finish();
    if save(db, dir, &item, windows, samples, &vocabulary, model, began.elapsed().as_secs_f64(), "local_after_server_failure", reason_of(&item)) { Ok(true) } else { Err(refused()) }
}
