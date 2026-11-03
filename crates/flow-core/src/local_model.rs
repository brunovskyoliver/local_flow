//! When the local rewrite model runs: `LocalModelResidency`. Starting and stopping are the platform's; this only decides.
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

/// How a wait for the model went: `cold` when it wasn't serving at the first check.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Wait {
    pub cold: bool,
    pub ready: bool,
    pub waited: Duration,
}

/// Before a request to this Mac's flowd: wakes the model and waits, at most `limit`, until flowd
/// reports it serving. `starting` runs once, when the first check finds it not serving. On timeout
/// the request goes anyway and reports its own failure.
pub fn wait_until_ready(origin: &str, secret: Option<&str>, limit: Duration, cancel: &AtomicBool, starting: &mut dyn FnMut()) -> Wait {
    if origin != loopback_endpoint() {
        return Wait { ready: true, ..Wait::default() };
    }
    let ready = || rewrite_health(origin, secret).is_ok_and(|h| h.backend.is_some_and(|b| b.state == "ready"));
    wait_for(ready, wake, limit, cancel, starting)
}

/// `ready` comes first, so a serving model costs one check and no start request.
fn wait_for(ready: impl Fn() -> bool, wake: impl Fn(), limit: Duration, cancel: &AtomicBool, starting: &mut dyn FnMut()) -> Wait {
    let began = Instant::now();
    let end = began + limit;
    let mut polls = 0u32;
    while Instant::now() < end && !cancel.load(SeqCst) {
        if ready() {
            return Wait { cold: polls > 0, ready: true, waited: began.elapsed() };
        }
        if polls == 0 {
            starting();
        }
        // launchd ignores a start while the job is still stopping (up to 5 s after SIGTERM), so keep asking.
        if polls % 20 == 0 {
            wake();
        }
        polls += 1;
        std::thread::sleep(Duration::from_millis(50));
    }
    Wait { cold: true, ready: false, waited: began.elapsed() }
}

/// One rewrite on this Mac's model, for `rewrite-timing.log`. Never holds text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Timing {
    pub wait: Wait,
    /// From the end of the wait to the answer.
    pub rewrite: Duration,
    /// `ok`, `timeout`, `cancelled`, `failed` or `not_eligible`.
    pub outcome: &'static str,
}

impl Timing {
    /// One line: Unix seconds, then `key=value` fields.
    pub fn line(&self, unix: u64) -> String {
        format!(
            "{unix} cold={} ready={} wait_ms={} rewrite_ms={} total_ms={} outcome={}\n",
            self.wait.cold,
            self.wait.ready,
            self.wait.waited.as_millis(),
            self.rewrite.as_millis(),
            (self.wait.waited + self.rewrite).as_millis(),
            self.outcome
        )
    }
}

/// Appends `line`; past `cap` bytes the file becomes `<name>.1` (replacing an older one) first.
pub fn append_capped(path: &std::path::Path, line: &str, cap: u64) -> std::io::Result<()> {
    use std::io::Write;
    if std::fs::metadata(path).is_ok_and(|m| m.len() + line.len() as u64 > cap) {
        std::fs::rename(path, path.with_extension("1.log"))?;
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::OpenOptions::new().create(true).append(true).open(path)?.write_all(line.as_bytes())
}

/// A game must stay in front this long before the model unloads; alt-tabbing through one doesn't count.
pub const GAME_DELAY: Duration = Duration::from_secs(60);

/// What the app sees on one tick.
#[derive(Clone, Copy, Default)]
pub struct Signals {
    pub wanted: bool,
    pub busy: bool,
    pub idle: Option<Duration>,
    /// The frontmost app's process when it's a game and "Unload during games" is on.
    pub game: Option<i32>,
    /// The system reported memory pressure since the last tick.
    pub pressure: bool,
}

#[derive(Default)]
pub struct Residency {
    running: bool,
    used: Option<Instant>,
    /// The game in front now, and when it can unload the model. The time clears once it fires, so a
    /// dictation during a long game keeps the model until the idle limit, as in Swift.
    game: Option<i32>,
    game_at: Option<Instant>,
    /// The game that unloaded the model: when it quits the model comes back.
    unloaded_for: Option<i32>,
}

impl Residency {
    /// Always asks for a start: one that's already up does nothing, and a crashed one recovers.
    pub fn wake(&mut self, wanted: bool, now: Instant) -> Option<bool> {
        if !wanted {
            return None;
        }
        (self.running, self.used, self.unloaded_for) = (true, Some(now), None);
        Some(true)
    }

    /// `Some(run)` when the model should change. `alive` says whether a game's process still runs.
    pub fn tick(&mut self, s: Signals, alive: impl Fn(i32) -> bool, now: Instant) -> Option<bool> {
        if !s.wanted {
            (self.used, self.game, self.game_at, self.unloaded_for) = (None, None, None, None);
            return std::mem::take(&mut self.running).then_some(false);
        }
        let Some(used) = self.used else { return self.wake(true, now) };
        if s.game != self.game {
            self.game = s.game;
            self.game_at = s.game.map(|_| now + GAME_DELAY);
        }
        if self.unloaded_for.is_some_and(|pid| !alive(pid)) {
            return self.wake(true, now);
        }
        if s.busy {
            self.used = Some(now);
            if self.game_at.is_some_and(|at| now >= at) {
                self.game_at = Some(now + GAME_DELAY);
            }
            return None;
        }
        if self.running && self.game_at.is_some_and(|at| now >= at) {
            self.game_at = None;
            (self.running, self.unloaded_for) = (false, self.game);
            return Some(false);
        }
        if self.running && (s.pressure || s.idle.is_some_and(|limit| now.duration_since(used) >= limit)) {
            self.running = false;
            return Some(false);
        }
        None
    }

    /// The game whose quit would bring the model back.
    pub fn unloaded_game(&self) -> Option<i32> {
        self.unloaded_for
    }

    /// At quit: `true` when the model must be stopped.
    pub fn stop(&mut self) -> bool {
        std::mem::take(&mut self.running)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on(idle: Option<u64>) -> Signals {
        Signals { wanted: true, idle: idle.map(Duration::from_secs), ..Signals::default() }
    }
    const ALIVE: fn(i32) -> bool = |_| true;

    #[test]
    fn a_ready_model_is_not_woken_and_a_loading_one_is_seen_quickly() {
        use std::cell::Cell;
        let (checks, wakes, stop) = (Cell::new(0), Cell::new(0), AtomicBool::new(false));
        let limit = Duration::from_secs(5);
        let starts = Cell::new(0);
        let warm = wait_for(|| { checks.set(checks.get() + 1); true }, || wakes.set(wakes.get() + 1), limit, &stop, &mut || starts.set(starts.get() + 1));
        assert_eq!((checks.get(), wakes.get(), starts.get()), (1, 0, 0));
        assert!(!warm.cold && warm.ready, "a serving model is warm");
        checks.set(0);
        let began = Instant::now();
        let cold = wait_for(|| { checks.set(checks.get() + 1); checks.get() == 3 }, || wakes.set(wakes.get() + 1), limit, &stop, &mut || starts.set(starts.get() + 1));
        assert_eq!(wakes.get(), 1, "a model that isn't up is asked for");
        assert_eq!(starts.get(), 1, "the starting notice runs once");
        assert!(cold.cold && cold.ready);
        assert!(began.elapsed() < Duration::from_secs(1), "polled, not slept through");
    }

    #[test]
    fn a_cancelled_or_timed_out_wait_ends_within_one_poll_and_is_not_ready() {
        let stop = AtomicBool::new(true);
        let w = wait_for(|| false, || {}, Duration::from_secs(5), &stop, &mut || {});
        assert!(!w.ready && w.waited < Duration::from_millis(100));
        let go = AtomicBool::new(false);
        let w = wait_for(|| false, || {}, Duration::from_millis(120), &go, &mut || {});
        assert!(!w.ready && w.cold && w.waited < Duration::from_millis(250));
    }

    #[test]
    fn a_timing_line_carries_numbers_only_and_the_log_rolls_over_once() {
        let t = Timing { wait: Wait { cold: true, ready: true, waited: Duration::from_millis(4200) }, rewrite: Duration::from_millis(810), outcome: "ok" };
        assert_eq!(t.line(7), "7 cold=true ready=true wait_ms=4200 rewrite_ms=810 total_ms=5010 outcome=ok\n");
        let dir = std::env::temp_dir().join(format!("lf-timing-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("rewrite-timing.log");
        let line = t.line(7);
        for _ in 0..5 {
            append_capped(&path, &line, line.len() as u64 * 2).unwrap();
        }
        let files: Vec<_> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        assert_eq!(files.len(), 2, "{files:?}");
        assert!(std::fs::metadata(&path).unwrap().len() <= line.len() as u64 * 2);
        assert!(dir.join("rewrite-timing.1.log").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn starts_once_unloads_when_idle_and_a_wake_brings_it_back() {
        let (mut r, t) = (Residency::default(), Instant::now());
        let at = |s| t + Duration::from_secs(s);
        let s = on(Some(900));
        assert_eq!(r.tick(s, ALIVE, t), Some(true), "at launch");
        assert_eq!(r.tick(s, ALIVE, at(899)), None);
        assert_eq!(r.tick(Signals { busy: true, ..s }, ALIVE, at(900)), None, "busy holds it and counts as use");
        assert_eq!(r.tick(s, ALIVE, at(1799)), None);
        assert_eq!(r.tick(s, ALIVE, at(1800)), Some(false));
        assert_eq!(r.tick(s, ALIVE, at(9000)), None, "stays stopped until asked");
        assert_eq!(r.wake(true, at(9001)), Some(true));
        assert_eq!(r.wake(true, at(9002)), Some(true), "repeats, to recover a crash");
    }

    #[test]
    fn never_unloads_without_a_limit_and_stops_when_no_longer_wanted() {
        let (mut r, t) = (Residency::default(), Instant::now());
        assert_eq!(r.tick(on(None), ALIVE, t), Some(true));
        assert_eq!(r.tick(on(None), ALIVE, t + Duration::from_secs(99_999)), None);
        assert_eq!(r.tick(Signals::default(), ALIVE, t), Some(false));
        assert_eq!(r.tick(Signals::default(), ALIVE, t), None);
        assert_eq!(r.wake(false, t), None);
        assert!(!r.stop());
        r.tick(on(None), ALIVE, t);
        assert!(r.stop());
    }

    #[test]
    fn a_game_in_front_for_a_minute_unloads_and_quitting_it_reloads() {
        let (mut r, t) = (Residency::default(), Instant::now());
        let at = |s| t + Duration::from_secs(s);
        let game = Signals { game: Some(7), ..on(None) };
        r.tick(on(None), ALIVE, t);
        assert_eq!(r.tick(game, ALIVE, at(1)), None);
        assert_eq!(r.tick(on(None), ALIVE, at(30)), None, "alt-tab away cancels");
        assert_eq!(r.tick(game, ALIVE, at(31)), None);
        assert_eq!(r.tick(game, ALIVE, at(90)), None, "the minute restarted");
        assert_eq!(r.tick(Signals { busy: true, ..game }, ALIVE, at(91)), None, "busy puts it off");
        assert_eq!(r.tick(game, ALIVE, at(150)), None);
        assert_eq!(r.tick(game, ALIVE, at(151)), Some(false));
        assert_eq!(r.tick(on(None), ALIVE, at(200)), None, "still open behind another app");
        assert_eq!(r.tick(on(None), |_| false, at(201)), Some(true), "game quit");
        assert_eq!(r.tick(on(None), |_| false, at(202)), None);
    }

    #[test]
    fn a_dictation_during_a_game_keeps_the_model_until_the_idle_limit() {
        let (mut r, t) = (Residency::default(), Instant::now());
        let at = |s| t + Duration::from_secs(s);
        let game = Signals { game: Some(7), ..on(Some(900)) };
        r.tick(on(Some(900)), ALIVE, t);
        r.tick(game, ALIVE, at(1));
        assert_eq!(r.tick(game, ALIVE, at(61)), Some(false));
        assert_eq!(r.wake(true, at(100)), Some(true));
        assert_eq!(r.tick(game, ALIVE, at(200)), None, "the game doesn't unload it twice");
        assert_eq!(r.tick(game, |_| false, at(201)), None, "and its quit isn't a reload any more");
        assert_eq!(r.tick(game, ALIVE, at(1000)), Some(false));
    }

    #[test]
    fn memory_pressure_unloads_unless_busy_and_a_game_quit_then_does_nothing() {
        let (mut r, t) = (Residency::default(), Instant::now());
        let pressed = Signals { pressure: true, ..on(None) };
        r.tick(on(None), ALIVE, t);
        assert_eq!(r.tick(Signals { busy: true, ..pressed }, ALIVE, t), None);
        assert_eq!(r.tick(pressed, ALIVE, t), Some(false));
        assert_eq!(r.tick(on(None), |_| false, t), None);
    }
}
