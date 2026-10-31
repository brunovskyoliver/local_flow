//! Transcriptions page: search, waiting dictations, the day-grouped list and its row actions.
mod detail;

use super::dictionary::ui::{confirm_dialog, outline, overlay, sheet_card, under_card_border};
use crate::core::Core;
use crate::insertion::{Delivery, Quality, ReviewEntry, begin_review};
use crate::pages::Page;
use crate::shell::Session;
use flow_core::history::*;
use flow_ui::prelude::*;
use flow_ui::prelude::Context;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::{Duration, Instant};

pub struct HistoryPage {
    model: Model,
    searching: bool,
    search: Entity<InputState>,
    search_generation: u64,
    confirming_delete: bool,
    discarding: Option<String>,
    copied: HashSet<String>,
    stage: detail::Stage,
    open: HashSet<String>,
    scroll: ScrollHandle,
    tops: Rc<RefCell<HashMap<String, Pixels>>>,
    /// The row kept in place while pages join above it, and where it was.
    pin: Rc<RefCell<Option<(String, Pixels)>>>,
    focus: FocusHandle,
    checked_at: Option<Instant>,
    signature: Option<(i64, i64)>,
    /// Keyboard focus inside a row's actions keeps them visible.
    action_focus: RefCell<HashMap<String, FocusHandle>>,
    voice_over: bool,
    /// Rows first seen a moment ago; they fade in (`.transition(.opacity)`).
    seen: RefCell<HashMap<String, Instant>>,
    /// The first list has been drawn, so a new row is news.
    settled: bool,
    _subs: Vec<Subscription>,
}

pub(super) fn review_entry(e: &Entry, text: String) -> ReviewEntry {
    let quality = match e.quality.as_str() {
        "incomplete" => Quality::Incomplete,
        "duration_limited" => Quality::DurationLimited,
        _ => Quality::Complete,
    };
    let delivery = match e.delivery_state.as_str() {
        "attempting" => Delivery::Attempting,
        "uncertain" => Delivery::Uncertain,
        "confirmed" => Delivery::Confirmed,
        _ => Delivery::None,
    };
    ReviewEntry { id: e.id.clone(), text, quality, delivery }
}

impl HistoryPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search"));
        let mut shown = cx.try_global::<Session>().map(|s| s.selection);
        let mut insertion = cx.try_global::<Session>().map(|s| s.insertion.generation());
        let subs = vec![
            cx.subscribe_in(&search, window, |this, _, e: &TextInputEvent, window, cx| this.search_event(e, window, cx)),
            cx.observe_global::<Session>(move |this, cx| {
                // `refreshHistory`: an insertion that ended changed its row.
                let run = Some(cx.global::<Session>().insertion.generation());
                if run != insertion {
                    insertion = run;
                    if !cx.global::<Session>().insertion.is_active() {
                        this.reload(cx);
                    }
                }
                let now = Some(cx.global::<Session>().selection);
                if now == shown {
                    return;
                }
                if shown == Some(Page::History) {
                    this.model.clear_detail();
                } else if now == Some(Page::History) {
                    this.appear(cx);
                }
                shown = now;
                cx.notify();
            }),
        ];
        let mut page = HistoryPage {
            model: Model::default(),
            searching: false,
            search,
            search_generation: 0,
            confirming_delete: false,
            discarding: None,
            copied: HashSet::new(),
            stage: detail::Stage::Normalized,
            open: HashSet::new(),
            scroll: ScrollHandle::new(),
            tops: Default::default(),
            pin: Default::default(),
            focus: cx.focus_handle(),
            checked_at: None,
            signature: None,
            action_focus: Default::default(),
            voice_over: cx.global::<Core>().services.voice_over_on(),
            seen: Default::default(),
            settled: false,
            _subs: subs,
        };
        page.signature = cx.global::<Core>().db.as_ref().map(signature);
        page.reload(cx);
        page.apply_scenario(cx);
        page
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        match cx.global::<Core>().db.as_ref() {
            Some(db) => self.model.refresh(db),
            None => self.model.error = Some(READ_ERROR.into()),
        }
        cx.notify();
    }

    /// `.onAppear`: the newest page, an open detail retried, pending reloaded.
    fn appear(&mut self, cx: &mut Context<Self>) {
        self.voice_over = cx.global::<Core>().services.voice_over_on();
        self.signature = cx.global::<Core>().db.as_ref().map(signature);
        self.reload(cx);
    }

    fn apply_scenario(&mut self, cx: &mut Context<Self>) {
        let scenario = cx.global::<Core>().scenario.clone().unwrap_or_default();
        let first = self.model.entries.first().map(|e| e.id.clone());
        match scenario.strip_prefix("history.").unwrap_or("") {
            "empty" => {
                self.model.entries.clear();
                self.model.has_older = false;
            }
            "error" => {
                self.model.entries.clear();
                self.model.has_older = false;
                self.model.error = Some(READ_ERROR.into());
            }
            "pending" => {
                let core = cx.global::<Core>();
                if let Some(db) = core.db.as_ref() {
                    seed_pending(db, &core.paths.pending_audio());
                    self.model.refresh_pending(db);
                }
            }
            "detail" => {
                if let (Some(id), Some(db)) = (first, cx.global::<Core>().db.as_ref()) {
                    self.model.show_detail(db, &id);
                }
            }
            "detailError" => {
                self.model.detail_id = first;
                self.model.detail_error = Some(DETAIL_ERROR.into());
            }
            "delete" => {
                self.model.selected = self.model.entries.first().cloned();
                self.confirming_delete = true;
            }
            _ => {}
        }
    }

    fn search_event(&mut self, e: &TextInputEvent, window: &mut Window, cx: &mut Context<Self>) {
        match e {
            TextInputEvent::Change => {
                let text = self.search.read(cx).value().to_string();
                if !self.model.set_search(&text) {
                    let kept = self.model.search_text.clone();
                    self.search.update(cx, |s, cx| s.set_value(kept, window, cx));
                    cx.notify();
                    return;
                }
                self.search_generation += 1;
                let generation = self.search_generation;
                // ponytail: the 250 ms wait stands in for Swift's request debounce.
                cx.spawn(async move |this, cx| {
                    cx.background_executor().timer(Duration::from_millis(250)).await;
                    let _ = this.update(cx, |this, cx| {
                        if this.search_generation == generation {
                            this.reload(cx);
                        }
                    });
                })
                .detach();
            }
            TextInputEvent::Blur if self.model.search_text.is_empty() => {
                self.searching = false;
                cx.notify();
            }
            _ => {}
        }
    }

    fn open_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.searching = true;
        self.search.update(cx, |s, cx| s.focus(window, cx));
        cx.notify();
    }

    fn busy(&self, cx: &App) -> bool {
        cx.try_global::<Session>().is_some_and(|s| s.dictation.as_ref().is_some_and(|d| d.busy))
    }

    pub(super) fn copy(&mut self, text: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(text));
    }

    fn copy_row(&mut self, e: &Entry, cx: &mut Context<Self>) {
        self.copy(e.text.clone(), cx);
        let id = e.id.clone();
        self.copied.insert(id.clone());
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(1200)).await;
            let _ = this.update(cx, |this, cx| {
                this.copied.remove(&id);
                cx.notify();
            });
        })
        .detach();
    }

    /// `services.reviewInsertion`; a refusal is silent, as in Swift (HIST-181).
    pub(super) fn insert(&mut self, e: &Entry, text: String, cx: &mut Context<Self>) {
        if cx.has_global::<Session>() {
            begin_review(review_entry(e, text), cx);
        }
    }

    pub(super) fn show_detail(&mut self, id: &str, cx: &mut Context<Self>) {
        self.stage = detail::Stage::Normalized;
        self.open.clear();
        if let Some(db) = cx.global::<Core>().db.as_ref() {
            self.model.show_detail(db, id);
        }
        cx.notify();
    }

    fn ask_delete(&mut self, e: &Entry, cx: &mut Context<Self>) {
        self.model.selected = Some(e.clone());
        self.confirming_delete = true;
        cx.notify();
    }

    fn delete(&mut self, cx: &mut Context<Self>) {
        self.confirming_delete = false;
        if let Some(db) = cx.global::<Core>().db.as_ref() {
            if self.model.delete_selected(db) {
                self.model.refresh(db);
                self.signature = Some(signature(db));
            }
        }
        cx.notify();
    }

    /// Remembers the first row in view so a page joining above it doesn't move it.
    fn pin_first_visible(&self) {
        let tops = self.tops.borrow();
        let top = self.scroll.bounds().top();
        let first = self.model.entries.iter().find_map(|e| tops.get(&e.id).filter(|y| **y >= top).map(|y| (e.id.clone(), *y)));
        *self.pin.borrow_mut() = first;
    }

    fn sentinel(&self, older: bool, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let page = cx.entity().downgrade();
        let loading = self.model.is_loading;
        div()
            .id(if older { "history.sentinel.older" } else { "history.sentinel.newer" })
            .test_support()
            .w_full()
            .h(px(44.))
            .flex()
            .items_center()
            .justify_center()
            .when(loading, |d| d.child(Spinner::new()))
            .child(
                canvas(
                    move |b, window, cx| {
                        // ponytail: `.onAppear` as a bounds check each frame; loading is idempotent.
                        if b.bottom() >= px(0.) && b.top() <= window.viewport_size().height {
                            let page = page.clone();
                            cx.defer(move |cx| {
                                let _ = page.update(cx, |this, cx| this.load_page(older, cx));
                            });
                        }
                    },
                    |_, _, _, _| {},
                )
                .size(px(1.)),
            )
    }

    fn load_page(&mut self, older: bool, cx: &mut Context<Self>) {
        if self.model.is_loading || (older && !self.model.has_older) || (!older && !self.model.has_newer) {
            return;
        }
        self.pin_first_visible();
        if let Some(db) = cx.global::<Core>().db.as_ref() {
            if older {
                self.model.load_older(db);
            } else {
                self.model.load_newer(db);
            }
        }
        cx.notify();
    }

    fn header(&self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let compact = cx.global::<Flow>().compact;
        let right = if self.searching || !self.model.search_text.is_empty() {
            h_flex()
                .gap(px(6.))
                .h(px(32.))
                .px(px(10.))
                .bg(p.canvas)
                .rounded(px(8.))
                .text_size(px(14.))
                .child(icon("magnifyingglass", 14., p.muted))
                .child(div().w(px(if compact { 90. } else { 160. })).child(Input::new(&self.search).appearance(false).aria_label("Search transcriptions").accessibility_id("history.search")))
                .into_any_element()
        } else {
            FlowButton::new("history.searchToggle", ButtonKind::Plain, "Search transcriptions")
                .tooltip("Search")
                .content(div().size(px(32.)).flex().items_center().justify_center().child(icon("magnifyingglass", 17.5, p.muted)))
                .on_click(cx.listener(|this, _, w, cx| this.open_search(w, cx)))
                .into_any_element()
        };
        h_flex().w_full().justify_between().pb(px(12.)).child(t("Transcriptions").font(26., 500.).tracking(-0.4)).child(right)
    }

    fn pending(&self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let core = cx.global::<Core>();
        let now = now_ms();
        let mut rows = v_flex().relative().w_full();
        for item in &self.model.pending_items {
            let (id, id2) = (item.id.clone(), item.id.clone());
            let when = core.db.as_ref().map(|db| day_time(db, item.created_at)).unwrap_or_default();
            let local_ok = self.model.local_speech;
            rows = rows.child(
                h_flex()
                    .id(SharedString::from(format!("history.pendingRemote.{id}")))
                    .w_full()
                    .gap(px(12.))
                    .py(px(14.))
                    .px(px(18.))
                    .child(v_flex().flex_1().gap(px(4.)).child(t(when).size(13.).mono_digits().color(p.muted)).child(t(item.status(now)).size(14.)).child(t(item.length_label()).size(12.).color(p.muted)))
                    .child(
                        prototype_button(format!("history.pending.recognize.{id}"), "Recognize Locally")
                            .disabled(!local_ok)
                            .tooltip(if local_ok { "Recognize with the speech model on this Mac" } else { "Install the local speech model first" }),
                    )
                    .child(prototype_button(format!("history.pending.save.{id}"), "Save Audio…").on_click(cx.listener(move |this, _, _, cx| this.save_audio(id.clone(), cx))))
                    .child(prototype_button(format!("history.pending.discard.{id2}"), "Discard").on_click(cx.listener(move |this, _, _, cx| {
                        this.discarding = Some(id2.clone());
                        cx.notify();
                    }))),
            );
        }
        v_flex()
            .w_full()
            .child(div().pt(px(28.)).pb(px(12.)).child(t("WAITING FOR SERVER").font(12., 500.).tracking(1.2).color(p.muted)))
            .child(rows.child(outline(cx)))
            .when_some(self.model.pending_error.clone(), |d, e| d.child(div().pt(px(8.)).child(t(e).size(12.).color(p.warning))))
    }

    /// `NSSavePanel`, through `Services`; without one, the failure Swift would show.
    fn save_audio(&mut self, id: String, cx: &mut Context<Self>) {
        let core = cx.global::<Core>();
        let dir = core.paths.pending_audio();
        match core.services.choose_save_path("LocalFlow dictation.wav") {
            Ok(Some(path)) => {
                if let Some(db) = core.db.as_ref() {
                    self.model.export_pending(db, &dir, &id, &path);
                }
            }
            Ok(None) => {}
            Err(_) => self.model.report_pending_failure(),
        }
        cx.notify();
    }

    fn row(&self, e: &Entry, first: bool, last: bool, busy: bool, cx: &mut Context<Self>) -> AnyElement {
        let p = pal(cx);
        let compact = cx.global::<Flow>().compact;
        let core = cx.global::<Core>();
        let time = core.db.as_ref().map(|db| time_of(db, e.created_at)).unwrap_or_default();
        let path = e.path_label(self.model.local_speech);
        let group: SharedString = format!("history.row.{}", e.id).into();
        let insert_off = busy || e.is_attempting();
        let insert_label = if e.is_confirmed() { "Insert again" } else { "Insert" };
        let copied = self.copied.contains(&e.id);
        let tops = self.tops.clone();
        let pin = self.pin.clone();
        let scroll = self.scroll.clone();
        let key = e.id.clone();
        let action_focus = self.action_focus.borrow_mut().entry(e.id.clone()).or_insert_with(|| cx.focus_handle()).clone();

        let action = |id: String, symbol: &'static str, label: &str, tip: bool| {
            let b = FlowButton::new(SharedString::from(id), ButtonKind::Plain, label.to_string()).content(div().size(px(28.)).flex().items_center().justify_center().child(icon(symbol, 14., p.muted)));
            if tip { b.tooltip(label.to_string()) } else { b }
        };
        let (c, i, m) = (e.clone(), e.clone(), e.clone());
        let page = cx.entity().downgrade();
        let actions = h_flex()
            .gap(px(2.))
            .ml(px(16.))
            .mt(px(-4.))
            .child(action(format!("history.copy.{}", e.id), if copied { "checkmark" } else { "doc.on.doc" }, "Copy", true).on_click(cx.listener(move |this, _, _, cx| this.copy_row(&c, cx))))
            .child(action(format!("history.insert.{}", e.id), "text.insert", insert_label, true).disabled(insert_off).on_click(cx.listener(move |this, _, _, cx| this.insert(&i, i.text.clone(), cx))))
            .child(
                Button::new(SharedString::from(format!("history.more.{}", e.id)))
                    .ghost()
                    .p_0()
                    .h(px(28.))
                    .w(px(28.))
                    .accessibility_label("More")
                    .child(div().size(px(28.)).flex().items_center().justify_center().child(icon("ellipsis", 14., p.muted)))
                    .dropdown_menu({
                        let (page, m) = (page.clone(), m.clone());
                        move |menu, _, _| row_menu(menu, page.clone(), m.clone(), insert_off, busy)
                    }),
            );
        let row = div()
            .id(group.clone())
            .group(group.clone())
            .relative()
            .w_full()
            .flex()
            .items_start()
            .py(px(16.))
            .pl(px(18.))
            .pr(px(12.))
            .when(first, |d| d.rounded_tl(px(12.)).rounded_tr(px(12.)))
            .when(last, |d| d.rounded_bl(px(12.)).rounded_br(px(12.)))
            .hover(|s| s.bg(p.canvas))
            .child(
                v_flex()
                    .flex_none()
                    .w(px(if compact { 72. } else { 104. }))
                    .pt(px(2.))
                    // `Txt` rounds lines up; Swift's fractional lines keep the column shorter.
                    .gap(px(2.))
                    .child(t(time).size(13.).mono_digits().color(p.muted))
                    .when_some(e.quality_label(), |d, q| d.child(t(q).font(11., 500.).color(p.warning).no_widow()))
                    .when_some(path, |d, l| d.child(t(l).id("history.pathLabel").size(11.).color(p.muted).no_widow())),
            )
            .child(div().id(SharedString::from(format!("history.text.{}", e.id))).test_support().flex_1().min_w_0().child(t(e.text.clone()).size(15.).line_spacing(4.).selectable().no_widow()))
            .child(hover_or_focus_revealed(group, self.voice_over, &action_focus, actions))
            .when(!last, |d| d.child(div().absolute().bottom_0().left_0().right_0().h(px(1.)).bg(p.line)))
            .child(
                canvas(
                    move |b, window, _| {
                        tops.borrow_mut().insert(key.clone(), b.top());
                        let mut pin = pin.borrow_mut();
                        if pin.as_ref().is_some_and(|(id, _)| id == &key) {
                            if let Some((_, was)) = pin.take() {
                                let o = scroll.offset();
                                scroll.set_offset(point(o.x, o.y - (b.top() - was)));
                                window.refresh();
                            }
                        }
                    },
                    |_, _, _, _| {},
                )
                .absolute()
                .size(px(0.)),
            )
            .context_menu(move |menu, _, _| row_menu(menu, page.clone(), m.clone(), insert_off, busy));
        // ponytail: fades rows in only; a removed row leaves at once, Swift fades it out too.
        if self.fades(&e.id) {
            let id = SharedString::from(format!("history.fade.{}", e.id));
            row.with_animation(id, Animation::new(Duration::from_millis(200)).with_easing(ease_out_quint()), |d, delta| d.opacity(delta)).into_any_element()
        } else {
            row.into_any_element()
        }
    }

    /// A row is new when it arrives after the first list was drawn; it fades for the next 300 ms.
    fn fades(&self, id: &str) -> bool {
        const FADE: Duration = Duration::from_millis(300);
        let first_seen = *self.seen.borrow_mut().entry(id.to_string()).or_insert_with(|| if self.settled { Instant::now() } else { Instant::now() - FADE });
        first_seen.elapsed() < FADE
    }

    fn list(&self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let busy = self.busy(cx);
        let groups = cx.global::<Core>().db.as_ref().map(|db| self.model.date_groups(db, now_ms())).unwrap_or_default();
        let mut col = v_flex().w_full();
        if self.model.has_newer {
            col = col.child(self.sentinel(false, cx));
        }
        for g in &groups {
            col = col.child(div().pt(px(28.)).pb(px(11.)).child(t(g.title.to_uppercase()).font(12., 500.).tracking(1.2).color(p.muted)));
            let n = g.entries.len();
            let mut group = v_flex().relative().w_full();
            for (i, e) in g.entries.iter().enumerate() {
                group = group.child(self.row(e, i == 0, i + 1 == n, busy, cx));
            }
            col = col.child(group.child(outline(cx)));
        }
        if self.model.has_older {
            col = col.child(self.sentinel(true, cx));
        }
        col
    }
}

/// The row menu's insert label, and whether Insert and Delete are off.
fn row_menu_state(e: &Entry, insert_off: bool, busy: bool) -> (&'static str, bool, bool) {
    (if e.is_confirmed() { "Insert again…" } else { "Insert…" }, insert_off, busy || e.is_attempting())
}

fn row_menu(menu: PopupMenu, page: WeakEntity<HistoryPage>, e: Entry, insert_off: bool, busy: bool) -> PopupMenu {
    let (a, b, c, d) = (page.clone(), page.clone(), page.clone(), page);
    let (ea, eb, ec, ed) = (e.clone(), e.clone(), e.clone(), e.clone());
    let (insert, insert_off, delete_off) = row_menu_state(&e, insert_off, busy);
    menu.item(PopupMenuItem::new("Copy").on_click(move |_, _, cx| {
        a.update(cx, |this, cx| this.copy_row(&ea, cx)).ok();
    }))
    .item(PopupMenuItem::new(insert).disabled(insert_off).on_click(move |_, _, cx| {
        b.update(cx, |this, cx| this.insert(&eb, eb.text.clone(), cx)).ok();
    }))
    .item(PopupMenuItem::new("Details").on_click(move |_, _, cx| {
        c.update(cx, |this, cx| this.show_detail(&ec.id, cx)).ok();
    }))
    .separator()
    .item(PopupMenuItem::new("Delete").disabled(delete_off).on_click(move |_, _, cx| {
        d.update(cx, |this, cx| this.ask_delete(&ed, cx)).ok();
    }))
}

impl Render for HistoryPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // The shell keeps this page alive, so a change while away refreshes when it's next drawn.
        // ponytail: checked at most once a second, a "page shown" call is exact.
        let due = self.checked_at.is_none_or(|l| l.elapsed() > Duration::from_secs(1));
        if due && cx.global::<Core>().scenario.is_none() && self.model.detail_id.is_none() {
            self.checked_at = Some(Instant::now());
            let now = cx.global::<Core>().db.as_ref().map(signature);
            if now != self.signature {
                self.signature = now;
                self.reload(cx);
            }
        }
        if window.focused(cx).is_none() {
            self.focus.focus(window, cx);
        }
        let p = pal(cx);
        let mut content = v_flex().w_full().text_color(p.ink).text_size(px(14.)).child(self.header(cx));
        if let Some(e) = self.model.error.clone() {
            content = content.child(
                h_flex()
                    .pt(px(20.))
                    .gap(px(8.))
                    .child(t(e).color(p.warning).selectable())
                    .child(prototype_button("history.retry", "Retry").on_click(cx.listener(|this, _, _, cx| {
                        this.model.error = None;
                        this.reload(cx);
                    }))),
            );
        }
        if !self.model.pending_items.is_empty() {
            content = content.child(self.pending(cx));
        }
        if self.model.entries.is_empty() && !self.model.is_loading {
            content = content.child(div().w_full().py(px(80.)).flex().justify_center().child(t(if self.model.is_no_matches() { "No matches" } else { "No transcriptions yet" }).color(p.muted)));
        } else {
            content = content.child(div().id("history.list").w_full().child(self.list(cx)));
            self.settled = true;
        }
        let compact = cx.global::<Flow>().compact;
        let page = div()
            .id("history.page")
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .flex()
            .flex_col()
            .items_center()
            .child(div().w_full().max_w(px(960.)).flex_none().px(px(if compact { 24. } else { 48. })).pt(px(if compact { 32. } else { 48. })).pb(px(64.)).child(content));
        let detail = if self.model.detail_id.is_some() { Some(self.detail_sheet(cx)) } else { None };
        let confirm = if self.confirming_delete {
            Some(confirm_dialog(
                "history.deleteDialog",
                "Delete this transcription?",
                "This can't be undone.",
                "Delete",
                cx,
                cx.listener(|this, _, _, cx| this.delete(cx)),
                cx.listener(|this, _, _, cx| {
                    this.confirming_delete = false;
                    this.model.selected = None;
                    cx.notify();
                }),
            ))
        } else {
            None
        };
        let discard = if self.discarding.is_some() {
            Some(confirm_dialog(
                "history.discardDialog",
                "Discard this recording?",
                "Its audio is deleted and it will not be recognized.",
                "Discard",
                cx,
                cx.listener(|this, _, _, cx| {
                    if let Some(id) = this.discarding.take() {
                        let core = cx.global::<Core>();
                        let dir = core.paths.pending_audio();
                        if let Some(db) = core.db.as_ref() {
                            this.model.discard_pending(db, &dir, &id);
                        }
                    }
                    cx.notify();
                }),
                cx.listener(|this, _, _, cx| {
                    this.discarding = None;
                    cx.notify();
                }),
            ))
        } else {
            None
        };
        div()
            .relative()
            .size_full()
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this, e: &KeyDownEvent, w, cx| {
                let k = &e.keystroke;
                if k.key == "f" && k.modifiers.platform {
                    this.open_search(w, cx);
                } else if k.key == "tab" {
                    // ponytail: no Kit `Root` in this shell, so no window-wide Tab; each page with row actions binds it.
                    if k.modifiers.shift { w.focus_prev(cx) } else { w.focus_next(cx) }
                } else if k.key == "escape" {
                    if this.model.detail_id.is_some() {
                        this.model.clear_detail();
                    } else if this.searching {
                        this.search.update(cx, |s, cx| s.set_value("", w, cx));
                        this.searching = false;
                    }
                    cx.notify();
                }
            }))
            .child(under_card_border(page))
            .when_some(detail, |d, s| d.child(overlay("history.detailOverlay", window, cx, s)))
            .when_some(confirm, |d, c| d.child(overlay("history.deleteOverlay", window, cx, c)))
            .when_some(discard, |d, c| d.child(overlay("history.discardOverlay", window, cx, c)))
    }
}

/// Used by the sheet module; keeps `sheet_card` in one import path.
pub(self) fn detail_card(cx: &App) -> Div {
    sheet_card(600., cx)
}

#[cfg(test)]
mod tests;
