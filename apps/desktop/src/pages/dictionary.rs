//! Dictionary page: title, filter tabs, intro banner, entries and the "Add to vocabulary" sheet.
pub mod ui;

use crate::core::Core;
use crate::pages::Page;
use crate::shell::Session;
use flow_core::dictionary::{Entry, Field, Filter, MAX_ENTRIES, Model, RetiredTerm, Source, Suggestion};
use flow_ui::prelude::*;
use ui::{confirm_dialog, destructive_item, help, outline, pill, sheet_card, under_card_border};

// ponytail: no spell checker service yet, so no common word is held back from suggestions
// (`NSSpellChecker`); the filter takes effect when Feature 025 adds it to `Services`.
fn is_english(_: &str) -> bool {
    false
}

pub struct DictionaryPage {
    model: Model,
    filter: Filter,
    searching: bool,
    search: Entity<InputState>,
    confirming_delete: Option<Entry>,
    /// The sheet's fields: the canonical word, then one per misspelling.
    canonical: Option<Entity<InputState>>,
    aliases: Vec<Entity<InputState>>,
    field_subs: Vec<Subscription>,
    focus: FocusHandle,
    action_focus: std::cell::RefCell<std::collections::HashMap<usize, FocusHandle>>,
    voice_over: bool,
    _search_sub: Subscription,
    _session_sub: Subscription,
}

impl DictionaryPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search"));
        let _search_sub = cx.subscribe(&search, |_, _, _: &TextInputEvent, cx| cx.notify());
        let mut shown = cx.try_global::<Session>().map(|s| s.selection);
        let mut revision = cx.try_global::<Session>().map_or(0, |s| s.history_revision);
        let _session_sub = cx.observe_global::<Session>(move |this, cx| {
            let now = Some(cx.global::<Session>().selection);
            if now != shown && now == Some(Page::Dictionary) {
                // A SwiftUI view rebuilt on appearing: `filter` is local state and starts at All again.
                this.filter = Filter::All;
                // `.task`: refreshes every time the page appears.
                this.voice_over = cx.global::<Core>().services.voice_over_on();
                this.refresh(cx);
                cx.notify();
            }
            shown = now;
            // The learner's `reload()`: it reports through the same notification once it exists (Feature 025).
            let latest = cx.global::<Session>().history_revision;
            if latest != revision && now == Some(Page::Dictionary) {
                this.refresh(cx);
                cx.notify();
            }
            revision = latest;
        });
        let mut page = DictionaryPage {
            model: Model::default(),
            filter: Filter::All,
            searching: false,
            search,
            confirming_delete: None,
            canonical: None,
            aliases: vec![],
            field_subs: vec![],
            focus: cx.focus_handle(),
            action_focus: Default::default(),
            voice_over: cx.global::<Core>().services.voice_over_on(),
            _search_sub,
            _session_sub,
        };
        page.refresh(cx);
        page.apply_scenario(window, cx);
        page
    }

    fn refresh(&mut self, cx: &mut Context<Self>) {
        let core = cx.global::<Core>();
        match &core.db {
            Some(db) => self.model.refresh(db, is_english),
            None => self.model.load_error = Some(core.db_error.clone().unwrap_or_default()),
        }
    }

    /// States the fixture data can't reach, for the audit.
    fn apply_scenario(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let scenario = cx.global::<Core>().scenario.clone().unwrap_or_default();
        match scenario.strip_prefix("dictionary.").unwrap_or("") {
            "empty" => {
                self.model.entries.clear();
                self.model.suggestions.clear();
            }
            "error" => {
                self.model.entries.clear();
                self.model.suggestions.clear();
                self.model.loaded = false;
                self.model.load_error = Some("The dictionary could not be read.".into());
            }
            "full" => {
                let first = self.model.entries[0].clone();
                self.model.entries = (0..MAX_ENTRIES).map(|i| Entry { id: format!("full-{i}"), canonical: format!("Term {i}"), ..first.clone() }).collect();
            }
            "add" => {
                self.model.begin_add();
                self.sync_fields(window, cx);
            }
            "misspelling" => {
                self.model.begin_add();
                self.model.add_alias();
                self.sync_fields(window, cx);
            }
            "word" => {
                self.model.begin_add();
                self.model.set_correcting(false);
                self.sync_fields(window, cx);
            }
            "delete" => self.confirming_delete = self.model.entries.first().cloned(),
            "edit" => {
                if let Some(e) = self.model.entries.first().cloned() {
                    self.begin_edit(&e, window, cx);
                }
            }
            "disabled" => self.filter = Filter::Disabled,
            "learned" => self.filter = Filter::Learned,
            "search" => {
                self.searching = true;
                self.search.update(cx, |s, cx| s.set_value("Ac", window, cx));
            }
            "saving" => self.model.saving = true,
            _ => {}
        }
    }

    /// Mutates the model against the database, then redraws. Writes are local and bounded.
    fn with_db(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut Model, &flow_core::db::Db)) {
        if let Some(db) = cx.global::<Core>().db.as_ref() {
            f(&mut self.model, db);
        }
        cx.notify();
    }

    /// Rebuilds the sheet's fields from the draft and focuses the one Swift focuses.
    fn sync_fields(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.field_subs.clear();
        self.canonical = None;
        self.aliases.clear();
        let Some(draft) = self.model.draft.clone() else { return };
        let canonical = cx.new(|cx| InputState::new(window, cx).placeholder(if draft.aliases.is_empty() { "Word" } else { "Correct spelling" }).default_value(draft.canonical.clone()));
        self.field_subs.push(cx.subscribe(&canonical, |this, input, e: &TextInputEvent, cx| {
            if matches!(e, TextInputEvent::Change) {
                let v = input.read(cx).value().to_string();
                this.model.set_canonical(v);
                cx.notify();
            }
        }));
        for (i, alias) in draft.aliases.iter().enumerate() {
            let input = cx.new(|cx| InputState::new(window, cx).placeholder("Misspelling").default_value(alias.clone()));
            self.field_subs.push(cx.subscribe(&input, move |this, input, e: &TextInputEvent, cx| {
                if matches!(e, TextInputEvent::Change) {
                    let v = input.read(cx).value().to_string();
                    this.model.set_alias(v, i);
                    cx.notify();
                }
            }));
            self.aliases.push(input);
        }
        let first = self.aliases.first().unwrap_or(&canonical).clone();
        first.update(cx, |s, cx| s.focus(window, cx));
        self.canonical = Some(canonical);
    }

    fn begin_add(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.model.begin_add();
        self.sync_fields(window, cx);
        cx.notify();
    }

    fn begin_edit(&mut self, e: &Entry, window: &mut Window, cx: &mut Context<Self>) {
        self.model.begin_edit(e);
        self.sync_fields(window, cx);
        cx.notify();
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.model.cancel_draft();
        self.sync_fields(window, cx);
        cx.notify();
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.model.can_save() || !self.model.draft_is_filled() {
            return;
        }
        self.with_db(cx, |m, db| m.save_draft(db, is_english));
        if self.model.draft.is_none() {
            self.sync_fields(window, cx);
        }
    }

    fn toggle(&mut self, e: &Entry, cx: &mut Context<Self>) {
        self.with_db(cx, |m, db| m.set_enabled(db, e, !e.enabled, is_english));
    }

    fn delete_confirmed(&mut self, cx: &mut Context<Self>) {
        if let Some(e) = self.confirming_delete.take() {
            self.with_db(cx, |m, db| m.delete(db, &e, is_english));
        }
    }

    fn restore(&mut self, e: &Entry, term: &RetiredTerm, cx: &mut Context<Self>) {
        self.with_db(cx, |m, db| m.restore(db, e, term, is_english));
    }

    fn header(&self, cx: &mut Context<Self>) -> Div {
        h_flex()
            .w_full()
            .justify_between()
            .child(t("Dictionary").font(26., 500.).tracking(-0.4))
            .child(
                pill("vocabulary.add", "Add new", true, cx)
                    .disabled(!self.model.can_add() || self.model.saving)
                    .on_click(cx.listener(|this, _, w, cx| this.begin_add(w, cx))),
            )
    }

    fn tabs(&self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let compact = cx.global::<Flow>().compact;
        let mut row = h_flex().w_full().gap(px(16.)).pt(px(26.)).relative().items_center();
        for item in Filter::ALL {
            let on = self.filter == item;
            row = row.child(
                FlowButton::new(format!("vocabulary.filter.{}", item.name().to_lowercase()), ButtonKind::Plain, item.name())
                    .a11y_selected(on)
                    .content(
                        v_flex()
                            .gap(px(6.))
                            .child(t(item.name()).font(15., if on { 500. } else { 400. }).color(if on { p.ink } else { p.muted }).a11y_hidden())
                            .child(div().h(px(2.)).w_full().when(on, |d| d.bg(p.ink))),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.filter = item;
                        cx.notify();
                    })),
            );
        }
        row.child(div().flex_1())
            .child(
                h_flex()
                    .gap(px(8.))
                    .pb(px(8.))
                    .when(self.searching, |d| {
                        // Swift's plain field is no taller than the tabs.
                        d.child(
                            div()
                                .id("vocabulary.searchField")
                                .test_support()
                                .h(px(18.))
                                .flex()
                                .items_center()
                                .w(px(if compact { 90. } else { 150. }))
                                .child(
                                    Input::new(&self.search)
                                        .appearance(false)
                                        .px_0()
                                        .text_color(p.muted)
                                        .aria_label("Search dictionary")
                                        .accessibility_id("vocabulary.search"),
                                ),
                        )
                    })
                    .child(
                        FlowButton::new("vocabulary.searchToggle", ButtonKind::Plain, "Search")
                            .content(icon("magnifyingglass", 13., p.muted))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.searching = !this.searching;
                                // Swift doesn't focus the field when it opens (DICT-023).
                                if !this.searching {
                                    this.search.update(cx, |s, cx| s.set_value("", window, cx));
                                }
                                cx.notify();
                            })),
                    ),
            )
            .child(div().absolute().bottom_0().left_0().right_0().h(px(1.)).bg(p.line))
    }

    fn banner(&self, cx: &mut Context<Self>) -> Div {
        let white_a = |o: f32| white().opacity(o);
        let serif = |s: &'static str| span(s).serif(true);
        div()
            .relative()
            .w_full()
            .mt(px(22.))
            .rounded(px(16.))
            .child(canvas(|_, _, _| {}, |b, _, w, _| banner_gradient(b, w)).absolute().size_full())
            .child(
                v_flex()
                    .w_full()
                    .px(px(32.))
                    .py(px(36.))
                    .gap(px(13.))
                    .child(div().text_size(px(34.)).child(rich(vec![serif("LocalFlow spells the way "), serif("you").italic(), serif(" do.")]).size(34.).tracking(-0.6).color(white())))
                    .child(
                        div().max_w(px(600.)).child(
                            rich(vec![span("Add a word once, so your "), span("personal terms, company jargon, or uncommon names").weight(700.), span(" are spelled right in every dictation.")])
                                .size(15.)
                                .line_spacing(3.)
                                .color(white_a(0.9)),
                        ),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .pt(px(5.))
                            .child(
                                FlowButton::new("vocabulary.bannerAdd", ButtonKind::Primary, "Add new word")
                                    .fill(white_a(0.18))
                                    .text_color(white())
                                    .disabled_opacity(0.5)
                                    .disabled(!self.model.can_add() || self.model.saving)
                                    .content(div().mx(px(2.)).my(px(1.)).child(t("Add new word").font(15., 500.).color(white()).a11y_hidden()))
                                    .on_click(cx.listener(|this, _, w, cx| this.begin_add(w, cx))),
                            )
                            .when(self.model.is_full(), |d| d.child(t(format!("Dictionary is full ({MAX_ENTRIES} words).")).size(12.).color(white_a(0.85)))),
                    ),
            )
            .child(
                div().absolute().top(px(12.)).right(px(12.)).child(
                    FlowButton::new("vocabulary.bannerDismiss", ButtonKind::Plain, "Dismiss introduction")
                        .content(div().p(px(6.)).rounded_full().bg(white_a(0.14)).child(icon("xmark@semibold", 11.5, white_a(0.8))))
                        .on_click(cx.listener(|_, _, _, cx| {
                            cx.global_mut::<Core>().prefs.set("dictionary.bannerDismissed", true);
                            cx.notify();
                        })),
                ),
            )
    }

    fn suggestions(&self, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = pal(cx);
        let count = self.model.suggestions.len();
        let mut rows = v_flex().relative().w_full();
        for (i, s) in self.model.suggestions.iter().enumerate() {
            let (add, dismiss) = (s.clone(), s.clone());
            rows = rows
                .child(
                    h_flex()
                        .w_full()
                        .gap(px(10.))
                        .px(px(18.))
                        .py(px(10.))
                        .when(!s.alias.is_empty(), |d| d.child(t(s.alias.clone()).size(15.)).child(icon("arrow.right@semibold", 12., p.ink)))
                        .child(t(s.canonical.clone()).size(15.))
                        .child(t(suggestion_note(s)).size(12.).color(p.muted))
                        .child(div().flex_1())
                        .child(
                            pill(format!("vocabulary.suggestion.add.{i}"), "Add", false, cx)
                                .a11y_label(format!("Add {}", s.canonical))
                                .disabled(!self.model.can_add() || self.model.saving)
                                .on_click(cx.listener(move |this, _, w, cx| {
                                    this.model.begin_add_suggestion(&add);
                                    this.sync_fields(w, cx);
                                    cx.notify();
                                })),
                        )
                        .child(
                            pill(format!("vocabulary.suggestion.dismiss.{i}"), "Dismiss", false, cx)
                                .a11y_label(format!("Dismiss {}", s.canonical))
                                .on_click(cx.listener(move |this, _, _, cx| this.with_db(cx, |m, db| m.dismiss(db, &dismiss)))),
                        ),
                )
                .when(i + 1 < count, |d| d.child(hairline(cx)));
        }
        v_flex().id("vocabulary.suggestions").w_full().mt(px(24.)).gap(px(9.)).child(t("Suggested").font(13., 500.).color(p.muted)).child(rows.child(outline(cx)))
    }

    fn list(&self, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let p = pal(cx);
        let search = self.search.read(cx).value().to_string();
        let entries = self.model.visible(self.filter, &search);
        if entries.is_empty() {
            let text = if self.model.entries.is_empty() {
                "No words yet"
            } else if search.is_empty() {
                "Nothing here"
            } else {
                "No matches"
            };
            return div().id("vocabulary.empty").test_support().w_full().mt(px(24.)).py(px(60.)).flex().justify_center().child(t(text).size(15.).color(p.muted)).into_any_element();
        }
        let count = entries.len();
        let mut list = v_flex().id("vocabulary.list").test_support().relative().w_full().mt(px(24.));
        for (i, e) in entries.into_iter().enumerate() {
            list = list.child(self.row(i, e, window, cx)).when(i + 1 < count, |d| d.child(hairline(cx)));
        }
        list.child(outline(cx)).into_any_element()
    }

    fn row(&self, i: usize, e: Entry, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let p = pal(cx);
        let busy = self.model.saving;
        let fg = if e.enabled { p.ink } else { p.muted };
        let retired = self.model.retired_terms(&e);
        let usage = cx.global::<Core>().db.as_ref().map(|db| self.model.usage_summary(db, &e)).unwrap_or_default();
        let group: SharedString = format!("dictionary.row.{i}").into();
        let action_focus = self.action_focus.borrow_mut().entry(i).or_insert_with(|| cx.focus_handle()).clone();
        let is_retired_alias = |a: &String| retired.iter().any(|r| !r.is_boost() && r.term != e.canonical && &r.term == a);

        let mut title = h_flex().gap(px(10.)).flex_1().min_w_0();
        if e.aliases.is_empty() {
            let strike = retired.iter().any(|r| r.term == e.canonical && !r.is_boost());
            title = title.child(rich(vec![if strike { span(e.canonical.clone()).strike() } else { span(e.canonical.clone()) }]).size(15.).color(fg));
        } else {
            // Swift's `HStack(spacing: 0)`: each alias is its own text and wraps on its own.
            let mut aliases = h_flex().min_w_0();
            for (n, a) in e.aliases.iter().enumerate() {
                let word = if is_retired_alias(a) { span(a.clone()).strike().color(fg.opacity(0.55)) } else { span(a.clone()) };
                // ponytail: SwiftUI wraps the first alias and keeps later ones whole here; very long later aliases clip.
                aliases = aliases.child(div().when(n > 0, |d| d.flex_none()).when(n == 0, |d| d.min_w_0()).child(rich(vec![word]).size(15.).color(fg)));
                if n + 1 < e.aliases.len() {
                    // `Txt` measures no trailing space, so it is a margin here.
                    aliases = aliases.child(div().flex_none().mr(px(4.)).child(t(",").size(15.).color(fg)));
                }
            }
            title = title.child(aliases).child(div().flex_none().child(icon("arrow.right@semibold", 12., fg))).child(div().flex_none().child(t(e.canonical.clone()).size(15.).color(fg)));
        }
        let chip = |text: &'static str| div().px(px(6.)).py(px(2.)).bg(p.tint).rounded_full().child(t(text).size(11.).color(p.muted));
        if self.model.is_provisional(&e) {
            title = title.child(help(format!("dictionary.learning.{i}"), "Learned from one correction. Kept three times, it is trusted; undone once, it turns off.", chip("Learning")).test_support());
        }
        if e.learned_at.is_some() {
            // Swift: `Color(nsColor: .systemYellow)`, the same in both modes here.
            title = title.child(help(format!("dictionary.learned.{i}"), "Learned from a correction you made", icon("sparkles", 10., rgb(0xFFCC00))).test_support());
        }
        if !e.enabled {
            title = title.child(div().id(SharedString::from(format!("dictionary.off.{i}"))).test_support().child(chip("Off")));
        }

        let (edit, toggle, delete) = (e.clone(), e.clone(), e.clone());
        let actions = h_flex()
            .gap(px(4.))
            .child(pill(format!("dictionary.edit.{i}"), "Edit", false, cx).a11y_label(format!("Edit {}", e.canonical)).disabled(busy).on_click(cx.listener(move |this, _, w, cx| this.begin_edit(&edit, w, cx))))
            .child(
                pill(format!("dictionary.toggle.{i}"), if e.enabled { "Disable" } else { "Enable" }, false, cx)
                    .a11y_label(format!("{} {}", if e.enabled { "Disable" } else { "Enable" }, e.canonical))
                    .disabled(busy)
                    .on_click(cx.listener(move |this, _, _, cx| this.toggle(&toggle, cx))),
            )
            .child(
                pill(format!("dictionary.delete.{i}"), "Delete", false, cx)
                    .a11y_label(format!("Delete {}", e.canonical))
                    .disabled(busy)
                    .on_click(cx.listener(move |this, _, w, cx| {
                        this.confirming_delete = Some(delete.clone());
                        // Escape reaches the dialog through the page's focus.
                        this.focus.focus(w, cx);
                        cx.notify();
                    })),
            );

        // `.mb(-1)`: `Txt` rounds the 12 line up; Swift's row is 1 shorter.
        let mut meta = h_flex().gap(px(8.)).mb(px(-1.)).child(t(usage).id("dictionary.entry.usage").size(12.).color(p.muted));
        for (n, term) in retired.iter().enumerate() {
            let label = if term.is_boost() { "Boost off · Restore".to_string() } else { format!("Restore \u{2018}{}\u{2019}", term.term) };
            let (entry, term) = (e.clone(), term.clone());
            meta = meta.child(
                FlowButton::new(format!("dictionary.alias.restore.{i}.{n}"), ButtonKind::Prototype, label.clone())
                    .fill(p.button)
                    .disabled_opacity(0.45)
                    .disabled(busy)
                    .tooltip("Stopped after you undid it. Restore to use it again.")
                    .content(t(label).font(11., 500.).color(p.ink).a11y_hidden())
                    .on_click(cx.listener(move |this, _, _, cx| this.restore(&entry, &term, cx))),
            );
        }

        let page = cx.entity().downgrade();
        let menu_entry = e.clone();
        v_flex()
            .id(format!("dictionary.row.{i}"))
            .test_support()
            .test_support()
            .group(group.clone())
            .w_full()
            .min_h(px(53.))
            .px(px(18.))
            .py(px(10.))
            .gap(px(4.))
            .text_color(fg)
            .child(h_flex().w_full().gap(px(10.)).child(title).child(focus_revealed(group, busy || self.voice_over, &action_focus, window, cx, actions)))
            .child(meta)
            .context_menu(move |menu, _, _| {
                let (a, b, c) = (page.clone(), page.clone(), page.clone());
                let (ea, eb, ec) = (menu_entry.clone(), menu_entry.clone(), menu_entry.clone());
                menu.item(PopupMenuItem::new("Edit").on_click(move |_, w, cx| {
                    a.update(cx, |this, cx| this.begin_edit(&ea, w, cx)).ok();
                }))
                .item(PopupMenuItem::new(if menu_entry.enabled { "Disable" } else { "Enable" }).on_click(move |_, _, cx| {
                    b.update(cx, |this, cx| this.toggle(&eb, cx)).ok();
                }))
                .item(destructive_item("Delete", None).on_click(move |_, w, cx| {
                    c.update(cx, |this, cx| {
                        this.confirming_delete = Some(ec.clone());
                        this.focus.focus(w, cx);
                        cx.notify();
                    })
                    .ok();
                }))
            })
            .into_any_element()
    }

    fn sheet(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = pal(cx);
        let Some(draft) = self.model.draft.clone() else { return div().into_any_element() };
        let editing = draft.id.is_some();
        let error = self.model.field_errors.get(&Field::Entry).or(self.model.field_errors.get(&Field::Store)).or(self.model.field_errors.get(&Field::Aliases)).cloned();
        let correcting = self.model.is_correcting();
        let save_label = if self.model.saving {
            "Saving…"
        } else if editing {
            "Save"
        } else {
            "Add word"
        };
        sheet_card(360., cx)
            .id("vocabulary.sheet")
            .test_support()
            .track_focus(&self.focus)
            // Swift's 18, plus the 3.5 the native sheet window adds above and below (measured on the pair).
            .px(px(18.))
            .py(px(21.5))
            .gap(px(14.))
            .on_key_down(cx.listener(|this, e: &KeyDownEvent, w, cx| match e.keystroke.key.as_str() {
                "escape" if !this.model.saving => this.cancel(w, cx),
                "enter" => this.save(w, cx),
                _ => {}
            }))
            .child(t(if editing { "Edit vocabulary" } else { "Add to vocabulary" }).font(15., 600.))
            .child(toggle_row("Correct a misspelling", "Replace a misspelling with the correct spelling. Off: keep this word's spelling.", "vocabulary.correctMisspelling", correcting, cx, cx.listener(|this, on: &bool, w, cx| {
                this.model.set_correcting(*on);
                this.sync_fields(w, cx);
                cx.notify();
            })))
            .child(toggle_row("Enabled", "Disabled words stay in the dictionary but are not applied.", "vocabulary.enabled", draft.enabled, cx, cx.listener(|this, on: &bool, _, cx| {
                if let Some(d) = this.model.draft.as_mut() {
                    d.enabled = *on;
                }
                cx.notify();
            })))
            .child(self.fields(cx))
            .when_some(error, |d, e| d.child(div().id("vocabulary.sheetError").test_support().w_full().child(error_text(e, cx))))
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.))
                    .pt(px(4.))
                    .child(pill("vocabulary.cancel", "Cancel", false, cx).disabled(self.model.saving).on_click(cx.listener(|this, _, w, cx| this.cancel(w, cx))))
                    .child(pill("vocabulary.save", save_label, true, cx).disabled(!self.model.can_save() || !self.model.draft_is_filled()).on_click(cx.listener(|this, _, w, cx| this.save(w, cx)))),
            )
            .text_color(p.ink)
            .into_any_element()
    }

    fn fields(&self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let Some(canonical) = self.canonical.clone() else { return v_flex() };
        let canonical_error = self.model.field_errors.get(&Field::Canonical).cloned();
        if self.aliases.is_empty() {
            return v_flex()
                .gap(px(4.))
                .child(field(&canonical, "Word", "vocabulary.canonical", cx))
                .when_some(canonical_error, |d, e| {
                    d.child(
                        div()
                            .id("vocabulary.canonicalError")
                            .test_support()
                            .child(error_text(e, cx)),
                    )
                });
        }
        let duplicates = self.model.duplicate_alias_indices();
        let canonical_text = canonical.read(cx).value().to_string();
        let mut col = v_flex().gap(px(14.));
        for (i, alias) in self.aliases.iter().enumerate() {
            let mut row = h_flex().w_full().gap(px(8.)).child(div().flex_1().min_w_0().child(field(alias, "Misspelling", &format!("vocabulary.alias.{i}"), cx))).child(icon("arrow.right", 10., p.muted));
            if i == 0 {
                row = row.child(div().flex_1().min_w_0().child(field(&canonical, "Correct spelling", "vocabulary.canonical", cx)));
            } else {
                row = row.child(div().flex_1().min_w_0().overflow_hidden().child(t(canonical_text.clone()).size(13.).color(p.muted).lines(1))).child(
                    FlowButton::new(format!("vocabulary.removeAlias.{i}"), ButtonKind::Plain, format!("Remove misspelling {}", i + 1))
                        .content(icon("xmark@semibold", 10., p.muted))
                        .on_click(cx.listener(move |this, _, w, cx| {
                            this.model.remove_alias(i);
                            this.sync_fields(w, cx);
                            cx.notify();
                        })),
                );
            }
            let err = self.model.field_errors.get(&Field::Alias(i)).cloned().or(duplicates.contains(&i).then(|| "Repeats another misspelling.".to_string()));
            col = col.child(
                v_flex()
                    .gap(px(4.))
                    .child(row)
                    .when_some(err, |d, e| d.child(error_text(e, cx)))
                    .when(i == 0, |d| {
                        d.when_some(canonical_error.clone(), |d, e| {
                            d.child(
                                div()
                                    .id("vocabulary.canonicalError")
                                    .test_support()
                                    .child(error_text(e, cx)),
                            )
                        })
                    }),
            );
        }
        let link = |id: &'static str, label: &'static str| FlowButton::new(id, ButtonKind::Plain, label).content(t(label).size(12.).color(p.accent).a11y_hidden());
        col.child(
            h_flex()
                .gap(px(12.))
                .when(self.model.can_add_alias(), |d| {
                    d.child(link("vocabulary.addAlias", "Add another misspelling").on_click(cx.listener(|this, _, w, cx| {
                        this.model.add_alias();
                        this.sync_fields(w, cx);
                        cx.notify();
                    })))
                })
                .when(!duplicates.is_empty(), |d| {
                    d.child(link("vocabulary.deduplicate", "Remove duplicates").on_click(cx.listener(|this, _, w, cx| {
                        this.model.deduplicate();
                        this.sync_fields(w, cx);
                        cx.notify();
                    })))
                }),
        )
    }
}

fn suggestion_note(s: &Suggestion) -> String {
    match s.source {
        Source::Correction => "You corrected this".into(),
        _ => format!("Seen in {} dictations", s.sightings),
    }
}

fn error_text(text: String, cx: &App) -> Txt {
    t(text).size(12.).color(pal(cx).warning)
}

/// `DictionaryField`: bordered plain field; the store owns validation.
fn field(state: &Entity<InputState>, label: &str, id: &str, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    div()
        .id(SharedString::from(format!("{id}.box")))
        .w_full()
        .h(px(29.))
        .flex()
        .items_center()
        .overflow_hidden()
        .bg(p.surface)
        .rounded(px(8.))
        .border_1()
        .border_color(p.line)
        .child(Input::new(state).appearance(false).h(px(27.)).text_size(px(13.)).aria_label(label.to_string()).accessibility_id(id.to_string()))
        .test_support()
}

fn toggle_row(title: &'static str, tip: &'static str, id: &'static str, on: bool, cx: &App, handler: impl Fn(&bool, &mut Window, &mut App) + 'static) -> Div {
    let p = pal(cx);
    h_flex()
        .w_full()
        .gap(px(6.))
        .child(t(title).size(13.))
        .child(help(format!("{id}.info"), tip, icon("info.circle", 11., p.muted)))
        .child(div().flex_1())
        .child(FlowSwitch::new(id).checked(on).with_size(ControlSize::Small).accessibility_label(title).on_click(handler))
}

/// Swift's three-stop gradient. Slices, not `linear_gradient`: GPUI's shader dither leaves vertical bands on this dark ramp.
// ponytail: each corner is one solid colour, at most 2 levels off across its 16 pt.
fn banner_gradient(b: Bounds<Pixels>, w: &mut Window) {
    let at = |x: f32| {
        let (t, (a, c)) = if x < 0.5 { (x * 2., ((0.13, 0.12, 0.11), (0.24, 0.2, 0.16))) } else { (x * 2. - 1., ((0.24, 0.2, 0.16), (0.48, 0.36, 0.2))) };
        let mix = |p: f32, q: f32| p + (q - p) * t;
        Hsla::from(Rgba { r: mix(a.0, c.0), g: mix(a.1, c.1), b: mix(a.2, c.2), a: 1. })
    };
    let (width, height, r) = (f32::from(b.size.width), f32::from(b.size.height), 16.);
    let quad_at = |x: f32, y: f32, qw: f32, qh: f32| Bounds::new(point(b.origin.x + px(x), b.origin.y + px(y)), size(px(qw), px(qh)));
    // Corners first and twice their radius, which GPUI otherwise halves; the slices paint over all but the curve.
    for (x, y, corners) in [
        (0., 0., Corners { top_left: px(r), ..Default::default() }),
        (width - r * 2., 0., Corners { top_right: px(r), ..Default::default() }),
        (0., height - r * 2., Corners { bottom_left: px(r), ..Default::default() }),
        (width - r * 2., height - r * 2., Corners { bottom_right: px(r), ..Default::default() }),
    ] {
        let edge = if x == 0. { r / 2. } else { width - r / 2. };
        w.paint_quad(fill(quad_at(x, y, r * 2., r * 2.), at(edge / width)).corner_radii(corners));
    }
    let mut x = 0.;
    while x < width {
        let inset = if x < r || x >= width - r { r } else { 0. };
        // 2.5: slices overlap, so a fractional origin leaves no seam; stopped short of the right corners.
        let slice = if inset == 0. { (width - r - x).min(2.5) } else { (width - x).min(2.5) };
        w.paint_quad(fill(quad_at(x, inset, slice, height - inset * 2.), at((x + 1.) / width)));
        x += 2.;
    }
}

impl Render for DictionaryPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let dismissed = cx.global::<Core>().prefs.bool_or("dictionary.bannerDismissed", false);
        let search_empty = self.search.read(cx).value().is_empty();
        let mut content = v_flex().w_full().child(self.header(cx)).child(self.tabs(cx));
        if !dismissed {
            content = content.child(self.banner(cx));
        }
        if let Some(e) = self.model.load_error.clone() {
            content = content.child(div().id("vocabulary.loadErrorLine").test_support().pt(px(24.)).child(t(e).id("vocabulary.loadError").size(13.).color(p.warning).selectable()));
        }
        if self.filter == Filter::All && search_empty && !self.model.suggestions.is_empty() {
            content = content.child(self.suggestions(cx));
        }
        content = content.child(self.list(window, cx));
        if let Some(s) = self.model.status.clone() {
            content = content.child(div().id("vocabulary.statusLine").test_support().pt(px(14.)).child(t(s).id("vocabulary.status").size(12.).color(p.muted)));
        }
        let sheet = if self.model.draft.is_some() { Some(self.sheet(cx)) } else { None };
        let confirm = if self.confirming_delete.is_some() {
            Some(confirm_dialog(
                "vocabulary.deleteDialog",
                "Delete this word?",
                "Past transcriptions keep their spelling.",
                "Delete word",
                cx,
                cx.listener(|this, _, _, cx| this.delete_confirmed(cx)),
                cx.listener(|this, _, _, cx| {
                    this.confirming_delete = None;
                    cx.notify();
                }),
            )
            // The glass picks up the banner behind it, measured from Swift's dialog.
            .when(!dismissed, |d| d.bg(if pal(cx).ink.l > 0.5 { rgb(0x35322E) } else { rgb(0xBCBAB7) })))
        } else {
            None
        };
        div()
            .id("dictionary.root")
            .track_focus(&self.focus)
            // ponytail: no Kit `Root` in this shell, so no window-wide Tab; each page with row actions binds it.
            .on_key_down(cx.listener(|this, e: &KeyDownEvent, w, cx| {
                if e.keystroke.key == "tab" {
                    if e.keystroke.modifiers.shift { w.focus_prev(cx) } else { w.focus_next(cx) }
                } else if e.keystroke.key == "escape" && this.confirming_delete.take().is_some() {
                    // An alert's other way out: `confirmingDelete` clears as Cancel clears it.
                    cx.notify();
                }
            }))
            .relative()
            .size_full()
            .child(under_card_border(prototype_page("dictionary.page", 960., cx, content)))
            .when_some(sheet, |d, s| d.child(sheet_overlay("vocabulary.sheetOverlay", window, cx, s)))
            .when_some(confirm, |d, c| d.child(sheet_overlay("vocabulary.deleteOverlay", window, cx, c)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{assert_saw, boot, saw};
    use flow_ui::test::{TestAppContext, TestQueryExt, TestWindowExt};

    fn open(cx: &mut TestAppContext) -> WindowHandle<DictionaryPage> {
        boot(cx, Mode::Light);
        let window = cx.add_window(|w, cx| DictionaryPage::new(w, cx));
        frame(cx, window);
        window
    }

    fn frame(cx: &mut TestAppContext, window: WindowHandle<DictionaryPage>) {
        cx.run_until_parked();
        flow_ui::probe::clear();
        cx.update_window(window.into(), |_, w, cx| w.render_frame(cx)).unwrap();
    }

    fn click(cx: &mut TestAppContext, window: WindowHandle<DictionaryPage>, id: &str) {
        let id = SharedString::from(id.to_string());
        cx.update_window(window.into(), |_, w, cx| w.click(id, cx)).unwrap();
        frame(cx, window);
    }

    // Real keystrokes: `set_value` sends no change event.
    fn type_into(cx: &mut TestAppContext, window: WindowHandle<DictionaryPage>, state: Entity<InputState>, text: &str) {
        cx.update_window(window.into(), |_, w, cx| {
            state.read(cx).focus_handle(cx).focus(w, cx);
        })
        .unwrap();
        frame(cx, window);
        cx.update_window(window.into(), |_, w, cx| w.input(text, cx)).unwrap();
        frame(cx, window);
    }

    fn stored(cx: &mut TestAppContext) -> Vec<Entry> {
        cx.update(|cx| flow_core::dictionary::load(cx.global::<Core>().db.as_ref().unwrap()).unwrap().entries)
    }

    // parity: DICT-008 DICT-009 DICT-014 DICT-017 DICT-027 DICT-029 DICT-041 DICT-071
    #[flow_ui::gpui::test]
    async fn page_shows_title_banner_suggestions_and_rows(cx: &mut TestAppContext) {
        let _w = open(cx);
        assert_saw(&["Dictionary", "Add new", "All", "Enabled", "Disabled", "Learned", "LocalFlow spells the way", "Add new word", "Suggested", "Figtree", "Acme Robotics", "Restore \u{2018}akme robotics\u{2019}", "Off"]);
    }

    // parity: DICT-015 DICT-016 DICT-018 DICT-019 DICT-020 DICT-042
    #[flow_ui::gpui::test]
    async fn filter_tabs_narrow_the_list(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.filter.disabled");
        assert_saw(&["Northwind"]);
        assert!(!saw("Brunel"));
        assert!(!saw("Suggested"));
        click(cx, w, "vocabulary.filter.learned");
        assert_saw(&["Kubernetes", "Qwen"]);
        assert!(!saw("Brunel"));
    }

    // parity: DICT-018
    #[flow_ui::gpui::test]
    async fn enabled_shows_only_enabled_words(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.filter.enabled");
        assert_saw(&["Brunel"]);
        assert!(!saw("Northwind"));
    }

    // parity: DICT-016
    #[flow_ui::gpui::test]
    async fn the_filter_goes_back_to_all_on_returning(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(crate::shell::ensure_session);
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Dictionary));
        let w = cx.add_window(|w, cx| DictionaryPage::new(w, cx));
        frame(cx, w);
        click(cx, w, "vocabulary.filter.disabled");
        assert!(!saw("Brunel"));
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Insights));
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Dictionary));
        frame(cx, w);
        assert_saw(&["Brunel", "Northwind"]);
    }

    // parity: DICT-023
    #[flow_ui::gpui::test]
    async fn the_search_field_reads_like_swift_and_does_not_take_focus(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.searchToggle");
        cx.update_window(w.into(), |_, win, _| {
            let field = win.find_by_label("Search dictionary");
            assert_eq!(field.placeholder().map(str::to_string).as_deref(), Some("Search"));
            assert_ne!(field.focused(), Some(true));
        })
        .unwrap();
    }

    // parity: DICT-088
    #[flow_ui::gpui::test]
    async fn the_row_menu_reads_edit_toggle_and_a_red_delete(cx: &mut TestAppContext) {
        let w = open(cx);
        let enabled = w.update(cx, |t, _, _| t.model.entries[0].enabled).unwrap();
        cx.update_window(w.into(), |_, win, cx| win.right_click("dictionary.edit.0", cx)).unwrap();
        frame(cx, w);
        assert_saw(&["Edit", if enabled { "Disable" } else { "Enable" }, "Delete"]);
        let red = cx.update(|cx| pal(cx).destructive());
        assert_eq!(flow_ui::probe::style_of("Delete").map(|s| s.color), Some(red));
    }

    // parity: DICT-091
    #[flow_ui::gpui::test]
    async fn cancel_and_escape_both_close_the_delete_dialog(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "dictionary.delete.1");
        click(cx, w, "vocabulary.deleteDialog.cancel");
        w.update(cx, |t, _, _| assert!(t.confirming_delete.is_none())).unwrap();
        click(cx, w, "dictionary.delete.1");
        w.update(cx, |t, _, _| assert!(t.confirming_delete.is_some())).unwrap();
        cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
        frame(cx, w);
        w.update(cx, |t, _, _| assert!(t.confirming_delete.is_none())).unwrap();
        assert!(stored(cx).iter().any(|e| e.canonical == "Brunel"));
    }

    // parity: DICT-121
    #[flow_ui::gpui::test]
    async fn save_is_off_while_blank_saving_or_after_a_load_error(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        assert_eq!(disabled(cx, w, "vocabulary.save"), Some(true), "blank");
        let field = w.update(cx, |t, _, _| t.canonical.clone().unwrap()).unwrap();
        type_into(cx, w, field, "Tatra");
        let alias = w.update(cx, |t, _, _| t.aliases[0].clone()).unwrap();
        type_into(cx, w, alias, "   ");
        assert_eq!(disabled(cx, w, "vocabulary.save"), Some(true), "a blank alias");
        let alias = w.update(cx, |t, _, _| t.aliases[0].clone()).unwrap();
        type_into(cx, w, alias, "tatry");
        assert_ne!(disabled(cx, w, "vocabulary.save"), Some(true), "filled");
        state(cx, w, |t| t.model.saving = true);
        assert_eq!(disabled(cx, w, "vocabulary.save"), Some(true), "saving");
        state(cx, w, |t| {
            t.model.saving = false;
            t.model.load_error = Some("x".into());
        });
        assert_eq!(disabled(cx, w, "vocabulary.save"), Some(true), "load error");
    }

    // parity: DICT-033 DICT-034
    #[flow_ui::gpui::test]
    async fn banner_dismissal_persists(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.bannerDismiss");
        assert!(!saw("LocalFlow spells"));
        cx.update(|cx| assert!(cx.global::<Core>().prefs.bool_or("dictionary.bannerDismissed", false)));
    }

    // parity: DICT-010 DICT-093 DICT-121 DICT-122
    #[flow_ui::gpui::test]
    async fn add_a_word_through_the_sheet(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        assert_saw(&["Add to vocabulary", "Correct a misspelling", "Add word"]);
        let field = w.update(cx, |this, _, _| this.canonical.clone().unwrap()).unwrap();
        type_into(cx, w, field, "Tatra");
        let alias = w.update(cx, |this, _, _| this.aliases[0].clone()).unwrap();
        type_into(cx, w, alias, "tatry");
        click(cx, w, "vocabulary.save");
        let saved = stored(cx)
            .into_iter()
            .find(|e| e.canonical == "Tatra")
            .unwrap();
        assert_eq!(
            (saved.id.len(), saved.id.matches('-').count()),
            (36, 4),
            "a UUID"
        );
        assert_saw(&["Tatra", "Entry added."]);
        assert!(!saw("Add to vocabulary"));
    }

    // parity: DICT-122
    #[flow_ui::gpui::test]
    async fn a_repeated_misspelling_blocks_the_save(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        let field = w
            .update(cx, |this, _, _| this.canonical.clone().unwrap())
            .unwrap();
        type_into(cx, w, field, "Tatra");
        click(cx, w, "vocabulary.addAlias");
        for a in w.update(cx, |this, _, _| this.aliases.clone()).unwrap() {
            type_into(cx, w, a, "tatry");
        }
        let count = stored(cx).len();
        cx.update_window(w.into(), |_, win, cx| win.press("enter", cx))
            .unwrap();
        frame(cx, w);
        assert_saw(&["This alias repeats another term in the entry."]);
        assert_eq!(stored(cx).len(), count);
    }

    // parity: DICT-108 DICT-109 DICT-111 DICT-112 DICT-113 DICT-114 DICT-157
    #[flow_ui::gpui::test]
    async fn misspelling_fields_add_remove_and_report_duplicates(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        w.update(cx, |this, window, cx| {
            this.model.set_correcting(true);
            this.sync_fields(window, cx);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        assert_saw(&["Add another misspelling"]);
        click(cx, w, "vocabulary.addAlias");
        for a in w.update(cx, |this, _, _| this.aliases.clone()).unwrap() {
            type_into(cx, w, a, "tatra");
        }
        assert_saw(&["Repeats another misspelling.", "Remove duplicates"]);
        let (add, remove) = (bounds(cx, w, "vocabulary.addAlias"), bounds(cx, w, "vocabulary.deduplicate"));
        assert_eq!(remove.origin.x - add.right(), px(12.));
        click(cx, w, "vocabulary.deduplicate");
        assert!(!saw("Repeats another misspelling."));
        w.update(cx, |this, _, _| assert_eq!(this.aliases.len(), 1)).unwrap();
    }

    // parity: DICT-082 DICT-085 DICT-086 DICT-087 DICT-089 DICT-090 DICT-091
    #[flow_ui::gpui::test]
    async fn disable_and_delete_write_through(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "dictionary.toggle.1");
        let brunel = stored(cx).into_iter().find(|e| e.canonical == "Brunel").unwrap();
        assert!(!brunel.enabled);
        assert_saw(&["Entry disabled."]);
        click(cx, w, "dictionary.delete.1");
        assert_saw(&["Delete this word?", "Past transcriptions keep their spelling.", "Delete word"]);
        click(cx, w, "vocabulary.deleteDialog.cancel");
        assert!(stored(cx).iter().any(|e| e.canonical == "Brunel"));
        click(cx, w, "dictionary.delete.1");
        click(cx, w, "vocabulary.deleteDialog.confirm");
        assert!(!stored(cx).iter().any(|e| e.canonical == "Brunel"));
    }

    // parity: DICT-077 DICT-080
    #[flow_ui::gpui::test]
    async fn restore_clears_a_retired_alias(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "dictionary.alias.restore.0.0");
        assert!(!saw("Restore \u{2018}akme robotics\u{2019}"));
        assert_saw(&["Restored akme robotics."]);
    }

    // parity: DICT-046 DICT-049
    #[flow_ui::gpui::test]
    async fn suggestion_add_fills_the_sheet_and_dismiss_persists(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.suggestion.dismiss.0");
        assert!(!saw("Figtree"));
        click(cx, w, "vocabulary.suggestion.add.0");
        assert_saw(&["Add to vocabulary"]);
        w.update(cx, |this, _, _| assert_eq!(this.model.draft.as_ref().unwrap().canonical, "Garamond")).unwrap();
    }

    // parity: DICT-022 DICT-024 DICT-061
    #[flow_ui::gpui::test]
    async fn search_filters_and_reports_no_matches(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.searchToggle");
        w.update(cx, |this, window, cx| this.search.update(cx, |s, cx| s.set_value("zzz", window, cx))).unwrap();
        frame(cx, w);
        assert_saw(&["No matches"]);
        assert!(!saw("Suggested"));
        click(cx, w, "vocabulary.searchToggle");
        assert_saw(&["Acme Robotics"]);
    }

    fn open_scenario(cx: &mut TestAppContext, scenario: &str) -> WindowHandle<DictionaryPage> {
        boot(cx, Mode::Light);
        cx.update(|cx| cx.global_mut::<Core>().scenario = Some(scenario.to_string()));
        let window = cx.add_window(|w, cx| DictionaryPage::new(w, cx));
        frame(cx, window);
        window
    }

    // parity: DICT-036
    #[flow_ui::gpui::test]
    async fn a_damaged_store_shows_the_swift_copy(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute("UPDATE vocabulary_entries SET canonical_text='Omega'", []).unwrap());
        let window = cx.add_window(|w, cx| DictionaryPage::new(w, cx));
        frame(cx, window);
        assert_saw(&["Preferred spellings could not be loaded. Repair or delete entries in Settings."]);
    }

    // parity: DICT-011 DICT-030 DICT-031 DICT-060
    #[flow_ui::gpui::test]
    async fn full_dictionary_blocks_adding(cx: &mut TestAppContext) {
        let w = open_scenario(cx, "dictionary.full");
        assert_saw(&["Dictionary is full (512 words)."]);
        click(cx, w, "vocabulary.add");
        assert!(!saw("Add to vocabulary"));
        click(cx, w, "vocabulary.bannerAdd");
        assert!(!saw("Add to vocabulary"));
        click(cx, w, "vocabulary.filter.disabled");
        assert_saw(&["Nothing here"]);
    }

    // parity: DICT-035 DICT-059 DICT-160
    #[flow_ui::gpui::test]
    async fn empty_and_error_states(cx: &mut TestAppContext) {
        let _w = open_scenario(cx, "dictionary.empty");
        assert_saw(&["No words yet"]);
        assert!(!saw("Suggested"));
        let _w = open_scenario(cx, "dictionary.error");
        assert_saw(&["The dictionary could not be read.", "No words yet"]);
    }

    // parity: DICT-119
    /// Both ways out: the draft and its field errors go, the store is untouched.
    #[flow_ui::gpui::test]
    async fn cancel_clears_the_draft_and_errors_and_saves_nothing(cx: &mut TestAppContext) {
        let w = open(cx);
        let before = stored(cx);
        for leave in ["vocabulary.cancel", "escape"] {
            click(cx, w, "vocabulary.add");
            let (canonical, alias) = w.update(cx, |this, _, _| (this.canonical.clone().unwrap(), this.aliases[0].clone())).unwrap();
            type_into(cx, w, canonical, "two  spaces");
            type_into(cx, w, alias, "tatry");
            cx.update_window(w.into(), |_, win, cx| win.press("enter", cx)).unwrap();
            frame(cx, w);
            w.update(cx, |t, _, _| assert!(!t.model.field_errors.is_empty(), "a field error to clear")).unwrap();
            if leave == "escape" {
                cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
            } else {
                cx.update_window(w.into(), |_, win, cx| win.click(leave, cx)).unwrap();
            }
            frame(cx, w);
            w.update(cx, |t, _, _| {
                assert!(t.model.draft.is_none(), "{leave}");
                assert!(t.model.field_errors.is_empty(), "{leave}");
                assert!(t.canonical.is_none() && t.aliases.is_empty(), "{leave}");
            })
            .unwrap();
            assert_eq!(stored(cx), before, "{leave}");
            assert!(!saw("Add to vocabulary"));
        }
    }

    // parity: DICT-115
    /// Figtree 12 in `warning`, and a long message wraps instead of being cut.
    #[flow_ui::gpui::test]
    async fn the_sheet_error_is_small_warning_text_that_wraps(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        let message = "Vocabulary storage is full. ".repeat(12);
        w.update(cx, |t, _, cx| {
            t.model.field_errors.insert(Field::Entry, message.clone());
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        let style = flow_ui::probe::style_of(&message).expect("the error is drawn");
        let warning = cx.update(|cx| pal(cx).warning);
        assert_eq!((style.size, style.color), (12., warning));
        assert_eq!(style.weight, 400.);
        assert!(bounds(cx, w, "vocabulary.sheetError").size.height > px(20.), "more than one line");
    }

    // parity: DICT-099 DICT-107 DICT-110 DICT-118
    #[flow_ui::gpui::test]
    async fn sheet_modes_alias_limit_and_cancel(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        for _ in 0..7 {
            click(cx, w, "vocabulary.addAlias");
        }
        w.update(cx, |this, _, _| assert_eq!(this.aliases.len(), 8)).unwrap();
        assert!(!saw("Add another misspelling"));
        click(cx, w, "vocabulary.removeAlias.7");
        w.update(cx, |this, _, _| assert_eq!(this.aliases.len(), 7)).unwrap();
        assert_saw(&["Add another misspelling"]);
        w.update(cx, |this, window, cx| {
            this.model.set_correcting(false);
            this.sync_fields(window, cx);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        w.update(cx, |this, _, _| assert!(this.aliases.is_empty())).unwrap();
        cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
        frame(cx, w);
        assert!(!saw("Add to vocabulary"));
        assert!(!stored(cx).iter().any(|e| e.canonical.is_empty()));
    }

    // parity: DICT-117 DICT-127
    #[flow_ui::gpui::test]
    async fn sheet_shows_a_validation_error_and_stays_open(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        let (canonical, alias) = w.update(cx, |this, _, _| (this.canonical.clone().unwrap(), this.aliases[0].clone())).unwrap();
        type_into(cx, w, canonical, "two  spaces");
        type_into(cx, w, alias, "tatry");
        cx.update_window(w.into(), |_, win, cx| win.press("enter", cx)).unwrap();
        frame(cx, w);
        assert_saw(&["Separate words with single spaces.", "Add to vocabulary"]);
        assert!(
            w.update(cx, |t, _, _| t
                .model
                .entries
                .iter()
                .all(|e| e.canonical != "two  spaces"))
                .unwrap(),
            "nothing written"
        );
        let (error, box_) = (
            bounds(cx, w, "vocabulary.canonicalError"),
            bounds(cx, w, "vocabulary.alias.0.box"),
        );
        assert_eq!(
            error.origin.y - box_.bottom(),
            px(4.),
            "below the first misspelling row"
        );
    }

    fn state(cx: &mut TestAppContext, w: WindowHandle<DictionaryPage>, f: impl FnOnce(&mut DictionaryPage)) {
        w.update(cx, |t, _, cx| {
            f(t);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
    }

    fn disabled(cx: &mut TestAppContext, w: WindowHandle<DictionaryPage>, id: &str) -> Option<bool> {
        let id = SharedString::from(id.to_string());
        cx.update_window(w.into(), |_, win, _| win.find(id).disabled()).unwrap()
    }

    // parity: DICT-006
    #[flow_ui::gpui::test]
    async fn coming_back_to_the_page_reloads(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(crate::shell::ensure_session);
        let w = cx.add_window(|w, cx| DictionaryPage::new(w, cx));
        frame(cx, w);
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Insights));
        cx.update(|cx| {
            let e = Entry { id: "arrived".into(), canonical: "Arrived".into(), aliases: vec![], enabled: true, learned_at: None };
            flow_core::dictionary::save(cx.global::<Core>().db.as_ref().unwrap(), &e, None, "established").unwrap();
        });
        w.update(cx, |t, _, _| assert!(t.model.entries.iter().all(|e| e.id != "arrived"))).unwrap();
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute("DELETE FROM term_suggestions", []).unwrap());
        w.update(cx, |t, _, _| assert!(!t.model.suggestions.is_empty())).unwrap();
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Dictionary));
        frame(cx, w);
        w.update(cx, |t, _, _| assert!(t.model.entries.iter().any(|e| e.id == "arrived"))).unwrap();
        w.update(cx, |t, _, _| assert!(t.model.suggestions.is_empty(), "suggestions read again too")).unwrap();
    }

    // parity: DICT-002
    #[flow_ui::gpui::test]
    async fn compact_narrows_the_search(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.searchToggle");
        let width = |cx: &mut TestAppContext| cx.update_window(w.into(), |_, win, _| win.find("vocabulary.searchField").bounds().size.width).unwrap();
        assert_eq!(width(cx), px(150.));
        cx.update(|cx| cx.global_mut::<Flow>().compact = true);
        cx.update_window(w.into(), |_, _, cx| cx.refresh_windows()).unwrap();
        frame(cx, w);
        assert_eq!(width(cx), px(90.));
    }

    // parity: DICT-040
    #[flow_ui::gpui::test]
    async fn non_ascii_terms_sort_after_z(cx: &mut TestAppContext) {
        let w = open(cx);
        cx.update(|cx| {
            let db = cx.global::<Core>().db.as_ref().unwrap();
            let e = Entry { id: "z-last".into(), canonical: "Éclair".into(), aliases: vec![], enabled: true, learned_at: None };
            flow_core::dictionary::save(db, &e, None, "established").unwrap();
        });
        w.update(cx, |t, _, cx| t.refresh(cx)).unwrap();
        frame(cx, w);
        w.update(cx, |t, _, _| {
            assert_eq!(t.model.entries.last().unwrap().canonical, "Éclair");
            assert!(t.model.entries.windows(2).take(t.model.entries.len() - 2).all(|p| p[0].canonical.to_lowercase() <= p[1].canonical.to_lowercase()));
        })
        .unwrap();
    }

    // parity: DICT-047 DICT-128
    #[flow_ui::gpui::test]
    async fn saving_turns_off_every_write(cx: &mut TestAppContext) {
        let w = open(cx);
        let writes = ["vocabulary.suggestion.add.0", "dictionary.edit.0", "dictionary.toggle.0", "dictionary.delete.0", "dictionary.alias.restore.0.0", "vocabulary.add"];
        for id in writes {
            assert_ne!(disabled(cx, w, id), Some(true), "{id}");
        }
        state(cx, w, |t| t.model.saving = true);
        for id in writes {
            assert_eq!(disabled(cx, w, id), Some(true), "{id}");
        }
        // The click does nothing either: the retired alias stays retired.
        click(cx, w, "dictionary.alias.restore.0.0");
        assert_saw(&["Restore \u{2018}akme robotics\u{2019}"]);
        // Save, with a draft that could otherwise be saved.
        state(cx, w, |t| t.model.saving = false);
        click(cx, w, "dictionary.edit.1");
        assert_ne!(disabled(cx, w, "vocabulary.save"), Some(true), "a filled draft");
        state(cx, w, |t| t.model.saving = true);
        assert_eq!(disabled(cx, w, "vocabulary.save"), Some(true), "while saving");
    }

    // parity: DICT-013
    #[flow_ui::gpui::test]
    async fn a_regular_pill_is_13_ink_and_28_tall(cx: &mut TestAppContext) {
        let w = open(cx);
        let ink = cx.update(|cx| pal(cx).ink);
        let s = flow_ui::probe::style_of("Dismiss").unwrap();
        assert_eq!((s.size, s.color), (13., ink));
        assert_eq!(bounds(cx, w, "dictionary.edit.0").size.height, px(7. + 13. + 7.), "7 around a headless Figtree 13 line");
    }

    // parity: DICT-058
    #[flow_ui::gpui::test]
    async fn the_list_holds_every_row_inside_its_border(cx: &mut TestAppContext) {
        let w = open(cx);
        let (list, first) = (bounds(cx, w, "vocabulary.list"), bounds(cx, w, "dictionary.row.0"));
        assert_eq!(first.origin.y, list.origin.y, "the 1 pt border takes no layout");
        let count = w.update(cx, |t, _, _| t.model.entries.len()).unwrap();
        let last = bounds(cx, w, &format!("dictionary.row.{}", count - 1));
        assert_eq!(last.bottom(), list.bottom(), "no divider after the last");
    }

    // parity: DICT-063
    #[flow_ui::gpui::test]
    async fn an_entry_row_has_its_padding_height_and_ink(cx: &mut TestAppContext) {
        let w = open(cx);
        let (ink, muted) = cx.update(|cx| (pal(cx).ink, pal(cx).muted));
        let entries = w.update(cx, |t, _, _| t.model.entries.clone()).unwrap();
        let on = entries.iter().find(|e| e.enabled && e.aliases.is_empty()).unwrap();
        let off = entries.iter().find(|e| !e.enabled).unwrap();
        let (on_style, off_style) = (flow_ui::probe::style_of(&on.canonical).unwrap(), flow_ui::probe::style_of(&off.canonical).unwrap());
        assert_eq!((on_style.size, on_style.color), (15., ink), "enabled");
        assert_eq!((off_style.size, off_style.color), (15., muted), "disabled");
        for i in 0..entries.len() {
            assert!(bounds(cx, w, &format!("dictionary.row.{i}")).size.height >= px(53.), "row {i}");
        }
        let (row, delete) = (bounds(cx, w, "dictionary.row.1"), bounds(cx, w, "dictionary.delete.1"));
        assert_eq!(row.right() - delete.right(), px(18.), "18 at the side");
        assert_eq!(delete.top() - row.top(), px(10.), "10 on top");
    }

    // parity: DICT-103 DICT-117
    #[flow_ui::gpui::test]
    async fn a_word_alone_has_its_placeholder_and_its_error_below(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        w.update(cx, |t, win, cx| {
            t.model.set_correcting(false);
            t.sync_fields(win, cx);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        let placeholder = cx.update_window(w.into(), |_, win, _| win.find_by_label("Word").placeholder().map(str::to_string)).unwrap();
        assert_eq!(placeholder.as_deref(), Some("Word"));
        let canonical = w.update(cx, |t, _, _| t.canonical.clone().unwrap()).unwrap();
        type_into(cx, w, canonical, "two  spaces");
        cx.update_window(w.into(), |_, win, cx| win.press("enter", cx)).unwrap();
        frame(cx, w);
        assert_saw(&["Separate words with single spaces."]);
        let (error, field) = (bounds(cx, w, "vocabulary.canonicalError"), bounds(cx, w, "vocabulary.canonical.box"));
        assert_eq!(error.origin.y - field.bottom(), px(4.), "below the Word field");
    }

    // parity: DICT-057
    #[flow_ui::gpui::test]
    async fn unreadable_suggestions_stay_quiet(cx: &mut TestAppContext) {
        let w = open(cx);
        assert_saw(&["Suggested"]);
        let dropped = cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute_batch("DROP TABLE term_suggestions"));
        assert!(dropped.is_ok(), "the table must exist for this to be a read failure: {dropped:?}");
        w.update(cx, |t, _, cx| {
            t.model.refresh(cx.global::<Core>().db.as_ref().unwrap(), |_| false);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        assert!(!saw("Suggested"));
        w.update(cx, |t, _, _| assert!(t.model.load_error.is_none())).unwrap();
    }

    // parity: DICT-062
    #[flow_ui::gpui::test]
    async fn before_the_load_add_stays_off(cx: &mut TestAppContext) {
        let w = open(cx);
        state(cx, w, |t| {
            t.model.loaded = false;
            t.model.entries.clear();
        });
        assert_eq!(disabled(cx, w, "vocabulary.add"), Some(true));
        assert_saw(&["No words yet"]);
    }

    // parity: DICT-068 DICT-070
    #[flow_ui::gpui::test]
    async fn learned_rows_show_their_marks(cx: &mut TestAppContext) {
        let w = open(cx);
        let ids: Vec<(usize, bool, bool)> = w.update(cx, |t, _, _| t.model.entries.iter().enumerate().map(|(i, e)| (i, t.model.is_provisional(e), e.learned_at.is_some())).collect()).unwrap();
        for (i, learning, learned) in ids {
            let has = |cx: &mut TestAppContext, part: &str| {
                let id = SharedString::from(format!("dictionary.{part}.{i}"));
                cx.update_window(w.into(), |_, win, _| win.try_find(id).is_some()).unwrap()
            };
            assert_eq!(has(cx, "learning"), learning, "row {i}");
            assert_eq!(has(cx, "learned"), learned, "row {i}");
        }
    }

    // parity: DICT-083
    #[flow_ui::gpui::test]
    async fn tab_reaches_row_actions_and_keeps_them_visible(cx: &mut TestAppContext) {
        let w = open(cx);
        w.update(cx, |t, win, cx| t.focus.focus(win, cx)).unwrap();
        let mut reached = false;
        for _ in 0..30 {
            cx.update_window(w.into(), |_, win, cx| win.press("tab", cx)).unwrap();
            reached = cx.update_window(w.into(), |_, win, _| win.find("dictionary.edit.0").focused()).unwrap() == Some(true);
            if reached {
                break;
            }
        }
        assert!(reached);
        assert!(w.update(cx, |t, win, cx| t.action_focus.borrow()[&0].contains_focused(win, cx)).unwrap());
    }

    // parity: DICT-084 DICT-095 DICT-103
    #[flow_ui::gpui::test]
    async fn edit_opens_filled_and_focuses_the_word(cx: &mut TestAppContext) {
        let w = open(cx);
        let e = w.update(cx, |t, _, _| t.model.entries[0].clone()).unwrap();
        let label = cx.update_window(w.into(), |_, win, _| win.find("dictionary.edit.0").label().map(str::to_string)).unwrap();
        assert_eq!(label, Some(format!("Edit {}", e.canonical)));
        state(cx, w, |t| {
            t.model.status = Some("old".into());
        });
        click(cx, w, "dictionary.edit.0");
        w.update(cx, |t, win, cx| {
            let d = t.model.draft.as_ref().unwrap();
            assert_eq!(d.id.as_deref(), Some(e.id.as_str()));
            assert!(t.model.status.is_none());
            if e.aliases.is_empty() {
                assert!(t.canonical.as_ref().unwrap().read(cx).focus_handle(cx).is_focused(win));
            } else {
                assert!(t.aliases[0].read(cx).focus_handle(cx).is_focused(win));
            }
        })
        .unwrap();
    }

    // parity: DICT-096 DICT-103 DICT-105
    #[flow_ui::gpui::test]
    async fn switching_mode_moves_focus_and_fields(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        // Add opens in misspelling mode on the first alias.
        w.update(cx, |t, win, cx| assert!(t.aliases[0].read(cx).focus_handle(cx).is_focused(win))).unwrap();
        click(cx, w, "vocabulary.correctMisspelling");
        w.update(cx, |t, win, cx| {
            assert!(t.aliases.is_empty());
            assert!(t.canonical.as_ref().unwrap().read(cx).focus_handle(cx).is_focused(win));
        })
        .unwrap();
        click(cx, w, "vocabulary.correctMisspelling");
        click(cx, w, "vocabulary.addAlias");
        w.update(cx, |t, _, _| assert_eq!(t.aliases.len(), 2)).unwrap();
        assert_saw(&["Add another misspelling"]);
        assert!(cx.update_window(w.into(), |_, win, _| win.try_find("vocabulary.removeAlias.1").is_some()).unwrap());
    }

    // parity: DICT-101
    #[flow_ui::gpui::test]
    async fn enabled_switch_is_written_on_save(cx: &mut TestAppContext) {
        let w = open(cx);
        let id = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| e.enabled).unwrap().id.clone()).unwrap();
        let i = w.update(cx, |t, _, _| t.model.entries.iter().position(|e| e.id == id).unwrap()).unwrap();
        click(cx, w, &format!("dictionary.edit.{i}"));
        click(cx, w, "vocabulary.enabled");
        assert!(stored(cx).iter().find(|e| e.id == id).unwrap().enabled);
        click(cx, w, "vocabulary.save");
        assert!(!stored(cx).iter().find(|e| e.id == id).unwrap().enabled);
    }

    // parity: DICT-106 DICT-116
    #[flow_ui::gpui::test]
    async fn sheet_shows_one_error_and_edits_clear_them(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        state(cx, w, |t| {
            t.model.field_errors.insert(Field::Entry, "entry problem".into());
            t.model.field_errors.insert(Field::Store, "store problem".into());
            t.model.field_errors.insert(Field::Aliases, "aliases problem".into());
        });
        assert_saw(&["entry problem"]);
        assert!(!saw("store problem") && !saw("aliases problem"));
        state(cx, w, |t| {
            t.model.field_errors.remove(&Field::Entry);
        });
        assert_saw(&["store problem"]);
        assert!(!saw("aliases problem"));
        state(cx, w, |t| {
            t.model.field_errors.remove(&Field::Store);
            t.model.field_errors.insert(Field::Canonical, "bad word".into());
            t.model.field_errors.insert(Field::Alias(0), "bad alias".into());
        });
        assert_saw(&["aliases problem"]);
        // An alias edit clears that alias's error and the aliases error; a word edit clears its own.
        state(cx, w, |t| t.model.set_alias("x".into(), 0));
        w.update(cx, |t, _, _| {
            assert!(!t.model.field_errors.contains_key(&Field::Alias(0)) && !t.model.field_errors.contains_key(&Field::Aliases));
            assert!(t.model.field_errors.contains_key(&Field::Canonical));
        })
        .unwrap();
        state(cx, w, |t| t.model.set_canonical("y".into()));
        w.update(cx, |t, _, _| assert!(!t.model.field_errors.contains_key(&Field::Canonical))).unwrap();
    }

    // parity: DICT-092
    #[flow_ui::gpui::test]
    async fn status_stays_below_the_list(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "dictionary.toggle.0");
        let status = w.update(cx, |t, _, _| t.model.status.clone()).unwrap().expect("a write leaves a status");
        assert_saw(&[&status]);
        cx.executor().advance_clock(std::time::Duration::from_secs(600));
        frame(cx, w);
        assert_saw(&[&status]);
    }

    // parity: DICT-088
    #[flow_ui::gpui::test]
    async fn the_row_menu_runs_the_row_actions(cx: &mut TestAppContext) {
        let w = open(cx);
        let menu = |cx: &mut TestAppContext, item: usize| {
            cx.update_window(w.into(), |_, win, cx| win.right_click("dictionary.edit.0", cx)).unwrap();
            frame(cx, w);
            cx.update_window(w.into(), |_, win, cx| win.click(ElementId::Integer(item as u64), cx)).unwrap();
            frame(cx, w);
        };
        let first = w.update(cx, |t, _, _| t.model.entries[0].clone()).unwrap();
        menu(cx, 1);
        assert_eq!(stored(cx).iter().find(|e| e.id == first.id).unwrap().enabled, !first.enabled);
        menu(cx, 0);
        w.update(cx, |t, _, _| assert_eq!(t.model.draft.as_ref().unwrap().id.as_deref(), Some(first.id.as_str()))).unwrap();
        click(cx, w, "vocabulary.cancel");
        menu(cx, 2);
        w.update(cx, |t, _, _| assert_eq!(t.confirming_delete.as_ref().map(|e| e.id.clone()), Some(first.id.clone()))).unwrap();
    }

    fn bounds(cx: &mut TestAppContext, w: WindowHandle<DictionaryPage>, id: &str) -> Bounds<Pixels> {
        let id = SharedString::from(id.to_string());
        cx.update_window(w.into(), |_, win, _| win.find(id).bounds()).unwrap()
    }

    // parity: DICT-015
    #[flow_ui::gpui::test]
    async fn a_filter_tab_is_label_gap_and_underline(cx: &mut TestAppContext) {
        let w = open(cx);
        let tab = bounds(cx, w, "vocabulary.filter.disabled");
        // Headless Figtree 15 is a 16 line, then spacing 6 and the 2 pt underline.
        assert_eq!(tab.size.height, px(16. + 6. + 2.));
    }

    // parity: DICT-021 DICT-023
    #[flow_ui::gpui::test]
    async fn the_search_field_is_150_wide_8_before_the_icon_and_90_when_compact(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.searchToggle");
        let (field, toggle) = (bounds(cx, w, "vocabulary.searchField"), bounds(cx, w, "vocabulary.searchToggle"));
        assert_eq!(field.size.width, px(150.));
        assert_eq!(toggle.origin.x - field.right(), px(8.));
        let add = bounds(cx, w, "vocabulary.add");
        assert_eq!(toggle.right(), add.right(), "right aligned with the page");
        cx.update(|cx| cx.global_mut::<Flow>().compact = true);
        w.update(cx, |_, _, cx| cx.notify()).unwrap();
        frame(cx, w);
        assert_eq!(bounds(cx, w, "vocabulary.searchField").size.width, px(90.));
    }

    // parity: DICT-032
    #[flow_ui::gpui::test]
    async fn the_banner_dismiss_sits_12_in_from_the_trailing_edge(cx: &mut TestAppContext) {
        let w = open(cx);
        let (dismiss, add) = (bounds(cx, w, "vocabulary.bannerDismiss"), bounds(cx, w, "vocabulary.add"));
        assert_eq!(add.right() - dismiss.right(), px(12.));
        assert_eq!(dismiss.size.width, dismiss.size.height, "a circle");
    }

    // parity: DICT-071
    #[flow_ui::gpui::test]
    async fn the_off_badge_has_its_padding(cx: &mut TestAppContext) {
        let w = open(cx);
        let i = w.update(cx, |t, _, _| t.model.entries.iter().position(|e| !e.enabled).unwrap()).unwrap();
        let badge = bounds(cx, w, &format!("dictionary.off.{i}"));
        // Headless Figtree 11 is a 12 line, with 2 above and below.
        assert_eq!(badge.size.height, px(12. + 2. + 2.));
    }

    // parity: DICT-082
    #[flow_ui::gpui::test]
    async fn row_actions_are_4_apart_and_right_aligned(cx: &mut TestAppContext) {
        let w = open(cx);
        let (edit, toggle, delete) = (bounds(cx, w, "dictionary.edit.0"), bounds(cx, w, "dictionary.toggle.0"), bounds(cx, w, "dictionary.delete.0"));
        assert_eq!(toggle.origin.x - edit.right(), px(4.));
        assert_eq!(delete.origin.x - toggle.right(), px(4.));
        // The row's 18 trailing padding; the list ends at the page's right edge.
        assert_eq!(bounds(cx, w, "vocabulary.add").right() - delete.right(), px(18.));
    }

    // parity: DICT-120
    #[flow_ui::gpui::test]
    async fn sheet_rows_keep_their_spacing(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        let (cancel, save) = (bounds(cx, w, "vocabulary.cancel"), bounds(cx, w, "vocabulary.save"));
        let field = bounds(cx, w, "vocabulary.canonical.box");
        assert_eq!(field.size.height, px(29.), "Swift's field, measured from the pair");
        assert_eq!(save.origin.x - cancel.right(), px(8.));
    }

    // parity: DICT-007
    #[flow_ui::gpui::test]
    async fn a_store_change_elsewhere_reloads_while_shown(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(crate::shell::ensure_session);
        let w = cx.add_window(|w, cx| DictionaryPage::new(w, cx));
        frame(cx, w);
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Dictionary));
        cx.run_until_parked();
        let (before, gone) = w.update(cx, |t, _, _| (t.model.entries.len(), t.model.entries[0].id.clone())).unwrap();
        cx.update(|cx| {
            flow_core::dictionary::delete(cx.global::<Core>().db.as_ref().unwrap(), &gone, None).unwrap();
            crate::shell::history_changed(cx);
        });
        cx.run_until_parked();
        assert!(w.update(cx, |t, _, _| t.model.entries.len()).unwrap() < before);
    }

    // Round 4: what the page actually draws, read back through the row buttons' labels.
    fn shown(cx: &mut TestAppContext, w: WindowHandle<DictionaryPage>) -> Vec<String> {
        cx.update_window(w.into(), |_, win, _| {
            (0..)
                .map_while(|i| win.try_find(SharedString::from(format!("dictionary.edit.{i}"))))
                .map(|s| s.label().unwrap().trim_start_matches("Edit ").to_string())
                .collect()
        })
        .unwrap()
    }

    fn label(cx: &mut TestAppContext, w: WindowHandle<DictionaryPage>, id: &str) -> Option<String> {
        let id = SharedString::from(id.to_string());
        cx.update_window(w.into(), |_, win, _| win.find(id).label().map(str::to_string)).unwrap()
    }

    // parity: DICT-017 DICT-018 DICT-019 DICT-020
    /// Each filter shows exactly the store's matching rows, not just one example.
    #[flow_ui::gpui::test]
    async fn each_filter_shows_exactly_its_entries(cx: &mut TestAppContext) {
        let w = open(cx);
        let all = stored(cx);
        let names = |keep: &dyn Fn(&Entry) -> bool| {
            let mut v: Vec<String> = all.iter().filter(|e| keep(e)).map(|e| e.canonical.clone()).collect();
            v.sort();
            v
        };
        let sorted = |mut v: Vec<String>| {
            v.sort();
            v
        };
        let got = shown(cx, w);
        assert_eq!(sorted(got), names(&|_| true), "All");
        assert!(names(&|_| true).len() == 7);
        click(cx, w, "vocabulary.filter.enabled");
        assert_eq!(sorted(shown(cx, w)), names(&|e| e.enabled), "Enabled");
        click(cx, w, "vocabulary.filter.disabled");
        assert_eq!(sorted(shown(cx, w)), names(&|e| !e.enabled), "Disabled");
        assert_eq!(shown(cx, w), ["Northwind"]);
        click(cx, w, "vocabulary.filter.learned");
        assert_eq!(sorted(shown(cx, w)), names(&|e| e.learned_at.is_some()), "Learned");
        assert_eq!(shown(cx, w), ["Kubernetes", "Qwen"]);
    }

    // parity: DICT-015
    /// Selected: medium, ink, selected trait. Unselected: regular, muted.
    #[flow_ui::gpui::test]
    async fn a_filter_tab_reads_selected_or_not(cx: &mut TestAppContext) {
        let w = open(cx);
        let (ink, muted) = cx.update(|cx| (pal(cx).ink, pal(cx).muted));
        let all = flow_ui::probe::style_of("All").unwrap();
        assert_eq!((all.size, all.weight, all.color), (15., 500., ink));
        let learned = flow_ui::probe::style_of("Learned").unwrap();
        assert_eq!((learned.size, learned.weight, learned.color), (15., 400., muted));
        click(cx, w, "vocabulary.filter.learned");
        let learned = flow_ui::probe::style_of("Learned").unwrap();
        assert_eq!((learned.weight, learned.color), (500., ink));
        let all = flow_ui::probe::style_of("All").unwrap();
        assert_eq!((all.weight, all.color), (400., muted));
    }

    // parity: DICT-021 DICT-022
    #[flow_ui::gpui::test]
    async fn the_search_toggle_is_a_muted_magnifier_and_closing_clears_the_query(cx: &mut TestAppContext) {
        let w = open(cx);
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "magnifyingglass"));
        assert_eq!(label(cx, w, "vocabulary.searchToggle").as_deref(), Some("Search"));
        assert!(cx.update_window(w.into(), |_, win, _| win.try_find("vocabulary.searchField").is_none()).unwrap(), "closed at first");
        click(cx, w, "vocabulary.searchToggle");
        let field = w.update(cx, |t, _, _| t.search.clone()).unwrap();
        type_into(cx, w, field, "kube");
        assert_eq!(shown(cx, w), ["Kubernetes"]);
        click(cx, w, "vocabulary.searchToggle");
        assert!(cx.update_window(w.into(), |_, win, _| win.try_find("vocabulary.searchField").is_none()).unwrap());
        w.update(cx, |t, _, cx| assert_eq!(t.search.read(cx).value().to_string(), "")).unwrap();
        assert_eq!(shown(cx, w).len(), 7);
        click(cx, w, "vocabulary.searchToggle");
        w.update(cx, |t, _, cx| assert_eq!(t.search.read(cx).value().to_string(), "", "reopens blank")).unwrap();
    }

    // parity: DICT-023
    /// Accessibility label and placeholder; the identifier itself is checked from the AX dump.
    #[flow_ui::gpui::test]
    async fn the_search_field_is_not_focused_and_ignores_escape(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.searchToggle");
        cx.update_window(w.into(), |_, win, _| {
            let f = win.find_by_label("Search dictionary");
            assert_eq!(f.placeholder(), Some("Search"));
            assert_ne!(f.focused(), Some(true), "no autofocus");
        })
        .unwrap();
        // No Esc handler: Escape leaves the field open.
        let field = w.update(cx, |t, _, _| t.search.clone()).unwrap();
        type_into(cx, w, field, "qw");
        cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
        frame(cx, w);
        w.update(cx, |t, _, cx| {
            assert!(t.searching);
            assert_eq!(t.search.read(cx).value().to_string(), "qw");
        })
        .unwrap();
    }

    // parity: DICT-024
    /// Trimmed, folded, contiguous, against canonical and every alias, together with the filter.
    #[flow_ui::gpui::test]
    async fn search_matches_folded_terms_and_aliases_with_the_filter(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.searchToggle");
        let query = |cx: &mut TestAppContext, q: &str| {
            let field = w.update(cx, |t, _, _| t.search.clone()).unwrap();
            let text = q.to_string();
            w.update(cx, |_, win, cx| field.update(cx, |s, cx| s.set_value(text, win, cx))).unwrap();
            frame(cx, w);
            shown(cx, w)
        };
        assert_eq!(query(cx, "BRUNEL"), ["Brunel"], "case folded");
        assert_eq!(query(cx, "  brunel  "), ["Brunel"], "trimmed");
        assert_eq!(query(cx, "cube ne"), ["Kubernetes"], "an alias, not the canonical");
        assert_eq!(query(cx, "kwen"), ["Qwen"], "the second alias");
        assert!(query(cx, "brnl").is_empty(), "contiguous, not a subsequence");
        assert!(query(cx, "zurich").is_empty(), "no diacritic folding");
        assert_eq!(query(cx, "ZÜR"), ["Zürich"]);
        assert_eq!(query(cx, "n"), ["Brunel", "Kubernetes", "Northwind", "Qwen", "Tallinn"]);
        click(cx, w, "vocabulary.filter.disabled");
        assert_eq!(query(cx, "n"), ["Northwind"], "with the filter");
    }

    // parity: DICT-030 DICT-010
    #[flow_ui::gpui::test]
    async fn the_banner_button_begins_an_add_like_add_new(cx: &mut TestAppContext) {
        let w = open(cx);
        assert_ne!(disabled(cx, w, "vocabulary.bannerAdd"), Some(true));
        click(cx, w, "vocabulary.bannerAdd");
        assert_saw(&["Add to vocabulary"]);
        w.update(cx, |t, _, _| assert_eq!(t.model.draft.as_ref().unwrap().id, None)).unwrap();
        click(cx, w, "vocabulary.cancel");
        state(cx, w, |t| t.model.saving = true);
        assert_eq!(disabled(cx, w, "vocabulary.bannerAdd"), Some(true), "saving");
        assert_eq!(disabled(cx, w, "vocabulary.add"), Some(true), "saving");
        state(cx, w, |t| t.model.saving = false);
        assert_ne!(disabled(cx, w, "vocabulary.add"), Some(true));
    }

    // parity: DICT-031
    #[flow_ui::gpui::test]
    async fn the_full_notice_is_12_white_at_85(cx: &mut TestAppContext) {
        let _w = open(cx);
        assert!(!saw("Dictionary is full"), "not below the limit");
        let w = open_scenario(cx, "dictionary.full");
        let s = flow_ui::probe::style_of("Dictionary is full (512 words).").unwrap();
        assert_eq!((s.size, s.color), (12., white().opacity(0.85)));
        assert_eq!(disabled(cx, w, "vocabulary.bannerAdd"), Some(true));
    }

    // parity: DICT-033 DICT-034
    /// Stays hidden on a page built afterwards, and no control offers it back.
    #[flow_ui::gpui::test]
    async fn a_dismissed_banner_stays_hidden_on_the_next_page(cx: &mut TestAppContext) {
        let w = open(cx);
        assert_eq!(label(cx, w, "vocabulary.bannerDismiss").as_deref(), Some("Dismiss introduction"));
        click(cx, w, "vocabulary.bannerDismiss");
        cx.update(|cx| assert!(cx.global::<Core>().prefs.bool_or("dictionary.bannerDismissed", false)));
        let again = cx.add_window(|w, cx| DictionaryPage::new(w, cx));
        frame(cx, again);
        assert!(!saw("LocalFlow spells"));
        assert!(cx.update_window(again.into(), |_, win, _| win.try_find("vocabulary.bannerAdd").is_none()).unwrap());
        assert_saw(&["Dictionary", "All"]);
    }

    // parity: DICT-035 DICT-036
    /// A real failed reload: the error is 13 warning under its identifier, the rows already loaded stay.
    #[flow_ui::gpui::test]
    async fn a_failed_reload_shows_the_error_and_keeps_the_rows(cx: &mut TestAppContext) {
        let w = open(cx);
        let before = shown(cx, w);
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute("UPDATE vocabulary_entries SET canonical_text='Omega' WHERE canonical_text='Brunel'", []).unwrap());
        w.update(cx, |t, _, cx| {
            t.refresh(cx);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        let copy = "Preferred spellings could not be loaded. Repair or delete entries in Settings.";
        let s = flow_ui::probe::style_of(copy).unwrap();
        let warning = cx.update(|cx| pal(cx).warning);
        assert_eq!((s.size, s.color), (13., warning));
        // Top padding 24 over a 13 text's headless 14 line.
        assert_eq!(bounds(cx, w, "vocabulary.loadErrorLine").size.height, px(24. + 14.));
        assert_eq!(shown(cx, w), before, "earlier entries stay");
        assert_eq!(disabled(cx, w, "vocabulary.add"), Some(true));
        assert!(!saw("Suggested"), "DICT-057: no suggestions on a load error");
    }

    // parity: DICT-042
    /// Only with All, an empty search and suggestions to show.
    #[flow_ui::gpui::test]
    async fn suggested_needs_all_an_empty_search_and_suggestions(cx: &mut TestAppContext) {
        let w = open(cx);
        assert_saw(&["Suggested"]);
        click(cx, w, "vocabulary.filter.enabled");
        assert!(!saw("Suggested"), "another filter");
        click(cx, w, "vocabulary.filter.all");
        assert_saw(&["Suggested"]);
        click(cx, w, "vocabulary.searchToggle");
        assert_saw(&["Suggested"]);
        let field = w.update(cx, |t, _, _| t.search.clone()).unwrap();
        type_into(cx, w, field, "b");
        assert!(!saw("Suggested"), "a search");
        click(cx, w, "vocabulary.searchToggle");
        assert_saw(&["Suggested"]);
        state(cx, w, |t| t.model.suggestions.clear());
        assert!(!saw("Suggested"), "none");
    }

    // parity: DICT-044 DICT-045 DICT-048
    #[flow_ui::gpui::test]
    async fn suggestion_rows_read_their_source_and_their_buttons(cx: &mut TestAppContext) {
        let w = open(cx);
        let (s, muted) = (flow_ui::probe::style_of("You corrected this").unwrap(), cx.update(|cx| pal(cx).muted));
        assert_eq!((s.size, s.color), (12., muted));
        let first = w.update(cx, |t, _, _| t.model.suggestions[0].canonical.clone()).unwrap();
        assert_eq!(first, "Figtree", "most sightings first");
        assert_eq!(label(cx, w, "vocabulary.suggestion.add.0"), Some("Add Figtree".to_string()));
        assert_eq!(label(cx, w, "vocabulary.suggestion.dismiss.0"), Some("Dismiss Figtree".to_string()));
        assert_saw(&["fig tree", "Add", "Dismiss"]);
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "arrow.right"));
        state(cx, w, |t| {
            t.model.suggestions[0].source = Source::Context;
            t.model.suggestions[0].sightings = 4;
        });
        assert_saw(&["Seen in 4 dictations"]);
        state(cx, w, |t| t.model.saving = true);
        assert_eq!(disabled(cx, w, "vocabulary.suggestion.add.0"), Some(true));
        assert_ne!(disabled(cx, w, "vocabulary.suggestion.dismiss.0"), Some(true), "Dismiss stays enabled while saving");
    }

    // parity: DICT-046 DICT-047
    #[flow_ui::gpui::test]
    async fn adding_a_suggestion_opens_the_sheet_and_saving_governs_the_term(cx: &mut TestAppContext) {
        let w = open(cx);
        let count = stored(cx).len();
        click(cx, w, "vocabulary.suggestion.add.0");
        w.update(cx, |t, _, _| {
            let d = t.model.draft.as_ref().unwrap();
            assert_eq!((d.canonical.as_str(), d.aliases.as_slice()), ("Figtree", &["fig tree".to_string()][..]));
            assert!(t.model.is_correcting());
        })
        .unwrap();
        assert_eq!(stored(cx).len(), count, "nothing persists until save");
        click(cx, w, "vocabulary.save");
        assert!(stored(cx).iter().any(|e| e.canonical == "Figtree" && e.aliases == ["fig tree"]));
        w.update(cx, |t, _, _| assert!(t.model.suggestions.iter().all(|s| s.canonical != "Figtree"), "now governed")).unwrap();
        // The one with no alias opens with misspelling mode off.
        click(cx, w, "vocabulary.suggestion.add.0");
        w.update(cx, |t, _, _| {
            assert_eq!(t.model.draft.as_ref().unwrap().canonical, "Garamond");
            assert!(!t.model.is_correcting() && t.aliases.is_empty());
        })
        .unwrap();
        click(cx, w, "vocabulary.cancel");
        // `!canAdd`: a full store turns it off too.
        let w = open_scenario(cx, "dictionary.full");
        assert_eq!(disabled(cx, w, "vocabulary.suggestion.add.0"), Some(true));
    }

    // parity: DICT-049
    #[flow_ui::gpui::test]
    async fn dismissing_a_suggestion_writes_it_and_it_stays_gone(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.suggestion.dismiss.0");
        assert!(!saw("Figtree"), "the row goes at once");
        let row: (i64, i64, i64) = cx.update(|cx| {
            cx.global::<Core>().db.as_ref().unwrap().conn.query_row("SELECT dismissed, sightings, last_seen FROM term_suggestions WHERE canonical='Figtree'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap()
        });
        assert_eq!((row.0, row.1), (1, 2), "dismissed, sightings kept on conflict");
        assert!(row.2 > 0);
        w.update(cx, |t, _, cx| t.refresh(cx)).unwrap();
        frame(cx, w);
        assert!(!saw("Figtree"));
    }

    // parity: DICT-059 DICT-060 DICT-061
    /// Three empty copies: 15 muted, 60 above and below, each on its own condition.
    #[flow_ui::gpui::test]
    async fn the_empty_texts_share_a_style_and_keep_60_around_them(cx: &mut TestAppContext) {
        let muted_of = |cx: &mut TestAppContext| cx.update(|cx| pal(cx).muted);
        let w = open_scenario(cx, "dictionary.empty");
        let muted = muted_of(cx);
        let s = flow_ui::probe::style_of("No words yet").unwrap();
        assert_eq!((s.size, s.color), (15., muted));
        // Headless Figtree 15 is a 16 line.
        assert_eq!(bounds(cx, w, "vocabulary.empty").size.height, px(60. + 16. + 60.));
        let w = open(cx);
        click(cx, w, "vocabulary.filter.learned");
        state(cx, w, |t| t.model.entries.retain(|e| e.learned_at.is_none()));
        let s = flow_ui::probe::style_of("Nothing here").unwrap();
        assert_eq!((s.size, s.color), (15., muted));
        click(cx, w, "vocabulary.filter.all");
        click(cx, w, "vocabulary.searchToggle");
        let field = w.update(cx, |t, _, _| t.search.clone()).unwrap();
        type_into(cx, w, field, "zzz");
        let s = flow_ui::probe::style_of("No matches").unwrap();
        assert_eq!((s.size, s.color), (15., muted));
        assert!(!saw("Nothing here"));
    }

    // parity: DICT-077
    /// Both labels, 11 medium, disabled while saving. The tooltip is a literal the test can't read.
    #[flow_ui::gpui::test]
    async fn restore_buttons_read_their_term_or_boost(cx: &mut TestAppContext) {
        let w = open(cx);
        let s = flow_ui::probe::style_of("Restore \u{2018}akme robotics\u{2019}").unwrap();
        assert_eq!((s.size, s.weight), (11., 500.));
        assert_saw(&["Boost off · Restore"]);
        let i = w.update(cx, |t, _, _| t.model.entries.iter().position(|e| e.canonical == "Tallinn").unwrap()).unwrap();
        assert_eq!(label(cx, w, &format!("dictionary.alias.restore.{i}.0")).as_deref(), Some("Boost off · Restore"));
        assert_ne!(disabled(cx, w, "dictionary.alias.restore.0.0"), Some(true));
        state(cx, w, |t| t.model.saving = true);
        assert_eq!(disabled(cx, w, "dictionary.alias.restore.0.0"), Some(true));
    }

    // parity: DICT-080
    /// All three copies through the button: a term, boost, and a failed write.
    #[flow_ui::gpui::test]
    async fn restore_reports_the_term_the_boost_or_a_failure(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "dictionary.alias.restore.0.0");
        assert_saw(&["Restored akme robotics."]);
        let i = w.update(cx, |t, _, _| t.model.entries.iter().position(|e| e.canonical == "Tallinn").unwrap()).unwrap();
        click(cx, w, &format!("dictionary.alias.restore.{i}.0"));
        assert_saw(&["Listening for Tallinn again."]);
        let z = w.update(cx, |t, _, _| t.model.entries.iter().position(|e| e.canonical == "Zürich").unwrap()).unwrap();
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute_batch("CREATE TRIGGER no_usage BEFORE UPDATE ON dictionary_key_usage BEGIN SELECT RAISE(ABORT, 'no'); END").unwrap());
        click(cx, w, &format!("dictionary.alias.restore.{z}.0"));
        assert_saw(&["Could not restore Zürich. Try again."]);
    }

    // parity: DICT-082 DICT-084 DICT-085 DICT-086 DICT-087
    /// The row's three pills: labels, accessibility names, disabled while saving, what each does.
    #[flow_ui::gpui::test]
    async fn row_pills_name_their_entry_and_do_what_they_say(cx: &mut TestAppContext) {
        let w = open(cx);
        let entries = w.update(cx, |t, _, _| t.model.entries.clone()).unwrap();
        let on = entries.iter().position(|e| e.enabled).unwrap();
        let off = entries.iter().position(|e| !e.enabled).unwrap();
        assert_eq!(label(cx, w, &format!("dictionary.toggle.{on}")), Some(format!("Disable {}", entries[on].canonical)));
        assert_eq!(label(cx, w, &format!("dictionary.toggle.{off}")), Some(format!("Enable {}", entries[off].canonical)));
        assert_eq!(label(cx, w, &format!("dictionary.delete.{on}")), Some(format!("Delete {}", entries[on].canonical)));
        assert_saw(&["Edit", "Disable", "Enable", "Delete"]);
        // Enable: the write, its revision, its copy.
        let revision = |cx: &mut TestAppContext| w.update(cx, |t, _, _| t.model.revision).unwrap();
        let hash = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.query_row("SELECT content_hash FROM vocabulary_state WHERE id=1", [], |r| r.get::<_, String>(0)).unwrap());
        let (r0, h0) = (revision(cx), hash(cx));
        click(cx, w, &format!("dictionary.toggle.{off}"));
        assert_saw(&["Entry enabled."]);
        assert!(stored(cx).iter().find(|e| e.id == entries[off].id).unwrap().enabled);
        assert_eq!(revision(cx), r0 + 1);
        assert_ne!(hash(cx), h0);
        click(cx, w, &format!("dictionary.toggle.{off}"));
        assert_saw(&["Entry disabled."]);
        // Delete only asks.
        let count = stored(cx).len();
        click(cx, w, &format!("dictionary.delete.{on}"));
        w.update(cx, |t, _, _| assert_eq!(t.confirming_delete.as_ref().unwrap().id, entries[on].id)).unwrap();
        assert_eq!(stored(cx).len(), count, "no write");
        cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
        frame(cx, w);
        // While saving the pills are off, and the model ignores an edit anyway.
        state(cx, w, |t| t.model.saving = true);
        for part in ["edit", "toggle", "delete"] {
            assert_eq!(disabled(cx, w, &format!("dictionary.{part}.{on}")), Some(true), "{part}");
        }
        w.update(cx, |t, _, _| {
            let e = t.model.entries[on].clone();
            t.model.begin_edit(&e);
            assert!(t.model.draft.is_none(), "Ignored while saving");
        })
        .unwrap();
    }

    // parity: DICT-084
    /// Id, canonical, aliases, enabled, `learnedAt` carried; errors and status cleared.
    #[flow_ui::gpui::test]
    async fn edit_carries_the_whole_entry(cx: &mut TestAppContext) {
        let w = open(cx);
        let (i, e) = w.update(cx, |t, _, _| t.model.entries.iter().enumerate().find(|(_, e)| e.canonical == "Qwen").map(|(i, e)| (i, e.clone())).unwrap()).unwrap();
        state(cx, w, |t| {
            t.model.status = Some("old".into());
            t.model.field_errors.insert(Field::Store, "old".into());
        });
        click(cx, w, &format!("dictionary.edit.{i}"));
        w.update(cx, |t, _, _| {
            let d = t.model.draft.as_ref().unwrap();
            assert_eq!((d.id.as_ref(), &d.canonical, &d.aliases, d.enabled, d.learned_at), (Some(&e.id), &e.canonical, &e.aliases, e.enabled, e.learned_at));
            assert!(e.learned_at.is_some());
            assert!(t.model.field_errors.is_empty() && t.model.status.is_none());
        })
        .unwrap();
        assert_saw(&["Edit vocabulary", "Save"]);
    }

    // parity: DICT-083
    /// Actions stay in the tree without a hover, and `voice_over` comes from Services. The opacity
    /// itself can't be read headless: it lives in `hover_or_focus_revealed`.
    #[flow_ui::gpui::test]
    async fn row_actions_stay_tabbable_while_hidden(cx: &mut TestAppContext) {
        let w = open(cx);
        for id in ["dictionary.edit.0", "dictionary.toggle.0", "dictionary.delete.0"] {
            assert!(cx.update_window(w.into(), |_, win, _| win.try_find(id).is_some()).unwrap(), "{id}");
        }
        w.update(cx, |t, _, _| assert!(!t.voice_over)).unwrap();
        // Focus on the page itself is not focus on any row's actions, so no row reveals.
        w.update(cx, |t, win, cx| {
            t.focus.focus(win, cx);
            assert!(t.action_focus.borrow().values().all(|f| !f.contains_focused(win, cx)));
        })
        .unwrap();
    }

    // parity: DICT-089 DICT-090
    #[flow_ui::gpui::test]
    async fn deleting_reads_the_dialog_removes_the_rows_and_closes_the_draft(cx: &mut TestAppContext) {
        let w = open(cx);
        let i = w.update(cx, |t, _, _| t.model.entries.iter().position(|e| e.canonical == "Brunel").unwrap()).unwrap();
        let id = stored(cx).into_iter().find(|e| e.canonical == "Brunel").unwrap().id;
        click(cx, w, &format!("dictionary.delete.{i}"));
        assert_saw(&["Delete this word?", "Past transcriptions keep their spelling.", "Delete word", "Cancel"]);
        // An open draft of that entry closes with it.
        state(cx, w, |t| {
            let e = t.model.entries[i].clone();
            t.model.begin_edit(&e);
        });
        let usage_rev = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.query_row("SELECT revision FROM dictionary_usage_state WHERE id=1", [], |r| r.get::<_, i64>(0)).unwrap());
        let before = usage_rev(cx);
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute("INSERT INTO dictionary_usage_events (dictation_id, entry_id, key_id, outcome, at) VALUES ('d', ?, 'boost', 'kept', 1)", [&id]).unwrap());
        let (events, vocab_rev) = (
            |cx: &mut TestAppContext, id: &str| cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.query_row("SELECT count(*) FROM dictionary_usage_events WHERE entry_id=?", [id], |r| r.get::<_, i64>(0)).unwrap()),
            |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.query_row("SELECT revision FROM vocabulary_state WHERE id=1", [], |r| r.get::<_, i64>(0)).unwrap()),
        );
        assert_eq!(events(cx, &id), 1);
        let rev = vocab_rev(cx);
        click(cx, w, "vocabulary.deleteDialog.confirm");
        assert_saw(&["Entry deleted."]);
        assert_eq!(events(cx, &id), 0, "usage events go");
        assert!(vocab_rev(cx) > rev, "vocabulary revision bumped");
        w.update(cx, |t, _, _| assert!(t.model.draft.is_none())).unwrap();
        assert!(usage_rev(cx) > before, "usage revision bumped");
        let rows: i64 = cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.query_row("SELECT count(*) FROM dictionary_key_usage WHERE entry_id=?", [&id], |r| r.get(0)).unwrap());
        assert_eq!(rows, 0, "usage cascades");
    }

    // parity: DICT-092
    #[flow_ui::gpui::test]
    async fn the_status_line_is_12_muted_and_ends_on_the_next_begin(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "dictionary.toggle.0");
        let muted = cx.update(|cx| pal(cx).muted);
        let status = w.update(cx, |t, _, _| t.model.status.clone().unwrap()).unwrap();
        let s = flow_ui::probe::style_of(&status).unwrap();
        assert_eq!((s.size, s.color), (12., muted));
        let line = bounds(cx, w, "vocabulary.statusLine");
        assert_eq!(line.size.height, px(14. + 13.), "top padding 14 over the 12 text");
        assert!(line.origin.y > bounds(cx, w, "dictionary.delete.6").bottom(), "below the list");
        click(cx, w, "vocabulary.add");
        assert!(cx.update_window(w.into(), |_, win, _| win.try_find("vocabulary.statusLine").is_none()).unwrap());
    }

    // parity: DICT-093 DICT-094 DICT-118
    /// Width 360; Escape and Cancel are refused while a save runs, and Cancel reads off.
    #[flow_ui::gpui::test]
    async fn the_sheet_is_360_wide_and_cannot_be_left_while_saving(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        assert_eq!(bounds(cx, w, "vocabulary.sheet").size.width, px(360.));
        let s = flow_ui::probe::style_of("Add to vocabulary").unwrap();
        assert_eq!((s.size, s.weight), (15., 600.));
        assert_saw(&["Cancel"]);
        state(cx, w, |t| t.model.saving = true);
        assert_eq!(disabled(cx, w, "vocabulary.cancel"), Some(true));
        cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
        frame(cx, w);
        w.update(cx, |t, _, _| assert!(t.model.draft.is_some(), "Escape ignored while saving")).unwrap();
        state(cx, w, |t| t.model.saving = false);
        assert_ne!(disabled(cx, w, "vocabulary.cancel"), Some(true));
        cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
        frame(cx, w);
        w.update(cx, |t, _, _| assert!(t.model.draft.is_none())).unwrap();
    }

    // parity: DICT-096
    /// On focuses the first alias, off focuses the word. Replaces an `||` that always held.
    #[flow_ui::gpui::test]
    async fn the_mode_switch_moves_focus_each_way(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        click(cx, w, "vocabulary.correctMisspelling");
        w.update(cx, |t, win, cx| assert!(t.canonical.as_ref().unwrap().read(cx).focus_handle(cx).is_focused(win), "off: the word")).unwrap();
        click(cx, w, "vocabulary.correctMisspelling");
        w.update(cx, |t, win, cx| assert!(t.aliases[0].read(cx).focus_handle(cx).is_focused(win), "on: the first alias")).unwrap();
    }

    // parity: DICT-098 DICT-099 DICT-100 DICT-103 DICT-104
    /// The switch, by click: identifiers, labels, placeholders, and aliases gone for good when off.
    #[flow_ui::gpui::test]
    async fn the_misspelling_switch_discards_aliases_and_returns_one_blank(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        assert_saw(&["Correct a misspelling", "Enabled"]);
        assert_eq!(cx.update_window(w.into(), |_, win, _| win.find("vocabulary.enabled").checked()).unwrap(), Some(true), "default on");
        assert_eq!(label(cx, w, "vocabulary.correctMisspelling").as_deref(), Some("Correct a misspelling"));
        assert_eq!(label(cx, w, "vocabulary.enabled").as_deref(), Some("Enabled"));
        // First row: Misspelling, arrow, Correct spelling, with both identifiers.
        cx.update_window(w.into(), |_, win, _| {
            assert_eq!(win.find_by_label("Misspelling").placeholder(), Some("Misspelling"));
            assert_eq!(win.find_by_label("Correct spelling").placeholder(), Some("Correct spelling"));
        })
        .unwrap();
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "arrow.right"));
        assert!(flow_ui::probe::symbols().iter().filter(|s| *s == "info.circle").count() >= 2);
        let alias = w.update(cx, |t, _, _| t.aliases[0].clone()).unwrap();
        type_into(cx, w, alias, "tatry");
        state(cx, w, |t| {
            t.model.field_errors.insert(Field::Alias(0), "x".into());
            t.model.field_errors.insert(Field::Aliases, "y".into());
        });
        let before = stored(cx);
        click(cx, w, "vocabulary.correctMisspelling");
        w.update(cx, |t, _, _| {
            assert!(t.model.draft.as_ref().unwrap().aliases.is_empty());
            assert!(t.model.field_errors.is_empty());
        })
        .unwrap();
        cx.update_window(w.into(), |_, win, _| assert_eq!(win.find_by_label("Word").placeholder(), Some("Word"))).unwrap();
        click(cx, w, "vocabulary.correctMisspelling");
        w.update(cx, |t, _, _| assert_eq!(t.model.draft.as_ref().unwrap().aliases, [""])).unwrap();
        assert_eq!(stored(cx), before, "persists nothing");
    }

    // parity: DICT-105 DICT-107 DICT-109
    #[flow_ui::gpui::test]
    async fn extra_misspelling_rows_show_the_word_and_a_named_remove(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        let canonical = w.update(cx, |t, _, _| t.canonical.clone().unwrap()).unwrap();
        type_into(cx, w, canonical, "Tatra");
        state(cx, w, |t| {
            t.model.field_errors.insert(Field::Aliases, "too many".into());
        });
        click(cx, w, "vocabulary.addAlias");
        w.update(cx, |t, _, _| {
            assert_eq!(t.model.draft.as_ref().unwrap().aliases, ["", ""], "a blank alias appended");
            assert!(!t.model.field_errors.contains_key(&Field::Aliases), "add clears the aliases error");
        })
        .unwrap();
        assert_eq!(label(cx, w, "vocabulary.removeAlias.1").as_deref(), Some("Remove misspelling 2"));
        assert!(cx.update_window(w.into(), |_, win, _| win.try_find("vocabulary.alias.1.box").is_some()).unwrap());
        let muted = cx.update(|cx| pal(cx).muted);
        let s = flow_ui::probe::style_of("Tatra").unwrap();
        assert_eq!((s.size, s.color), (13., muted), "the read only canonical");
        assert!(flow_ui::probe::symbols().iter().any(|s| s == "xmark"));
        state(cx, w, |t| {
            t.model.field_errors.insert(Field::Alias(0), "a".into());
            t.model.field_errors.insert(Field::Alias(1), "b".into());
            t.model.field_errors.insert(Field::Canonical, "keep".into());
        });
        click(cx, w, "vocabulary.removeAlias.1");
        w.update(cx, |t, _, _| {
            assert_eq!(t.aliases.len(), 1);
            assert!(!t.model.field_errors.keys().any(|k| matches!(k, Field::Alias(_))), "every alias field error");
            assert!(t.model.field_errors.contains_key(&Field::Canonical));
        })
        .unwrap();
    }

    // parity: DICT-106
    /// Through real keystrokes, not direct model calls.
    #[flow_ui::gpui::test]
    async fn typing_clears_that_fields_error(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        state(cx, w, |t| {
            t.model.field_errors.insert(Field::Canonical, "bad word".into());
            t.model.field_errors.insert(Field::Alias(0), "bad alias".into());
            t.model.field_errors.insert(Field::Aliases, "aliases".into());
        });
        let alias = w.update(cx, |t, _, _| t.aliases[0].clone()).unwrap();
        type_into(cx, w, alias, "x");
        w.update(cx, |t, _, _| {
            assert!(!t.model.field_errors.contains_key(&Field::Alias(0)));
            assert!(!t.model.field_errors.contains_key(&Field::Aliases));
            assert!(t.model.field_errors.contains_key(&Field::Canonical));
        })
        .unwrap();
        let canonical = w.update(cx, |t, _, _| t.canonical.clone().unwrap()).unwrap();
        type_into(cx, w, canonical, "y");
        w.update(cx, |t, _, _| assert!(t.model.field_errors.is_empty())).unwrap();
    }

    // parity: DICT-108 DICT-111 DICT-112 DICT-113 DICT-114
    #[flow_ui::gpui::test]
    async fn duplicates_are_flagged_styled_and_removed_with_a_count(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        let canonical = w.update(cx, |t, _, _| t.canonical.clone().unwrap()).unwrap();
        type_into(cx, w, canonical, "Tatra");
        let (accent, warning) = cx.update(|cx| (pal(cx).accent, pal(cx).warning));
        let s = flow_ui::probe::style_of("Add another misspelling").unwrap();
        assert_eq!((s.size, s.color), (12., accent));
        // An alias equal to its own canonical is a duplicate, folded.
        let a = w.update(cx, |t, _, _| t.aliases[0].clone()).unwrap();
        type_into(cx, w, a, "TATRA");
        let s = flow_ui::probe::style_of("Repeats another misspelling.").unwrap();
        assert_eq!((s.size, s.color), (12., warning));
        let s = flow_ui::probe::style_of("Remove duplicates").unwrap();
        assert_eq!((s.size, s.color), (12., accent));
        // A stored error on that index wins.
        state(cx, w, |t| {
            t.model.field_errors.insert(Field::Alias(0), "stored".into());
        });
        assert_saw(&["stored"]);
        assert!(!saw("Repeats another misspelling."));
        let before = stored(cx);
        click(cx, w, "vocabulary.deduplicate");
        assert_saw(&["Removed 1 duplicate alias."]);
        w.update(cx, |t, _, _| assert!(t.model.field_errors.is_empty(), "clears field errors")).unwrap();
        assert_eq!(stored(cx), before, "persists nothing");
        assert!(cx.update_window(w.into(), |_, win, _| win.try_find("vocabulary.deduplicate").is_none()).unwrap(), "gone with no duplicates");
        // Two at once reads plural.
        state(cx, w, |t| {
            let d = t.model.draft.as_mut().unwrap();
            d.aliases = vec!["a b".into(), "A B".into(), "a b".into()];
        });
        state(cx, w, |t| t.model.deduplicate());
        assert_saw(&["Removed 2 duplicate aliases."]);
    }

    // parity: DICT-116
    /// A real store error reaches the sheet's single line under `Field::Store`.
    #[flow_ui::gpui::test]
    async fn a_real_stale_write_reaches_the_sheet_and_the_status(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        let (canonical, alias) = w.update(cx, |t, _, _| (t.canonical.clone().unwrap(), t.aliases[0].clone())).unwrap();
        type_into(cx, w, canonical, "Tatra");
        type_into(cx, w, alias, "tatry");
        state(cx, w, |t| t.model.revision -= 1);
        let before = stored(cx).len();
        click(cx, w, "vocabulary.save");
        let copy = "The vocabulary changed. Review and save again.";
        assert_saw(&[copy, "Add to vocabulary"]);
        assert!(cx.update_window(w.into(), |_, win, _| win.try_find("vocabulary.sheetError").is_some()).unwrap());
        w.update(cx, |t, _, _| {
            assert_eq!(t.model.status.as_deref(), Some(copy), "DICT-126: in status too");
            assert!(t.model.draft.is_some(), "DICT-126: draft stays");
        })
        .unwrap();
        assert_eq!(stored(cx).len(), before);
    }

    // parity: DICT-126 DICT-127
    /// Conflict suffix, missing entry, an SQL failure; the list refreshes each time.
    #[flow_ui::gpui::test]
    async fn write_errors_go_to_their_field_with_the_right_copy(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        let (canonical, alias) = w.update(cx, |t, _, _| (t.canonical.clone().unwrap(), t.aliases[0].clone())).unwrap();
        type_into(cx, w, canonical, "Tatra");
        type_into(cx, w, alias, "Brunel");
        click(cx, w, "vocabulary.save");
        assert!(saw("Conflicts with “Brunel”."), "{:?}", flow_ui::probe::seen());
        click(cx, w, "vocabulary.cancel");
        // A row gone behind the page's back: status set, and the stale row refreshed away.
        let gone = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| e.canonical == "Northwind").unwrap().clone()).unwrap();
        cx.update(|cx| {
            let db = cx.global::<Core>().db.as_ref().unwrap();
            flow_core::dictionary::delete(db, &gone.id, None).unwrap();
        });
        // The page holds an old revision, so the staleness copy wins, and the list refreshes.
        w.update(cx, |t, _, cx| t.toggle(&gone, cx)).unwrap();
        frame(cx, w);
        assert_saw(&["The vocabulary changed. Review and save again."]);
        assert!(!shown(cx, w).contains(&"Northwind".to_string()), "the list refreshed");
        // With the revision current, a row that's gone reads as missing.
        w.update(cx, |t, _, cx| t.toggle(&gone, cx)).unwrap();
        frame(cx, w);
        let missing = flow_core::dictionary::Code::MissingEntry.message();
        w.update(cx, |t, _, _| assert_eq!(t.model.status.as_deref(), Some(missing))).unwrap();
        // Anything else: "Could not save. …".
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute_batch("CREATE TRIGGER no_write BEFORE UPDATE ON vocabulary_entries BEGIN SELECT RAISE(ABORT, 'no'); END").unwrap());
        let e = w.update(cx, |t, _, _| t.model.entries[0].clone()).unwrap();
        w.update(cx, |t, _, cx| t.toggle(&e, cx)).unwrap();
        frame(cx, w);
        w.update(cx, |t, _, _| assert!(t.model.status.as_deref().unwrap_or("").starts_with("Could not save. "), "{:?}", t.model.status)).unwrap();
    }

    // parity: DICT-120 DICT-121 DICT-122
    #[flow_ui::gpui::test]
    async fn the_save_button_names_its_state_and_edit_saves(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.add");
        assert_eq!(label(cx, w, "vocabulary.save").as_deref(), Some("Add word"));
        state(cx, w, |t| t.model.saving = true);
        assert_eq!(label(cx, w, "vocabulary.save").as_deref(), Some("Saving…"));
        assert_saw(&["Saving…"]);
        state(cx, w, |t| t.model.saving = false);
        click(cx, w, "vocabulary.cancel");
        let i = w.update(cx, |t, _, _| t.model.entries.iter().position(|e| e.canonical == "Brunel").unwrap()).unwrap();
        click(cx, w, &format!("dictionary.edit.{i}"));
        assert_eq!(label(cx, w, "vocabulary.save").as_deref(), Some("Save"));
        let (canonical, save) = (bounds(cx, w, "vocabulary.canonical.box"), bounds(cx, w, "vocabulary.save"));
        assert!(save.origin.y >= canonical.bottom() + px(4.), "top padding 4");
        let field = w.update(cx, |t, _, _| t.canonical.clone().unwrap()).unwrap();
        type_into(cx, w, field, "x");
        cx.update_window(w.into(), |_, win, cx| win.press("enter", cx)).unwrap();
        frame(cx, w);
        assert_saw(&["Entry saved."]);
        assert!(!stored(cx).iter().any(|e| e.canonical == "Brunel"), "the edit was written");
    }

    // parity: DICT-128
    /// Toggle and delete do nothing while a write runs, not just their pills.
    #[flow_ui::gpui::test]
    async fn writes_are_ignored_while_one_runs(cx: &mut TestAppContext) {
        let w = open(cx);
        let before = stored(cx);
        let e = w.update(cx, |t, _, _| t.model.entries[0].clone()).unwrap();
        state(cx, w, |t| t.model.saving = true);
        w.update(cx, |t, _, cx| {
            t.toggle(&e, cx);
            t.confirming_delete = Some(e.clone());
            t.delete_confirmed(cx);
        })
        .unwrap();
        assert_eq!(stored(cx), before);
        w.update(cx, |t, _, cx| {
            t.model.draft = Some(flow_core::dictionary::Draft { id: None, canonical: "New".into(), aliases: vec![], enabled: true, learned_at: None });
            t.model.save_draft(cx.global::<Core>().db.as_ref().unwrap(), is_english);
        })
        .unwrap();
        assert_eq!(stored(cx), before);
    }

    /// The identifier an input hands AccessKit, as gpui-component's own test reads it.
    fn author_id(cx: &mut TestAppContext, w: WindowHandle<DictionaryPage>, state: Entity<InputState>) -> Option<String> {
        use flow_ui::gpui::{Element as _, IntoElement as _, Render as _, Role, accesskit::Node};
        w.update(cx, |_, win, cx| {
            state.update(cx, |s, cx| {
                let input = s.render(win, cx).into_element();
                let mut node = Node::new(Role::Unknown);
                input.write_a11y_info(&mut node);
                node.author_id().map(ToOwned::to_owned)
            })
        })
        .unwrap()
    }

    // parity: DICT-023 DICT-103 DICT-104
    #[flow_ui::gpui::test]
    async fn inputs_carry_swifts_identifiers(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "vocabulary.searchToggle");
        let search = w.update(cx, |t, _, _| t.search.clone()).unwrap();
        assert_eq!(author_id(cx, w, search).as_deref(), Some("vocabulary.search"));
        click(cx, w, "vocabulary.add");
        let (canonical, alias) = w.update(cx, |t, _, _| (t.canonical.clone().unwrap(), t.aliases[0].clone())).unwrap();
        assert_eq!(author_id(cx, w, canonical).as_deref(), Some("vocabulary.canonical"));
        assert_eq!(author_id(cx, w, alias).as_deref(), Some("vocabulary.alias.0"));
    }
}
