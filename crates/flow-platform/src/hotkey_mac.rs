//! The global shortcut's event taps, each on its own thread and run loop so a stalled UI can't time
//! one out. Created only when asked for: no test reaches this module, and creating a tap is what can
//! bring up the system's permission prompt. Logic lives in `flow_core::dictation::hotkey`.
use crate::{ACCESSIBILITY_REQUIRED, INPUT_MONITORING_REQUIRED, INVALID_SHORTCUT, SHORTCUT_NOT_STARTED, Unavailable};
use flow_core::dictation::hotkey::{Engine, Event, HELD_POLL, IDLE_HEALTH};
use flow_core::settings::{KeyEvent, Shortcut};
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, mpsc};
use std::time::{Duration, Instant, SystemTime};

type Ref = *mut c_void;
type Callback = unsafe extern "C" fn(Ref, u32, Ref, *mut c_void) -> Ref;

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGEventTapCreate(tap: u32, place: u32, options: u32, mask: u64, callback: Callback, info: *mut c_void) -> Ref;
    fn CGEventTapEnable(tap: Ref, enable: bool);
    fn CGEventTapIsEnabled(tap: Ref) -> bool;
    fn CGEventGetFlags(event: Ref) -> u64;
    fn CGEventGetIntegerValueField(event: Ref, field: u32) -> i64;
    fn CGEventSourceFlagsState(state: i32) -> u64;
    fn CGEventSourceKeyState(state: i32, key: u16) -> bool;
    fn CGPreflightListenEventAccess() -> bool;
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFRunLoopDefaultMode: Ref;
    fn CFMachPortCreateRunLoopSource(allocator: Ref, port: Ref, order: isize) -> Ref;
    fn CFMachPortInvalidate(port: Ref);
    fn CFRunLoopGetCurrent() -> Ref;
    fn CFRunLoopAddSource(run_loop: Ref, source: Ref, mode: Ref);
    fn CFRunLoopRunInMode(mode: Ref, seconds: f64, return_after_source: bool) -> i32;
    fn CFRunLoopStop(run_loop: Ref);
    fn CFRetain(value: Ref) -> Ref;
    fn CFRelease(value: *const c_void);
}
#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
}
#[link(name = "Carbon", kind = "framework")]
unsafe extern "C" {
    fn IsSecureEventInputEnabled() -> bool;
}

const SESSION_TAP: u32 = 1;
const HEAD_INSERT: u32 = 0;
const DEFAULT_TAP: u32 = 0;
const LISTEN_ONLY: u32 = 1;
const KEY_DOWN: u32 = 10;
const KEY_UP: u32 = 11;
const FLAGS_CHANGED: u32 = 12;
const DISABLED_BY_TIMEOUT: u32 = 0xFFFF_FFFE;
const DISABLED_BY_USER_INPUT: u32 = 0xFFFF_FFFF;
const FIELD_AUTOREPEAT: u32 = 8;
const FIELD_KEYCODE: u32 = 9;
const HID_STATE: i32 = 1;
/// ponytail: a jump in the wall clock stands in for `NSWorkspace.willSleepNotification`, so the hold
/// is cancelled on wake rather than before sleep. A manual clock change also cancels one hold.
const SLEEP_GAP: Duration = Duration::from_secs(10);
const RECORDER_TICK: Duration = Duration::from_millis(250);

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

struct Context {
    engine: Arc<Mutex<Engine>>,
    recording: bool,
    port: Ref,
}

/// Runs on the tap's thread. Nothing here may panic: it would abort across the C boundary.
unsafe extern "C" fn callback(_proxy: Ref, kind: u32, event: Ref, info: *mut c_void) -> Ref {
    // SAFETY: `info` is the `Context` that `run` keeps alive until the tap is invalidated, and
    // this callback only runs inside that thread's run loop.
    let context = unsafe { &*(info as *const Context) };
    let mut engine = lock(&context.engine);
    match kind {
        DISABLED_BY_TIMEOUT | DISABLED_BY_USER_INPUT if context.recording => engine.recorder.finish(None),
        // The thread stalled. The hold stays: the re-enabled tap or the poll ends it.
        DISABLED_BY_TIMEOUT => unsafe { CGEventTapEnable(context.port, true) },
        DISABLED_BY_USER_INPUT => {
            engine.cancel_held();
            unsafe { CGEventTapEnable(context.port, true) }
        }
        KEY_DOWN | KEY_UP | FLAGS_CHANGED => {
            if context.recording && !crate::macos::app_is_active() {
                engine.recorder.finish(None);
                return event;
            }
            // Finished but not yet gone: the key isn't this tap's, and the other tap sees it too.
            if context.recording && !engine.recorder.is_running() {
                return event;
            }
            let key_event = match kind {
                KEY_DOWN => KeyEvent::Down,
                KEY_UP => KeyEvent::Up,
                _ => KeyEvent::Flags,
            };
            // SAFETY: the tap hands a valid event for the duration of the call.
            let (key, repeat, flags) = unsafe { (CGEventGetIntegerValueField(event, FIELD_KEYCODE) as u32, CGEventGetIntegerValueField(event, FIELD_AUTOREPEAT) != 0, CGEventGetFlags(event)) };
            if engine.receive(key_event, key, flags, repeat) {
                return std::ptr::null_mut();
            }
        }
        _ => {}
    }
    event
}

/// `checkHealth`: secure input and lost grants cancel; a tap that went off is re-enabled, and only
/// one that stays off cancels. Otherwise the physical state backs up a lost key-up.
fn check_health(engine: &Mutex<Engine>, port: Ref, priority: bool, available: &AtomicBool) {
    // SAFETY: read-only queries, and `port` stays valid for the thread's life. None of them prompts.
    unsafe {
        let listen = CGPreflightListenEventAccess();
        let allowed = listen && (!priority || AXIsProcessTrusted());
        let mut engine = lock(engine);
        if !allowed || IsSecureEventInputEnabled() {
            engine.cancel_held();
        } else {
            if !CGEventTapIsEnabled(port) {
                CGEventTapEnable(port, true);
            }
            if CGEventTapIsEnabled(port) {
                let key_down = engine.polled_key().is_some_and(|key| CGEventSourceKeyState(HID_STATE, key as u16));
                engine.poll(CGEventSourceFlagsState(HID_STATE), key_down);
            } else {
                engine.cancel_held();
            }
        }
        available.store(allowed && CGEventTapIsEnabled(port), Ordering::Relaxed);
    }
}

fn run(options: u32, recording: bool, engine: Arc<Mutex<Engine>>, stop: Arc<AtomicBool>, available: Arc<AtomicBool>, ready: mpsc::SyncSender<Option<usize>>) {
    let mask = 1u64 << KEY_DOWN | 1 << KEY_UP | 1 << FLAGS_CHANGED;
    let mut context = Box::new(Context { engine, recording, port: std::ptr::null_mut() });
    let info = &mut *context as *mut Context as *mut c_void;
    // SAFETY: the Core Foundation calls take objects created here and released below. The callback
    // can't run before the run loop does, by which time `context.port` is set.
    unsafe {
        let port = CGEventTapCreate(SESSION_TAP, HEAD_INSERT, options, mask, callback, info);
        if port.is_null() {
            let _ = ready.send(None);
            return;
        }
        let source = CFMachPortCreateRunLoopSource(std::ptr::null_mut(), port, 0);
        if source.is_null() {
            CFMachPortInvalidate(port);
            CFRelease(port);
            let _ = ready.send(None);
            return;
        }
        context.port = port;
        let run_loop = CFRunLoopGetCurrent();
        CFRunLoopAddSource(run_loop, source, kCFRunLoopDefaultMode);
        CGEventTapEnable(port, true);
        available.store(true, Ordering::Relaxed);
        let _ = ready.send(Some(CFRetain(run_loop) as usize));

        let priority = options == DEFAULT_TAP;
        let mut last_wall = SystemTime::now();
        let mut next_check = Instant::now() + IDLE_HEALTH;
        while !stop.load(Ordering::Relaxed) {
            let held = lock(&context.engine).is_held();
            if held {
                next_check = next_check.min(Instant::now() + HELD_POLL);
            }
            let wait = if recording { RECORDER_TICK } else { next_check.saturating_duration_since(Instant::now()) };
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, wait.as_secs_f64(), true);

            if recording {
                let mut engine = lock(&context.engine);
                engine.recorder.tick(Instant::now());
                if !crate::macos::app_is_active() || !CGEventTapIsEnabled(port) {
                    engine.recorder.finish(None);
                }
                if !engine.recorder.is_running() {
                    break;
                }
                continue;
            }
            let wall = SystemTime::now();
            if wall.duration_since(last_wall).is_ok_and(|gap| gap > SLEEP_GAP + IDLE_HEALTH) {
                lock(&context.engine).cancel_held();
            }
            last_wall = wall;
            if Instant::now() >= next_check {
                check_health(&context.engine, port, priority, &available);
                next_check = Instant::now() + if lock(&context.engine).is_held() { HELD_POLL } else { IDLE_HEALTH };
            }
        }
        available.store(false, Ordering::Relaxed);
        CGEventTapEnable(port, false);
        CFMachPortInvalidate(port);
        CFRelease(source);
        CFRelease(port);
    }
}

struct Tap {
    stop: Arc<AtomicBool>,
    run_loop: usize,
    thread: Option<std::thread::JoinHandle<()>>,
    available: Arc<AtomicBool>,
}

impl Tap {
    fn start(options: u32, recording: bool, engine: Arc<Mutex<Engine>>) -> Result<Tap, Unavailable> {
        let stop = Arc::new(AtomicBool::new(false));
        let available = Arc::new(AtomicBool::new(false));
        let (ready, started) = mpsc::sync_channel(1);
        let (thread_stop, thread_available) = (stop.clone(), available.clone());
        let thread = std::thread::Builder::new().name("localflow-shortcut".into()).spawn(move || run(options, recording, engine, thread_stop, thread_available, ready)).map_err(|_| SHORTCUT_NOT_STARTED)?;
        match started.recv() {
            Ok(Some(run_loop)) => Ok(Tap { stop, run_loop, thread: Some(thread), available }),
            _ => Err(SHORTCUT_NOT_STARTED),
        }
    }
}

impl Drop for Tap {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        // SAFETY: the retained run loop stays valid whether or not its thread still runs.
        unsafe { CFRunLoopStop(self.run_loop as Ref) };
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        unsafe { CFRelease(self.run_loop as Ref) };
    }
}

// SAFETY: `run_loop` is only a retained Core Foundation pointer, and CFRunLoopStop is thread-safe.
unsafe impl Send for Tap {}

#[derive(Default)]
struct State {
    engine: Arc<Mutex<Engine>>,
    tap: Option<Tap>,
    recorder: Option<Tap>,
}
static STATE: LazyLock<Mutex<State>> = LazyLock::new(Default::default);

/// `ShortcutController.install`: every new resource exists before the working binding goes.
pub fn install(json: &str) -> Result<(), Unavailable> {
    let shortcut = Shortcut::from_json(json).filter(Shortcut::is_valid).ok_or(INVALID_SHORTCUT)?;
    let mut state = lock(&STATE);
    if !shortcut.enabled {
        state.tap = None;
        lock(&state.engine).set_shortcut(None);
        return Ok(());
    }
    // SAFETY: preflight checks with no arguments. Neither prompts.
    let (listen, trusted) = unsafe { (CGPreflightListenEventAccess(), AXIsProcessTrusted()) };
    if !listen {
        return Err(INPUT_MONITORING_REQUIRED);
    }
    if shortcut.kind == "key_combination" && !trusted {
        return Err(ACCESSIBILITY_REQUIRED);
    }
    let new = Tap::start(if trusted { DEFAULT_TAP } else { LISTEN_ONLY }, false, state.engine.clone())?;
    state.tap = Some(new);
    lock(&state.engine).set_shortcut(Some(shortcut));
    Ok(())
}

/// `ShortcutController.isAvailable`.
pub fn available() -> bool {
    lock(&STATE).tap.as_ref().is_some_and(|tap| tap.available.load(Ordering::Relaxed))
}

/// `ShortcutRecorder.start`: one at a time, needs Accessibility, consumes keys while it runs.
pub fn record() -> Result<(), Unavailable> {
    let mut state = lock(&STATE);
    // SAFETY: a preflight check; it doesn't prompt.
    if !unsafe { AXIsProcessTrusted() } {
        return Err(ACCESSIBILITY_REQUIRED);
    }
    if !lock(&state.engine).recorder.start(Instant::now()) {
        return Err(SHORTCUT_NOT_STARTED);
    }
    state.recorder = None;
    match Tap::start(DEFAULT_TAP, true, state.engine.clone()) {
        Ok(tap) => {
            state.recorder = Some(tap);
            Ok(())
        }
        Err(e) => {
            lock(&state.engine).recorder.stop();
            Err(e)
        }
    }
}

pub fn stop_recording() {
    let mut state = lock(&STATE);
    lock(&state.engine).recorder.stop();
    state.recorder = None;
}

pub fn take_recorded() -> Option<Option<String>> {
    let mut state = lock(&STATE);
    let result = lock(&state.engine).recorder.take()?;
    state.recorder = None;
    Some(result.map(|shortcut| shortcut.json()))
}

pub fn take_events() -> Vec<Event> {
    let state = lock(&STATE);
    let events = lock(&state.engine).take_events();
    events
}

pub fn set_session_active(active: bool) {
    let state = lock(&STATE);
    lock(&state.engine).set_session_active(active);
}
