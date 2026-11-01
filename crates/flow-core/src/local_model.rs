//! When the local rewrite model runs: `LocalModelResidency`, without its game and memory-pressure
//! rules. Starting and stopping are the platform's; this only decides.
use crate::settings::{loopback_endpoint, rewrite_health, routing};
use crate::prefs::Prefs;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::time::{Duration, Instant};

static WAKE: AtomicBool = AtomicBool::new(false);

/// Asks the app's next tick for the model, from any thread.
pub fn wake() {
    WAKE.store(true, SeqCst);
}
pub fn take_wake() -> bool {
    WAKE.swap(false, SeqCst)
}

/// Rewriting points at this Mac, and a server doesn't serve both rewriting and summaries.
pub fn wanted(prefs: &Prefs) -> bool {
    let r = routing(prefs);
    !r.local_rewrite_model_unneeded() && r.rewrite_endpoint(&prefs.string("rewriteEndpoint").unwrap_or_default()) == loopback_endpoint()
}

/// Before a request to this Mac's flowd: wakes the model and waits, at most `limit`, until flowd
/// reports it serving. On timeout the request goes anyway and reports its own failure.
pub fn wait_until_ready(origin: &str, secret: Option<&str>, limit: Duration, cancel: &AtomicBool) {
    if origin != loopback_endpoint() {
        return;
    }
    wake();
    let end = Instant::now() + limit;
    while Instant::now() < end && !cancel.load(SeqCst) {
        if rewrite_health(origin, secret).is_ok_and(|h| h.backend.is_some_and(|b| b.state == "ready")) {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

#[derive(Default)]
pub struct Residency {
    running: bool,
    used: Option<Instant>,
}

impl Residency {
    /// Always asks for a start: one that's already up does nothing, and a crashed one recovers.
    pub fn wake(&mut self, wanted: bool, now: Instant) -> Option<bool> {
        if !wanted {
            return None;
        }
        (self.running, self.used) = (true, Some(now));
        Some(true)
    }

    /// `Some(run)` when the model should change. A `None` idle limit never unloads.
    pub fn tick(&mut self, wanted: bool, busy: bool, idle: Option<Duration>, now: Instant) -> Option<bool> {
        if !wanted {
            self.used = None;
            return std::mem::take(&mut self.running).then_some(false);
        }
        let Some(used) = self.used else { return self.wake(true, now) };
        if busy {
            self.used = Some(now);
        } else if self.running && idle.is_some_and(|limit| now.duration_since(used) >= limit) {
            self.running = false;
            return Some(false);
        }
        None
    }

    /// At quit: `true` when the model must be stopped.
    pub fn stop(&mut self) -> bool {
        std::mem::take(&mut self.running)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_once_unloads_when_idle_and_a_wake_brings_it_back() {
        let (mut r, t) = (Residency::default(), Instant::now());
        let idle = Some(Duration::from_secs(900));
        let at = |s| t + Duration::from_secs(s);
        assert_eq!(r.tick(true, false, idle, t), Some(true), "at launch");
        assert_eq!(r.tick(true, false, idle, at(899)), None);
        assert_eq!(r.tick(true, true, idle, at(900)), None, "busy holds it and counts as use");
        assert_eq!(r.tick(true, false, idle, at(1799)), None);
        assert_eq!(r.tick(true, false, idle, at(1800)), Some(false));
        assert_eq!(r.tick(true, false, idle, at(9000)), None, "stays stopped until asked");
        assert_eq!(r.wake(true, at(9001)), Some(true));
        assert_eq!(r.wake(true, at(9002)), Some(true), "repeats, to recover a crash");
    }

    #[test]
    fn never_unloads_without_a_limit_and_stops_when_no_longer_wanted() {
        let (mut r, t) = (Residency::default(), Instant::now());
        assert_eq!(r.tick(true, false, None, t), Some(true));
        assert_eq!(r.tick(true, false, None, t + Duration::from_secs(99_999)), None);
        assert_eq!(r.tick(false, false, None, t), Some(false));
        assert_eq!(r.tick(false, false, None, t), None);
        assert_eq!(r.wake(false, t), None);
        assert!(!r.stop());
        r.tick(true, false, None, t);
        assert!(r.stop());
    }
}
