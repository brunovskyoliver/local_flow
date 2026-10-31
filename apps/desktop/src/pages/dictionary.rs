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
                                        .aria_label("Search dictionary")
                                        .accessibility_id("vocabulary.search"),
                                ),
                        )
                    })
                    .child(
                        FlowButton::new("vocabulary.searchToggle", ButtonKind::Plain, "Search")
                            .content(icon("magnifyingglass", 15.5, p.muted))
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
        // GPUI gradients take two stops; Swift's three become two halves.
        let half = |a: u32, b: u32| div().flex_1().h_full().bg(linear_gradient(90., linear_color_stop(rgb(a), 0.), linear_color_stop(rgb(b), 1.)));
        div()
            .relative()
            .w_full()
            .mt(px(22.))
            .rounded(px(16.))
            .child(h_flex().absolute().inset_0().child(half(0x211F1C, 0x3D3329).rounded_l(px(16.))).child(half(0x3D3329, 0x7A5C33).rounded_r(px(16.))))
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
                            .pt(px(4.))
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
                        .content(div().p(px(6.)).rounded_full().bg(white_a(0.14)).child(icon("xmark", 13., white_a(0.8))))
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
                        .when(!s.alias.is_empty(), |d| d.child(t(s.alias.clone()).size(15.)).child(icon("arrow.right", 12., p.ink)))
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
        v_flex().id("vocabulary.suggestions").w_full().mt(px(24.)).gap(px(10.)).child(t("Suggested").font(13., 500.).color(p.muted)).child(rows.child(outline(cx)))
    }

    fn list(&self, cx: &mut Context<Self>) -> AnyElement {
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
            return div().w_full().mt(px(24.)).py(px(60.)).flex().justify_center().child(t(text).size(15.).color(p.muted)).into_any_element();
        }
        let count = entries.len();
        let mut list = v_flex().id("vocabulary.list").relative().w_full().mt(px(24.));
        for (i, e) in entries.into_iter().enumerate() {
            list = list.child(self.row(i, e, cx)).when(i + 1 < count, |d| d.child(hairline(cx)));
        }
        list.child(outline(cx)).into_any_element()
    }

    fn row(&self, i: usize, e: Entry, cx: &mut Context<Self>) -> AnyElement {
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
            title = title.child(aliases).child(div().flex_none().child(icon("arrow.right", 12., fg))).child(div().flex_none().child(t(e.canonical.clone()).size(15.).color(fg)));
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

        let mut meta = h_flex().gap(px(8.)).child(t(usage).id("dictionary.entry.usage").size(12.).color(p.muted));
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
            .group(group.clone())
            .w_full()
            .min_h(px(53.))
            .px(px(18.))
            .py(px(10.))
            .gap(px(4.))
            .text_color(fg)
            .child(h_flex().w_full().gap(px(10.)).child(title).child(hover_or_focus_revealed(group, busy || self.voice_over, &action_focus, actions)))
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
            .track_focus(&self.focus)
            .p(px(18.))
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
                        .content(icon("xmark", 10., p.muted))
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
            content = content.child(div().pt(px(24.)).child(t(e).id("vocabulary.loadError").size(13.).color(p.warning).selectable()));
        }
        if self.filter == Filter::All && search_empty && !self.model.suggestions.is_empty() {
            content = content.child(self.suggestions(cx));
        }
        content = content.child(self.list(cx));
        if let Some(s) = self.model.status.clone() {
            content = content.child(div().pt(px(14.)).child(t(s).id("vocabulary.status").size(12.).color(p.muted)));
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
            ))
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
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Dictionary));
        frame(cx, w);
        w.update(cx, |t, _, _| assert!(t.model.entries.iter().any(|e| e.id == "arrived"))).unwrap();
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
        for id in ["vocabulary.suggestion.add.0", "dictionary.edit.0", "dictionary.toggle.0", "dictionary.delete.0", "vocabulary.add"] {
            assert_ne!(disabled(cx, w, id), Some(true), "{id}");
        }
        state(cx, w, |t| t.model.saving = true);
        for id in ["vocabulary.suggestion.add.0", "dictionary.edit.0", "dictionary.toggle.0", "dictionary.delete.0", "vocabulary.add"] {
            assert_eq!(disabled(cx, w, id), Some(true), "{id}");
        }
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
        w.update(cx, |t, win, cx| assert!(!t.aliases.is_empty() && t.aliases[0].read(cx).focus_handle(cx).is_focused(win) || t.aliases.len() == 2)).unwrap();
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
}
