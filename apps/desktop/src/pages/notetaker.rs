//! The Notetaker page: `MeetingLibraryView` and everything it opens. Capture, ASR, diarization,
//! identification and summary generation stay in the Mac workers (`Services::meeting_worker`); the
//! views read what those workers stored and write what the user changes.
mod active;
mod detail;
mod library;
mod speakers;
mod summary;
#[cfg(test)]
mod tests;
mod transcript;

use crate::core::Core;
use flow_core::db::Db;
use flow_core::meetings::*;
use flow_ui::prelude::*;
use std::collections::HashSet;

pub(crate) use active::LiveStatus;
use speakers::AssignState;
use summary::SummaryState;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tab {
    Thoughts,
    Transcript,
    Summary,
}

pub(crate) enum Confirm {
    DeleteRow(String, i64),
    DeleteOpen,
    RemoveEdits,
}

/// (state, failure, progress percent) of a speaker run: stored, or injected by a scenario.
#[derive(Clone, Default)]
pub(crate) struct RunLine {
    pub state: String,
    pub failure: Option<String>,
    pub percent: i64,
}

pub struct NotetakerPage {
    pub(crate) lib: Library,
    pub(crate) query: Entity<InputState>,
    pub(crate) show_search: bool,
    pub(crate) transcribe: bool,
    pub(crate) menu: Option<String>,
    pub(crate) confirm: Option<Confirm>,
    pub(crate) status: Option<LiveStatus>,
    pub(crate) live_section: Option<String>,
    pub(crate) active_title: Entity<InputState>,
    pub(crate) active_title_notice: Option<String>,
    pub(crate) refusal: Option<String>,
    pub(crate) waiting: HashSet<String>,
    pub(crate) can_start: bool,
    pub(crate) preview_epoch: u64,
    // Open note.
    pub(crate) tab: Tab,
    pub(crate) title: Entity<InputState>,
    pub(crate) thoughts: Entity<TextareaState>,
    pub(crate) editor: Option<NotesEditor>,
    pub(crate) save_epoch: u64,
    pub(crate) force_pending: bool,
    pub(crate) leaving: bool,
    pub(crate) provenance: Option<String>,
    pub(crate) playing: bool,
    pub(crate) play_notice: Option<String>,
    // Transcript.
    pub(crate) pager: Option<Pager>,
    pub(crate) search_open: bool,
    pub(crate) search: Entity<InputState>,
    pub(crate) search_epoch: u64,
    pub(crate) transcript_notice: Option<String>,
    pub(crate) scroll: ScrollHandle,
    pub(crate) section_scroll: ScrollHandle,
    pub(crate) speaker_run: Option<RunLine>,
    pub(crate) identify_run: Option<RunLine>,
    pub(crate) past_search: Option<(String, i64)>,
    pub(crate) past_prompt: Option<(String, i64)>,
    pub(crate) enrolling: bool,
    // Sheets and tabs with their own state.
    pub(crate) assign: Option<AssignState>,
    pub(crate) summary: SummaryState,
    _subs: Vec<Subscription>,
}

pub(crate) fn db_of(cx: &App) -> Option<&Db> {
    cx.global::<Core>().db.as_ref()
}
pub(crate) fn offset_at(ms: i64, cx: &App) -> i32 {
    db_of(cx).map_or(0, |db| local_offset(db, ms))
}
/// AppKit's system colors in light and dark.
pub(crate) fn sys(cx: &App, light: u32, dark: u32) -> Hsla {
    rgb(if pal(cx).mode.is_dark() { dark } else { light }).into()
}
pub(crate) fn red(cx: &App) -> Hsla {
    sys(cx, 0xFF3B30, 0xFF453A)
}
pub(crate) fn orange(cx: &App) -> Hsla {
    sys(cx, 0xFF9500, 0xFF9F0A)
}
pub(crate) fn green(cx: &App) -> Hsla {
    sys(cx, 0x34C759, 0x30D158)
}
pub(crate) fn purple(cx: &App) -> Hsla {
    sys(cx, 0xAF52DE, 0xBF5AF2)
}
const SPEAKER_DOTS: [(u32, u32); 8] = [(0x1F6FD1, 0x5AA2FF), (0xC2570C, 0xFF9A4D), (0x1E8A4C, 0x4CC983), (0x7B4BD1, 0xA98BFF), (0x0E7C86, 0x3CC6CF), (0xC23B3B, 0xFF7373), (0xB8397D, 0xF07AB8), (0x8A6A1F, 0xD4B25A)];
const SPEAKER_TEXT: [(u32, u32); 8] = [(0x1D66C0, 0x5AA2FF), (0xA84B0A, 0xFF9A4D), (0x187441, 0x4CC983), (0x7B4BD1, 0xA98BFF), (0x0C717A, 0x3CC6CF), (0xB23636, 0xFF7373), (0xA8346F, 0xF07AB8), (0x7E611C, 0xD4B25A)];
pub(crate) fn speaker_dot(i: usize, cx: &App) -> Hsla {
    let (l, d) = SPEAKER_DOTS[i % 8];
    sys(cx, l, d)
}
pub(crate) fn speaker_text(i: usize, cx: &App) -> Hsla {
    let (l, d) = SPEAKER_TEXT[i % 8];
    sys(cx, l, d)
}
/// A sheet dims the whole window. The page sits 220 + 45 in from its top left and 9 from the rest.
// ponytail: fixed to the shell's page inset; a window-level overlay if the shell ever gets one.
pub(crate) fn window_backdrop(id: &'static str) -> Stateful<Div> {
    div().id(id).absolute().top(px(-45.)).left(px(-217.)).right(px(-9.)).bottom(px(-9.)).rounded(px(12.))
}
pub(crate) fn sid(text: impl Into<String>) -> SharedString {
    SharedString::from(text.into())
}

type Click = Box<dyn Fn(&ClickEvent, &mut Window, &mut App) + 'static>;

/// `NoteIconButton`: a 13 symbol in a 28 square with a tooltip.
pub(crate) fn note_icon(id: impl Into<ElementId>, symbol: &'static str, label: &str, color: Hsla) -> FlowButton {
    plain_button(id, sid(label)).tooltip(sid(label)).content(div().size(px(28.)).flex().items_center().justify_center().child(icon(symbol, 15., color)))
}
/// The trigger of a native `Menu`: a borderless symbol in a square.
pub(crate) fn menu_trigger(id: impl Into<ElementId>, label: &'static str, symbol: &'static str, size: f32, frame: f32, color: Hsla) -> Button {
    Button::new(id).ghost().p_0().h(px(frame)).w(px(frame)).accessibility_label(label).child(div().size(px(frame)).flex().items_center().justify_center().child(icon(symbol, size, color)))
}
/// A menu item's click, delivered to the page.
pub(crate) fn act(page: &WeakEntity<NotetakerPage>, f: impl Fn(&mut NotetakerPage, &mut Window, &mut Context<NotetakerPage>) + 'static) -> impl Fn(&ClickEvent, &mut Window, &mut App) + 'static {
    let page = page.clone();
    move |_, window, cx| {
        page.update(cx, |this, cx| f(this, window, cx)).ok();
    }
}
/// `NoteTab`.
pub(crate) fn note_tab(id: impl Into<ElementId>, title: &'static str, selected: bool, cx: &App) -> FlowButton {
    let p = pal(cx);
    plain_button(id, title).a11y_selected(selected).content(
        div()
            .py(px(12.))
            .relative()
            .child(t(title).font(15., if selected { 500. } else { 400. }).color(if selected { p.ink } else { p.muted }).a11y_hidden())
            .when(selected, |d| d.child(div().absolute().bottom_0().left_0().right_0().h(px(2.)).bg(p.ink))),
    )
}
/// A popover hung under its anchor. `.menu` holds the open one, so opening another closes this.
pub(crate) fn popover_panel(width: f32, top: f32, cx: &Context<NotetakerPage>, content: impl IntoElement) -> impl IntoElement {
    let p = pal(cx);
    deferred(
        div()
            .id("notetaker.popover")
            .test_support()
            .absolute()
            .top(px(top))
            .right_0()
            .w(px(width))
            .bg(p.surface)
            .border_1()
            .border_color(p.line)
            .rounded(px(10.))
            .shadow_md()
            .occlude()
            .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                this.menu = None;
                cx.notify();
            }))
            .child(content),
    )
    .with_priority(2)
}
/// The overflow popover's row.
pub(crate) fn menu_row(id: impl Into<ElementId>, title: impl Into<SharedString>, symbol: Option<&'static str>, color: Hsla, on: Click) -> FlowButton {
    let title: SharedString = title.into();
    plain_button(id, title.clone()).full_width().on_click(on).content(
        h_flex()
            .w_full()
            .gap(px(6.))
            .px(px(10.))
            .py(px(9.))
            .when_some(symbol, |d, s| d.child(icon(s, 14., color)))
            .child(t(title).size(14.).color(color).a11y_hidden()),
    )
}

impl NotetakerPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let query = cx.new(|cx| InputState::new(window, cx).placeholder("Search"));
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search"));
        let title = cx.new(|cx| InputState::new(window, cx).placeholder("Untitled"));
        let active_title = cx.new(|cx| InputState::new(window, cx).placeholder("Title (optional)"));
        let thoughts = cx.new(|cx| TextareaState::new(window, cx));
        let subs = vec![
            // `onDisappear`: leaving the page lets go of the open note and the preview.
            cx.observe_global_in::<crate::shell::Session>(window, |this, window, cx| {
                if cx.global::<crate::shell::Session>().selection != crate::pages::Page::Meetings && (this.lib.detail.is_some() || this.lib.preview_id.is_some()) {
                    this.preview_epoch += 1;
                    this.lib.release_detail();
                    this.close_note_state(window, cx);
                    cx.notify();
                }
            }),
            cx.subscribe_in(&active_title, window, |this, _, e: &TextInputEvent, _, cx| {
                if matches!(e, TextInputEvent::PressEnter { .. }) {
                    this.save_active_title(cx);
                }
            }),
            cx.subscribe_in(&query, window, |_, _, e: &TextInputEvent, _, cx| {
                if matches!(e, TextInputEvent::Change) {
                    cx.notify();
                }
            }),
            cx.subscribe_in(&search, window, |this, input, e: &TextInputEvent, _, cx| match e {
                TextInputEvent::Change => this.search_changed(cx),
                TextInputEvent::Blur if input.read(cx).value().is_empty() => {
                    this.search_open = false;
                    cx.notify();
                }
                _ => {}
            }),
            cx.subscribe_in(&title, window, |this, _, e: &TextInputEvent, window, cx| {
                if matches!(e, TextInputEvent::Blur | TextInputEvent::PressEnter { .. }) {
                    this.save_title(window, cx);
                }
            }),
            cx.subscribe_in(&thoughts, window, |this, input, e: &TextInputEvent, window, cx| {
                if matches!(e, TextInputEvent::Change) {
                    let value = input.read(cx).value().to_string();
                    this.thoughts_changed(&value, input.clone(), window, cx);
                }
            }),
        ];
        let core = cx.global::<Core>();
        let transcribe = core.prefs.bool_or("meetingTranscriptionEnabled", true);
        let mut page = NotetakerPage {
            lib: Library::default(),
            query,
            show_search: false,
            transcribe,
            menu: None,
            confirm: None,
            status: None,
            live_section: None,
            active_title,
            active_title_notice: None,
            refusal: None,
            waiting: HashSet::new(),
            can_start: true,
            preview_epoch: 0,
            tab: Tab::Thoughts,
            title,
            thoughts,
            editor: None,
            save_epoch: 0,
            force_pending: false,
            leaving: false,
            provenance: None,
            playing: false,
            play_notice: None,
            pager: None,
            search_open: false,
            search,
            search_epoch: 0,
            transcript_notice: None,
            scroll: ScrollHandle::new(),
            section_scroll: ScrollHandle::new(),
            speaker_run: None,
            identify_run: None,
            past_search: None,
            past_prompt: None,
            enrolling: false,
            assign: None,
            summary: SummaryState::new(window, cx),
            _subs: subs,
        };
        page.refresh(cx);
        if let Some(name) = cx.global::<Core>().scenario.clone().and_then(|s| s.strip_prefix("notetaker.").map(String::from)) {
            page.apply_scenario(&name, window, cx);
        }
        page
    }

    pub(crate) fn active_id(&self) -> Option<String> {
        self.status.as_ref().filter(|s| !is_terminal(&s.state)).map(|s| s.id.clone())
    }
    pub(crate) fn refresh(&mut self, cx: &mut Context<Self>) {
        let active = self.active_id();
        if let Some(db) = db_of(cx) {
            self.lib.refresh(db, active.as_deref());
        } else {
            self.lib.notice = Some("Meetings could not be loaded. Check app storage.".into());
        }
        cx.notify();
    }
    /// What a Mac-only action does here: the worker says it can't, and the view shows that.
    pub(crate) fn worker(what: &'static str, cx: &App) -> Result<(), String> {
        cx.global::<Core>().services.meeting_worker(what).map_err(|u| format!("{} isn't available in this version yet.", u.0))
    }
    pub(crate) fn meetings_root(cx: &App) -> std::path::PathBuf {
        cx.global::<Core>().paths.root.join("Meetings")
    }
    /// Audit states fixture rows can't reach.
    fn apply_scenario(&mut self, name: &str, window: &mut Window, cx: &mut Context<Self>) {
        let open = |this: &mut Self, id: &str, tab: Tab, window: &mut Window, cx: &mut Context<Self>| {
            this.open_note(id, tab, window, cx);
        };
        match name {
            "empty" => {
                self.lib.rows.clear();
                self.lib.has_older = false;
            }
            "notice" => self.lib.notice = Some("Meetings could not be loaded. Check app storage.".into()),
            "evicted" => self.lib.evicted_newest = true,
            "search" => self.show_search = true,
            "waiting" => {
                self.waiting.insert(SEED_IPHONE.into());
            }
            "waiting-detail" => {
                self.waiting.insert(SEED_IPHONE.into());
                open(self, SEED_IPHONE, Tab::Thoughts, window, cx);
            }
            "refusal" => self.refusal = Some("Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone.".into()),
            // `section:<transcript state>[:<live health>[:<failure>]]`, or `panel` for the recording panel beside a refusal.
            s if s.starts_with("section:") => {
                let mut parts = s["section:".len()..].splitn(3, ':');
                let (state, live, failure) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next());
                self.status = Some(LiveStatus::scenario("live"));
                self.status.as_mut().unwrap().state = "interrupted".into();
                self.live_section = Some(section_status_text(state, live, failure, 0.0));
                self.refresh(cx);
            }
            "panel" => {
                self.status = Some(LiveStatus::scenario("recording"));
                self.refusal = Some("Meeting is busy".into());
                self.editor = Some(NotesEditor::new(SEED_UNTITLED, "", 0));
                self.refresh(cx);
            }
            "recording" | "paused" | "finalizing" | "preparing" | "interrupted-card" | "failed-card" | "notice-card" => {
                self.status = Some(LiveStatus::scenario(name));
                self.can_start = false;
                self.refresh(cx);
            }
            "live" | "live-paused" | "live-off" | "live-listening" => {
                self.status = Some(LiveStatus::scenario(name));
                self.can_start = false;
                self.refresh(cx);
                open(self, SEED_UNTITLED, Tab::Transcript, window, cx);
            }
            "detail" => open(self, SEED_FULL, Tab::Thoughts, window, cx),
            "transcript" => open(self, SEED_FULL, Tab::Transcript, window, cx),
            "summary" => open(self, SEED_FULL, Tab::Summary, window, cx),
            "untitled" => open(self, SEED_UNTITLED, Tab::Thoughts, window, cx),
            "interrupted" => open(self, SEED_INTERRUPTED, Tab::Transcript, window, cx),
            "iphone" => open(self, SEED_IPHONE, Tab::Transcript, window, cx),
            "iphone-summary" => open(self, SEED_IPHONE, Tab::Summary, window, cx),
            "off-summary" => open(self, SEED_UNTITLED, Tab::Summary, window, cx),
            "failed" => open(self, SEED_FAILED, Tab::Transcript, window, cx),
            "delete" => {
                open(self, SEED_FULL, Tab::Thoughts, window, cx);
                self.confirm = Some(Confirm::DeleteOpen);
            }
            "delete-row" => self.confirm = Some(Confirm::DeleteRow(SEED_FULL.into(), 0)),
            "labeling" | "labeling-update" | "label-waiting" | "label-failed" | "identifying" | "identify-waiting" | "identify-failed" | "past-search" | "past-prompt" | "enrolling" => {
                open(self, SEED_FULL, Tab::Transcript, window, cx);
                let run = |state: &str, failure: Option<&str>, percent| Some(RunLine { state: state.into(), failure: failure.map(String::from), percent });
                match name {
                    "labeling" => {
                        if let Some(p) = &mut self.pager {
                            p.speakers = None;
                        }
                        self.speaker_run = run("running", None, 40);
                    }
                    "labeling-update" => self.speaker_run = run("running", None, 40),
                    "label-waiting" => {
                        if let Some(p) = &mut self.pager {
                            p.speakers = None;
                        }
                        self.speaker_run = run("pending", None, 0);
                    }
                    "label-failed" => self.speaker_run = run("failed", Some("audio_missing"), 0),
                    "identifying" => self.identify_run = run("running", None, 25),
                    "identify-waiting" => self.identify_run = run("pending", None, 0),
                    "identify-failed" => self.identify_run = run("failed", Some("model_load_failure"), 0),
                    "past-search" => self.past_search = Some(("Tomas Novak".into(), 12)),
                    "past-prompt" => self.past_prompt = Some(("Tomas Novak".into(), 3)),
                    _ => self.enrolling = true,
                }
            }
            "assign" => {
                open(self, SEED_FULL, Tab::Transcript, window, cx);
                self.open_assign(None, window, cx);
            }
            s if s.starts_with("summary-") => {
                open(self, SEED_FULL, Tab::Summary, window, cx);
                self.summary.apply_scenario(&s["summary-".len()..]);
            }
            _ => {}
        }
    }
}

impl Render for NotetakerPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // Only take when set: `update_session` notifies observers, which re-render this page.
        if cx.has_global::<crate::shell::Session>() && cx.global::<crate::shell::Session>().open_meeting.is_some() {
            if let Some((id, tab)) = crate::shell::update_session(cx, |s| s.open_meeting.take()) {
                let tab = match tab {
                    Some("transcript") => Tab::Transcript,
                    Some("summary") => Tab::Summary,
                    _ => Tab::Thoughts,
                };
                self.open_note(&id, tab, window, cx);
            }
        }
        let p = pal(cx);
        let body = if self.lib.detail.is_some() { self.detail_view(window, cx).into_any_element() } else { self.library_view(window, cx).into_any_element() };
        div()
            .relative()
            .size_full()
            .text_color(p.ink)
            .text_size(px(13.))
            .child(body)
            .when(self.assign.is_some(), |d| d.child(self.assign_sheet(window, cx)))
            .when(self.confirm.is_some(), |d| d.child(self.confirm_dialog(cx)))
    }
}

impl NotetakerPage {
    fn confirm_dialog(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let offset_title = self.lib.detail.as_ref().map(|d| d.meeting.display_title(offset_at(d.meeting.created_at, cx)));
        let (title, message, action): (String, &str, &str) = match self.confirm {
            Some(Confirm::DeleteRow(..)) => ("Delete this note?".into(), "This removes the recording, transcript and thoughts from this Mac.", "Delete note"),
            Some(Confirm::DeleteOpen) => (format!("Delete \"{}\"?", offset_title.unwrap_or_default()), "This removes the meeting's audio files and notes from this Mac. Other meetings are kept.", "Delete meeting"),
            _ => ("Remove all edits?".into(), "Your changes to the summary, owners, due dates and items are deleted, and the generated text comes back. This can't be undone.", "Remove All Edits"),
        };
        let action_id: SharedString = if matches!(self.confirm, Some(Confirm::RemoveEdits)) { "meeting.summary.removeEdits.confirm".into() } else { "notetaker.delete.confirm".into() };
        deferred(
            window_backdrop("notetaker.confirm").flex().items_center().justify_center().bg(gpui::black().opacity(0.2)).occlude().child(
                v_flex()
                    .w(px(280.))
                    .p(px(20.))
                    .gap(px(10.))
                    .bg(p.surface)
                    .rounded(px(14.))
                    .shadow_lg()
                    .items_center()
                    .child(t(title).font(13., 700.).center())
                    .child(t(message).size(11.).center())
                    .child(v_flex().w_full().gap(px(6.)).pt(px(6.)).child(prototype_button(action_id, action).full_width().text_color(red(cx)).on_click(cx.listener(|this, _, w, cx| this.confirmed(w, cx)))).child(prototype_button("notetaker.delete.cancel", "Cancel").full_width().on_click(cx.listener(|this, _, _, cx| {
                        this.confirm = None;
                        cx.notify();
                    })))),
            ),
        )
        .with_priority(3)
    }
    fn confirmed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.confirm.take() {
            Some(Confirm::DeleteRow(id, revision)) => self.delete(&id, revision, window, cx),
            Some(Confirm::DeleteOpen) => {
                if let Some(m) = self.lib.detail.as_ref().map(|d| (d.meeting.id.clone(), d.meeting.revision)) {
                    self.playing = false;
                    self.delete(&m.0, m.1, window, cx);
                }
            }
            Some(Confirm::RemoveEdits) => self.remove_all_edits(cx),
            None => {}
        }
        cx.notify();
    }
    pub(crate) fn delete(&mut self, id: &str, revision: i64, window: &mut Window, cx: &mut Context<Self>) {
        let active = self.active_id();
        let root = Self::meetings_root(cx);
        if let Some(db) = db_of(cx) {
            self.lib.delete(db, &root, id, revision, active.as_deref());
        }
        if self.lib.detail.is_none() {
            self.close_note_state(window, cx);
        }
        cx.notify();
    }
}

