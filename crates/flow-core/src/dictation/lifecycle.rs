//! One owner for the speech worker (principle 3): lazy start, keep or release, exclusive use,
//! restart with backoff, release by exit. The caller drives it from one thread; `recognize` blocks.
use super::worker::{
    Backoff, Boost, Client, Fatal, JOB_DEADLINE, JobError, ModelIdentity, READY_TIMEOUT,
    Recognized, SHUTDOWN_GRACE, Started, UNAVAILABLE_RETRY,
};
use std::io::{self, Read, Write};
use std::time::{Duration, Instant};

/// `ModelLifecycleCoordinator`'s client cooldown.
pub const IDLE_RELEASE: Duration = Duration::from_secs(30);

pub trait Process: Send {
    fn kill(&mut self);
    /// True once it has exited; false if `timeout` passed first.
    fn wait(&mut self, timeout: Duration) -> bool;
}

pub struct Spawned {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    pub process: Box<dyn Process>,
}

/// Starts a worker. `flow-platform` implements it, since `flow-core` can't spawn.
pub trait Launcher: Send {
    fn launch(&mut self) -> io::Result<Spawned>;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Another session or a model install holds the worker.
    Busy,
    /// Not the lease holder.
    NotHeld,
    /// Crashed; the next start is due after this long.
    Restarting(Duration),
    /// The worker says it has no verified model, with its reason.
    Unavailable(String),
    /// It couldn't be spawned, usually because it isn't installed.
    NotInstalled,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecognizeError {
    Refused(Refusal),
    /// The worker's code for this job; it stays up.
    Job(String),
    /// A bad request, never sent.
    Invalid,
    /// It died with this job. The audio must be kept as a waiting dictation.
    Lost(Fatal),
}

#[derive(Debug, PartialEq, Eq)]
pub struct Lease(u64);

struct Running {
    client: Client,
    process: Box<dyn Process>,
    model: ModelIdentity,
}

pub struct Lifecycle {
    launcher: Box<dyn Launcher>,
    clock: Box<dyn Fn() -> Instant + Send>,
    running: Option<Running>,
    holder: Option<u64>,
    next_lease: u64,
    keep_loaded: bool,
    last_used: Option<Instant>,
    retry_at: Option<Instant>,
    unavailable: Option<String>,
    backoff: Backoff,
    pub job_deadline: Duration,
    pub ready_timeout: Duration,
}

impl Lifecycle {
    pub fn new(launcher: Box<dyn Launcher>, clock: Box<dyn Fn() -> Instant + Send>) -> Lifecycle {
        Lifecycle {
            launcher,
            clock,
            running: None,
            holder: None,
            next_lease: 1,
            keep_loaded: false,
            last_used: None,
            retry_at: None,
            unavailable: None,
            backoff: Backoff::default(),
            job_deadline: JOB_DEADLINE,
            ready_timeout: READY_TIMEOUT,
        }
    }

    /// Exclusive use. Nothing starts until it's needed.
    pub fn acquire(&mut self) -> Result<Lease, Refusal> {
        if self.holder.is_some() {
            return Err(Refusal::Busy);
        }
        let id = self.next_lease;
        self.next_lease += 1;
        self.holder = Some(id);
        Ok(Lease(id))
    }

    pub fn finish(&mut self, lease: Lease) {
        if self.holder == Some(lease.0) {
            self.holder = None;
            self.last_used = Some((self.clock)());
        }
    }

    /// `keepModelReady`. Turning it off counts as idle from now.
    pub fn set_keep_loaded(&mut self, keep: bool) {
        if self.keep_loaded && !keep {
            self.last_used = Some((self.clock)());
        }
        self.keep_loaded = keep;
    }

    /// The identity from `ready`, while a worker runs.
    pub fn model(&self) -> Option<&ModelIdentity> {
        self.running.as_ref().map(|r| &r.model)
    }

    /// Starts the worker if none runs, within its backoff or retry window. Blocks until `ready`.
    pub fn ensure_started(&mut self) -> Result<&ModelIdentity, Refusal> {
        if self.running.is_none() {
            let now = (self.clock)();
            if let Some(at) = self.retry_at.filter(|at| *at > now) {
                return Err(match &self.unavailable {
                    Some(reason) => Refusal::Unavailable(reason.clone()),
                    None => Refusal::Restarting(at - now),
                });
            }
            let Ok(spawned) = self.launcher.launch() else {
                self.retry_at = Some(now + self.backoff.next_delay());
                return Err(Refusal::NotInstalled);
            };
            let mut client = Client::new(spawned.reader, spawned.writer);
            let mut process = spawned.process;
            match client.wait_ready(self.ready_timeout) {
                Ok(Started::Ready(model)) => {
                    self.retry_at = None;
                    self.unavailable = None;
                    self.running = Some(Running {
                        client,
                        process,
                        model,
                    });
                }
                Ok(Started::Unavailable(reason)) => {
                    // It exits 0 on its own; the grace is only for one that doesn't.
                    if !process.wait(SHUTDOWN_GRACE) {
                        process.kill();
                    }
                    self.retry_at = Some(now + UNAVAILABLE_RETRY);
                    self.unavailable = Some(reason.clone());
                    return Err(Refusal::Unavailable(reason));
                }
                Err(_) => {
                    let delay = self.backoff.next_delay();
                    process.kill();
                    process.wait(SHUTDOWN_GRACE);
                    self.retry_at = Some(now + delay);
                    return Err(Refusal::Restarting(delay));
                }
            }
        }
        Ok(&self.running.as_ref().expect("started above").model)
    }

    /// One job under the lease. Backoff starts when the job's failure is seen.
    pub fn recognize(
        &mut self,
        lease: &Lease,
        samples: &[f32],
        boost: Option<Boost>,
    ) -> Result<Recognized, RecognizeError> {
        if self.holder != Some(lease.0) {
            return Err(RecognizeError::Refused(Refusal::NotHeld));
        }
        self.ensure_started().map_err(RecognizeError::Refused)?;
        let deadline = self.job_deadline;
        let running = self.running.as_mut().expect("started above");
        match running.client.recognize(samples, boost, deadline) {
            Ok(result) => {
                self.backoff.reset();
                Ok(result)
            }
            Err(JobError::Code(code)) => Err(RecognizeError::Job(code)),
            Err(JobError::Refused(_)) => Err(RecognizeError::Invalid),
            Err(JobError::Fatal(fatal)) => {
                self.lose();
                Err(RecognizeError::Lost(fatal))
            }
        }
    }

    fn lose(&mut self) {
        if let Some(mut running) = self.running.take() {
            running.process.kill();
            running.process.wait(SHUTDOWN_GRACE);
        }
        self.retry_at = Some((self.clock)() + self.backoff.next_delay());
    }

    /// Call on a slow timer. Releases an idle worker; with keep-loaded on, restarts one that's due.
    pub fn tick(&mut self) {
        if self.holder.is_some() {
            return;
        }
        let now = (self.clock)();
        if self.keep_loaded {
            if self.running.is_none() && self.retry_at.is_none_or(|at| at <= now) {
                let _ = self.ensure_started();
            }
        } else if self.running.is_some()
            && self
                .last_used
                .is_none_or(|used| now.duration_since(used) >= IDLE_RELEASE)
        {
            self.release();
        }
    }

    /// Release by exit: `shutdown`, then a kill if the grace passes.
    fn release(&mut self) {
        if let Some(mut running) = self.running.take() {
            running.client.shutdown();
            drop(running.client);
            if !running.process.wait(SHUTDOWN_GRACE) {
                running.process.kill();
                running.process.wait(SHUTDOWN_GRACE);
            }
        }
    }

    /// `shutdownIfIdle`: false refuses while a session holds the worker.
    pub fn shutdown_if_idle(&mut self) -> bool {
        if self.holder.is_some() {
            return false;
        }
        self.release();
        true
    }

    /// A model was installed: a start refused for a missing model can be tried at once.
    pub fn model_changed(&mut self) {
        self.unavailable = None;
        self.retry_at = None;
    }
}

#[cfg(test)]
mod tests {
    use super::super::worker::tests::identity;
    use super::super::worker::{CODE_FAILED, Header, decode_samples, encode_frame, read_frame};
    use super::*;
    use serde_json::json;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Copy, PartialEq)]
    enum Script {
        Serve,
        Unavailable,
        CrashOnJob,
        FailJob,
    }

    /// Worker threads over real pipes; `kill` closes nothing because the script's end decides.
    struct Fake {
        scripts: Vec<Script>,
        launched: Arc<Mutex<usize>>,
        killed: Arc<Mutex<usize>>,
        exited_cleanly: Arc<Mutex<usize>>,
    }

    struct FakeProcess {
        killed: Arc<Mutex<usize>>,
        done: std::sync::mpsc::Receiver<()>,
    }
    impl Process for FakeProcess {
        fn kill(&mut self) {
            *self.killed.lock().unwrap() += 1;
        }
        fn wait(&mut self, timeout: Duration) -> bool {
            self.done.recv_timeout(timeout).is_ok()
        }
    }

    impl Launcher for Fake {
        fn launch(&mut self) -> io::Result<Spawned> {
            let index = {
                let mut n = self.launched.lock().unwrap();
                *n += 1;
                *n - 1
            };
            let script = *self.scripts.get(index).unwrap_or(&Script::Serve);
            let (mut in_r, in_w) = io::pipe()?;
            let (out_r, mut out_w) = io::pipe()?;
            let (done_tx, done) = std::sync::mpsc::sync_channel(1);
            let exited = self.exited_cleanly.clone();
            std::thread::spawn(move || {
                let mut send = |h: Header| out_w.write_all(&encode_frame(&h, &[]).unwrap());
                if script == Script::Unavailable {
                    let _ = send(Header::unavailable("model_missing"));
                    let _ = done_tx.send(());
                    return;
                }
                let _ = send(Header::ready(identity()));
                while let Ok(Some(frame)) = read_frame(&mut in_r) {
                    if frame.header.kind == "shutdown" {
                        *exited.lock().unwrap() += 1;
                        break;
                    }
                    let job = frame.header.job.unwrap();
                    match script {
                        Script::CrashOnJob => break,
                        Script::FailJob => drop(send(Header::error(job, CODE_FAILED))),
                        _ => drop(send(Header::result(
                            job,
                            json!({"samples": decode_samples(&frame.payload).len()}),
                            1,
                        ))),
                    }
                }
                let _ = done_tx.send(());
            });
            Ok(Spawned {
                reader: Box::new(out_r),
                writer: Box::new(in_w),
                process: Box::new(FakeProcess {
                    killed: self.killed.clone(),
                    done,
                }),
            })
        }
    }

    struct Rig {
        lifecycle: Lifecycle,
        now: Arc<Mutex<Instant>>,
        launched: Arc<Mutex<usize>>,
        killed: Arc<Mutex<usize>>,
        exited: Arc<Mutex<usize>>,
    }

    fn rig(scripts: &[Script]) -> Rig {
        let now = Arc::new(Mutex::new(Instant::now()));
        let (launched, killed, exited) = (
            Arc::new(Mutex::new(0)),
            Arc::new(Mutex::new(0)),
            Arc::new(Mutex::new(0)),
        );
        let fake = Fake {
            scripts: scripts.to_vec(),
            launched: launched.clone(),
            killed: killed.clone(),
            exited_cleanly: exited.clone(),
        };
        let clock = now.clone();
        Rig {
            lifecycle: Lifecycle::new(Box::new(fake), Box::new(move || *clock.lock().unwrap())),
            now,
            launched,
            killed,
            exited,
        }
    }

    impl Rig {
        fn advance(&self, by: Duration) {
            *self.now.lock().unwrap() += by;
        }
        fn launches(&self) -> usize {
            *self.launched.lock().unwrap()
        }
    }

    #[test]
    fn starts_only_when_needed_and_answers_a_job() {
        let mut r = rig(&[Script::Serve]);
        let lease = r.lifecycle.acquire().unwrap();
        assert_eq!(r.launches(), 0, "acquiring starts nothing");
        assert_eq!(
            r.lifecycle
                .recognize(&lease, &[0.0, 0.0], None)
                .unwrap()
                .window["samples"],
            2
        );
        assert_eq!(r.launches(), 1);
        assert_eq!(r.lifecycle.model(), Some(&identity()));
        r.lifecycle.recognize(&lease, &[0.0], None).unwrap();
        assert_eq!(r.launches(), 1, "one process for both jobs");
    }

    #[test]
    fn one_holder_at_a_time() {
        let mut r = rig(&[]);
        let lease = r.lifecycle.acquire().unwrap();
        assert_eq!(r.lifecycle.acquire(), Err(Refusal::Busy));
        assert!(
            !r.lifecycle.shutdown_if_idle(),
            "a held worker refuses shutdown"
        );
        r.lifecycle.finish(lease);
        let second = r.lifecycle.acquire().unwrap();
        assert_eq!(
            r.lifecycle.recognize(&Lease(999), &[0.0], None),
            Err(RecognizeError::Refused(Refusal::NotHeld))
        );
        assert_eq!(r.launches(), 0, "the refused job started nothing");
        r.lifecycle.finish(second);
        assert!(r.lifecycle.shutdown_if_idle());
    }

    #[test]
    fn idle_worker_is_released_by_exit_unless_kept() {
        let mut r = rig(&[]);
        let lease = r.lifecycle.acquire().unwrap();
        r.lifecycle.recognize(&lease, &[0.0], None).unwrap();
        r.lifecycle.tick();
        assert!(r.lifecycle.model().is_some(), "held");
        r.lifecycle.finish(lease);
        r.advance(IDLE_RELEASE - Duration::from_secs(1));
        r.lifecycle.tick();
        assert!(r.lifecycle.model().is_some(), "still cooling");
        r.lifecycle.set_keep_loaded(true);
        r.advance(IDLE_RELEASE * 2);
        r.lifecycle.tick();
        assert!(r.lifecycle.model().is_some(), "kept");
        r.lifecycle.set_keep_loaded(false);
        r.lifecycle.tick();
        assert!(
            r.lifecycle.model().is_some(),
            "cools from when it was turned off"
        );
        r.advance(IDLE_RELEASE);
        r.lifecycle.tick();
        assert_eq!(r.lifecycle.model(), None);
        assert_eq!(*r.exited.lock().unwrap(), 1, "asked to shut down");
        assert_eq!(*r.killed.lock().unwrap(), 0, "and went by itself");
    }

    #[test]
    fn a_crash_loses_the_job_and_restarts_with_backoff() {
        let mut r = rig(&[Script::CrashOnJob, Script::CrashOnJob, Script::Serve]);
        let lease = r.lifecycle.acquire().unwrap();
        assert_eq!(
            r.lifecycle.recognize(&lease, &[0.0], None),
            Err(RecognizeError::Lost(Fatal::Exited))
        );
        assert_eq!(*r.killed.lock().unwrap(), 1, "its process is killed");
        assert_eq!(
            r.lifecycle.recognize(&lease, &[0.0], None),
            Err(RecognizeError::Refused(Refusal::Restarting(
                Duration::from_secs(1)
            )))
        );
        assert_eq!(r.launches(), 1, "not before the backoff");
        r.advance(Duration::from_secs(1));
        assert_eq!(
            r.lifecycle.recognize(&lease, &[0.0], None),
            Err(RecognizeError::Lost(Fatal::Exited))
        );
        assert_eq!(
            r.lifecycle.recognize(&lease, &[0.0], None),
            Err(RecognizeError::Refused(Refusal::Restarting(
                Duration::from_secs(2)
            ))),
            "doubled"
        );
        r.advance(Duration::from_secs(2));
        assert!(r.lifecycle.recognize(&lease, &[0.0], None).is_ok());
        assert_eq!(r.launches(), 3);
    }

    #[test]
    fn a_job_error_keeps_the_worker() {
        let mut r = rig(&[Script::FailJob]);
        let lease = r.lifecycle.acquire().unwrap();
        assert_eq!(
            r.lifecycle.recognize(&lease, &[0.0], None),
            Err(RecognizeError::Job(CODE_FAILED.into()))
        );
        assert!(r.lifecycle.model().is_some());
        assert_eq!(*r.killed.lock().unwrap(), 0);
    }

    #[test]
    fn unavailable_retries_after_a_minute_or_a_model_install() {
        let mut r = rig(&[Script::Unavailable, Script::Unavailable, Script::Serve]);
        let missing = Refusal::Unavailable("model_missing".into());
        assert_eq!(r.lifecycle.ensure_started().err(), Some(missing.clone()));
        assert_eq!(r.lifecycle.ensure_started().err(), Some(missing.clone()));
        assert_eq!(r.launches(), 1, "no second start inside the window");
        r.advance(UNAVAILABLE_RETRY);
        assert_eq!(r.lifecycle.ensure_started().err(), Some(missing));
        assert_eq!(r.launches(), 2);
        r.lifecycle.model_changed();
        assert_eq!(r.lifecycle.ensure_started().ok(), Some(&identity()));
    }

    #[test]
    fn keep_loaded_restarts_a_lost_worker_when_due() {
        let mut r = rig(&[Script::CrashOnJob, Script::Serve]);
        r.lifecycle.set_keep_loaded(true);
        let lease = r.lifecycle.acquire().unwrap();
        assert!(matches!(
            r.lifecycle.recognize(&lease, &[0.0], None),
            Err(RecognizeError::Lost(_))
        ));
        r.lifecycle.finish(lease);
        r.lifecycle.tick();
        assert_eq!(r.launches(), 1, "waits out the backoff");
        r.advance(Duration::from_secs(1));
        r.lifecycle.tick();
        assert_eq!(r.launches(), 2);
        assert!(r.lifecycle.model().is_some());
    }

    #[test]
    fn a_worker_that_cannot_be_spawned_is_not_installed() {
        struct Missing;
        impl Launcher for Missing {
            fn launch(&mut self) -> io::Result<Spawned> {
                Err(io::ErrorKind::NotFound.into())
            }
        }
        let mut lifecycle = Lifecycle::new(Box::new(Missing), Box::new(Instant::now));
        assert_eq!(
            lifecycle.ensure_started().err(),
            Some(Refusal::NotInstalled)
        );
    }

    #[test]
    fn no_ready_inside_the_timeout_restarts_with_backoff() {
        struct Hangs;
        impl Launcher for Hangs {
            fn launch(&mut self) -> io::Result<Spawned> {
                let (reader, hold) = io::pipe()?;
                let (_unread, writer) = io::pipe()?;
                // Its end stays open, so only the timeout can end the wait.
                std::mem::forget(hold);
                struct Gone;
                impl Process for Gone {
                    fn kill(&mut self) {}
                    fn wait(&mut self, _: Duration) -> bool {
                        true
                    }
                }
                Ok(Spawned {
                    reader: Box::new(reader),
                    writer: Box::new(writer),
                    process: Box::new(Gone),
                })
            }
        }
        let mut lifecycle = Lifecycle::new(Box::new(Hangs), Box::new(Instant::now));
        lifecycle.ready_timeout = Duration::from_millis(30);
        assert_eq!(
            lifecycle.ensure_started().err(),
            Some(Refusal::Restarting(Duration::from_secs(1)))
        );
    }
}
