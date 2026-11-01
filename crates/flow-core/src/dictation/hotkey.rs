//! The logic of `ShortcutController` and `ShortcutRecorder`, without the event source. The platform
//! feeds it key events and physical-state polls. Bounded state only: key contents are neither
//! retained nor logged.
use crate::settings::{Capture, CaptureState, FLAG_FN, FLAG_SHIFT, KeyEvent, Shortcut, modifiers_from};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

pub const ESCAPE: u32 = 53;
pub const IDLE_HEALTH: Duration = Duration::from_secs(2);
pub const HELD_POLL: Duration = Duration::from_millis(100);
pub const RECORD_TIMEOUT: Duration = Duration::from_secs(30);
const MISSED_RELEASE_POLLS: u32 = 2;
const SHIFT_BITS: u64 = 0x2 | 0x4 | FLAG_SHIFT;
const MAX_QUEUED: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    Pressed,
    /// `bypass_rewrite`: Shift was held at release and isn't in the binding, so skip rewriting once.
    Released {
        bypass_rewrite: bool,
    },
    Cancelled,
}

/// `ShortcutHoldState`.
#[derive(Default)]
struct Hold {
    held: bool,
    release_required: bool,
}
#[derive(Clone, Copy, PartialEq, Debug)]
enum HoldEvent {
    Pressed,
    Released,
    Cancelled,
}
impl Hold {
    fn set_held(&mut self, value: bool) -> Option<HoldEvent> {
        if value == self.held {
            return None;
        }
        self.held = value;
        if !value {
            let required = std::mem::take(&mut self.release_required);
            return (!required).then_some(HoldEvent::Released);
        }
        (!self.release_required).then_some(HoldEvent::Pressed)
    }
    fn cancel(&mut self) -> Option<HoldEvent> {
        if !self.held || self.release_required {
            return None;
        }
        self.release_required = true;
        Some(HoldEvent::Cancelled)
    }
}

/// `ShortcutCancellationState`: a release ends capture, but Escape stays armed until the session ends.
#[derive(Default)]
struct Cancellation {
    active: bool,
    cancelled: bool,
}
impl Cancellation {
    fn pressed(&mut self) {
        if !self.active {
            self.active = true;
            self.cancelled = false;
        }
    }
    fn set_session_active(&mut self, value: bool) {
        self.active = value;
        if !value {
            self.cancelled = false;
        }
    }
    fn cancel(&mut self) -> bool {
        if !self.active || self.cancelled {
            return false;
        }
        self.cancelled = true;
        true
    }
}

/// What one key event did. `consume` is true only for events belonging to the binding.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Step {
    pub event: Option<Event>,
    pub consume: bool,
}

/// `ShortcutController.receive` and its poll, for one binding.
pub struct Machine {
    shortcut: Shortcut,
    hold: Hold,
    cancellation: Cancellation,
    consumed_key: bool,
    shift_held: bool,
    misses: u32,
}

impl Machine {
    pub fn new(shortcut: Shortcut) -> Machine {
        Machine { shortcut, hold: Hold::default(), cancellation: Cancellation::default(), consumed_key: false, shift_held: false, misses: 0 }
    }
    pub fn is_held(&self) -> bool {
        self.hold.held
    }
    pub fn shortcut(&self) -> &Shortcut {
        &self.shortcut
    }
    fn bypass_available(&self) -> bool {
        !self.shortcut.includes_shift()
    }
    fn strip(&self, flags: u64) -> u64 {
        if self.bypass_available() { flags & !SHIFT_BITS } else { flags }
    }
    fn emit(&mut self, event: Option<HoldEvent>) -> Option<Event> {
        match event? {
            HoldEvent::Pressed => {
                self.cancellation.pressed();
                Some(Event::Pressed)
            }
            HoldEvent::Released => Some(Event::Released { bypass_rewrite: self.shift_held }),
            HoldEvent::Cancelled => {
                self.cancellation.cancel();
                Some(Event::Cancelled)
            }
        }
    }

    pub fn receive(&mut self, kind: KeyEvent, key: u32, flags: u64, autorepeat: bool) -> Step {
        // Shift is transparent to matching unless the binding uses it: read at release instead.
        self.shift_held = self.bypass_available() && flags & FLAG_SHIFT != 0;
        let flags = self.strip(flags);
        let modifiers = modifiers_from(flags, (kind != KeyEvent::Flags).then_some(key));
        if kind == KeyEvent::Down && key == ESCAPE {
            return Step { event: self.cancel_held(), consume: false };
        }
        let wanted = self.shortcut.modifiers;
        if self.shortcut.kind == "key_combination" {
            if key == self.shortcut.key_code && kind == KeyEvent::Up && self.consumed_key {
                self.consumed_key = false;
                let held = self.hold.set_held(false);
                return Step { event: self.emit(held), consume: true };
            }
            if key == self.shortcut.key_code && kind == KeyEvent::Down {
                if self.consumed_key {
                    return Step { event: None, consume: true };
                }
                if modifiers != wanted || !self.shortcut.matches_sides(flags, false) || autorepeat {
                    return Step::default();
                }
                self.consumed_key = true;
                let held = self.hold.set_held(true);
                return Step { event: self.emit(held), consume: true };
            }
            if kind == KeyEvent::Flags && self.hold.held && (modifiers != wanted || !self.shortcut.matches_sides(flags, false)) {
                let held = self.hold.set_held(false);
                return Step { event: self.emit(held), consume: false };
            }
            return Step::default();
        }
        let required = if self.shortcut.kind == "fn_globe" { crate::settings::FN } else { wanted };
        if kind == KeyEvent::Flags {
            let was_held = self.hold.held;
            if modifiers == required && self.shortcut.matches_sides(flags, false) {
                let held = self.hold.set_held(true);
                return Step { event: self.emit(held), consume: true };
            }
            if modifiers & required == required && self.shortcut.matches_sides(flags, true) {
                self.hold.set_held(true);
                let cancelled = self.hold.cancel();
                return Step { event: self.emit(cancelled), consume: false };
            }
            let held = self.hold.set_held(false);
            return Step { event: self.emit(held), consume: was_held };
        }
        if kind == KeyEvent::Down {
            let cancelled = self.hold.cancel();
            return Step { event: self.emit(cancelled), consume: false };
        }
        Step::default()
    }

    /// `pollHeldShortcut`, the backstop for a lost key-up. `flags` is the physical state and
    /// `key_down` whether the binding's key is down. Two misses in a row guard against one misread.
    pub fn poll(&mut self, flags: u64, key_down: bool) -> Option<Event> {
        if !self.hold.held {
            return None;
        }
        let flags = self.strip(flags);
        let down = if self.shortcut.kind == "fn_globe" {
            flags & FLAG_FN != 0
        } else {
            let combo = self.shortcut.kind == "key_combination";
            modifiers_from(flags, combo.then_some(self.shortcut.key_code)) == self.shortcut.modifiers && self.shortcut.matches_sides(flags, false) && (!combo || key_down)
        };
        if down {
            self.misses = 0;
            return None;
        }
        self.misses += 1;
        if self.misses < MISSED_RELEASE_POLLS {
            return None;
        }
        self.misses = 0;
        self.consumed_key = false;
        let held = self.hold.set_held(false);
        self.emit(held)
    }

    /// `cancelHeldSession`: Escape, lost permission, secure input, sleep, a tap that stays off.
    pub fn cancel_held(&mut self) -> Option<Event> {
        self.hold.cancel();
        self.cancellation.cancel().then_some(Event::Cancelled)
    }
    pub fn set_session_active(&mut self, active: bool) {
        self.cancellation.set_session_active(active);
    }
}

/// `ShortcutRecorder`'s state: one at a time, ends with a value, nothing or a timeout.
#[derive(Default)]
pub struct Recorder {
    running: Option<(CaptureState, Instant)>,
    result: Option<Option<Shortcut>>,
}

impl Recorder {
    /// False when one is already running.
    pub fn start(&mut self, now: Instant) -> bool {
        if self.running.is_some() {
            return false;
        }
        self.result = None;
        self.running = Some((CaptureState::default(), now));
        true
    }
    pub fn is_running(&self) -> bool {
        self.running.is_some()
    }
    pub fn receive(&mut self, kind: KeyEvent, key: u32, flags: u64) {
        let Some((capture, _)) = &mut self.running else { return };
        match capture.receive(kind, key, flags) {
            Capture::Pending => {}
            Capture::Cancelled => self.finish(None),
            Capture::Captured(value) => self.finish(Some(value)),
        }
    }
    pub fn tick(&mut self, now: Instant) {
        if self.running.as_ref().is_some_and(|(_, started)| now.duration_since(*started) >= RECORD_TIMEOUT) {
            self.finish(None);
        }
    }
    /// Ended by something other than a key: the app went inactive, the tap went off.
    pub fn finish(&mut self, value: Option<Shortcut>) {
        if self.running.take().is_some() {
            self.result = Some(value);
        }
    }
    /// The record button's second press: drops the recorder, and nothing is reported.
    pub fn stop(&mut self) {
        self.running = None;
        self.result = None;
    }
    /// `None` while running or idle, `Some(None)` when it ended empty.
    pub fn take(&mut self) -> Option<Option<Shortcut>> {
        self.result.take()
    }
}

/// Binding and recorder together, as a platform's event source drives them.
#[derive(Default)]
pub struct Engine {
    machine: Option<Machine>,
    pub recorder: Recorder,
    events: VecDeque<Event>,
}

impl Engine {
    fn push(&mut self, event: Option<Event>) {
        if let Some(event) = event {
            if self.events.len() == MAX_QUEUED {
                self.events.pop_front();
            }
            self.events.push_back(event);
        }
    }
    /// Replaces the binding. A press in progress is cancelled, as `remove()` does.
    pub fn set_shortcut(&mut self, shortcut: Option<Shortcut>) {
        let cancelled = self.machine.as_mut().and_then(Machine::cancel_held);
        self.push(cancelled);
        self.machine = shortcut.map(Machine::new);
    }
    pub fn has_shortcut(&self) -> bool {
        self.machine.is_some()
    }
    pub fn is_held(&self) -> bool {
        self.machine.as_ref().is_some_and(Machine::is_held)
    }
    /// The key the poll needs the physical state of, for a held chord.
    pub fn polled_key(&self) -> Option<u32> {
        self.machine.as_ref().filter(|m| m.is_held() && m.shortcut.kind == "key_combination").map(|m| m.shortcut.key_code)
    }
    /// Before a key reaches `receive` from a source that sees every app's keys: a recorder running
    /// behind another app ends empty, so it can't capture what's typed there.
    pub fn end_recorder_unless(&mut self, app_in_front: impl FnOnce() -> bool) {
        if self.recorder.is_running() && !app_in_front() {
            self.recorder.finish(None);
        }
    }
    /// Returns whether to consume the event. While the recorder runs, keys go only to it.
    pub fn receive(&mut self, kind: KeyEvent, key: u32, flags: u64, autorepeat: bool) -> bool {
        if self.recorder.is_running() {
            self.recorder.receive(kind, key, flags);
            return true;
        }
        let Some(machine) = &mut self.machine else { return false };
        let step = machine.receive(kind, key, flags, autorepeat);
        self.push(step.event);
        step.consume
    }
    pub fn poll(&mut self, flags: u64, key_down: bool) {
        let event = self.machine.as_mut().and_then(|m| m.poll(flags, key_down));
        self.push(event);
    }
    pub fn cancel_held(&mut self) {
        let event = self.machine.as_mut().and_then(Machine::cancel_held);
        self.push(event);
    }
    pub fn set_session_active(&mut self, active: bool) {
        if let Some(machine) = &mut self.machine {
            machine.set_session_active(active);
        }
    }
    pub fn take_events(&mut self) -> Vec<Event> {
        self.events.drain(..).collect()
    }
}

/// `ShortcutPermissionRecovery`: reconciles grants with the installed shortcut while setup shows.
#[derive(Default)]
pub struct PermissionRecovery {
    input_monitoring: bool,
    accessibility: bool,
}
impl PermissionRecovery {
    /// Whether to reinstall now.
    pub fn refresh(&mut self, input_monitoring: bool, accessibility: bool, available: bool, busy: bool) -> bool {
        let install = input_monitoring && (!available || !self.input_monitoring || accessibility != self.accessibility) && !busy;
        if !busy {
            self.input_monitoring = input_monitoring;
            self.accessibility = accessibility;
        }
        install
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{FLAG_COMMAND, FLAG_CONTROL, FLAG_OPTION, KeyEvent::*};
    const RIGHT_CONTROL: u64 = FLAG_CONTROL | 0x2000;
    const LEFT_CONTROL: u64 = FLAG_CONTROL | 0x1;
    const RELEASED: Event = Event::Released { bypass_rewrite: false };
    const CMD_MODIFIER: u32 = 1 << 8;

    #[test]
    fn a_recorder_behind_another_app_ends_before_it_sees_that_apps_key() {
        let mut engine = Engine::default();
        engine.set_shortcut(Some(combo()));
        assert!(engine.recorder.start(Instant::now()));
        engine.end_recorder_unless(|| true);
        assert!(engine.recorder.is_running(), "in front: it keeps listening");
        engine.end_recorder_unless(|| false);
        assert!(!engine.receive(Down, 0, FLAG_COMMAND, false), "the key isn't the recorder's now");
        assert_eq!(engine.recorder.take(), Some(None), "ended empty, nothing captured");
        engine.end_recorder_unless(|| panic!("no recorder, so no check"));
    }

    fn combo() -> Shortcut {
        Shortcut { kind: "key_combination".into(), key_code: 49, modifiers: CMD_MODIFIER, ..Default::default() }
    }
    fn step(event: Option<Event>, consume: bool) -> Step {
        Step { event, consume }
    }

    #[test]
    fn modifier_only_press_release_and_sides() {
        let mut m = Machine::new(Shortcut::right_control());
        assert_eq!(m.receive(Flags, 59, LEFT_CONTROL, false), step(None, false), "the other side isn't the binding");
        assert_eq!(m.receive(Flags, 62, 0, false), step(None, false));
        assert_eq!(m.receive(Flags, 62, RIGHT_CONTROL, false), step(Some(Event::Pressed), true));
        assert_eq!(m.receive(Flags, 62, 0, false), step(Some(RELEASED), true));
        assert_eq!(m.receive(Flags, 62, 0, false), step(None, false), "a second release says nothing");
    }

    #[test]
    fn typing_or_an_extra_modifier_cancels_and_release_stays_silent() {
        let mut m = Machine::new(Shortcut::right_control());
        m.receive(Flags, 62, RIGHT_CONTROL, false);
        assert_eq!(m.receive(Down, 0, RIGHT_CONTROL, false), step(Some(Event::Cancelled), false), "a chord, not dictation");
        assert_eq!(m.receive(Flags, 62, 0, false), step(None, true), "released without a Released");

        let mut m = Machine::new(Shortcut::right_control());
        m.receive(Flags, 62, RIGHT_CONTROL, false);
        assert_eq!(m.receive(Flags, 58, RIGHT_CONTROL | FLAG_OPTION | 0x20, false).event, Some(Event::Cancelled));
        assert_eq!(m.receive(Flags, 58, RIGHT_CONTROL, false).event, None, "a cancelled hold needs a full release");
        assert_eq!(m.receive(Flags, 62, 0, false).event, None);
        m.set_session_active(false);
        assert_eq!(m.receive(Flags, 62, RIGHT_CONTROL, false).event, Some(Event::Pressed), "the next press works");
    }

    #[test]
    fn shift_is_transparent_and_read_at_release_unless_bound() {
        let mut m = Machine::new(Shortcut::right_control());
        m.receive(Flags, 62, RIGHT_CONTROL, false);
        assert_eq!(m.receive(Flags, 56, RIGHT_CONTROL | FLAG_SHIFT | 0x2, false), step(None, true), "holding Shift neither cancels nor ends");
        assert_eq!(m.receive(Flags, 62, FLAG_SHIFT | 0x2, false).event, Some(Event::Released { bypass_rewrite: true }));
        assert_eq!(m.receive(Flags, 62, RIGHT_CONTROL, false).event, Some(Event::Pressed));
        assert_eq!(m.receive(Flags, 62, 0, false).event, Some(RELEASED), "the bypass is for one dictation");

        let bound = Shortcut { kind: "modifier_only".into(), modifiers: 1 << 9, device_modifiers: None, ..Default::default() };
        let mut m = Machine::new(bound);
        assert_eq!(m.receive(Flags, 56, FLAG_SHIFT | 0x2, false).event, Some(Event::Pressed));
        assert_eq!(m.receive(Flags, 56, 0, false).event, Some(RELEASED), "Shift in the binding is no bypass");
    }

    #[test]
    fn chord_consumes_its_key_ignores_repeats_and_ends_on_a_modifier() {
        let mut m = Machine::new(combo());
        assert_eq!(m.receive(Down, 49, 0, false), step(None, false), "no modifier");
        assert_eq!(m.receive(Down, 49, FLAG_COMMAND, true), step(None, false), "a repeat doesn't start it");
        assert_eq!(m.receive(Down, 49, FLAG_COMMAND, false), step(Some(Event::Pressed), true));
        assert_eq!(m.receive(Down, 49, FLAG_COMMAND, true), step(None, true), "repeats are swallowed");
        assert_eq!(m.receive(Down, 0, FLAG_COMMAND, false), step(None, false), "other keys pass");
        assert_eq!(m.receive(Up, 49, FLAG_COMMAND, false), step(Some(RELEASED), true));
        assert_eq!(m.receive(Up, 49, FLAG_COMMAND, false), step(None, false));
        m.receive(Down, 49, FLAG_COMMAND, false);
        assert_eq!(m.receive(Flags, 55, 0, false), step(Some(RELEASED), false), "dropping the modifier ends it");
        assert_eq!(m.receive(Up, 49, 0, false), step(None, true), "and the key's own up is still ours");
    }

    #[test]
    fn globe_uses_the_fn_flag_only() {
        let mut m = Machine::new(Shortcut::default());
        assert_eq!(m.receive(Flags, 63, FLAG_FN, false).event, Some(Event::Pressed));
        assert_eq!(m.receive(Flags, 63, 0, false).event, Some(RELEASED));
        assert_eq!(m.receive(Flags, 59, FLAG_CONTROL, false).event, None);
    }

    #[test]
    fn escape_cancels_once_and_stays_armed_after_release_until_the_session_ends() {
        let mut m = Machine::new(Shortcut::right_control());
        assert_eq!(m.receive(Down, ESCAPE, 0, false), step(None, false), "no session, nothing to cancel");
        m.receive(Flags, 62, RIGHT_CONTROL, false);
        m.receive(Flags, 62, 0, false);
        assert_eq!(m.receive(Down, ESCAPE, 0, false), step(Some(Event::Cancelled), false), "released but still transcribing");
        assert_eq!(m.receive(Down, ESCAPE, 0, false).event, None, "only once");
        m.set_session_active(false);
        assert_eq!(m.receive(Down, ESCAPE, 0, false).event, None, "session over");
    }

    #[test]
    fn poll_needs_two_misses_and_reads_physical_state() {
        let mut m = Machine::new(Shortcut::right_control());
        assert_eq!(m.poll(0, false), None, "nothing held");
        m.receive(Flags, 62, RIGHT_CONTROL, false);
        assert_eq!(m.poll(RIGHT_CONTROL, false), None);
        assert_eq!(m.poll(0, false), None, "one misread");
        assert_eq!(m.poll(RIGHT_CONTROL, false), None, "resets the count");
        assert_eq!(m.poll(0, false), None);
        assert_eq!(m.poll(0, false), Some(RELEASED), "a lost key-up still ends in a release, not a cancel");
        assert!(!m.is_held());

        let mut m = Machine::new(combo());
        m.receive(Down, 49, FLAG_COMMAND, false);
        assert_eq!(m.poll(FLAG_COMMAND, true), None);
        m.poll(FLAG_COMMAND, false);
        assert_eq!(m.poll(FLAG_COMMAND, false), Some(RELEASED), "the key is up");
        assert_eq!(m.receive(Down, 49, FLAG_COMMAND, false).event, Some(Event::Pressed), "and the chord can start again");

        let mut m = Machine::new(Shortcut::default());
        m.receive(Flags, 63, FLAG_FN, false);
        assert_eq!(m.poll(FLAG_FN | FLAG_CONTROL, false), None, "Globe reads only the fn flag");
    }

    // parity: ONB-369 SET-155 SET-156
    #[test]
    fn recorder_is_single_captures_and_times_out() {
        let start = Instant::now();
        let mut r = Recorder::default();
        assert!(r.start(start) && !r.start(start), "one at a time");
        assert_eq!(r.take(), None, "running");
        r.receive(Flags, 62, RIGHT_CONTROL);
        r.receive(Flags, 62, 0);
        assert_eq!(r.take(), Some(Some(Shortcut::right_control())));
        assert_eq!(r.take(), None, "taken once");
        assert!(!r.is_running());

        assert!(r.start(start));
        r.tick(start + RECORD_TIMEOUT - Duration::from_millis(1));
        assert!(r.is_running());
        r.tick(start + RECORD_TIMEOUT);
        assert_eq!(r.take(), Some(None), "30 s: ends with nothing");
    }

    // parity: ONB-370
    #[test]
    fn recorder_escape_ends_empty_and_stop_reports_nothing() {
        let now = Instant::now();
        let mut r = Recorder::default();
        r.start(now);
        r.receive(Down, ESCAPE, 0);
        assert_eq!(r.take(), Some(None));
        r.start(now);
        r.stop();
        assert!(!r.is_running());
        assert_eq!(r.take(), None, "the second press drops it");
    }

    #[test]
    fn engine_routes_keys_to_the_recorder_first_and_cancels_on_replacement() {
        let mut e = Engine::default();
        assert!(!e.receive(Flags, 62, RIGHT_CONTROL, false), "no binding, nothing consumed");
        e.set_shortcut(Some(Shortcut::right_control()));
        e.recorder.start(Instant::now());
        assert!(e.receive(Flags, 62, RIGHT_CONTROL, false), "the recorder eats it");
        assert_eq!(e.take_events(), [], "and the binding didn't see it");
        e.recorder.stop();
        assert!(e.receive(Flags, 62, 0, false) == false);
        assert!(e.receive(Flags, 62, RIGHT_CONTROL, false));
        assert!(e.is_held());
        e.set_shortcut(None);
        assert_eq!(e.take_events(), [Event::Pressed, Event::Cancelled]);
        assert!(!e.has_shortcut());
        for _ in 0..200 {
            e.set_shortcut(Some(Shortcut::right_control()));
            e.receive(Flags, 62, RIGHT_CONTROL, false);
        }
        assert!(e.take_events().len() <= MAX_QUEUED, "bounded with no reader");
    }

    // parity: ONB-013 SET-018
    #[test]
    fn recovery_reinstalls_on_change_only() {
        let mut r = PermissionRecovery::default();
        assert!(!r.refresh(false, false, false, false), "not allowed");
        assert!(r.refresh(true, false, false, false), "newly allowed");
        assert!(!r.refresh(true, false, true, false), "steady");
        assert!(r.refresh(true, true, true, false), "Accessibility changed the tap's options");
        assert!(r.refresh(true, true, false, false), "the tap is gone");
        assert!(!r.refresh(true, false, true, true), "busy waits");
        assert!(r.refresh(true, false, true, false), "and the change is still seen");
    }
}
