//! The global shortcut on Windows. `WH_KEYBOARD_LL` is called on the installing thread's message
//! loop and Windows drops a hook that overruns `LowLevelHooksTimeout`, so the callback only queues
//! into a bounded channel. A second thread does the rest. Consequently the hook can't consume keys:
//! a chord still reaches the focused app. Logic lives in `flow_core::dictation::hotkey` and
//! `win_rules`, tested on the Mac; none of this file has run on Windows.
use crate::win_rules::{self, KeyTracker, UNMAPPED};
use crate::{INVALID_SHORTCUT, SHORTCUT_NOT_STARTED, Unavailable};
use flow_core::dictation::hotkey::{Engine, Event, HELD_POLL, IDLE_HEALTH};
use flow_core::settings::Shortcut;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant, SystemTime};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{GetCurrentProcessId, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState;
use windows::Win32::UI::WindowsAndMessaging::{CallNextHookEx, DispatchMessageW, GetForegroundWindow, GetMessageW, GetWindowThreadProcessId, HC_ACTION, HHOOK, KBDLLHOOKSTRUCT, MSG, PM_NOREMOVE, PeekMessageW, PostThreadMessageW, SetTimer, SetWindowsHookExW, UnhookWindowsHookEx, WH_KEYBOARD_LL, WM_KEYUP, WM_QUIT, WM_SYSKEYUP, WM_TIMER};

const QUEUE_SIZE: usize = 256;
/// A hook Windows dropped for being slow says nothing, so a new one replaces it on this cadence.
const HOOK_REFRESH_MS: u32 = 30_000;
/// ponytail: a jump in the wall clock stands in for a power notification, so the hold is cancelled
/// on wake rather than before sleep. A manual clock change also cancels one hold.
const SLEEP_GAP: Duration = Duration::from_secs(10);

#[derive(Clone, Copy)]
struct RawKey {
    vk: u32,
    scan: u32,
    flags: u32,
    up: bool,
}

static QUEUE: OnceLock<SyncSender<RawKey>> = OnceLock::new();
/// Keys the processor was too far behind to queue. The physical-state poll covers a lost key-up.
static DROPPED: AtomicU64 = AtomicU64::new(0);

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        // SAFETY: for HC_ACTION, `lparam` points at this event's KBDLLHOOKSTRUCT.
        let key = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let raw = RawKey { vk: key.vkCode, scan: key.scanCode, flags: key.flags.0, up: matches!(wparam.0 as u32, WM_KEYUP | WM_SYSKEYUP) };
        if QUEUE.get().is_none_or(|queue| queue.try_send(raw).is_err()) {
            DROPPED.fetch_add(1, Ordering::Relaxed);
        }
    }
    // SAFETY: passes the event on unchanged.
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

fn set_hook() -> Option<HHOOK> {
    // SAFETY: `hook_proc` lives for the whole process.
    unsafe {
        let module = GetModuleHandleW(None).ok()?;
        SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), Some(module.into()), 0).ok()
    }
}

fn hook_thread(ready: mpsc::SyncSender<Option<u32>>) {
    // SAFETY: the message calls use this thread's own queue. PeekMessageW creates that queue before
    // the thread id is handed out, so WM_QUIT can't be lost.
    unsafe {
        let mut message = MSG::default();
        let _ = PeekMessageW(&mut message, None, 0, 0, PM_NOREMOVE);
        let Some(mut hook) = set_hook() else {
            let _ = ready.send(None);
            return;
        };
        let _ = SetTimer(None, 0, HOOK_REFRESH_MS, None);
        let _ = ready.send(Some(GetCurrentThreadId()));
        while GetMessageW(&mut message, None, 0, 0).0 > 0 {
            if message.message == WM_TIMER {
                // New before old, so no key falls between. A failure keeps the one there is.
                if let Some(new) = set_hook() {
                    let _ = UnhookWindowsHookEx(hook);
                    hook = new;
                }
            } else {
                DispatchMessageW(&message);
            }
        }
        let _ = UnhookWindowsHookEx(hook);
    }
}

fn pressed(vk: u32) -> bool {
    // SAFETY: reads key state; the high bit is "down now".
    unsafe { GetAsyncKeyState(vk as i32) < 0 }
}

fn app_in_front() -> bool {
    // SAFETY: both calls read the state of the foreground window, which may be none.
    unsafe {
        let mut pid = 0;
        let window: HWND = GetForegroundWindow();
        GetWindowThreadProcessId(window, Some(&mut pid));
        pid == GetCurrentProcessId()
    }
}

fn processor(queue: mpsc::Receiver<RawKey>, engine: Arc<Mutex<Engine>>) {
    let mut tracker = KeyTracker::default();
    let mut last_wall = SystemTime::now();
    let mut next_check = Instant::now();
    loop {
        let wait = next_check.saturating_duration_since(Instant::now());
        match queue.recv_timeout(wait) {
            Ok(raw) => {
                if let Some((kind, key, flags, repeat)) = tracker.receive(raw.vk, raw.scan, raw.flags, raw.up) {
                    let mut engine = lock(&engine);
                    if key != UNMAPPED || !engine.recorder.is_running() {
                        // The return value is for a tap that can consume; this hook can't.
                        engine.receive(kind, key, flags, repeat);
                    }
                    if engine.is_held() {
                        next_check = next_check.min(Instant::now() + HELD_POLL);
                    }
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        if Instant::now() < next_check {
            continue;
        }
        let mut engine = lock(&engine);
        let wall = SystemTime::now();
        if wall.duration_since(last_wall).is_ok_and(|gap| gap > SLEEP_GAP + IDLE_HEALTH) {
            engine.cancel_held();
        }
        last_wall = wall;
        engine.recorder.tick(Instant::now());
        if engine.recorder.is_running() && !app_in_front() {
            engine.recorder.finish(None);
        }
        // Only during a hold: an idle sync could race a press that's still in the queue.
        if engine.is_held() {
            let flags = tracker.sync(pressed);
            let key_down = engine.polled_key().and_then(win_rules::vk_for).is_some_and(pressed);
            engine.poll(flags, key_down);
        }
        next_check = Instant::now() + if engine.is_held() { HELD_POLL } else { IDLE_HEALTH };
    }
}

struct Hook {
    thread_id: u32,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Drop for Hook {
    fn drop(&mut self) {
        // SAFETY: the thread's queue exists before its id is known.
        let _ = unsafe { PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) };
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[derive(Default)]
struct State {
    engine: Arc<Mutex<Engine>>,
    hook: Option<Hook>,
}
static STATE: LazyLock<Mutex<State>> = LazyLock::new(Default::default);

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

/// Starts the hook if something needs it and removes it otherwise.
fn sync_hook(state: &mut State) -> Result<(), Unavailable> {
    let wanted = {
        let engine = lock(&state.engine);
        engine.has_shortcut() || engine.recorder.is_running()
    };
    if !wanted {
        state.hook = None;
        return Ok(());
    }
    if state.hook.is_some() {
        return Ok(());
    }
    if QUEUE.get().is_none() {
        let (sender, receiver) = mpsc::sync_channel(QUEUE_SIZE);
        let _ = QUEUE.set(sender);
        let engine = state.engine.clone();
        std::thread::Builder::new().name("localflow-shortcut-keys".into()).spawn(move || processor(receiver, engine)).map_err(|_| SHORTCUT_NOT_STARTED)?;
    }
    let (ready, started) = mpsc::sync_channel(1);
    let thread = std::thread::Builder::new().name("localflow-shortcut-hook".into()).spawn(move || hook_thread(ready)).map_err(|_| SHORTCUT_NOT_STARTED)?;
    match started.recv() {
        Ok(Some(thread_id)) => {
            state.hook = Some(Hook { thread_id, thread: Some(thread) });
            Ok(())
        }
        _ => Err(SHORTCUT_NOT_STARTED),
    }
}

pub fn install(json: &str) -> Result<(), Unavailable> {
    let shortcut = Shortcut::from_json(json).filter(|s| s.is_valid() && win_rules::shortcut_possible(s)).ok_or(INVALID_SHORTCUT)?;
    let mut state = lock(&STATE);
    if !shortcut.enabled {
        lock(&state.engine).set_shortcut(None);
        return sync_hook(&mut state);
    }
    let previous = lock(&state.engine).has_shortcut();
    lock(&state.engine).set_shortcut(Some(shortcut));
    let started = sync_hook(&mut state);
    if started.is_err() && !previous {
        lock(&state.engine).set_shortcut(None);
    }
    started
}

pub fn available() -> bool {
    let state = lock(&STATE);
    state.hook.is_some() && lock(&state.engine).has_shortcut()
}

pub fn record() -> Result<(), Unavailable> {
    let mut state = lock(&STATE);
    if !lock(&state.engine).recorder.start(Instant::now()) {
        return Err(SHORTCUT_NOT_STARTED);
    }
    let started = sync_hook(&mut state);
    if started.is_err() {
        lock(&state.engine).recorder.stop();
    }
    started
}

pub fn stop_recording() {
    let mut state = lock(&STATE);
    lock(&state.engine).recorder.stop();
    let _ = sync_hook(&mut state);
}

pub fn take_recorded() -> Option<Option<String>> {
    let mut state = lock(&STATE);
    let result = lock(&state.engine).recorder.take()?;
    let _ = sync_hook(&mut state);
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
