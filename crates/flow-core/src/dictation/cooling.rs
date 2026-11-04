//! After a dictation falls back from the server, the next ones skip it for a while instead of each
//! waiting out the accept budget again. A background identity probe ends the wait early; a server
//! dictation that completes ends it too. Nothing here listens or adds a protocol message: the probe
//! is the `GET /v1/remote/identity` pairing already uses.
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The first skip after a failure; each failure after it doubles, up to `COOLING_MAX`.
pub const COOLING_FIRST: Duration = Duration::from_secs(30);
pub const COOLING_MAX: Duration = Duration::from_secs(5 * 60);
/// How often the probe asks while the server is cooling.
pub const PROBE_INTERVAL: Duration = Duration::from_secs(10);

/// The failures that say the server can't take a dictation right now. Pairing and approval
/// answers aren't here: those change the enrollment, and routing follows it.
pub fn cools(reason: &str) -> bool {
    matches!(reason, "unreachable" | "timeout" | "worker_unavailable" | "busy")
}

pub type Probe = Arc<dyn Fn(&str) -> bool + Send + Sync>;
/// Time that counts sleep, as `remote::enrollment::system_now`: a Mac asleep through the backoff
/// wakes with it spent.
type Clock = Box<dyn Fn() -> Duration + Send + Sync>;

#[derive(Default)]
struct State {
    /// The server that failed, until when, and why.
    origin: Option<String>,
    until: Option<Duration>,
    reason: &'static str,
    /// The skip the next failure starts.
    next: Duration,
    probing: bool,
}

pub struct Cooling {
    state: Mutex<State>,
    now: Clock,
    probe: Option<Probe>,
}

impl Cooling {
    /// `probe` runs on its own thread while cooling; `None` leaves probing to `probe_once`.
    pub fn new(probe: Option<Probe>, now: Clock) -> Arc<Cooling> {
        Arc::new(Cooling { state: Mutex::new(State { next: COOLING_FIRST, ..State::default() }), now, probe })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The reason the server at `origin` is being skipped, while it is.
    pub fn skip(&self, origin: &str) -> Option<&'static str> {
        let now = (self.now)();
        let s = self.state();
        (s.origin.as_deref() == Some(origin) && s.until.is_some_and(|until| now < until)).then_some(s.reason)
    }

    /// A dictation lost the server for `reason`. Other reasons don't cool it.
    pub fn failed(self: &Arc<Self>, origin: &str, reason: &'static str) {
        if !cools(reason) {
            return;
        }
        let now = (self.now)();
        let mut s = self.state();
        if s.origin.as_deref() != Some(origin) {
            s.next = COOLING_FIRST;
        }
        s.origin = Some(origin.to_string());
        s.until = Some(now + s.next);
        s.reason = reason;
        s.next = (s.next * 2).min(COOLING_MAX);
        let start = self.probe.is_some() && !std::mem::replace(&mut s.probing, true);
        drop(s);
        if start {
            let me = self.clone();
            let spawned = std::thread::Builder::new().name("server-probe".into()).spawn(move || {
                loop {
                    std::thread::sleep(PROBE_INTERVAL);
                    if !me.probe_once() {
                        break;
                    }
                }
                me.state().probing = false;
            });
            if spawned.is_err() {
                self.state().probing = false;
            }
        }
    }

    /// The server answered: back to normal, and the next failure skips it for `COOLING_FIRST`.
    pub fn succeeded(&self) {
        let mut s = self.state();
        (s.origin, s.until, s.next) = (None, None, COOLING_FIRST);
    }

    /// One probe of the cooling server. True while it's still cooling, so the probe keeps going.
    pub fn probe_once(&self) -> bool {
        let origin = self.state().origin.clone();
        let Some(origin) = origin.filter(|o| self.skip(o).is_some()) else { return false };
        let Some(probe) = &self.probe else { return true };
        if probe(&origin) {
            // A dictation may have cooled another server meanwhile; only this one clears.
            if self.state().origin.as_deref() == Some(origin.as_str()) {
                self.succeeded();
            }
            return false;
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::SeqCst};

    /// A clock tests move by hand, and a probe they answer.
    fn rig() -> (Arc<Cooling>, Arc<AtomicU64>, Arc<AtomicBool>) {
        let (offset, answer) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicBool::new(false)));
        let (clock, probe_answer) = (offset.clone(), answer.clone());
        let cooling = Arc::new(Cooling { state: Mutex::new(State { next: COOLING_FIRST, ..State::default() }), now: Box::new(move || Duration::from_secs(clock.load(SeqCst))), probe: Some(Arc::new(move |_| probe_answer.load(SeqCst))) });
        (cooling, offset, answer)
    }

    #[test]
    fn a_failure_skips_the_server_for_a_backoff_that_doubles_to_five_minutes() {
        let (c, clock, _) = rig();
        // The probe thread this starts sleeps `PROBE_INTERVAL` before its first try, past this test.
        let failed = |c: &Arc<Cooling>| c.failed("o", "worker_unavailable");
        assert_eq!(c.skip("o"), None);
        failed(&c);
        assert_eq!(c.skip("o"), Some("worker_unavailable"));
        assert_eq!(c.skip("another"), None, "only the server that failed");
        clock.store(29, SeqCst);
        assert!(c.skip("o").is_some());
        clock.store(30, SeqCst);
        assert_eq!(c.skip("o"), None, "the backoff ran out: the next dictation tries the server");
        let mut skips = vec![];
        for _ in 0..6 {
            let at = clock.load(SeqCst);
            failed(&c);
            let mut t = at;
            while c.skip("o").is_some() {
                t += 1;
                clock.store(t, SeqCst);
            }
            skips.push(t - at);
        }
        assert_eq!(skips, [60, 120, 240, 300, 300, 300]);
        c.succeeded();
        assert_eq!(c.skip("o"), None);
        let at = clock.load(SeqCst);
        failed(&c);
        clock.store(at + 30, SeqCst);
        assert_eq!(c.skip("o"), None, "a success starts the backoff over");
    }

    #[test]
    fn only_availability_failures_cool_the_server() {
        let (c, _, _) = rig();
        for reason in ["unauthorized", "revoked", "pin_mismatch", "protocol_error", "limit_exceeded", "not_approved"] {
            c.failed("o", reason);
            assert_eq!(c.skip("o"), None, "{reason}");
        }
        assert!(["unreachable", "timeout", "worker_unavailable", "busy"].iter().all(|r| cools(r)));
    }

    #[test]
    fn a_probe_success_clears_cooling_and_a_failure_keeps_it() {
        let (c, _, answer) = rig();
        {
            let mut s = c.state();
            s.origin = Some("o".into());
            s.until = Some((c.now)() + COOLING_FIRST);
            s.reason = "unreachable";
        }
        assert!(c.probe_once(), "still down: keep probing");
        assert_eq!(c.skip("o"), Some("unreachable"));
        answer.store(true, SeqCst);
        assert!(!c.probe_once(), "up: the probe stops");
        assert_eq!(c.skip("o"), None);
        assert!(!c.probe_once(), "nothing cooling: nothing to probe");
    }

    #[test]
    fn a_failure_starts_one_probe_thread() {
        let (c, _, _) = rig();
        c.failed("o", "unreachable");
        c.failed("o", "unreachable");
        assert!(c.state().probing);
        // The thread sleeps `PROBE_INTERVAL` first; clearing now makes its first probe its last.
        c.succeeded();
    }
}
