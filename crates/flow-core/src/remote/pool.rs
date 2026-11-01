//! `RemoteChannelPool`: a device's channels by role. flowd allows four per device and runs one op at a
//! time on each, so each role serves one caller at a time and the next waits.
use super::channel::{Channel, ChannelError};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Condvar, Mutex};
use std::time::Duration;

/// flowd closes a channel after 30 s between operations, counted from before the client parks it.
/// An older parked channel is closed instead of used.
pub const MAX_PARKED_AGE: Duration = Duration::from_secs(20);

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    /// Dictation and rewrite.
    Interactive,
    /// Live meeting preview.
    Live,
    /// Summaries and meeting jobs.
    Background,
}

struct Parked {
    channel: Channel,
    next_op: i64,
    at: Duration,
}

#[derive(Default)]
struct State {
    parked: BTreeMap<Role, Parked>,
    leased: BTreeSet<Role>,
    /// Leased when `close_parked` ran: these close on release instead of parking.
    closing: BTreeSet<Role>,
}

pub type Opener = Box<dyn Fn() -> Result<Channel, ChannelError> + Send + Sync>;

pub struct Pool {
    open: Opener,
    now: Box<dyn Fn() -> Duration + Send + Sync>,
    state: Mutex<State>,
    freed: Condvar,
}

impl Pool {
    /// `now` includes time asleep, so a channel parked before sleep isn't reused.
    pub fn new(open: Opener, now: Box<dyn Fn() -> Duration + Send + Sync>) -> Pool {
        Pool { open, now, state: Mutex::default(), freed: Condvar::new() }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn claim(&self, role: Role) -> Option<Parked> {
        let mut state = self.state();
        while state.leased.contains(&role) {
            state = self.freed.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        state.leased.insert(role);
        state.parked.remove(&role)
    }

    fn hand_off(&self, role: Role) {
        let mut state = self.state();
        state.leased.remove(&role);
        state.closing.remove(&role);
        drop(state);
        self.freed.notify_all();
    }

    /// The role's channel and the op number to use, once no other caller holds the role. Pair every
    /// lease with `release`.
    pub fn lease(&self, role: Role) -> Result<(Channel, i64), ChannelError> {
        if let Some(current) = self.claim(role) {
            if (self.now)().saturating_sub(current.at) <= MAX_PARKED_AGE {
                return Ok((current.channel, current.next_op));
            }
        }
        match (self.open)() {
            Ok(channel) => Ok((channel, 1)),
            Err(e) => {
                self.hand_off(role);
                Err(e)
            }
        }
    }

    /// Ends the lease. A channel whose op finished cleanly is kept for the next op; any other closes.
    pub fn release(&self, role: Role, channel: Channel, next_op: Option<i64>) {
        let at = (self.now)();
        let mut state = self.state();
        if let Some(next_op) = next_op.filter(|_| !state.closing.contains(&role)) {
            state.parked.insert(role, Parked { channel, next_op, at });
        }
        drop(state);
        self.hand_off(role);
    }

    /// Keeps a channel an op outside the pool finished on, as dictation hands its channel to the
    /// rewrite after it. One the role doesn't need right now closes.
    pub fn park(&self, role: Role, channel: Channel, next_op: i64) {
        let at = (self.now)();
        let mut state = self.state();
        if !state.leased.contains(&role) {
            state.parked.insert(role, Parked { channel, next_op, at });
        }
    }

    /// A fresh channel for `role`, timed to `ready` and closed. A parked one closes first: reusing it
    /// proves nothing about the server.
    pub fn round_trip(&self, role: Role) -> Result<Duration, ChannelError> {
        drop(self.claim(role));
        let started = (self.now)();
        let opened = (self.open)();
        let elapsed = (self.now)().saturating_sub(started);
        self.hand_off(role);
        opened.map(|_| elapsed)
    }

    /// A new session channel outside the roles, for one long op. The caller closes it.
    pub fn open_channel(&self) -> Result<Channel, ChannelError> {
        (self.open)()
    }

    /// Closes every idle channel, and every leased one as its op ends.
    pub fn close_parked(&self) {
        let mut state = self.state();
        state.parked.clear();
        state.closing = state.leased.clone();
    }
}

#[cfg(test)]
mod tests {
    use super::super::channel::{Purpose, Transports};
    use super::super::scripted::{Counters, Reply, Script};
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn pool(replies: usize) -> (Pool, Counters, Arc<AtomicU64>) {
        let script = Script::new(vec![Reply::ready(); replies]);
        let counters = script.counters();
        let clock = Arc::new(AtomicU64::new(0));
        let now = clock.clone();
        let open: Opener = Box::new(move || {
            let mut channel = Channel::new(script.open("ws://x").map_err(|_| ChannelError::Unreachable)?, &script.public_key())?;
            channel.open(Purpose::Session, Some("token"))?;
            Ok(channel)
        });
        (Pool::new(open, Box::new(move || Duration::from_secs(now.load(Ordering::SeqCst)))), counters, clock)
    }

    #[test]
    fn a_clean_channel_is_reused_with_the_next_op() {
        let (pool, counters, _) = pool(3);
        let (channel, op) = pool.lease(Role::Background).unwrap();
        assert_eq!(op, 1);
        pool.release(Role::Background, channel, Some(2));
        let (channel, op) = pool.lease(Role::Background).unwrap();
        assert_eq!(op, 2, "the parked channel");
        assert_eq!(counters.opened(), 1);
        pool.release(Role::Background, channel, None);
        assert_eq!(counters.closed(), 1, "a channel that didn't finish cleanly closes");
        let (_, op) = pool.lease(Role::Background).unwrap();
        assert_eq!(op, 1);
        assert_eq!(counters.opened(), 2);
    }

    #[test]
    fn roles_park_one_channel_each_and_old_ones_close() {
        let (pool, counters, clock) = pool(4);
        let (live, _) = pool.lease(Role::Live).unwrap();
        let (interactive, _) = pool.lease(Role::Interactive).unwrap();
        pool.release(Role::Live, live, Some(2));
        pool.release(Role::Interactive, interactive, Some(2));
        assert_eq!(counters.opened(), 2);
        clock.store(21, Ordering::SeqCst);
        let (_fresh, op) = pool.lease(Role::Live).unwrap();
        assert_eq!(op, 1, "older than 20 s");
        assert_eq!(counters.opened(), 3);
        assert_eq!(counters.closed(), 1);
    }

    #[test]
    fn close_parked_closes_every_idle_channel_and_only_those() {
        let (pool, counters, _) = pool(3);
        let (live, _) = pool.lease(Role::Live).unwrap();
        let (interactive, _) = pool.lease(Role::Interactive).unwrap();
        let (leased, _) = pool.lease(Role::Background).unwrap();
        pool.release(Role::Live, live, Some(2));
        pool.release(Role::Interactive, interactive, Some(2));
        pool.close_parked();
        assert_eq!(counters.closed(), 2);
        drop(leased);
    }

    #[test]
    fn a_channel_leased_during_close_parked_closes_on_release() {
        let (pool, counters, _) = pool(2);
        let (leased, _) = pool.lease(Role::Background).unwrap();
        pool.close_parked();
        pool.release(Role::Background, leased, Some(2));
        assert_eq!(counters.closed(), 1);
        let (_, op) = pool.lease(Role::Background).unwrap();
        assert_eq!(op, 1, "a fresh channel, and only this lease was marked");
    }

    #[test]
    fn round_trip_never_reuses_a_parked_channel() {
        let (pool, counters, _) = pool(2);
        let (channel, _) = pool.lease(Role::Background).unwrap();
        pool.release(Role::Background, channel, Some(2));
        pool.round_trip(Role::Background).unwrap();
        assert_eq!(counters.opened(), 2);
        assert_eq!(counters.closed(), 2, "the parked one and the fresh one");
    }

    #[test]
    fn a_failed_open_frees_the_role() {
        let (pool, _, _) = pool(0);
        assert!(pool.lease(Role::Live).is_err());
        assert!(pool.lease(Role::Live).is_err(), "not stuck waiting for itself");
    }

    #[test]
    fn the_next_caller_waits_for_the_role() {
        let (pool, counters, _) = pool(1);
        let pool = Arc::new(pool);
        let (channel, _) = pool.lease(Role::Background).unwrap();
        let other = pool.clone();
        let waiter = std::thread::spawn(move || other.lease(Role::Background).map(|(_, op)| op));
        std::thread::sleep(Duration::from_millis(50));
        assert!(!waiter.is_finished());
        pool.release(Role::Background, channel, Some(2));
        assert_eq!(waiter.join().unwrap(), Ok(2));
        assert_eq!(counters.opened(), 1);
    }
}
