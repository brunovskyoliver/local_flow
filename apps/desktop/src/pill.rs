//! The dictation pill: `IndicatorPanel` and `DictationIndicator`. State is plain data on
//! `Session.pill`, so any state can be injected; capture will drive the same setters later.
use crate::core::Core;
use crate::pages::Page;
use crate::shell::{self, DictState, Session, update_session};
use flow_platform::SessionCommand;
use flow_ui::prelude::*;
use flow_ui::tokens::pill as style;
use std::collections::HashSet;
use std::time::{Duration, Instant};

pub const HEIGHT: f32 = 38.;
pub const COMPACT_WIDTH: f32 = 46.;
pub const EXPANDED_WIDTH: f32 = 118.;
pub const INDICATOR_WIDTH: f32 = 153.;
pub const BAR_COUNT: usize = 15;
const PITCH: f32 = 6.;
/// Below-the-pill room for the rise, because GPUI can't move or fade a window (PILL-017).
const RISE: f32 = 10.;
pub const SHOW: f32 = 0.3;
pub const HIDE: f32 = 0.18;
pub const MORPH: (f32, f32) = (0.42, 0.86);
pub const SWAP: (f32, f32) = (0.34, 0.9);
pub const LEARNED_SECONDS: u64 = 6;
pub const MICROPHONE_SECONDS: u64 = 8;
pub const CLIPBOARD_SECONDS: u64 = 6;
pub const ACTION_SECONDS: u64 = 6;
pub const HIDDEN_GRACE_SECONDS: u64 = 10;
pub const RESIZE: f32 = 0.32;
const BOUNCE: f32 = 0.4;
const PULSE: f64 = 1.6;
/// Longer than the swap spring takes to settle.
const HOVER_SETTLE: f32 = 0.6;
/// Swift's `CAMediaTimingFunction(controlPoints:)` for the panel frame.
pub const RESIZE_CURVE: [f32; 4] = [0.2, 0.9, 0.25, 1.];

/// `showsPanel`.
pub fn shows_dictation(s: DictState) -> bool {
    !matches!(s, DictState::Idle | DictState::Recovery | DictState::Failed)
}
pub fn is_compact(s: DictState) -> bool {
    matches!(s, DictState::Preparing | DictState::Connecting)
}
pub fn is_processing(s: DictState) -> bool {
    matches!(s, DictState::Transcribing | DictState::Persisting | DictState::Inserting | DictState::Cancelling)
}

pub fn accessibility_label(s: DictState) -> &'static str {
    match s {
        DictState::Recording => "Recording",
        DictState::Connecting => "Connecting to the microphone",
        DictState::Preparing => "Preparing, microphone off",
        DictState::Rewriting => "Rewriting text, microphone off",
        _ => "Processing, microphone off",
    }
}

pub fn cancel_label(s: DictState) -> &'static str {
    if s == DictState::Rewriting { "Cancel rewrite" } else { "Cancel dictation" }
}

/// `IndicatorPanel.announcement(from:to:)`.
pub fn announcement(previous: DictState, state: DictState) -> Option<&'static str> {
    if previous == state {
        return None;
    }
    Some(match state {
        DictState::Preparing => "Preparing dictation. Microphone off.",
        DictState::Connecting => "Connecting to the microphone.",
        DictState::Recording => "Recording.",
        DictState::Transcribing => "Transcribing. Microphone off.",
        DictState::Persisting => "Saving dictation.",
        DictState::Rewriting => "Rewriting text. Microphone off.",
        DictState::Inserting => "Inserting saved text.",
        DictState::Cancelling => "Cancelling dictation.",
        DictState::Recovery => "Text saved for review.",
        DictState::Failed => "Dictation failed. Open LocalFlow for details.",
        DictState::Idle if previous == DictState::Cancelling => "Dictation cancelled.",
        DictState::Idle => "Dictation stopped.",
    })
}

/// A damped spring's step response, 0 at `t = 0` settling at 1.
pub fn spring(t: f32, (response, damping): (f32, f32)) -> f32 {
    if t <= 0. {
        return 0.;
    }
    let w = std::f32::consts::TAU / response;
    let wd = w * (1. - damping * damping).sqrt();
    1. - (-damping * w * t).exp() * ((wd * t).cos() + damping * w / wd * (wd * t).sin())
}

/// `cubic-bezier(0.2, 0.9, 0.25, 1)`, the panel's settle.
pub fn settle(t: f32) -> f32 {
    let bez = |a: f32, b: f32, u: f32| 3. * (1. - u) * (1. - u) * u * a + 3. * (1. - u) * u * u * b + u * u * u;
    let (mut lo, mut hi) = (0f32, 1f32);
    for _ in 0..16 {
        let mid = (lo + hi) / 2.;
        if bez(0.2, 0.25, mid) < t.clamp(0., 1.) { lo = mid } else { hi = mid }
    }
    bez(0.9, 1., hi)
}

pub fn connecting_opacity(time: f64) -> f32 {
    (0.675 + 0.325 * (time * std::f64::consts::TAU / 1.6).sin()) as f32
}

pub fn processing_height(bar: usize, time: f64) -> f32 {
    let phase = time.rem_euclid(1.2) / 1.2;
    let crest = phase * (BAR_COUNT + 6) as f64 - 3.;
    let distance = ((BAR_COUNT - 1 - bar) as f64 - crest).abs();
    (4. + 12. * (-distance * distance / 4.5).exp()) as f32
}

pub fn rewriting_wave(bar: usize, time: f64) -> (f32, f32) {
    let roll = (time * 5.5 + bar as f64 * 0.55).sin();
    let sweep = (time / 1.6).rem_euclid(1.) * (BAR_COUNT + 8) as f64 - 4.;
    let glow = (-((BAR_COUNT - 1 - bar) as f64 - sweep).powi(2) / 6.).exp();
    ((11. + 6. * roll) as f32, (0.45 + 0.55 * glow) as f32)
}

/// Static heights: compact, Reduce Motion recording, and every-third-bar processing.
pub fn static_height(bar: usize, s: DictState) -> f32 {
    const PATTERN: [f32; 15] = [7., 12., 19., 10., 23., 15., 27., 18., 11., 23., 15., 8., 18., 11., 6.];
    match s {
        DictState::Preparing | DictState::Connecting => 4.,
        DictState::Recording => PATTERN[bar] * 0.75,
        _ if bar % 3 == 0 => 14.,
        _ => 4.,
    }
}

/// Bars come in from the right when the pill opens: `(15 - slot) * 0.014` s after it starts.
pub fn reveal(slot: usize, since_expand: f32) -> f32 {
    spring(since_expand - (BAR_COUNT as f32 - slot as f32) * 0.014, MORPH).clamp(0., 1.)
}

/// Non-finite levels become 0; values clamp to 0...1.
pub fn clamp_level(level: f32) -> f32 {
    if level.is_finite() { level.clamp(0., 1.) } else { 0. }
}

/// `WaveformHistory`.
#[derive(Clone)]
pub struct Waveform {
    slices: Vec<f32>,
    current: f32,
    start: Option<f64>,
}

impl Default for Waveform {
    fn default() -> Self {
        Waveform { slices: vec![0.; BAR_COUNT], current: 0., start: None }
    }
}

impl Waveform {
    pub const SLICE: f64 = 0.07;
    pub fn advance(&mut self, time: f64, level: f32) {
        let level = clamp_level(level);
        let Some(start) = self.start else {
            self.start = Some(time);
            self.current = level;
            return;
        };
        let ended = ((time - start) / Self::SLICE) as usize;
        if ended > 0 {
            for i in 0..ended.min(self.slices.len()) {
                self.slices.remove(0);
                self.slices.push(if i == 0 { self.current } else { 0. });
            }
            self.start = Some(start + ended as f64 * Self::SLICE);
            self.current = level;
        } else {
            self.current = self.current.max(level);
        }
    }
    pub fn progress(&self, time: f64) -> f32 {
        self.start.map_or(0., |s| (((time - s) / Self::SLICE) as f32).clamp(0., 1.))
    }
    pub fn heights(&self) -> Vec<f32> {
        self.slices.iter().chain([&self.current]).map(|l| Self::height(*l)).collect()
    }
    pub fn height(level: f32) -> f32 {
        let loud = if level.is_finite() { (level * 5.).clamp(0., 1.) } else { 0. };
        3. + 25. * loud.powf(0.7)
    }
}

/// The incoming content's `(opacity, scale)`: scale from 0.88 with opacity on the swap spring.
pub fn swap_style(elapsed: f32) -> (f32, f32) {
    let f = spring(elapsed, SWAP).clamp(0., 1.);
    (f, 0.88 + 0.12 * f)
}

/// Left fade of the recording strip: clear at 0 to opaque at 0.28 of the 87 window.
pub fn fade(x: f32) -> f32 {
    (x / (0.28 * 87.)).clamp(0., 1.)
}

/// `RewriteNotice.text(for:context:)` and whether Retry is offered.
pub const REWRITE_NOTICES: &[(&str, bool)] = &[
    ("Rewrite server unreachable. Original text inserted.", true),
    ("Rewrite connection failed. Original text inserted.", true),
    ("Rewrite took too long. Original text inserted.", true),
    ("Rewrite server rejected the credential. Check Settings.", true),
    ("Rewrite model is not available on the server.", true),
    ("Rewrite server sent an unusable reply.", true),
    ("Rewrite result was rejected.", true),
    ("Rewriting skipped: no credential for this server. Original text inserted.", true),
    ("Rewriting skipped: unencrypted connection blocked. Original text inserted.", true),
    ("Rewriting skipped: the endpoint is invalid. Original text inserted.", true),
    ("Rewriting skipped: the text is too long. Original text inserted.", true),
    ("Rewriting skipped: history is full. Original text inserted.", true),
    ("This dictation already has ten rewrite attempts.", false),
    ("Two rewrites are still running. Original text inserted.", true),
    ("Rewrite was interrupted by a restart.", true),
    ("Rewrite used on-screen text you did not say; inserted your transcript.", true),
    ("Rewrite cancelled. Original text inserted.", true),
    ("Previous dictation saved to history, not inserted.", false),
    // `showMeetingNotice` always passes `canRetry: false` (SHELL-236).
    ("Meeting in progress", false),
    ("Meeting transcript is finalizing. Wait for it to finish.", false),
    ("Server only is on, so this Mac doesn't run models. Change it in Settings › Server.", false),
    ("This meeting can't be moved to this Mac right now.", false),
];

#[derive(Clone, PartialEq, Debug)]
pub enum LearnedKind {
    Added,
    Retired { alias: String },
}

#[derive(Clone)]
pub struct Learned {
    pub word: String,
    pub kind: LearnedKind,
    pub shown: Instant,
}

impl Learned {
    pub fn message(&self) -> String {
        match &self.kind {
            LearnedKind::Added => "Added to dictionary".into(),
            LearnedKind::Retired { alias } if *alias == self.word => format!("Stopped listening for \u{2018}{}\u{2019}", self.word),
            LearnedKind::Retired { alias } => format!("Stopped changing \u{2018}{alias}\u{2019} to \u{2018}{}\u{2019}", self.word),
        }
    }
    /// Swift labels the group by the word when added and by the message when retired.
    fn group_label(&self) -> String {
        match self.kind {
            LearnedKind::Added => format!("Added {} to dictionary", self.word),
            LearnedKind::Retired { .. } => self.message(),
        }
    }
    pub fn announcement(&self) -> String {
        match &self.kind {
            LearnedKind::Added => format!("Added {} to dictionary.", self.word),
            LearnedKind::Retired { alias } => format!("Stopped changing {alias} to {}. Restore is available.", self.word),
        }
    }
    fn action(&self) -> (&'static str, &'static str, String) {
        match self.kind {
            LearnedKind::Added => ("Undo", "dictionary.notice.undo", format!("Undo adding {} to dictionary", self.word)),
            LearnedKind::Retired { .. } => ("Restore", "dictionary.notice.restore", format!("Restore {}", self.word)),
        }
    }
}

#[derive(Clone)]
pub struct TextNotice {
    pub id: u64,
    pub message: String,
}

#[derive(Clone)]
pub struct ActionNotice {
    pub id: u64,
    pub message: String,
    pub can_retry: bool,
    pub shown: Instant,
}

#[derive(Clone)]
pub struct ClipboardNotice {
    pub id: u64,
    pub inserted_uncertain: bool,
    pub shown: Instant,
}

impl ClipboardNotice {
    pub fn message(&self) -> &'static str {
        if self.inserted_uncertain { "Copied to clipboard in case it's missing" } else { "Couldn't insert · copied to clipboard" }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BackgroundKind {
    Finalizing,
    Resuming,
    Labeling,
    Summarizing { queued: usize },
}

#[derive(Clone)]
pub struct BackgroundNotice {
    pub meeting_id: String,
    pub kind: BackgroundKind,
    pub progress: Option<f32>,
}

impl BackgroundNotice {
    pub fn symbol(&self) -> &'static str {
        match self.kind {
            BackgroundKind::Finalizing | BackgroundKind::Resuming => "text.badge.checkmark",
            BackgroundKind::Labeling => "person.2",
            BackgroundKind::Summarizing { .. } => "text.quote",
        }
    }
    pub fn text(&self) -> String {
        let base = match self.kind {
            BackgroundKind::Finalizing => "Finalizing transcript".to_string(),
            BackgroundKind::Resuming => "Resuming interrupted transcript".to_string(),
            BackgroundKind::Labeling => "Labeling speakers".to_string(),
            BackgroundKind::Summarizing { queued: 0 } => "Summarizing…".to_string(),
            BackgroundKind::Summarizing { queued } => format!("Summarizing… ({queued} queued)"),
        };
        match (self.kind, self.progress) {
            (BackgroundKind::Finalizing, Some(p)) => format!("{base} · {} %", (p * 100.).round().clamp(0., 100.) as i32),
            _ => base,
        }
    }
    fn tab(&self) -> &'static str {
        if matches!(self.kind, BackgroundKind::Summarizing { .. }) { "summary" } else { "transcript" }
    }
}

/// `IndicatorPresentation.Content`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Content {
    Dictation,
    Microphone,
    Learned,
    Clipboard,
    Action,
    Background,
    None,
}

pub struct Pill {
    pub state: DictState,
    pub level: f32,
    /// Advanced while rendering, so it can't go through `update_session`: that re-renders forever.
    pub waveform: std::cell::RefCell<Waveform>,
    pub state_since: Instant,
    pub expand_since: Option<Instant>,
    pub microphone: Option<TextNotice>,
    pub learned: Option<Learned>,
    pub clipboard: Option<ClipboardNotice>,
    pub action: Option<ActionNotice>,
    pub background: Option<BackgroundNotice>,
    pub hidden: HashSet<String>,
    pub layouts: u64,
    next_id: u64,
    hidden_generation: u64,
}

impl Default for Pill {
    fn default() -> Self {
        Pill {
            state: DictState::Idle,
            level: 0.,
            waveform: Default::default(),
            state_since: Instant::now(),
            expand_since: None,
            microphone: None,
            learned: None,
            clipboard: None,
            action: None,
            background: None,
            hidden: HashSet::new(),
            layouts: 0,
            next_id: 0,
            hidden_generation: 0,
        }
    }
}

impl Pill {
    /// First that applies: dictation, microphone, learned, clipboard, action, background.
    pub fn content(&self) -> Content {
        if shows_dictation(self.state) {
            Content::Dictation
        } else if self.microphone.is_some() {
            Content::Microphone
        } else if self.learned.is_some() {
            Content::Learned
        } else if self.clipboard.is_some() {
            Content::Clipboard
        } else if self.action.is_some() {
            Content::Action
        } else if self.background.is_some() {
            Content::Background
        } else {
            Content::None
        }
    }

    /// Background alone presents only if it isn't suppressed; anything else always does.
    pub fn should_show(&self, suppressed: bool) -> bool {
        match self.content() {
            Content::None => false,
            Content::Background => !suppressed && self.background.as_ref().is_some_and(|b| !self.hidden.contains(&b.meeting_id)),
            _ => true,
        }
    }

    fn id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    /// `showMeetingNotice` and the rewrite notices.
    fn set_state(&mut self, state: DictState) {
        if state == DictState::Recording && self.state != DictState::Recording {
            *self.waveform.borrow_mut() = Waveform::default();
        }
        if is_compact(self.state) != is_compact(state) || !shows_dictation(self.state) {
            self.expand_since = (!is_compact(state)).then(Instant::now);
        }
        self.state = state;
        self.state_since = Instant::now();
        self.layouts += 1;
    }
}

fn announce(message: &str, cx: &App) {
    // Unavailable until `Services` has the platform call: it must never block the state change.
    let _ = cx.global::<Core>().services.announce(message);
}

fn suppressed(cx: &App) -> bool {
    cx.global::<Session>().window_focused || !cx.global::<Core>().prefs.bool_or("showsBackgroundProgress", true)
}

/// `update(state:level:)`.
pub fn set_state(state: DictState, level: f32, cx: &mut App) {
    let previous = cx.global::<Session>().pill.state;
    update_session(cx, |s| {
        s.pill.set_state(state);
        s.pill.level = clamp_level(level);
    });
    if let Some(message) = announcement(previous, state) {
        announce(message, cx);
    }
}

/// `updateLevel`: same state means no layout, only the level.
pub fn update_level(state: DictState, level: f32, cx: &mut App) {
    if cx.global::<Session>().pill.state != state || !shows_dictation(state) {
        set_state(state, level, cx);
        return;
    }
    update_session(cx, |s| s.pill.level = clamp_level(level));
}

/// Microphone notice, self-dismissed after 8 s; `message` is "No microphone available" or
/// "<name> didn't respond".
pub fn show_microphone(message: impl Into<String>, cx: &mut App) {
    let message: String = message.into();
    let id = update_session(cx, |s| {
        let id = s.pill.id();
        s.pill.microphone = Some(TextNotice { id, message: message.clone() });
        id
    });
    announce(&message, cx);
    after(MICROPHONE_SECONDS, cx, move |p| {
        if p.microphone.as_ref().is_some_and(|m| m.id == id) {
            p.microphone = None;
        }
    });
}

pub fn show_learned(word: impl Into<String>, kind: LearnedKind, cx: &mut App) {
    let notice = Learned { word: word.into(), kind, shown: Instant::now() };
    announce(&notice.announcement(), cx);
    let shown = notice.shown;
    update_session(cx, |s| s.pill.learned = Some(notice));
    after(LEARNED_SECONDS, cx, move |p| {
        if p.learned.as_ref().is_some_and(|l| l.shown == shown) {
            p.learned = None;
        }
    });
}

pub fn show_clipboard(uncertain: bool, cx: &mut App) {
    let (id, message) = update_session(cx, |s| {
        let id = s.pill.id();
        let notice = ClipboardNotice { id, inserted_uncertain: uncertain, shown: Instant::now() };
        let message = notice.message();
        s.pill.clipboard = Some(notice);
        (id, message)
    });
    announce(&format!("{message}. Paste with Command-V."), cx);
    after(CLIPBOARD_SECONDS, cx, move |p| {
        if p.clipboard.as_ref().is_some_and(|c| c.id == id) {
            p.clipboard = None;
        }
    });
}

/// The 6 s window runs from first show, even while another pill covers it.
pub fn show_action(message: impl Into<String>, can_retry: bool, cx: &mut App) {
    let message: String = message.into();
    let id = update_session(cx, |s| {
        let id = s.pill.id();
        s.pill.action = Some(ActionNotice { id, message: message.clone(), can_retry, shown: Instant::now() });
        id
    });
    announce(&message, cx);
    after(ACTION_SECONDS, cx, move |p| {
        if p.action.as_ref().is_some_and(|a| a.id == id) {
            p.action = None;
        }
    });
}

/// Announces when the notice changes, not on progress. Hidden ids clear 10 s after work goes quiet.
pub fn set_background(notice: Option<BackgroundNotice>, cx: &mut App) {
    let previous = cx.global::<Session>().pill.background.as_ref().map(|b| (b.meeting_id.clone(), b.kind));
    let next = notice.as_ref().map(|b| (b.meeting_id.clone(), b.kind));
    if previous != next && let Some(b) = &notice {
        announce(&b.text(), cx);
    }
    let quiet = notice.is_none();
    let generation = update_session(cx, |s| {
        s.pill.background = notice;
        s.pill.hidden_generation += 1;
        s.pill.hidden_generation
    });
    if quiet {
        after(HIDDEN_GRACE_SECONDS, cx, move |p| {
            if p.hidden_generation == generation {
                p.hidden.clear();
            }
        });
    }
}

fn after(seconds: u64, cx: &mut App, f: impl FnOnce(&mut Pill) + 'static) {
    cx.spawn(async move |cx| {
        cx.background_executor().timer(Duration::from_secs(seconds)).await;
        let _ = cx.update(|cx| update_session(cx, |s| f(&mut s.pill)));
    })
    .detach();
}

/// Called when the main window's focus changes; the Session observer handles the rest.
pub fn focus_changed(cx: &mut App) {
    sync_window(cx);
}

fn tap_cancel(cx: &mut App) {
    shell::cancel_dictation(cx);
}

fn tap_learned(cx: &mut App) {
    let Some(n) = cx.global::<Session>().pill.learned.clone() else { return };
    let command = if n.kind == LearnedKind::Added { SessionCommand::UndoLearned } else { SessionCommand::RestoreLearned };
    // Swift dismisses first, then writes; a refused store shows nothing more in Swift either.
    let _ = cx.global::<Core>().services.session_command(command);
    update_session(cx, |s| s.pill.learned = None);
}

fn tap_retry(cx: &mut App) {
    let _ = cx.global::<Core>().services.session_command(SessionCommand::RetryRewrite);
    update_session(cx, |s| s.pill.action = None);
}

fn tap_microphones(cx: &mut App) {
    update_session(cx, |s| s.pill.microphone = None);
    shell::show_microphones(cx);
}

fn tap_background(cx: &mut App) {
    let Some(b) = cx.global::<Session>().pill.background.clone() else { return };
    update_session(cx, |s| s.open_meeting = Some((b.meeting_id.clone(), Some(b.tab()))));
    shell::open(Some(Page::Meetings), cx);
}

fn tap_hide(cx: &mut App) {
    let Some(b) = cx.global::<Session>().pill.background.clone() else { return };
    update_session(cx, |s| {
        s.pill.hidden.insert(b.meeting_id);
    });
    announce("Progress hidden. It stays in LocalFlow.", cx);
}

/// `remaining` of a countdown; Reduce Motion keeps the ring full, the timeout unchanged.
pub fn remaining(elapsed: f32, seconds: f32, reduce_motion: bool) -> f32 {
    if reduce_motion { 1. } else { (1. - elapsed / seconds).clamp(0., 1.) }
}

/// `(fill, stroke)` of the capsule.
fn capsule_colors(highlighted: bool) -> (Hsla, Hsla) {
    if highlighted { (style::fill().opacity(0.92), style::white(0.22)) } else { (style::fill(), style::white(0.13)) }
}

fn capsule(highlighted: bool, k: f32) -> Div {
    let (fill, stroke) = capsule_colors(highlighted);
    div().h(px(HEIGHT * k)).rounded(px(HEIGHT * k / 2.)).bg(fill).border_1().border_color(stroke)
}

/// The capsule stroke trimmed to `remaining`, 1.5 wide with round caps.
fn ring(remaining: f32) -> impl IntoElement {
    canvas(
        |_, _, _| {},
        move |bounds, _, window, _| {
            if remaining <= 0. {
                return;
            }
            let (w, h) = (f32::from(bounds.size.width) - 1.5, f32::from(bounds.size.height) - 1.5);
            let r = h / 2.;
            let straight = (w - h).max(0.);
            let perimeter = 2. * straight + std::f32::consts::TAU * r;
            let at = |d: f32| {
                let d = d.rem_euclid(perimeter);
                let (x, y) = if d < straight {
                    (r + d, 0.)
                } else if d < straight + std::f32::consts::PI * r {
                    let a = (d - straight) / r;
                    (r + straight + r * a.sin(), r - r * a.cos())
                } else if d < 2. * straight + std::f32::consts::PI * r {
                    (r + straight - (d - straight - std::f32::consts::PI * r), h)
                } else {
                    let a = (d - 2. * straight - std::f32::consts::PI * r) / r;
                    (r - r * a.sin(), r + r * a.cos())
                };
                bounds.origin + point(px(x + 0.75), px(y + 0.75))
            };
            let mut path = PathBuilder::stroke(px(1.5));
            let length = perimeter * remaining;
            path.move_to(at(0.));
            let steps = (length / 2.).ceil().max(1.) as usize;
            for i in 1..=steps {
                path.line_to(at(length * i as f32 / steps as f32));
            }
            if let Ok(path) = path.build() {
                window.paint_path(path, style::ink().opacity(0.9));
            }
        },
    )
    .absolute()
    .top_0()
    .left_0()
    .size_full()
}

#[allow(clippy::too_many_arguments)]
fn chip(id: &'static str, title: &'static str, a11y: String, remaining: Option<f32>, tip: Option<&'static str>, content: Option<AnyElement>, f: fn(&mut App), k: f32) -> impl IntoElement {
    let mut body = div()
        .relative()
        .rounded(px(19. * k))
        .px(px(12. * k))
        .py(px(6. * k))
        .bg(style::white(0.1))
        .child(content.unwrap_or_else(|| t(title).font(11. * k, 600.).color(style::ink()).a11y_hidden().into_any_element()));
    if let Some(r) = remaining {
        body = body.child(ring(r));
    }
    let mut b = plain_button(id, a11y).content(div().when(remaining.is_some(), |d| d.p(px(1.))).child(body)).on_click(move |_, _, cx| f(cx));
    if let Some(tip) = tip {
        b = b.tooltip(tip);
    }
    b
}

/// A notice's symbol, `up` points above its resting place.
fn glyph(symbol: &'static str, up: f32, k: f32) -> AnyElement {
    div().id("pill.notice.symbol").test_support().relative().top(px(-up)).child(icon(symbol, 11. * k, style::ink().opacity(0.9))).into_any_element()
}

/// `spacer` is Swift's `Spacer(minLength: 4)`, in the learned and clipboard notices only.
/// The capsule's 1 stroke sits inside Swift's padding but outside GPUI's, hence the `- 1.`.
fn notice(symbol: AnyElement, message: String, label: String, max_width: f32, spacer: bool, action: Option<AnyElement>, k: f32) -> impl IntoElement {
    let trailing = if action.is_some() { 5. } else { 16. };
    capsule(false, k)
        .id("pill.notice")
        .test_support()
        .role(accesskit::Role::Group)
        .aria_label(label)
        .flex()
        .items_center()
        .gap(px(10. * k))
        .pl(px(14. * k - 1.))
        .pr(px(trailing * k - 1.))
        .child(symbol)
        .child(div().id("pill.notice.message").test_support().max_w(px(max_width * k)).child(t(message).font(12. * k, 500.).color(style::ink()).lines(1)))
        .when(spacer, |d| d.child(div().w(px(4. * k)).flex_none()))
        .children(action)
}

/// Swift's `.truncationMode(.middle)`: keeps both ends, the centre becomes an ellipsis.
pub fn truncate_middle(text: &str, max: f32, width: impl Fn(&str) -> f32) -> String {
    if width(text) <= max {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let fit = |keep: usize| -> String {
        let (head, tail) = (keep.div_ceil(2), keep / 2);
        chars[..head].iter().chain(['\u{2026}'].iter()).chain(chars[chars.len() - tail..].iter()).collect()
    };
    let (mut lo, mut hi) = (0, chars.len());
    while lo < hi {
        let keep = (lo + hi).div_ceil(2);
        if width(&fit(keep)) <= max { lo = keep } else { hi = keep - 1 }
    }
    fit(lo)
}

/// One symbol bounce, in points above rest. ponytail: an approximation of `.symbolEffect(.bounce)`, whose curve isn't published.
pub fn bounce(t: f32) -> f32 {
    if (0. ..BOUNCE).contains(&t) { 2.5 * (std::f32::consts::PI * t / BOUNCE).sin() } else { 0. }
}

/// A repeating symbol pulse. ponytail: an approximation of `.symbolEffect(.pulse, options: .repeating)`.
pub fn pulse(time: f64) -> f32 {
    (0.65 + 0.35 * (time * std::f64::consts::TAU / PULSE).cos()) as f32
}

/// A non-recording bar's height and opacity; Reduce Motion holds the static shape at full opacity.
fn bar_target(i: usize, state: DictState, reduce: bool, time: f64) -> (f32, f32) {
    match state {
        DictState::Rewriting if !reduce => rewriting_wave(i, time),
        DictState::Connecting if !reduce => (4., connecting_opacity(time)),
        s if is_processing(s) && !reduce => (processing_height(i, time), 1.),
        s => (static_height(i, s), 1.),
    }
}

/// One bar: x from the slot's left, centered vertically.
fn bar(slot: usize, x: f32, height: f32, opacity: f32) -> impl IntoElement {
    div().id(("pill.bar", slot)).absolute().left(px(x)).top(px((HEIGHT - 2. - height) / 2.)).w(px(3.)).h(px(height)).rounded(px(1.5)).bg(style::ink().opacity(opacity)).test_support()
}

pub struct PillView {
    hovering: bool,
    /// The running hover animation: when it began and the mix it began from.
    hover_anim: Option<(Instant, f32)>,
    shown_at: Instant,
    hide_since: Option<Instant>,
    shown: Content,
    swap_since: Option<Instant>,
    _sub: Subscription,
}

impl PillView {
    pub fn new(cx: &mut Context<Self>) -> Self {
        PillView { hovering: false, hover_anim: None, shown_at: Instant::now(), hide_since: None, shown: cx.global::<Session>().pill.content(), swap_since: None, _sub: cx.observe_global::<Session>(|_, cx| cx.notify()) }
    }

    fn set_hover(&mut self, hovering: bool, cx: &mut Context<Self>) {
        let from = self.hover_mix();
        self.hovering = hovering;
        self.hover_anim = Some((Instant::now(), from));
        cx.notify();
    }

    /// 1 hovered, 0 not, on the swap spring between them.
    fn hover_mix(&self) -> f32 {
        let target = if self.hovering { 1. } else { 0. };
        self.hover_anim.map_or(target, |(since, from)| from + (target - from) * spring(since.elapsed().as_secs_f32(), SWAP).clamp(0., 1.))
    }

    /// The mix for this frame, asking for the next while it moves. `animated` false jumps to the end.
    fn hover_frame(&mut self, animated: bool, window: &mut Window) -> f32 {
        if !animated || self.hover_anim.is_some_and(|(since, _)| since.elapsed().as_secs_f32() >= HOVER_SETTLE) {
            self.hover_anim = None;
        }
        if self.hover_anim.is_some() {
            window.request_animation_frame();
        }
        self.hover_mix()
    }

    fn dictation(&mut self, time: f64, reduce: bool, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let pill = &cx.global::<Session>().pill;
        let (state, level) = (pill.state, pill.level);
        let since_expand = pill.expand_since.map_or(1000., |t| t.elapsed().as_secs_f32());
        if state == DictState::Recording && !reduce {
            pill.waveform.borrow_mut().advance(time, level);
        }
        let (heights, progress) = (pill.waveform.borrow().heights(), pill.waveform.borrow().progress(time));
        let expanded = !is_compact(state);
        let morph = if reduce { 1. } else { spring(since_expand, MORPH) };
        let width = if expanded { COMPACT_WIDTH + (EXPANDED_WIDTH - COMPACT_WIDTH) * morph } else { COMPACT_WIDTH };
        let reveal_at = |slot| if !expanded || reduce { 1. } else { reveal(slot, since_expand) };
        let inner_left = (width - 2. - EXPANDED_WIDTH) / 2.;
        let mut row = div().absolute().left(px(inner_left + 15.5)).top_0().w(px(87.)).h(px(HEIGHT - 2.));
        if state == DictState::Recording && !reduce {
            row = row.overflow_hidden().children(heights.iter().enumerate().map(|(slot, h)| {
                let x = slot as f32 * PITCH - PITCH * progress;
                let r = reveal_at(slot.min(BAR_COUNT - 1));
                bar(slot, x, h * (0.2 + 0.8 * r), r * fade(x))
            }));
        } else {
            row = row.children((0..BAR_COUNT).map(|i| {
                let x = i as f32 * PITCH;
                let (h, o) = bar_target(i, state, reduce, time);
                let r = if state == DictState::Rewriting { 1. } else { reveal_at(i) };
                bar(i, x, h * (0.2 + 0.8 * r), o * r)
            }));
        }
        if !reduce {
            window.request_animation_frame();
        }
        let hover = self.hover_frame(!reduce, window);
        // Scale 0.6 to 1 on hover; Reduce Motion keeps scale 1 and only toggles opacity.
        let scale = if reduce { 1. } else { 0.6 + 0.4 * hover };
        let cancel = plain_button("pill.cancel", cancel_label(state))
            .content(div().id("pill.cancel.face").test_support().size(px(24. * scale)).flex().items_center().justify_center().rounded(px(12.)).bg(p.canvas).child(icon("xmark", 10. * scale, p.ink)))
            .on_click(|_, _, cx| tap_cancel(cx));
        div()
            .id("pill.dictation")
            .test_support()
            .relative()
            .w(px(INDICATOR_WIDTH))
            .h(px(HEIGHT))
            .role(accesskit::Role::Group)
            .aria_label(accessibility_label(state))
            .on_hover(cx.listener(|this, h: &bool, _, cx| this.set_hover(*h, cx)))
            .child(div().id("pill.capsule").test_support().absolute().left(px((EXPANDED_WIDTH - width) / 2.)).top_0().w(px(width)).h(px(HEIGHT)).child(capsule(false, 1.).relative().w_full().overflow_hidden().child(row)))
            .child(div().absolute().left(px(EXPANDED_WIDTH + 35. - 24.)).top(px(7.)).w(px(24.)).h(px(24.)).flex().items_center().justify_center().opacity(hover).child(cancel))
    }

    fn content(&mut self, time: f64, reduce: bool, k: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let pill = &cx.global::<Session>().pill;
        let content = pill.content();
        let countdown = |shown: Instant, seconds: u64| remaining(shown.elapsed().as_secs_f32(), seconds as f32, reduce);
        match content {
            Content::Dictation => self.dictation(time, reduce, window, cx).into_any_element(),
            Content::Microphone => {
                let m = pill.microphone.clone().unwrap();
                let action = chip("dictation.notice.microphones", "Microphones…", "Open Microphones settings".into(), None, None, None, tap_microphones, k);
                notice(glyph("mic.slash", 0., k), m.message.clone(), m.message, 420., false, Some(action.into_any_element()), k).into_any_element()
            }
            Content::Learned => {
                let n = pill.learned.clone().unwrap();
                let (title, id, a11y) = n.action();
                let r = countdown(n.shown, LEARNED_SECONDS);
                if !reduce {
                    window.request_animation_frame();
                }
                let message = truncate_middle(&n.message(), 360., |s| text_width(s, 12., 500., cx));
                notice(glyph("sparkles", 0., k), message, n.group_label(), 360., true, Some(chip(id, title, a11y, Some(r), None, None, tap_learned, k).into_any_element()), k).into_any_element()
            }
            Content::Clipboard => {
                let c = pill.clipboard.clone().unwrap();
                let r = countdown(c.shown, CLIPBOARD_SECONDS);
                let appeared = c.shown.elapsed().as_secs_f32();
                // The bounce has no Reduce Motion guard in Swift either (SHELL-238).
                if !reduce || appeared < BOUNCE {
                    window.request_animation_frame();
                }
                let keycap = h_flex().gap(px(1.)).child(icon("command", 9. * k, style::ink())).child(t("V").font(11. * k, 600.).color(style::ink()).a11y_hidden());
                let action = chip("clipboard.notice.dismiss", "V", "Dismiss. Paste with Command-V".into(), Some(r), Some("Paste with Command-V"), Some(keycap.into_any_element()), |cx| update_session(cx, |s| s.pill.clipboard = None), k);
                notice(glyph("doc.on.clipboard", bounce(appeared), k), c.message().to_string(), c.message().to_string(), 420., true, Some(action.into_any_element()), k).into_any_element()
            }
            Content::Action => {
                let a = pill.action.clone().unwrap();
                let r = countdown(a.shown, ACTION_SECONDS);
                if !reduce && a.can_retry {
                    window.request_animation_frame();
                }
                let action = a.can_retry.then(|| div().id("rewrite.notice.retry.group").test_support().child(chip("rewrite.notice.retry", "Retry", "Retry rewrite".into(), Some(r), None, None, tap_retry, k)).aria_description("Available here briefly. Retry is also in History.").into_any_element());
                notice(glyph("text.badge.xmark", 0., k), a.message.clone(), a.message, 420., false, action, k).into_any_element()
            }
            Content::Background => {
                let b = pill.background.clone().unwrap();
                // No Reduce Motion guard on the hover spring or the pulse in Swift either (SHELL-238).
                let hover = self.hover_frame(true, window);
                let scale = 0.5 + 0.5 * hover;
                window.request_animation_frame();
                h_flex()
                    .id("pill.background")
                    .test_support()
                    .gap(px(6.))
                    .pl(px(28.))
                    .on_hover(cx.listener(|this, h: &bool, _, cx| this.set_hover(*h, cx)))
                    .child(div().id("background.notice.group").test_support().aria_description("Opens LocalFlow").child(
                        plain_button("background.notice", b.text())
                            .content(capsule(self.hovering, k).id("background.notice.capsule").test_support().flex().items_center().gap(px(10. * k)).px(px(16. * k - 1.)).child(div().opacity(pulse(time)).child(icon(b.symbol(), 11. * k, style::ink().opacity(0.9)))).child(div().max_w(px(420. * k)).child(t(b.text()).font(12. * k, 500.).color(style::ink()).lines(1).mono_digits().a11y_hidden())))
                            .on_click(|_, _, cx| tap_background(cx)),
                    ))
                    .child(
                        div().size(px(22.)).flex().items_center().justify_center().opacity(hover).child(
                            plain_button("background.notice.hide", "Hide progress")
                                .tooltip("Hide until this meeting is done")
                                .content(div().id("background.notice.hide.face").test_support().size(px(22. * scale)).flex().items_center().justify_center().rounded(px(11.)).bg(style::fill()).border_1().border_color(style::white(0.13)).child(icon("xmark", 9. * scale, style::ink().opacity(0.85))))
                                .on_click(|_, _, cx| tap_hide(cx)),
                        ),
                    )
                    .into_any_element()
            }
            Content::None => div().into_any_element(),
        }
    }
}

impl Render for PillView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let reduce = cx.global::<Flow>().reduce_motion;
        let time = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0., |d| d.as_secs_f64());
        let (mut opacity, mut drop) = (1., 0.);
        if !reduce {
            if let Some(h) = self.hide_since {
                let f = (h.elapsed().as_secs_f32() / HIDE).clamp(0., 1.);
                (opacity, drop) = (1. - f * f, RISE * f * f);
            } else {
                let f = settle(self.shown_at.elapsed().as_secs_f32() / SHOW);
                (opacity, drop) = (f, RISE * (1. - f));
            }
            if opacity < 1. || self.hide_since.is_some() {
                window.request_animation_frame();
            }
        }
        // The new content fades in and scales from 0.88. GPUI has no view scale, so sizes carry it.
        // ponytail: the outgoing content isn't kept for Swift's 0.1 s fade: its notice is already gone from `Session`.
        // The dictation pill fades without scaling, since its bars animate their own geometry.
        let current = cx.global::<Session>().pill.content();
        if current != self.shown {
            self.shown = current;
            self.swap_since = (!reduce).then(Instant::now);
        }
        let (fade_in, mut k) = self.swap_since.map_or((1., 1.), |t| swap_style(t.elapsed().as_secs_f32()));
        if self.swap_since.is_some_and(|t| t.elapsed().as_secs_f32() >= 1.) {
            self.swap_since = None;
        } else if self.swap_since.is_some() {
            window.request_animation_frame();
        }
        if current == Content::Dictation {
            k = 1.;
        }
        let content = self.content(time, reduce, k, window, cx);
        div().size_full().flex().justify_center().font_family(FIGTREE).opacity(opacity * fade_in).pt(px(drop)).child(content)
    }
}

struct PillWindow {
    handle: AnyWindowHandle,
    view: Entity<PillView>,
    key: (Content, i32),
}
impl Global for PillWindow {}

/// x centers the 118 waveform for dictation and the whole width for notices; y is 20 up.
pub fn panel_origin(visible: Bounds<Pixels>, width: f32, dictating: bool) -> Point<Pixels> {
    let mid = f32::from(visible.origin.x) + f32::from(visible.size.width) / 2.;
    let x = if dictating { mid - EXPANDED_WIDTH / 2. } else { mid - width / 2. };
    let y = f32::from(visible.origin.y) + f32::from(visible.size.height) - 20. - HEIGHT;
    point(px(x.round()), px(y))
}

/// A line's width in Figtree. ponytail: sums advances without kerning; only a window can shape a line, and the panel's width is needed before one exists.
fn text_width(text: &str, size: f32, weight: f32, cx: &App) -> f32 {
    let mut f = font(FIGTREE);
    f.weight = FontWeight(weight);
    let system = cx.text_system();
    let id = system.resolve_font(&f);
    text.chars().map(|c| system.advance(id, px(size), c).map_or(0., |a| f32::from(a.width))).sum::<f32>() + 2.
}

/// The ceiling of what the content lays out to, since a window can't follow its view here.
pub fn content_width(cx: &App) -> f32 {
    let pill = &cx.global::<Session>().pill;
    let text_width = |text: &str, size: f32, weight: f32| text_width(text, size, weight, cx);
    let notice = |message: &str, max: f32, chip: Option<f32>| 14. + 11. + 10. + text_width(message, 12., 500.).min(max) + chip.map_or(16., |c| 10. + c + 5.);
    let chip = |title: &str, ring: bool| 24. + text_width(title, 11., 600.) + if ring { 2. } else { 0. };
    let width: f32 = match pill.content() {
        Content::Dictation | Content::None => INDICATOR_WIDTH,
        Content::Microphone => notice(&pill.microphone.as_ref().unwrap().message, 420., Some(chip("Microphones…", false))),
        Content::Learned => {
            let n = pill.learned.as_ref().unwrap();
            notice(&n.message(), 360., Some(4. + 10. + chip(n.action().0, true)))
        }
        Content::Clipboard => notice(pill.clipboard.as_ref().unwrap().message(), 420., Some(4. + 10. + chip("V", true) + 10.)),
        Content::Action => {
            let a = pill.action.as_ref().unwrap();
            notice(&a.message, 420., a.can_retry.then(|| chip("Retry", true)))
        }
        Content::Background => {
            let b = pill.background.as_ref().unwrap();
            28. + 32. + 11. * flow_ui::icons::advance(b.symbol()) + 10. + text_width(&b.text(), 12., 500.).min(420.) + 6. + 22.
        }
    };
    width.ceil()
}

/// Presents or hides the panel to match `Session.pill`. Called from the Session observer.
pub fn sync_window(cx: &mut App) {
    let show = cx.global::<Session>().pill.should_show(suppressed(cx));
    let content = cx.global::<Session>().pill.content();
    let width = if show { content_width(cx) } else { 0. };
    let key = (content, width as i32);
    let current = cx.try_global::<PillWindow>().map(|w| (w.handle, w.key, w.view.clone()));
    if let Some((handle, old, view)) = current {
        if show && old == key {
            return;
        }
        let reduce = cx.global::<Flow>().reduce_motion;
        if show && !reduce {
            // The same panel moves to its new frame over 0.32 s; `PillView` swaps the content.
            let visible = panel_screen(cx);
            let x = f32::from(panel_origin(visible, width, content == Content::Dictation).x);
            let moved = handle.update(cx, |_, w, cx| cx.global::<Core>().services.animate_panel_frame(w, x, width, RESIZE, RESIZE_CURVE).is_ok());
            if matches!(moved, Ok(true)) {
                cx.global_mut::<PillWindow>().key = key;
                return;
            }
        }
        cx.remove_global::<PillWindow>();
        if show || reduce {
            // Reduce Motion resizes at once; where the platform can't animate a frame, a new window takes the new size.
            let _ = handle.update(cx, |_, w, _| w.remove_window());
        } else {
            view.update(cx, |v, cx| {
                v.hide_since = Some(Instant::now());
                cx.notify();
            });
            cx.spawn(async move |cx| {
                cx.background_executor().timer(Duration::from_secs_f32(HIDE)).await;
                let _ = cx.update(|cx| handle.update(cx, |_, w, _| w.remove_window()));
            })
            .detach();
        }
    }
    if !show {
        return;
    }
    let visible = panel_screen(cx);
    let origin = panel_origin(visible, width, content == Content::Dictation);
    let bounds = Bounds { origin, size: size(px(width), px(HEIGHT + RISE)) };
    if let Ok((handle, view)) = flow_ui::open_bare_window(panel_options(bounds), cx, |_, cx| cx.new(PillView::new)) {
        let _ = handle.update(cx, |_, w, cx| cx.global::<Core>().services.pin_panel(w));
        cx.set_global(PillWindow { handle, view, key });
    }
}

/// Borderless and nonactivating: `PopUp` is GPUI's NSPanel, which also joins all Spaces and full-screen ones.
/// The visible frame of the screen under `point`, Swift's `NSMouseInRect` over `NSScreen.screens`.
fn screen_under(point: Option<Point<Pixels>>, screens: &[(Bounds<Pixels>, Bounds<Pixels>)]) -> Option<Bounds<Pixels>> {
    let point = point?;
    screens.iter().find(|(frame, _)| frame.contains(&point)).map(|(_, visible)| *visible)
}

/// Where the panels show: the mouse's screen, then the primary one.
/// ponytail: Swift tries the target AX window's screen first; the capture feature has no window frame yet.
pub(crate) fn panel_screen(cx: &App) -> Bounds<Pixels> {
    let pointer = cx.global::<Core>().services.pointer_location().map(|(x, y)| point(px(x), px(y)));
    let screens: Vec<_> = cx.displays().iter().map(|d| (d.bounds(), d.visible_bounds())).collect();
    screen_under(pointer, &screens)
        .or_else(|| cx.primary_display().map(|d| d.visible_bounds()))
        .unwrap_or(Bounds { origin: point(px(0.), px(0.)), size: size(px(1280.), px(800.)) })
}

fn panel_options(bounds: Bounds<Pixels>) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: false,
        kind: WindowKind::PopUp,
        is_movable: false,
        is_resizable: false,
        window_background: WindowBackgroundAppearance::Transparent,
        ..Default::default()
    }
}

/// `LOCALFLOW_SCENARIO=pill.<state>` puts the pill on screen for the audit.
pub fn apply_scenario(cx: &mut App) {
    let Some(state) = cx.global::<Core>().scenario.clone().and_then(|s| s.strip_prefix("pill.").map(String::from)) else { return };
    let dict = match state.as_str() {
        "preparing" => Some(DictState::Preparing),
        "connecting" => Some(DictState::Connecting),
        "recording" => Some(DictState::Recording),
        "transcribing" => Some(DictState::Transcribing),
        "rewriting" => Some(DictState::Rewriting),
        _ => None,
    };
    if let Some(d) = dict {
        set_state(d, 0.12, cx);
        return;
    }
    let bg = |kind, progress| Some(BackgroundNotice { meeting_id: "scenario".into(), kind, progress });
    match state.as_str() {
        "microphone" => show_microphone("No microphone available", cx),
        "learned" => show_learned("LocalFlow", LearnedKind::Added, cx),
        "retired" => show_learned("LocalFlow", LearnedKind::Retired { alias: "local flow".into() }, cx),
        "clipboard" => show_clipboard(false, cx),
        // The microphone notice replaces the clipboard one after 1.5 s: the live check of PILL-019 and PILL-025.
        "swap" => {
            show_clipboard(false, cx);
            cx.spawn(async move |cx| {
                cx.background_executor().timer(Duration::from_millis(1500)).await;
                let _ = cx.update(|cx| show_microphone("No microphone available", cx));
            })
            .detach();
        }
        "action" => show_action(REWRITE_NOTICES[0].0, true, cx),
        "action-no-retry" => show_action(REWRITE_NOTICES[12].0, false, cx),
        "background" => set_background(bg(BackgroundKind::Finalizing, Some(0.42)), cx),
        "summarizing" => set_background(bg(BackgroundKind::Summarizing { queued: 2 }, None), cx),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::ensure_session;
    use crate::testing::{assert_saw, boot};
    use flow_platform::Fake;
    use flow_ui::test::{TestAppContext, TestWindowExt};
    use std::{cell::RefCell, rc::Rc};

    const DICT: [DictState; 9] = [DictState::Preparing, DictState::Connecting, DictState::Recording, DictState::Transcribing, DictState::Persisting, DictState::Rewriting, DictState::Inserting, DictState::Cancelling, DictState::Preparing];

    fn view(cx: &mut TestAppContext) -> (WindowHandle<PillView>, Rc<RefCell<Vec<String>>>, Rc<RefCell<Vec<SessionCommand>>>) {
        boot(cx, Mode::Dark);
        // Reduce Motion freezes the running timers, so the assertions read fixed values.
        cx.update(|cx| cx.global_mut::<Flow>().reduce_motion = true);
        let (announced, commands): (Rc<RefCell<Vec<String>>>, Rc<RefCell<Vec<SessionCommand>>>) = Default::default();
        cx.update(|cx| {
            ensure_session(cx);
            let fake = Fake { announced: announced.clone(), commands: commands.clone(), ..Default::default() };
            fake.session_ok.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
        });
        let w = cx.add_window(|_, cx| PillView::new(cx));
        (w, announced, commands)
    }

    fn frame(cx: &mut TestAppContext, w: WindowHandle<PillView>) {
        flow_ui::probe::clear();
        cx.run_until_parked();
        cx.update_window(w.into(), |_, w, cx| w.render_frame(cx)).unwrap();
    }

    fn pill<R>(cx: &mut TestAppContext, f: impl FnOnce(&Pill) -> R) -> R {
        cx.update(|cx| f(&cx.global::<Session>().pill))
    }

    // parity: PILL-011 PILL-012
    #[flow_ui::gpui::test]
    async fn opening_the_pill_pins_its_panel(cx: &mut TestAppContext) {
        boot(cx, Mode::Dark);
        let pinned: Rc<std::cell::Cell<usize>> = Default::default();
        cx.update(|cx| {
            ensure_session(cx);
            cx.global_mut::<Flow>().reduce_motion = true;
            cx.global_mut::<Core>().services = Box::new(Fake { pinned_panels: pinned.clone(), ..Default::default() });
            show_microphone("No microphone available", cx);
            sync_window(cx);
        });
        cx.run_until_parked();
        assert_eq!(pinned.get(), 1);
        assert!(cx.update(|cx| cx.has_global::<PillWindow>()));
    }

    // parity: PILL-015
    #[flow_ui::gpui::test]
    async fn panels_show_on_the_mouses_screen(cx: &mut TestAppContext) {
        let rect = |x: f32, y: f32, w: f32, h: f32| Bounds { origin: point(px(x), px(y)), size: size(px(w), px(h)) };
        let (left, right) = (rect(0., 0., 1440., 900.), rect(1440., -100., 2560., 1440.));
        let (left_visible, right_visible) = (rect(0., 25., 1440., 800.), rect(1440., -75., 2560., 1400.));
        let screens = [(left, left_visible), (right, right_visible)];
        assert_eq!(screen_under(Some(point(px(100.), px(100.))), &screens), Some(left_visible));
        assert_eq!(screen_under(Some(point(px(2000.), px(-50.))), &screens), Some(right_visible));
        assert_eq!(screen_under(Some(point(px(-5.), px(-5.))), &screens), None);
        assert_eq!(screen_under(None, &screens), None);
        // Off every screen, through the production path: the primary display.
        boot(cx, Mode::Dark);
        cx.update(|cx| {
            let fake = Fake::default();
            fake.pointer.set(Some((-5000., -5000.)));
            cx.global_mut::<Core>().services = Box::new(fake);
            assert_eq!(panel_screen(cx), cx.primary_display().unwrap().visible_bounds());
        });
    }

    // parity: PILL-001 PILL-002 PILL-003 PILL-004
    #[test]
    fn pill_colors_ignore_appearance() {
        assert_eq!(style::fill(), Hsla::from(rgb(0x242522)));
        assert_eq!(style::ink(), Hsla::from(rgb(0xF5F5F1)));
        assert_eq!(capsule_colors(false), (style::fill(), Hsla::from(rgb(0xFFFFFF)).opacity(0.13)));
        assert_eq!(capsule_colors(true), (Hsla::from(rgb(0x242522)).opacity(0.92), Hsla::from(rgb(0xFFFFFF)).opacity(0.22)));
    }

    fn bounds_of(cx: &mut TestAppContext, w: WindowHandle<PillView>, id: &'static str) -> Vec<Bounds<Pixels>> {
        cx.update_window(w.into(), |_, win, _| win.find_all(id).into_iter().map(|e| e.bounds()).collect()).unwrap()
    }

    fn bar_bounds(cx: &mut TestAppContext, w: WindowHandle<PillView>) -> Vec<Bounds<Pixels>> {
        cx.update_window(w.into(), |_, win, _| (0..32usize).filter_map(|i| win.try_find(("pill.bar", i)).map(|e| e.bounds())).collect()).unwrap()
    }

    // parity: PILL-007 PILL-008 PILL-009 PILL-029 PILL-035 PILL-036 PILL-041
    /// From laid-out bounds, under Reduce Motion so nothing animates.
    #[flow_ui::gpui::test]
    async fn dictation_lays_out_swifts_sizes(cx: &mut TestAppContext) {
        let (w, _, _) = view(cx);
        cx.update(|cx| set_state(DictState::Preparing, 0., cx));
        frame(cx, w);
        let whole = bounds_of(cx, w, "pill.dictation")[0];
        assert_eq!(whole.size, size(px(153.), px(38.)));
        let capsule = bounds_of(cx, w, "pill.capsule")[0];
        assert_eq!(capsule.size.width, px(46.));
        let bars = bar_bounds(cx, w);
        assert_eq!(bars.len(), 15);
        // The 87-wide row is wider than the compact capsule and centered on it, which clips it.
        assert!(bars[0].origin.x < capsule.origin.x && bars[14].right() > capsule.right());
        assert_eq!(bars[0].origin.x + bars[14].right(), capsule.origin.x + capsule.right());
        assert_eq!((bars[0].size.width, bars[1].origin.x - bars[0].origin.x), (px(3.), px(6.)));
        assert!(bars.iter().all(|b| b.size.height == px(4.)));
        cx.update(|cx| set_state(DictState::Recording, 0.5, cx));
        frame(cx, w);
        assert_eq!(bounds_of(cx, w, "pill.capsule")[0].size.width, px(118.));
        let bars = bar_bounds(cx, w);
        assert_eq!((bars[6].size.height, bars[14].size.height), (px(20.), px(4.5)), "27 and 6 at 0.75, on the layout grid");
        cx.update(|cx| set_state(DictState::Transcribing, 0., cx));
        frame(cx, w);
        let bars = bar_bounds(cx, w);
        assert_eq!((bars[3].size.height, bars[4].size.height), (px(14.), px(4.)));
    }

    // parity: PILL-032 PILL-034
    #[flow_ui::gpui::test]
    async fn recording_draws_sixteen_bars_at_the_level_height(cx: &mut TestAppContext) {
        let (w, _, _) = view(cx);
        cx.update(|cx| {
            cx.global_mut::<Flow>().reduce_motion = false;
            set_state(DictState::Recording, 1., cx);
            update_session(cx, |s| s.pill.expand_since = None);
        });
        cx.update_window(w.into(), |_, win, cx| win.render_frame(cx)).unwrap();
        let bars = bar_bounds(cx, w);
        assert_eq!(bars.len(), 16);
        assert_eq!(bars[15].size.height, px(28.), "a full level draws the tallest bar");
        assert_eq!(bars[0].size.height, px(3.), "silence draws the shortest");
        assert_eq!(bars[1].origin.x - bars[0].origin.x, px(6.));
    }

    // parity: PILL-047 PILL-048 PILL-049
    /// The button's face is 24 on hover and under Reduce Motion, 0.6 of that at rest.
    #[flow_ui::gpui::test]
    async fn cancel_scales_with_hover_unless_reduce_motion(cx: &mut TestAppContext) {
        let (w, _, _) = view(cx);
        cx.update(|cx| set_state(DictState::Recording, 0., cx));
        frame(cx, w);
        assert_eq!(bounds_of(cx, w, "pill.cancel.face")[0].size.width, px(24.));
        cx.update(|cx| cx.global_mut::<Flow>().reduce_motion = false);
        cx.update_window(w.into(), |_, win, cx| win.render_frame(cx)).unwrap();
        assert_eq!(bounds_of(cx, w, "pill.cancel.face")[0].size.width, px(14.5), "0.6 of 24, on the layout grid");
        cx.update_window(w.into(), |_, win, cx| {
            win.hover("pill.dictation", cx);
            win.render_frame(cx);
        }).unwrap();
        assert!(w.update(cx, |v, _, _| v.hovering).unwrap());
        // The swap spring carries it: part way after 0.05 s, 1 once settled.
        w.update(cx, |v, _, _| v.hover_anim = Some((Instant::now() - Duration::from_millis(50), 0.))).unwrap();
        let mid = w.update(cx, |v, _, _| v.hover_mix()).unwrap();
        assert!(mid > 0.05 && mid < 0.95, "{mid}");
        w.update(cx, |v, _, cx| {
            v.hover_anim = Some((Instant::now() - Duration::from_secs(1), 0.));
            cx.notify();
        }).unwrap();
        cx.update_window(w.into(), |_, win, cx| win.render_frame(cx)).unwrap();
        let (face, whole) = (bounds_of(cx, w, "pill.cancel.face")[0], bounds_of(cx, w, "pill.dictation")[0]);
        assert_eq!(face.size.width, px(24.));
        assert_eq!((face.right() - whole.origin.x, face.origin.y - whole.origin.y), (px(153.), px(7.)), "35 right of the 118 slot's end, less its 24");
        assert!(w.update(cx, |v, _, _| v.hover_anim.is_none()).unwrap());
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "xmark"));
    }

    fn wide(cx: &mut TestAppContext) -> (WindowHandle<PillView>, Rc<RefCell<Vec<String>>>, Rc<RefCell<Vec<SessionCommand>>>) {
        let v = view(cx);
        cx.update_window(v.0.into(), |_, win, _| win.resize(size(px(1000.), px(100.)))).unwrap();
        v
    }

    // parity: PILL-071
    /// The message stops at 360 with its middle gone, and 4 of spacer keeps the chip 24 away.
    #[flow_ui::gpui::test]
    async fn learned_message_truncates_its_middle_at_the_maximum(cx: &mut TestAppContext) {
        let chars = |s: &str| s.chars().count() as f32;
        assert_eq!(truncate_middle("short", 10., chars), "short");
        assert_eq!(truncate_middle("abcdefghij", 5., chars), "ab\u{2026}ij");
        let (w, _, _) = wide(cx);
        cx.update(|cx| show_learned("LocalFlow".repeat(30), LearnedKind::Retired { alias: "x".into() }, cx));
        frame(cx, w);
        let message = bounds_of(cx, w, "pill.notice.message")[0];
        assert!(message.size.width <= px(360.) && message.size.width > px(300.), "{message:?}");
        let seen = flow_ui::probe::seen();
        let line = seen.iter().find(|s| s.starts_with("Stopped")).expect("message drawn");
        assert!(line.contains('\u{2026}') && line.ends_with("LocalFlow\u{2019}"), "{line}");
        assert_eq!(bounds_of(cx, w, "dictionary.notice.restore")[0].origin.x - message.right(), px(24.));
    }

    // parity: PILL-064 PILL-065 PILL-066 PILL-085
    /// Measured in a laid-out notice. The ring's trim start and round cap are painted, not laid out.
    #[flow_ui::gpui::test]
    async fn notices_lay_out_swifts_padding_and_chips(cx: &mut TestAppContext) {
        let (w, _, _) = wide(cx);
        cx.update(|cx| show_microphone("No microphone available", cx));
        frame(cx, w);
        let (capsule, symbol, message, plain) = (bounds_of(cx, w, "pill.notice")[0], bounds_of(cx, w, "pill.notice.symbol")[0], bounds_of(cx, w, "pill.notice.message")[0], bounds_of(cx, w, "dictation.notice.microphones")[0]);
        assert_eq!(capsule.size.height, px(38.));
        assert_eq!(symbol.origin.x - capsule.origin.x, px(14.));
        assert_eq!(message.origin.x - symbol.right(), px(10.));
        assert_eq!(plain.origin.x - message.right(), px(10.), "no spacer without a countdown");
        assert_eq!(capsule.right() - plain.right(), px(5.));
        let style = flow_ui::probe::style_of("No microphone available").unwrap();
        assert_eq!((style.size, style.weight, style.color), (12., 500., style::ink()));
        let chip = flow_ui::probe::style_of("Microphones\u{2026}").unwrap();
        assert_eq!((chip.size, chip.weight, chip.color), (11., 600., style::ink()));

        cx.update(|cx| show_action("Rewrite took too long.", true, cx));
        cx.update(|cx| update_session(cx, |s| s.pill.microphone = None));
        frame(cx, w);
        let ringed = bounds_of(cx, w, "rewrite.notice.retry")[0];
        assert_eq!(ringed.size.height - plain.size.height, px(2.), "the ring adds 1 outer padding");

        cx.update(|cx| show_action("Rewrite took too long.", false, cx));
        frame(cx, w);
        let (capsule, message) = (bounds_of(cx, w, "pill.notice")[0], bounds_of(cx, w, "pill.notice.message")[0]);
        assert_eq!(capsule.right() - message.right(), px(16.), "no chip, trailing 16");
        assert_eq!(remaining(1.5, 6., false), 0.75, "drains linearly");
    }

    // parity: PILL-016
    /// The window fits what the content then lays out to, within the kerning the sum ignores.
    #[flow_ui::gpui::test]
    async fn panel_width_is_a_whole_point_ceiling(cx: &mut TestAppContext) {
        let (w, _, _) = wide(cx);
        cx.update(|cx| assert_eq!(content_width(cx), INDICATOR_WIDTH));
        let clear = |cx: &mut TestAppContext| cx.update(|cx| update_session(cx, |s| s.pill = Pill::default()));
        let fits = |cx: &mut TestAppContext, id: &'static str| {
            frame(cx, w);
            let (laid, width) = (bounds_of(cx, w, id)[0].size.width, cx.update(|cx| content_width(cx)));
            assert_eq!(width.fract(), 0.);
            assert!(laid <= px(width) && px(width) - laid < px(12.), "{id}: laid {laid:?}, window {width}");
        };
        cx.update(|cx| show_microphone("Studio didn't respond", cx));
        fits(cx, "pill.notice");
        clear(cx);
        cx.update(|cx| show_learned("LocalFlow", LearnedKind::Added, cx));
        fits(cx, "pill.notice");
        clear(cx);
        cx.update(|cx| show_clipboard(false, cx));
        fits(cx, "pill.notice");
        clear(cx);
        cx.update(|cx| set_background(Some(BackgroundNotice { meeting_id: "m".into(), kind: BackgroundKind::Labeling, progress: None }), cx));
        fits(cx, "pill.background");
    }

    // parity: PILL-011 PILL-012
    /// The options the production panel opens with.
    #[test]
    fn panel_is_a_borderless_nonactivating_popup() {
        let o = panel_options(Bounds::default());
        assert!(!o.focus && !o.is_movable && !o.is_resizable && o.titlebar.is_none());
        assert_eq!(o.kind, WindowKind::PopUp);
        assert_eq!(o.window_background, WindowBackgroundAppearance::Transparent);
    }

    // parity: PILL-017 PILL-018
    /// Starts 10 low, settles to 0; a hide goes back toward 10 on an ease-in, half way at 2.5.
    #[flow_ui::gpui::test]
    async fn show_rises_and_hide_drops_in_the_frame(cx: &mut TestAppContext) {
        panels(cx, false, false);
        cx.update(|cx| show_microphone("No microphone available", cx));
        let w = cx.add_window(|_, cx| PillView::new(cx));
        let y = |cx: &mut TestAppContext| {
            cx.update_window(w.into(), |_, win, cx| win.render_frame(cx)).unwrap();
            f32::from(bounds_of(cx, w, "pill.notice")[0].origin.y)
        };
        w.update(cx, |v, _, cx| {
            v.shown_at = Instant::now();
            cx.notify();
        }).unwrap();
        assert!(y(cx) > 5., "starts low");
        w.update(cx, |v, _, cx| {
            v.shown_at = Instant::now() - Duration::from_secs(1);
            cx.notify();
        }).unwrap();
        assert_eq!(y(cx), 0.);
        assert!((settle(0.5) - 0.5).abs() > 0.2, "the cubic is not linear");
        w.update(cx, |v, _, cx| {
            v.hide_since = Some(Instant::now() - Duration::from_millis(90));
            cx.notify();
        }).unwrap();
        let halfway = y(cx);
        assert!((2.5..4.5).contains(&halfway), "{halfway}");
    }

    // parity: PILL-079
    #[flow_ui::gpui::test]
    async fn clipboard_symbol_bounces_once_and_the_keycap_draws(cx: &mut TestAppContext) {
        assert_eq!((bounce(0.), bounce(0.2), bounce(0.4)), (0., 2.5, 0.));
        let (w, _, _) = wide(cx);
        cx.update(|cx| show_clipboard(false, cx));
        let at = |cx: &mut TestAppContext, ms: u64| {
            cx.update(|cx| update_session(cx, |s| s.pill.clipboard.as_mut().unwrap().shown = Instant::now() - Duration::from_millis(ms)));
            frame(cx, w);
            bounds_of(cx, w, "pill.notice.symbol")[0].origin.y
        };
        let up = at(cx, 200) - at(cx, 1000);
        assert!(up <= px(-2.), "{up:?}");
        let symbols = flow_ui::probe::symbols();
        assert!(symbols.iter().any(|s| s == "doc.on.clipboard") && symbols.iter().any(|s| s == "command"), "{symbols:?}");
        let v = flow_ui::probe::style_of("V").unwrap();
        assert_eq!((v.size, v.weight), (11., 600.));
    }

    // parity: PILL-005 PILL-006 PILL-017 PILL-033
    #[test]
    fn timing_and_waveform_math() {
        assert_eq!(spring(0., MORPH), 0.);
        assert!((spring(2., MORPH) - 1.).abs() < 0.001);
        assert!((spring(2., SWAP) - 1.).abs() < 0.001);
        // The bars and the swap read the constants; these literals are Swift's.
        assert_eq!(reveal(14, 0.014 + 0.42), spring(0.42, (0.42, 0.86)).clamp(0., 1.));
        assert_eq!(swap_style(0.2).0, spring(0.2, (0.34, 0.9)).clamp(0., 1.));
        assert!((settle(1.) - 1.).abs() < 0.01 && settle(0.).abs() < 0.01 && settle(0.3) > 0.7);
        assert_eq!((Waveform::height(0.), Waveform::height(0.2), Waveform::height(1.), Waveform::height(f32::NAN)), (3., 28., 28., 3.));
        let mut w = Waveform::default();
        w.advance(0., 0.1);
        w.advance(0.03, 0.2);
        w.advance(0.05, 0.05);
        assert_eq!(w.heights().len(), 16);
        assert_eq!(*w.heights().last().unwrap(), Waveform::height(0.2), "keeps the loudest");
        w.advance(0.15, 0.);
        let h = w.heights();
        // Two slices ended: the loud one, then silence for the gap.
        assert_eq!((h[13], h[14]), (Waveform::height(0.2), 3.));
        // History resets on entering recording, and only then.
        let mut p = Pill::default();
        p.set_state(DictState::Recording);
        p.waveform.borrow_mut().advance(0., 1.);
        p.set_state(DictState::Recording);
        assert_eq!(*p.waveform.borrow().heights().last().unwrap(), 28.);
        p.set_state(DictState::Transcribing);
        p.set_state(DictState::Recording);
        assert_eq!(*p.waveform.borrow().heights().last().unwrap(), 3.);
    }

    // parity: PILL-030 PILL-031
    /// Connecting pulses unless Reduce Motion: then bars rest at height 4, full opacity, in the frame too.
    #[flow_ui::gpui::test]
    async fn connecting_with_reduce_motion_is_static(cx: &mut TestAppContext) {
        assert_eq!(bar_target(3, DictState::Connecting, true, 1.2), (4., 1.));
        assert!((bar_target(3, DictState::Connecting, false, 1.2).1 - 0.35).abs() < 0.001);
        let (w, ..) = view(cx);
        cx.update(|cx| set_state(DictState::Connecting, 0., cx));
        frame(cx, w);
        let h = cx.update_window(w.into(), |_, win, _| win.find(("pill.bar", 5usize)).bounds().size.height).unwrap();
        assert_eq!(h, px(4.));
    }

    // parity: PILL-036 PILL-037 PILL-038 PILL-039 PILL-040 PILL-042 PILL-043
    #[test]
    fn bars_follow_swift_formulas() {
        // The crest in the states that share it, through what the frame draws.
        let crest_time = 1.2 * (7. + 3.) / 21.;
        for s in [DictState::Transcribing, DictState::Persisting, DictState::Inserting, DictState::Cancelling] {
            assert!((bar_target(7, s, false, crest_time).0 - 16.).abs() < 0.001, "{s:?}");
            assert_eq!(bar_target(3, s, true, crest_time).0, 14.);
        }
        // Delay `(15 - slot) * 0.014`: still nothing at the end of it.
        assert_eq!((reveal(14, 0.014), reveal(0, 0.21)), (0., 0.));
        assert_eq!(static_height(5, DictState::Preparing), 4.);
        assert!((connecting_opacity(0.4) - 1.).abs() < 0.001);
        assert!((connecting_opacity(1.2) - 0.35).abs() < 0.001);
        assert_eq!(static_height(6, DictState::Recording), 27. * 0.75);
        assert_eq!((static_height(3, DictState::Transcribing), static_height(4, DictState::Transcribing)), (14., 4.));
        assert_eq!(static_height(3, DictState::Rewriting), 14.);
        // Crest at bar 14 - crest: at phase where crest = 7, bar 7 is lifted to 16.
        let time = 1.2 * (7. + 3.) / 21.;
        assert!((processing_height(7, time) - 16.).abs() < 0.001);
        assert!(processing_height(0, time) < 4.01);
        let (h, o) = rewriting_wave(0, std::f64::consts::FRAC_PI_2 / 5.5);
        assert!((h - 17.).abs() < 0.001 && (0.45..=1.).contains(&o));
        // Right bars first.
        assert!(reveal(14, 0.1) > reveal(0, 0.1));
        assert_eq!((fade(0.), fade(0.28 * 87.)), (0., 1.));
    }

    // parity: PILL-053..PILL-063
    /// Through `set_state`, the path capture will call, into the platform's announce.
    #[flow_ui::gpui::test]
    async fn state_changes_announce_swifts_words(cx: &mut TestAppContext) {
        use DictState::*;
        let (_w, announced, _) = view(cx);
        let spoken = |state, cx: &mut TestAppContext| {
            announced.borrow_mut().clear();
            cx.update(|cx| set_state(state, 0., cx));
            announced.borrow().first().cloned().unwrap_or_default()
        };
        assert_eq!(spoken(Preparing, cx), "Preparing dictation. Microphone off.");
        assert_eq!(spoken(Connecting, cx), "Connecting to the microphone.");
        assert_eq!(spoken(Recording, cx), "Recording.");
        assert_eq!(spoken(Recording, cx), "", "the same state says nothing");
        assert_eq!(spoken(Transcribing, cx), "Transcribing. Microphone off.");
        assert_eq!(spoken(Persisting, cx), "Saving dictation.");
        assert_eq!(spoken(Rewriting, cx), "Rewriting text. Microphone off.");
        assert_eq!(spoken(Inserting, cx), "Inserting saved text.");
        assert_eq!(spoken(Cancelling, cx), "Cancelling dictation.");
        assert_eq!(spoken(Idle, cx), "Dictation cancelled.");
        assert_eq!(spoken(Recovery, cx), "Text saved for review.");
        assert_eq!(spoken(Failed, cx), "Dictation failed. Open LocalFlow for details.");
        assert_eq!(spoken(Idle, cx), "Dictation stopped.");
    }

    // parity: PILL-013 PILL-014
    #[test]
    fn panel_position() {
        let visible = Bounds { origin: point(px(0.), px(25.)), size: size(px(1440.), px(875.)) };
        assert_eq!(panel_origin(visible, 153., true), point(px(661.), px(842.)));
        assert_eq!(panel_origin(visible, 300., false), point(px(570.), px(842.)));
    }

    // parity: PILL-023 PILL-024 PILL-028 PILL-044 PILL-045 PILL-046 PILL-121
    #[flow_ui::gpui::test]
    async fn precedence_and_show_decision(cx: &mut TestAppContext) {
        let (_w, announced, _) = view(cx);
        let p = Pill::default();
        assert_eq!((p.content(), p.should_show(false)), (Content::None, false));
        for s in [DictState::Idle, DictState::Failed, DictState::Recovery] {
            cx.update(|cx| set_state(s, 0., cx));
            assert_eq!(pill(cx, |p| p.content()), Content::None);
        }
        assert!(announced.borrow().contains(&"Text saved for review.".to_string()));
        // Cancelled has no look of its own: idle, nothing shown, and it says so.
        cx.update(|cx| {
            set_state(DictState::Cancelling, 0., cx);
            set_state(DictState::Idle, 0., cx);
        });
        assert_eq!(pill(cx, |p| p.content()), Content::None);
        assert_eq!(announced.borrow().last().unwrap(), "Dictation cancelled.");
        cx.update(|cx| {
            set_background(Some(BackgroundNotice { meeting_id: "m".into(), kind: BackgroundKind::Labeling, progress: None }), cx);
            assert_eq!(cx.global::<Session>().pill.content(), Content::Background);
            // Hidden while the main window is focused or the preference is off.
            assert!(cx.global::<Session>().pill.should_show(false));
            assert!(!cx.global::<Session>().pill.should_show(true));
            assert!(!suppressed(cx));
            update_session(cx, |s| s.window_focused = true);
            assert!(suppressed(cx));
            update_session(cx, |s| s.window_focused = false);
            cx.global_mut::<Core>().prefs.set("showsBackgroundProgress", false);
            assert!(suppressed(cx));
            show_action("a", false, cx);
            assert_eq!(cx.global::<Session>().pill.content(), Content::Action);
            show_clipboard(false, cx);
            assert_eq!(cx.global::<Session>().pill.content(), Content::Clipboard);
            show_learned("w", LearnedKind::Added, cx);
            assert_eq!(cx.global::<Session>().pill.content(), Content::Learned);
            show_microphone("m", cx);
            assert_eq!(cx.global::<Session>().pill.content(), Content::Microphone);
            set_state(DictState::Recording, 0., cx);
            assert_eq!(cx.global::<Session>().pill.content(), Content::Dictation);
        });
    }

    // parity: PILL-027
    #[flow_ui::gpui::test]
    async fn meter_updates_skip_layout(cx: &mut TestAppContext) {
        let _ = view(cx);
        cx.update(|cx| set_state(DictState::Recording, 0.5, cx));
        let layouts = pill(cx, |p| p.layouts);
        cx.update(|cx| update_level(DictState::Recording, f32::NAN, cx));
        assert_eq!(pill(cx, |p| (p.layouts, p.level)), (layouts, 0.));
        cx.update(|cx| update_level(DictState::Recording, 9., cx));
        assert_eq!(pill(cx, |p| p.level), 1.);
        cx.update(|cx| update_level(DictState::Transcribing, 0., cx));
        assert_eq!(pill(cx, |p| p.layouts), layouts + 1);
    }

    // parity: PILL-029 PILL-030 PILL-037 PILL-038 PILL-039 PILL-040 PILL-050
    #[flow_ui::gpui::test]
    async fn dictation_labels_and_cancel(cx: &mut TestAppContext) {
        let (w, _, commands) = view(cx);
        for s in DICT {
            cx.update(|cx| set_state(s, 0.1, cx));
            frame(cx, w);
            cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("pill.cancel").label().as_deref(), Some(cancel_label(s)))).unwrap();
        }
        let spoken = |cx: &mut TestAppContext, s: DictState| {
            cx.update(|cx| set_state(s, 0.1, cx));
            frame(cx, w);
            cx.update_window(w.into(), |_, win, _| win.find("pill.dictation").label().map(str::to_string)).unwrap().unwrap()
        };
        assert_eq!(spoken(cx, DictState::Preparing), "Preparing, microphone off");
        assert_eq!(spoken(cx, DictState::Connecting), "Connecting to the microphone");
        assert_eq!(spoken(cx, DictState::Recording), "Recording");
        assert_eq!(spoken(cx, DictState::Transcribing), "Processing, microphone off");
        assert_eq!(spoken(cx, DictState::Persisting), "Processing, microphone off");
        assert_eq!(spoken(cx, DictState::Inserting), "Processing, microphone off");
        assert_eq!(spoken(cx, DictState::Cancelling), "Processing, microphone off");
        assert_eq!(spoken(cx, DictState::Rewriting), "Rewriting text, microphone off");
        assert_eq!(cancel_label(DictState::Rewriting), "Cancel rewrite");
        cx.update(|cx| {
            update_session(cx, |s| s.dictation.as_mut().unwrap().busy = true);
            set_state(DictState::Recording, 0., cx);
            update_session(cx, |s| s.dictation.as_mut().unwrap().state = DictState::Recording);
        });
        frame(cx, w);
        cx.update_window(w.into(), |_, win, cx| win.click("pill.cancel", cx)).unwrap();
        assert_eq!(*commands.borrow(), vec![SessionCommand::CancelDictation]);
        cx.update(|cx| update_session(cx, |s| s.dictation.as_mut().unwrap().state = DictState::Rewriting));
        frame(cx, w);
        cx.update_window(w.into(), |_, win, cx| win.click("pill.cancel", cx)).unwrap();
        assert_eq!(commands.borrow().last(), Some(&SessionCommand::CancelRewrite));
    }

    // parity: PILL-067 PILL-068 PILL-069 PILL-070 PILL-071 PILL-074
    #[flow_ui::gpui::test]
    async fn learned_notice_copy_actions_and_timer(cx: &mut TestAppContext) {
        let (w, announced, commands) = view(cx);
        cx.update(|cx| show_learned("LocalFlow", LearnedKind::Added, cx));
        frame(cx, w);
        assert_saw(&["Added to dictionary", "Undo"]);
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "sparkles"));
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("pill.notice").label().as_deref(), Some("Added LocalFlow to dictionary"))).unwrap();
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("dictionary.notice.undo").label().as_deref(), Some("Undo adding LocalFlow to dictionary"))).unwrap();
        assert_eq!(announced.borrow().last().unwrap(), "Added LocalFlow to dictionary.");
        cx.update_window(w.into(), |_, win, cx| win.click("dictionary.notice.undo", cx)).unwrap();
        assert_eq!(commands.borrow().last(), Some(&SessionCommand::UndoLearned));
        assert!(pill(cx, |p| p.learned.is_none()));

        cx.update(|cx| show_learned("flow", LearnedKind::Retired { alias: "flow".into() }, cx));
        frame(cx, w);
        assert_saw(&["Stopped listening for \u{2018}flow\u{2019}", "Restore"]);
        cx.update_window(w.into(), |_, win, _| {
            assert_eq!(win.find("pill.notice").label().as_deref(), Some("Stopped listening for \u{2018}flow\u{2019}"));
            assert_eq!(win.find("dictionary.notice.restore").label().as_deref(), Some("Restore flow"));
        }).unwrap();
        cx.update(|cx| show_learned("LocalFlow", LearnedKind::Retired { alias: "local flow".into() }, cx));
        frame(cx, w);
        assert_saw(&["Stopped changing \u{2018}local flow\u{2019} to \u{2018}LocalFlow\u{2019}"]);
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("pill.notice").label().as_deref(), Some("Stopped changing \u{2018}local flow\u{2019} to \u{2018}LocalFlow\u{2019}"))).unwrap();
        assert_eq!(announced.borrow().last().unwrap(), "Stopped changing local flow to LocalFlow. Restore is available.");
        cx.update_window(w.into(), |_, win, cx| win.click("dictionary.notice.restore", cx)).unwrap();
        assert_eq!(commands.borrow().last(), Some(&SessionCommand::RestoreLearned));

        cx.update(|cx| show_learned("x", LearnedKind::Added, cx));
        cx.executor().advance_clock(Duration::from_secs(5));
        cx.run_until_parked();
        assert!(pill(cx, |p| p.learned.is_some()));
        cx.executor().advance_clock(Duration::from_secs(2));
        cx.run_until_parked();
        assert!(pill(cx, |p| p.learned.is_none()));
        assert_eq!(remaining(3., 6., false), 0.5);
        assert_eq!(remaining(3., 6., true), 1.);
    }

    // parity: PILL-075 PILL-076 PILL-077 PILL-078
    #[flow_ui::gpui::test]
    async fn microphone_notice(cx: &mut TestAppContext) {
        let (w, announced, _) = view(cx);
        cx.update(|cx| show_microphone("No microphone available", cx));
        frame(cx, w);
        assert_saw(&["No microphone available", "Microphones…"]);
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "mic.slash"));
        assert_eq!(announced.borrow().last().unwrap(), "No microphone available");
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("dictation.notice.microphones").label().as_deref(), Some("Open Microphones settings"))).unwrap();
        cx.update(|cx| update_session(cx, |s| s.window = Some(w.into())));
        cx.update_window(w.into(), |_, win, cx| win.click("dictation.notice.microphones", cx)).unwrap();
        cx.update(|cx| {
            let s = cx.global::<Session>();
            assert!(s.pill.microphone.is_none() && s.microphones_anchor);
            assert_eq!(s.selection, Page::Settings);
        });
        cx.update(|cx| show_microphone("Studio didn't respond", cx));
        cx.executor().advance_clock(Duration::from_secs(9));
        cx.run_until_parked();
        assert!(pill(cx, |p| p.microphone.is_none()));
    }

    // parity: PILL-079 PILL-080 PILL-081 PILL-082 PILL-083
    #[flow_ui::gpui::test]
    async fn clipboard_notice(cx: &mut TestAppContext) {
        let (w, announced, _) = view(cx);
        cx.update(|cx| show_clipboard(true, cx));
        frame(cx, w);
        assert_saw(&["Copied to clipboard in case it's missing", "V"]);
        assert_eq!(announced.borrow().last().unwrap(), "Copied to clipboard in case it's missing. Paste with Command-V.");
        cx.update(|cx| show_clipboard(false, cx));
        frame(cx, w);
        assert_saw(&["Couldn't insert · copied to clipboard"]);
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("pill.notice").label().as_deref(), Some("Couldn't insert · copied to clipboard"))).unwrap();
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("clipboard.notice.dismiss").label().as_deref(), Some("Dismiss. Paste with Command-V"))).unwrap();
        cx.update_window(w.into(), |_, win, cx| win.click("clipboard.notice.dismiss", cx)).unwrap();
        assert!(pill(cx, |p| p.clipboard.is_none()));
        // Dismissing doesn't paste or touch the clipboard.
        assert!(cx.read_from_clipboard().is_none());
        cx.update(|cx| show_clipboard(false, cx));
        cx.executor().advance_clock(Duration::from_secs(7));
        cx.run_until_parked();
        assert!(pill(cx, |p| p.clipboard.is_none()));
    }

    // parity: PILL-084 PILL-085 PILL-087
    #[flow_ui::gpui::test]
    async fn action_notice_retry_chip_and_timer(cx: &mut TestAppContext) {
        let (w, announced, commands) = view(cx);
        cx.update(|cx| show_action("Rewrite took too long. Original text inserted.", false, cx));
        frame(cx, w);
        assert_eq!(announced.borrow().last().unwrap(), "Rewrite took too long. Original text inserted.");
        cx.update_window(w.into(), |_, win, _| assert!(win.try_find("rewrite.notice.retry").is_none())).unwrap();
        cx.update(|cx| show_action("Rewrite took too long. Original text inserted.", true, cx));
        frame(cx, w);
        assert_saw(&["Rewrite took too long. Original text inserted.", "Retry"]);
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "text.badge.xmark"));
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("rewrite.notice.retry.group").description().as_deref(), Some("Available here briefly. Retry is also in History."))).unwrap();
        cx.update_window(w.into(), |_, win, _| win.resize(size(px(1000.), px(100.)))).unwrap();
        cx.update(|cx| show_action("Rewrite took too long. ".repeat(40), true, cx));
        frame(cx, w);
        let long = bounds_of(cx, w, "pill.notice.message")[0].size.width;
        assert!(long <= px(420.) && long > px(400.), "{long:?}");
        cx.update(|cx| show_action("Rewrite took too long. Original text inserted.", true, cx));
        frame(cx, w);
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find("rewrite.notice.retry").label().as_deref(), Some("Retry rewrite"))).unwrap();
        cx.update_window(w.into(), |_, win, cx| win.click("rewrite.notice.retry", cx)).unwrap();
        assert_eq!(commands.borrow().last(), Some(&SessionCommand::RetryRewrite));
        assert!(pill(cx, |p| p.action.is_none()));
        // The window runs from first show, even when another notice covers it.
        cx.update(|cx| {
            show_action("Covered", true, cx);
            show_microphone("On top", cx);
        });
        cx.executor().advance_clock(Duration::from_secs(7));
        cx.run_until_parked();
        assert!(pill(cx, |p| p.action.is_none()));
    }

    // parity: PILL-088..PILL-095
    /// `RewriteNotice.text`'s live words: the bounded category text plus Swift's suffix. Whatever
    /// posts them (Feature 026) gets the wording from here; flowd only supplies the category.
    #[test]
    fn rewrite_failure_categories_map_to_the_live_words() {
        use flow_core::history::rewrite_notice;
        let suffix = " Original text inserted.";
        for (category, tail) in [("server_unreachable", suffix), ("transport_error", suffix), ("timeout", suffix), ("authentication_failed", ""), ("backend_unavailable", ""), ("malformed_response", ""), ("empty_response", ""), ("missing_credential", suffix)] {
            let live = format!("{}{tail}", rewrite_notice(category));
            assert!(REWRITE_NOTICES.iter().any(|(m, retry)| *m == live && *retry), "{live}");
        }
        assert!(REWRITE_NOTICES.iter().any(|(m, _)| *m == "Rewrite connection failed. Original text inserted."));
    }

    // Copy only: nothing posts these until Features 025 and 026, so the rows stay `recorded`.
    /// The words and whether Retry is offered. No production caller yet.
    #[test]
    fn rewrite_and_meeting_notices_keep_swifts_words() {
        let offers = |message: &str| REWRITE_NOTICES.iter().find(|(m, _)| *m == message).map(|(_, retry)| *retry);
        assert_eq!(offers("Rewriting skipped: unencrypted connection blocked. Original text inserted."), Some(true));
        assert_eq!(offers("Rewriting skipped: the endpoint is invalid. Original text inserted."), Some(true));
        assert_eq!(offers("Rewriting skipped: the text is too long. Original text inserted."), Some(true));
        assert_eq!(offers("Rewriting skipped: history is full. Original text inserted."), Some(true));
        assert_eq!(offers("This dictation already has ten rewrite attempts."), Some(false));
        assert_eq!(offers("Two rewrites are still running. Original text inserted."), Some(true));
        assert_eq!(offers("Rewrite was interrupted by a restart."), Some(true));
        assert_eq!(offers("Rewrite used on-screen text you did not say; inserted your transcript."), Some(true));
        assert_eq!(offers("Rewrite cancelled. Original text inserted."), Some(true));
        assert_eq!(offers("Previous dictation saved to history, not inserted."), Some(false));
        assert_eq!(offers("Meeting in progress"), Some(false));
        assert_eq!(offers("Meeting transcript is finalizing. Wait for it to finish."), Some(false));
        assert_eq!(offers("Server only is on, so this Mac doesn't run models. Change it in Settings › Server."), Some(false));
        assert_eq!(offers("This meeting can't be moved to this Mac right now."), Some(false));
    }

    // parity: PILL-112 PILL-113 PILL-114
    /// The capsule, the always laid out hide button, the hint and the hover spring.
    #[flow_ui::gpui::test]
    async fn background_capsule_and_hide_button(cx: &mut TestAppContext) {
        let (w, _, _) = wide(cx);
        cx.update(|cx| set_background(Some(BackgroundNotice { meeting_id: "m".into(), kind: BackgroundKind::Labeling, progress: None }), cx));
        frame(cx, w);
        let (whole, capsule, face) = (bounds_of(cx, w, "pill.background")[0], bounds_of(cx, w, "background.notice.capsule")[0], bounds_of(cx, w, "background.notice.hide.face")[0]);
        assert_eq!(capsule.origin.x - whole.origin.x, px(28.));
        assert_eq!(capsule.size.height, px(38.));
        assert_eq!(face.size.width, px(11.), "0.5 of 22 at rest");
        assert_eq!(face.origin.x + px(5.5) - capsule.right(), px(6. + 11.), "6 gap to the centre of a 22 slot");
        let style = flow_ui::probe::style_of("Labeling speakers").unwrap();
        assert_eq!((style.size, style.weight, style.color), (12., 500., style::ink()));
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "xmark"));
        assert!(pulse(0.) == 1. && (pulse(0.8) - 0.3).abs() < 0.001, "repeats from full to dim");
        cx.update_window(w.into(), |_, win, _| {
            assert_eq!(win.find("background.notice.group").description().as_deref(), Some("Opens LocalFlow"));
            assert_eq!(win.find("background.notice").label().as_deref(), Some("Labeling speakers"));
            assert_eq!(win.find("background.notice.hide").label().as_deref(), Some("Hide progress"));
        }).unwrap();
        // Hover: animated from rest, the button at 22 once settled.
        cx.update_window(w.into(), |_, win, cx| win.hover("pill.background", cx)).unwrap();
        assert!(w.update(cx, |v, _, _| v.hover_anim.is_some() && v.hover_mix() < 0.9).unwrap());
        w.update(cx, |v, _, cx| {
            v.hover_anim = Some((Instant::now() - Duration::from_secs(1), 0.));
            cx.notify();
        }).unwrap();
        frame(cx, w);
        assert_eq!(bounds_of(cx, w, "background.notice.hide.face")[0].size.width, px(22.));
        // Text is capped at 420 like the other notices.
        cx.update(|cx| set_background(Some(BackgroundNotice { meeting_id: "m".into(), kind: BackgroundKind::Summarizing { queued: 0 }, progress: None }), cx));
        frame(cx, w);
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "text.quote"));
    }

    // parity: PILL-112 PILL-113 PILL-115..PILL-120 PILL-122..PILL-125
    #[flow_ui::gpui::test]
    async fn background_notice(cx: &mut TestAppContext) {
        let (w, announced, _) = view(cx);
        let n = |kind, progress| Some(BackgroundNotice { meeting_id: "m1".into(), kind, progress });
        let shown = |kind, progress, cx: &mut TestAppContext| {
            cx.update(|cx| set_background(n(kind, progress), cx));
            frame(cx, w);
            let b = n(kind, progress).unwrap();
            assert_saw(&[&b.text()]);
            assert!(flow_ui::probe::symbols().iter().any(|s| s == b.symbol()), "{} not drawn", b.symbol());
            (b.text(), b.symbol(), b.tab())
        };
        assert_eq!(shown(BackgroundKind::Finalizing, None, cx), ("Finalizing transcript".to_string(), "text.badge.checkmark", "transcript"));
        assert_eq!(shown(BackgroundKind::Finalizing, Some(0.424), cx).0, "Finalizing transcript · 42 %");
        assert_eq!(shown(BackgroundKind::Resuming, None, cx), ("Resuming interrupted transcript".to_string(), "text.badge.checkmark", "transcript"));
        assert_eq!(shown(BackgroundKind::Labeling, None, cx), ("Labeling speakers".to_string(), "person.2", "transcript"));
        assert_eq!(shown(BackgroundKind::Summarizing { queued: 0 }, None, cx), ("Summarizing…".to_string(), "text.quote", "summary"));
        assert_eq!(shown(BackgroundKind::Summarizing { queued: 3 }, None, cx).0, "Summarizing… (3 queued)");
        // Hovering highlights the capsule and reveals the hide button.
        cx.update_window(w.into(), |_, win, cx| win.hover("pill.background", cx)).unwrap();
        assert!(w.update(cx, |v, _, _| v.hovering).unwrap());
        // Progress updates in one stage announce nothing new.
        cx.update(|cx| set_background(n(BackgroundKind::Finalizing, Some(0.1)), cx));
        let count = announced.borrow().len();
        cx.update(|cx| set_background(n(BackgroundKind::Finalizing, Some(0.2)), cx));
        assert_eq!(announced.borrow().len(), count);
        frame(cx, w);
        cx.update_window(w.into(), |_, win, cx| win.click("background.notice.hide", cx)).unwrap();
        assert_eq!(announced.borrow().last().unwrap(), "Progress hidden. It stays in LocalFlow.");
        assert!(!pill(cx, |p| p.should_show(false)));
        // Another stage of the same meeting stays hidden.
        cx.update(|cx| set_background(n(BackgroundKind::Labeling, None), cx));
        assert!(!pill(cx, |p| p.should_show(false)));
        // Ten seconds after work goes quiet, it can return.
        cx.update(|cx| set_background(None, cx));
        cx.executor().advance_clock(Duration::from_secs(11));
        cx.run_until_parked();
        cx.update(|cx| set_background(n(BackgroundKind::Labeling, None), cx));
        assert!(pill(cx, |p| p.should_show(false)));
        cx.update(|cx| update_session(cx, |s| s.window = Some(w.into())));
        frame(cx, w);
        cx.update_window(w.into(), |_, win, cx| win.click("background.notice", cx)).unwrap();
        cx.update(|cx| {
            let s = cx.global::<Session>();
            assert_eq!(s.selection, Page::Meetings);
            assert_eq!(s.open_meeting, Some(("m1".to_string(), Some("transcript"))));
        });
    }

    fn panel(cx: &TestAppContext) -> Option<AnyWindowHandle> {
        cx.update(|cx| cx.try_global::<PillWindow>().map(|w| w.handle))
    }

    fn panels(cx: &mut TestAppContext, reduce: bool, refuse: bool) -> Rc<RefCell<Vec<(f32, f32, [f32; 4])>>> {
        boot(cx, Mode::Dark);
        let calls: Rc<RefCell<Vec<(f32, f32, [f32; 4])>>> = Default::default();
        cx.update(|cx| {
            ensure_session(cx);
            cx.global_mut::<Flow>().reduce_motion = reduce;
            cx.global_mut::<Core>().services = Box::new(Fake { panel_frames: (!refuse).then(|| calls.clone()), ..Default::default() });
        });
        calls
    }

    // parity: PILL-019
    /// A new size animates the same panel over 0.32 s on Swift's cubic.
    #[flow_ui::gpui::test]
    async fn resize_animates_the_same_panel(cx: &mut TestAppContext) {
        let calls = panels(cx, false, false);
        cx.update(|cx| show_clipboard(false, cx));
        cx.update(sync_window);
        let first = panel(cx).expect("open");
        assert!(calls.borrow().is_empty(), "opening isn't a resize");
        cx.update(|cx| show_microphone("No microphone available", cx));
        cx.update(sync_window);
        assert_eq!(panel(cx), Some(first), "same panel");
        let call = calls.borrow().last().copied().expect("frame animated");
        assert_eq!((call.1, call.2), (0.32, [0.2, 0.9, 0.25, 1.]));
        assert_eq!(call.0, cx.update(|cx| content_width(cx)));
    }

    // parity: PILL-020
    /// Reduce Motion resizes at once, without the animator, and hides without a fade.
    #[flow_ui::gpui::test]
    async fn reduce_motion_resizes_and_hides_at_once(cx: &mut TestAppContext) {
        let calls = panels(cx, true, false);
        cx.update(|cx| show_clipboard(false, cx));
        cx.update(sync_window);
        let first = panel(cx).expect("open");
        cx.update(|cx| show_microphone("No microphone available", cx));
        cx.update(sync_window);
        assert!(calls.borrow().is_empty());
        assert_ne!(panel(cx), Some(first));
        let last = panel(cx).unwrap();
        cx.update(|cx| {
            update_session(cx, |s| s.pill = Pill::default());
            sync_window(cx);
        });
        cx.run_until_parked();
        assert!(panel(cx).is_none());
        assert!(cx.update(|cx| last.update(cx, |_, _, _| ()).is_err()), "gone without waiting for a fade");
    }

    // parity: PILL-019
    /// Where the platform refuses, a new window takes the new size.
    #[flow_ui::gpui::test]
    async fn unavailable_frames_reopen_the_panel(cx: &mut TestAppContext) {
        panels(cx, false, true);
        cx.update(|cx| show_clipboard(false, cx));
        cx.update(sync_window);
        let first = panel(cx).expect("open");
        cx.update(|cx| show_microphone("No microphone available", cx));
        cx.update(sync_window);
        assert_ne!(panel(cx), Some(first));
    }

    // parity: PILL-018 PILL-022
    /// Hiding starts the 0.18 s fade, stays on screen for it, then orders out.
    #[flow_ui::gpui::test]
    async fn hide_fades_then_closes(cx: &mut TestAppContext) {
        panels(cx, false, false);
        cx.update(|cx| show_microphone("No microphone available", cx));
        cx.update(sync_window);
        let handle = panel(cx).unwrap();
        let view = cx.update(|cx| cx.global::<PillWindow>().view.clone());
        cx.update(|cx| {
            update_session(cx, |s| s.pill = Pill::default());
            sync_window(cx);
        });
        assert!(cx.update(|cx| view.read(cx).hide_since.is_some()));
        assert_eq!(HIDE, 0.18);
        cx.executor().advance_clock(Duration::from_millis(100));
        assert!(cx.update(|cx| handle.update(cx, |_, _, _| ()).is_ok()), "still fading");
        cx.executor().advance_clock(Duration::from_millis(100));
        cx.run_until_parked();
        assert!(cx.update(|cx| handle.update(cx, |_, _, _| ()).is_err()), "ordered out");
        assert!(cx.update(|cx| !cx.has_global::<PillWindow>()), "nothing keeps the view or its callbacks");
    }

    // parity: PILL-025 PILL-026
    /// A swap restarts the fade and the 0.88 scale; Reduce Motion has neither.
    #[flow_ui::gpui::test]
    async fn content_swap_springs_in_and_reduce_motion_cuts(cx: &mut TestAppContext) {
        assert_eq!(swap_style(0.), (0., 0.88));
        assert!((swap_style(2.).0 - 1.).abs() < 0.001 && (swap_style(2.).1 - 1.).abs() < 0.001);
        let mid = swap_style(0.08);
        assert!(mid.0 > 0. && mid.0 < 1. && mid.1 > 0.88 && mid.1 < 1.);
        panels(cx, false, false);
        cx.update(|cx| show_clipboard(false, cx));
        let w = cx.add_window(|_, cx| PillView::new(cx));
        cx.update_window(w.into(), |_, w, cx| w.render_frame(cx)).unwrap();
        assert!(w.update(cx, |v, _, _| v.swap_since.is_none()).unwrap());
        cx.update(|cx| show_microphone("No microphone available", cx));
        w.update(cx, |_, _, cx| cx.notify()).unwrap();
        cx.update_window(w.into(), |_, w, cx| w.render_frame(cx)).unwrap();
        assert!(w.update(cx, |v, _, _| v.swap_since.is_some() && v.shown == Content::Microphone).unwrap());
        cx.update(|cx| cx.global_mut::<Flow>().reduce_motion = true);
        cx.update(|cx| update_session(cx, |s| s.pill.microphone = None));
        w.update(cx, |_, _, cx| cx.notify()).unwrap();
        cx.update_window(w.into(), |_, w, cx| w.render_frame(cx)).unwrap();
        assert!(w.update(cx, |v, _, _| v.swap_since.is_none() && v.shown == Content::Clipboard).unwrap());
    }
}
