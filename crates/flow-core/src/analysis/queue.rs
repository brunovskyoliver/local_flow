//! `MeetingIntelligenceCoordinator`: one bounded, deduplicated queue and one run at a time. Admission
//! writes the `pending` row first, so queue and database agree after a relaunch. Every method may be
//! called from the UI thread; admission and the run happen on their own threads.
use super::run::{self, Admission, Deps, Route, WAITING_DETAIL};
use super::store;
use crate::db::Db;
use crate::history::now_ms;
use crate::meetings::{QUEUE_CAPACITY, analysis_failure_text};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const QUEUE_FULL: &str = "Summary queue is full";
/// Seconds between health probes after an automatic run found the server unreachable.
const PROBE_DELAYS: [u32; 3] = [30, 60, 120];

/// `waitingDelay`: 30 s doubling to 10 min.
pub fn waiting_delay(attempt: u32) -> u32 {
    600.min(30 << attempt.min(5))
}
enum Requeue {
    At(Instant),
    Probe { trigger: String, index: usize, at: Instant },
}
#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    Queued(usize),
    Running(Option<(String, f32)>),
}
#[derive(Default)]
struct Inner {
    queue: Vec<String>,
    admissions: HashMap<String, Admission>,
    admitting: HashSet<String>,
    cancelled: HashSet<String>,
    active: Option<(String, Arc<AtomicBool>)>,
    progress: Option<(String, f32)>,
    requeue: HashMap<String, Requeue>,
    busy_requeued: HashSet<String>,
    unreachable_requeued: HashSet<String>,
    waiting: HashMap<String, u32>,
    notices: Vec<String>,
    not_offered: bool,
}
impl Inner {
    fn drop_requeue(&mut self, id: &str) {
        self.requeue.remove(id);
        self.busy_requeued.remove(id);
        self.unreachable_requeued.remove(id);
        self.waiting.remove(id);
    }
    fn in_flight(&self) -> usize {
        self.queue.len() + self.admitting.len() + usize::from(self.active.is_some())
    }
    fn forget_queued(&mut self, id: &str) {
        self.queue.retain(|q| q != id);
        self.admissions.remove(id);
        self.drop_requeue(id);
    }
}
pub struct Coordinator {
    deps: Arc<Deps>,
    inner: Mutex<Inner>,
    revision: AtomicU64,
}
impl Coordinator {
    pub fn new(deps: Deps) -> Arc<Coordinator> {
        Arc::new(Coordinator { deps: Arc::new(deps), inner: Mutex::default(), revision: AtomicU64::new(0) })
    }
    fn state(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
    fn changed(&self) {
        self.revision.fetch_add(1, Ordering::SeqCst);
    }
    /// Moves on every change the page should show.
    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::SeqCst)
    }
    /// `meetingSpeakersDidSettle`. `meetingSummariesAutomatic` is a retired key in Swift, always true.
    pub fn settled(self: &Arc<Self>, id: &str, route: &Route) {
        self.enqueue(id, "automatic", route);
    }
    /// Launch resume: the reconciler interrupted the leftover rows and picked these meetings.
    pub fn resume(self: &Arc<Self>, ids: &[String], route: &Route) {
        for id in ids {
            self.enqueue(id, "restart", route);
        }
    }
    /// Generate Summary, Retry and Regenerate; the user's request replaces any pending re-queue.
    pub fn request(self: &Arc<Self>, id: &str, trigger: &str, route: &Route) {
        self.state().drop_requeue(id);
        self.enqueue(id, trigger, route);
    }
    fn enqueue(self: &Arc<Self>, id: &str, trigger: &str, route: &Route) {
        {
            let mut s = self.state();
            if s.queue.iter().any(|q| q == id) || s.admitting.contains(id) || s.active.as_ref().is_some_and(|a| a.0 == id) {
                return;
            }
            if s.in_flight() >= QUEUE_CAPACITY {
                s.notices.push(QUEUE_FULL.into());
                drop(s);
                self.changed();
                return;
            }
            s.admitting.insert(id.to_string());
        }
        self.changed();
        let (this, id, trigger, route) = (self.clone(), id.to_string(), trigger.to_string(), route.clone());
        std::thread::spawn(move || this.admit(&id, &trigger, &route));
    }
    fn admit(self: &Arc<Self>, id: &str, trigger: &str, route: &Route) {
        let database = self.deps.database.exists().then(|| Db::open(&self.deps.database).ok()).flatten();
        let outcome = match &database {
            Some(db) => run::admit(&self.deps, db, route, id, trigger),
            None => Err(run::Stop::Internal { full: false }),
        };
        let quiet = trigger == "automatic" || trigger == "restart";
        {
            let mut s = self.state();
            s.admitting.remove(id);
            match outcome {
                Ok(admission) => {
                    if s.cancelled.remove(id) {
                        if let Some(db) = &database {
                            let _ = store::cancel(db, &admission.run, now_ms());
                        }
                    } else {
                        s.queue.push(id.to_string());
                        s.admissions.insert(id.to_string(), admission);
                    }
                }
                Err(stop) => {
                    s.cancelled.remove(id);
                    if !quiet {
                        let category = match &stop {
                            run::Stop::Failure(f) if f.detail.as_deref() == Some("active_run") => None,
                            run::Stop::Failure(f) => Some(f.category),
                            _ => Some("persistence_failure"),
                        };
                        if let Some(category) = category {
                            s.notices.push(analysis_failure_text(category).to_string());
                        }
                    }
                }
            }
        }
        self.changed();
        self.pump();
    }
    fn pump(self: &Arc<Self>) {
        let (id, admission, cancel) = {
            let mut s = self.state();
            if s.active.is_some() || s.queue.is_empty() {
                return;
            }
            let id = s.queue.remove(0);
            let Some(admission) = s.admissions.remove(&id) else {
                drop(s);
                return self.pump();
            };
            let cancel = Arc::new(AtomicBool::new(false));
            s.active = Some((id.clone(), cancel.clone()));
            s.progress = None;
            (id, admission, cancel)
        };
        self.changed();
        let this = self.clone();
        std::thread::spawn(move || {
            let report = |value: Option<(String, f32)>| {
                this.state().progress = value;
                this.changed();
            };
            let row = run::execute(&this.deps, &admission, &cancel, &report);
            this.finish(&id, row);
        });
    }
    fn finish(self: &Arc<Self>, id: &str, row: Option<store::RunRow>) {
        {
            let mut s = self.state();
            s.active = None;
            s.progress = None;
            s.cancelled.remove(id);
            let failed = row.as_ref().filter(|r| r.state == "failed");
            let category = failed.and_then(|r| r.failure_category.as_deref());
            let detail = failed.and_then(|r| r.failure_detail.as_deref());
            let at = |seconds: u32| Instant::now() + self.deps.wait_unit * seconds;
            if detail == Some("not_offered") {
                s.not_offered = true;
            }
            if category == Some("server_unreachable") && detail == Some(WAITING_DETAIL) {
                let attempt = s.waiting.get(id).copied().unwrap_or(0);
                s.waiting.insert(id.to_string(), attempt + 1);
                s.requeue.insert(id.to_string(), Requeue::At(at(waiting_delay(attempt))));
            } else {
                s.waiting.remove(id);
                if category == Some("server_unavailable") && detail == Some("server_busy") && !s.busy_requeued.contains(id) {
                    s.busy_requeued.insert(id.to_string());
                    s.requeue.insert(id.to_string(), Requeue::At(at(30)));
                } else {
                    s.busy_requeued.remove(id);
                }
                let automatic = failed.filter(|r| r.trigger == "automatic" || r.trigger == "restart");
                match automatic.filter(|_| category == Some("server_unreachable") && !s.unreachable_requeued.contains(id)) {
                    Some(r) => {
                        s.unreachable_requeued.insert(id.to_string());
                        s.requeue.insert(id.to_string(), Requeue::Probe { trigger: r.trigger.clone(), index: 0, at: at(PROBE_DELAYS[0]) });
                    }
                    None => {
                        s.unreachable_requeued.remove(id);
                    }
                }
            }
        }
        self.changed();
        self.pump();
    }
    /// Whether a re-queue is due, so the caller can skip building a route (and reading the Keychain).
    pub fn due(&self) -> bool {
        let now = Instant::now();
        self.state().requeue.values().any(|r| match r {
            Requeue::At(at) | Requeue::Probe { at, .. } => *at <= now,
        })
    }
    /// Starts what is due: a retry, or a health probe off this thread.
    pub fn tick(self: &Arc<Self>, route: &Route) {
        let now = Instant::now();
        let mut retries = vec![];
        let mut probes = vec![];
        {
            let mut s = self.state();
            let keys: Vec<String> = s.requeue.keys().cloned().collect();
            for id in keys {
                match s.requeue.get_mut(&id) {
                    Some(Requeue::At(at)) if *at <= now => {
                        s.requeue.remove(&id);
                        retries.push(id);
                    }
                    Some(Requeue::Probe { at, trigger, index }) if *at <= now => {
                        // Far ahead while the probe is out; the probe's answer replaces it.
                        *at = now + Duration::from_secs(3600);
                        probes.push((id, trigger.clone(), *index));
                    }
                    _ => {}
                }
            }
        }
        for id in retries {
            self.enqueue(&id, "retry", route);
        }
        for (id, trigger, index) in probes {
            let (this, route) = (self.clone(), route.clone());
            std::thread::spawn(move || {
                let reachable = run::server_reachable(&this.deps, &route);
                {
                    let mut s = this.state();
                    // Cancelled, deleted or re-requested while the probe was out.
                    if !s.requeue.contains_key(&id) {
                        return;
                    }
                    if !reachable && index + 1 < PROBE_DELAYS.len() {
                        let at = Instant::now() + this.deps.wait_unit * PROBE_DELAYS[index + 1];
                        s.requeue.insert(id.clone(), Requeue::Probe { trigger: trigger.clone(), index: index + 1, at });
                        return;
                    }
                    s.requeue.remove(&id);
                }
                if reachable {
                    this.enqueue(&id, &trigger, &route);
                }
            });
        }
    }
    /// A channel opened or the network changed: runs waiting for the server retry now, and their
    /// backoff starts again.
    pub fn server_may_be_reachable(self: &Arc<Self>, route: &Route) {
        let ids: Vec<String> = {
            let mut s = self.state();
            let ids: Vec<String> = s.waiting.keys().filter(|id| s.requeue.contains_key(*id)).cloned().collect();
            for id in &ids {
                s.requeue.remove(id);
                s.waiting.insert(id.clone(), 0);
            }
            ids
        };
        for id in ids {
            self.enqueue(&id, "retry", route);
        }
    }
    /// **Run on this Mac**: the meeting is already marked; its summary runs locally now.
    pub fn run_locally(self: &Arc<Self>, id: &str, route: &Route) {
        {
            let mut s = self.state();
            if s.waiting.remove(id).is_none() {
                return;
            }
            s.requeue.remove(id);
        }
        self.enqueue(id, "retry", route);
    }
    /// Cancels the queued or running analysis. `db` is the caller's connection.
    pub fn cancel(self: &Arc<Self>, db: &Db, id: &str) {
        {
            let mut s = self.state();
            s.forget_queued(id);
            match &s.active {
                Some((active, flag)) if active == id => flag.store(true, Ordering::SeqCst),
                _ => {
                    if s.admitting.contains(id) {
                        s.cancelled.insert(id.to_string());
                    }
                    cancel_latest(db, id);
                }
            }
        }
        self.changed();
    }
    /// `meetingWillDelete`.
    // ponytail: doesn't join a running run as Swift does. Its later writes find no row and are dropped; a
    // request in flight runs to its answer. Join here if a deleted meeting's text mustn't reach the server.
    pub fn will_delete(self: &Arc<Self>, db: &Db, id: &str) {
        {
            let mut s = self.state();
            s.forget_queued(id);
            if let Some((active, flag)) = &s.active
                && active == id
            {
                flag.store(true, Ordering::SeqCst);
            }
            if s.admitting.contains(id) {
                s.cancelled.insert(id.to_string());
            }
            cancel_latest(db, id);
        }
        if let Ok(mut cache) = self.deps.partials.lock() {
            cache.forget(id);
        }
        self.changed();
    }
    pub fn status(&self, id: &str) -> Option<Status> {
        let s = self.state();
        if s.active.as_ref().is_some_and(|a| a.0 == id) {
            return Some(Status::Running(s.progress.clone()));
        }
        s.queue.iter().position(|q| q == id).map(|p| Status::Queued(p + 1))
    }
    /// A run holds the local model: idle, game and pressure unloads wait.
    pub fn busy(&self) -> bool {
        self.state().active.is_some()
    }
    pub fn in_flight(&self) -> usize {
        self.state().in_flight()
    }
    pub fn queued(&self) -> Vec<String> {
        let s = self.state();
        s.active.iter().map(|a| a.0.clone()).chain(s.queue.iter().cloned()).chain(s.admitting.iter().cloned()).collect()
    }
    /// `waitingForServer`.
    pub fn waiting(&self) -> HashSet<String> {
        self.state().waiting.keys().cloned().collect()
    }
    pub fn drain_notices(&self) -> Vec<String> {
        std::mem::take(&mut self.state().notices)
    }
    /// The server answered `not_offered` since the last call: the caller drops the capability.
    pub fn take_not_offered(&self) -> bool {
        std::mem::take(&mut self.state().not_offered)
    }
}
fn cancel_latest(db: &Db, id: &str) {
    if let Ok(Some(run)) = store::latest_run(db, id)
        && matches!(run.state.as_str(), "pending" | "running")
    {
        let _ = store::cancel(db, &run.id, now_ms());
    }
}
