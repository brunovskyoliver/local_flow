//! Dictionary page: title, filter tabs, intro banner, entries and the "Add to vocabulary" sheet.
pub mod ui;

use crate::core::Core;
use crate::pages::Page;
use crate::shell::Session;
use flow_core::dictionary::{Entry, Field, Filter, MAX_ENTRIES, Model, RetiredTerm, Source, Suggestion};
use flow_ui::prelude::*;
use ui::{confirm_dialog, help, outline, overlay, pill, sheet_card, under_card_border};

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
        let _session_sub = cx.observe_global::<Session>(move |this, cx| {
            let now = Some(cx.global::<Session>().selection);
            if now != shown && now == Some(Page::Dictionary) {
                // `.task`: refreshes every time the page appears.
                this.voice_over = cx.global::<Core>().services.voice_over_on();
                this.refresh(cx);
                cx.notify();
            }
            shown = now;
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
                self.model.set_correcting(true);
                self.sync_fields(window, cx);
            }
            "delete" => self.confirming_delete = self.model.entries.first().cloned(),
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
                        d.child(div().w(px(if compact { 90. } else { 150. })).child(Input::new(&self.search).appearance(false).aria_label("Search dictionary").accessibility_id("vocabulary.search")))
                    })
                    .child(
                        FlowButton::new("vocabulary.searchToggle", ButtonKind::Plain, "Search")
                            .content(icon("magnifyingglass", 15.5, p.muted))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.searching = !this.searching;
                                if this.searching {
                                    this.search.update(cx, |s, cx| s.focus(window, cx));
                                } else {
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
            let mut spans = vec![];
            for (n, a) in e.aliases.iter().enumerate() {
                spans.push(if is_retired_alias(a) { span(a.clone()).strike().color(fg.opacity(0.55)) } else { span(a.clone()) });
                if n + 1 < e.aliases.len() {
                    spans.push(span(", "));
                }
            }
            title = title.child(rich(spans).size(15.).color(fg)).child(icon("arrow.right", 12., fg)).child(t(e.canonical.clone()).size(15.).color(fg));
        }
        let chip = |text: &'static str| div().px(px(6.)).py(px(2.)).bg(p.tint).rounded_full().child(t(text).size(11.).color(p.muted));
        if self.model.is_provisional(&e) {
            title = title.child(help(format!("dictionary.learning.{i}"), "Learned from one correction. Kept three times, it is trusted; undone once, it turns off.", chip("Learning")));
        }
        if e.learned_at.is_some() {
            // Swift: `Color(nsColor: .systemYellow)`, the same in both modes here.
            title = title.child(help(format!("dictionary.learned.{i}"), "Learned from a correction you made", icon("sparkles", 10., rgb(0xFFCC00))));
        }
        if !e.enabled {
            title = title.child(chip("Off"));
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
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.confirming_delete = Some(delete.clone());
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
                .item(PopupMenuItem::new("Delete").on_click(move |_, _, cx| {
                    c.update(cx, |this, cx| {
                        this.confirming_delete = Some(ec.clone());
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
            .when_some(error, |d, e| d.child(error_text(e, cx)))
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
            return v_flex().gap(px(4.)).child(field(&canonical, "Word", "vocabulary.canonical", cx)).when_some(canonical_error, |d, e| d.child(error_text(e, cx)));
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
                    .when(i == 0, |d| d.when_some(canonical_error.clone(), |d, e| d.child(error_text(e, cx)))),
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
fn field(state: &Entity<InputState>, label: &str, id: &str, cx: &App) -> Stateful<Div> {
    let p = pal(cx);
    div()
        .id(SharedString::from(format!("{id}.box")))
        .w_full()
        .bg(p.surface)
        .rounded(px(8.))
        .border_1()
        .border_color(p.line)
        .child(Input::new(state).appearance(false).h(px(27.)).text_size(px(13.)).aria_label(label.to_string()).accessibility_id(id.to_string()))
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
            .relative()
            .size_full()
            .child(under_card_border(prototype_page("dictionary.page", 960., cx, content)))
            .when_some(sheet, |d, s| d.child(overlay("vocabulary.sheetOverlay", window, cx, s)))
            .when_some(confirm, |d, c| d.child(overlay("vocabulary.deleteOverlay", window, cx, c)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{assert_saw, boot, saw};
    use flow_ui::test::{TestAppContext, TestWindowExt};

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

    // parity: DICT-032 DICT-033 DICT-034
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
        assert!(stored(cx).iter().any(|e| e.canonical == "Tatra"));
        assert_saw(&["Tatra"]);
        assert!(!saw("Add to vocabulary"));
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

    // parity: DICT-021 DICT-022 DICT-023 DICT-024 DICT-061
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

    // parity: DICT-099 DICT-107 DICT-110 DICT-118 DICT-119
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

    // parity: DICT-115 DICT-117 DICT-120 DICT-127 DICT-133
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
    }
}
