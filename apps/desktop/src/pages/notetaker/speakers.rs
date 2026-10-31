//! `AssignSpeakersView`.
use super::*;
use std::collections::HashMap;

pub(crate) struct AssignState {
    pub model: AssignModel,
    pub inputs: HashMap<String, Entity<InputState>>,
    pub focused: Option<String>,
    pub scroll: ScrollHandle,
    _subs: Vec<Subscription>,
}

impl NotetakerPage {
    pub(crate) fn open_assign(&mut self, focus: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()) else { return };
        let identify = cx.global::<Core>().prefs.bool_or("speakerIdentificationEnabled", true);
        let Some(db) = db_of(cx) else { return };
        let model = AssignModel::new(db, &id, identify);
        let mut inputs = HashMap::new();
        let mut subs = vec![];
        for s in &model.sections {
            let speaker = s.speaker.id.clone();
            let draft = s.draft.clone();
            let input = cx.new(|cx| InputState::new(window, cx).placeholder("Type a name").default_value(draft));
            subs.push(cx.subscribe_in(&input, window, move |this, input, e: &TextInputEvent, window, cx| this.name_event(&speaker, input.clone(), e, window, cx)));
            inputs.insert(s.speaker.id.clone(), input);
        }
        let first = focus.or(model.sections.iter().find(|s| s.speaker.includes.is_empty()).map(|s| s.speaker.id.clone()));
        if let Some(input) = first.as_ref().and_then(|f| inputs.get(f)) {
            input.read(cx).focus_handle(cx).focus(window, cx);
        }
        let mut model = model;
        if let (Some(f), Some(db)) = (&first, db_of(cx)) {
            model.refresh_suggestions(db, f);
        }
        self.assign = Some(AssignState { model, inputs, focused: first, scroll: ScrollHandle::new(), _subs: subs });
        cx.notify();
    }
    fn name_event(&mut self, speaker: &str, input: Entity<InputState>, e: &TextInputEvent, window: &mut Window, cx: &mut Context<Self>) {
        let Some(db) = db_of(cx) else { return };
        let Some(a) = &mut self.assign else { return };
        match e {
            TextInputEvent::Change => {
                let value = input.read(cx).value().to_string();
                a.model.set_draft(speaker, &value);
                a.focused = Some(speaker.to_string());
                a.model.refresh_suggestions(db, speaker);
            }
            TextInputEvent::Focus => {
                a.focused = Some(speaker.to_string());
                a.model.refresh_suggestions(db, speaker);
            }
            TextInputEvent::PressEnter { .. } => {
                self.save_assign(window, cx);
                return;
            }
            _ => {}
        }
        cx.notify();
    }
    pub(crate) fn save_assign(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        let Some(db) = db_of(cx) else { return };
        let Some(a) = &mut self.assign else { return };
        if a.model.enrollment_completed {
            self.close_assign(cx);
            return;
        }
        if !a.model.can_save() {
            return;
        }
        // Voice samples come from the Mac's embedding worker; names and links still save.
        let closed = a.model.save(db, "The voice sample could not be stored on this Mac.");
        if let Some(p) = &mut self.pager {
            p.refresh_labels(db);
        }
        if closed {
            self.close_assign(cx);
        }
        cx.notify();
    }
    /// `close`: the summary re-reads the speaker names when the sheet goes away (MEET-090).
    pub(crate) fn close_assign(&mut self, cx: &mut Context<Self>) {
        self.assign = None;
        self.summary_refresh(cx);
        cx.notify();
    }
    pub(crate) fn set_identity(&mut self, speaker: &str, action: IdentityAction, cx: &mut Context<Self>) {
        if let Some(a) = &mut self.assign {
            a.model.set_action(speaker, action);
        }
        cx.notify();
    }
    pub(crate) fn merge_into(&mut self, id: &str, target: &str, cx: &mut Context<Self>) {
        let Some(db) = db_of(cx) else { return };
        if let Some(a) = &mut self.assign {
            a.model.merge(db, id, target);
        }
        cx.notify();
    }

    pub(crate) fn assign_sheet(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let a = self.assign.as_ref().expect("assign");
        let sections: Vec<Section> = a.model.sections.clone();
        let reviews = a.model.reviews.clone();
        let (notice, can_save, none) = (a.model.notice.clone(), a.model.can_save(), sections.is_empty());
        let done = a.model.enrollment_completed;
        let handle = a.scroll.clone();
        let mut scroll = v_flex().w_full().gap(px(28.)).px(px(32.)).pt(px(20.)).pb(px(28.));
        if none && a.model.is_loading {
            scroll = scroll.child(div().id("meeting.speakers.loading").test_support().w_full().p(px(20.)).flex().justify_center().child(Spinner::new()));
        } else if none {
            scroll = scroll.child(t("There are no speakers to name.").size(14.).color(p.muted));
        }
        for (id, text) in reviews {
            scroll = scroll.child(
                h_flex()
                    .id("meeting.speakers.review")
                    .test_support()
                    .w_full()
                    .gap(px(8.))
                    .p(px(12.))
                    .bg(p.canvas)
                    .rounded(px(10.))
                    .child(icon("exclamationmark.triangle", 13., orange(cx)))
                    .child(div().flex_1().child(t(text.clone()).size(13.)))
                    .child(plain_button("meeting.speakers.review.dismiss", "Dismiss").a11y_label(sid(format!("Dismiss notice: {text}"))).on_click(cx.listener(move |this, _, _, cx| {
                        if let (Some(db), Some(a)) = (db_of(cx), &mut this.assign) {
                            a.model.dismiss_review(db, &id);
                        }
                        cx.notify();
                    })).content(t("Dismiss").font(12., 500.).color(p.muted).a11y_hidden())),
            );
        }
        for (position, s) in sections.iter().enumerate() {
            scroll = scroll.child(self.section_view(position, s, cx));
        }
        deferred(
            window_backdrop("meeting.speakers.backdrop").flex().items_center().justify_center().bg(gpui::black().opacity(0.2)).occlude().on_key_down(cx.listener(|this, e: &KeyDownEvent, _, cx| {
                if e.keystroke.key == "escape" {
                    this.close_assign(cx);
                }
            })).child(
                v_flex()
                    .id("meeting.speakers.assign")
                    .test_support()
                    .relative()
                    .w(px(560.))
                    .bg(p.surface)
                    .rounded(px(14.))
                    .shadow_lg()
                    .child(div().px(px(32.)).pt(px(28.)).pb(px(12.)).child(t("Assign speakers").font(28., 400.).serif()))
                    .child(div().absolute().top(px(22.)).right(px(22.)).child(plain_button("meeting.speakers.close", "Close").on_click(cx.listener(|this, _, _, cx| this.close_assign(cx))).content(div().size(px(30.)).flex().items_center().justify_center().child(icon("xmark", 15., p.ink)))))
                    .child(
                        // The scroller shows that more voices follow below the fold (UI-14).
                        div().relative().w_full().flex().flex_col().child(div().id("meeting.speakers.scroll").test_support().w_full().min_h(px(160.)).max_h(px(480.)).overflow_y_scroll().track_scroll(&handle).child(scroll)).child(Scrollbar::vertical(&handle).mode(ScrollbarMode::Always).styles(move |styles| styles.track(|x| x.bg(p.canvas)).thumb(|x| x.bg(p.muted.opacity(0.6)).width(px(7.)).radius(px(4.))).thumb_hover(|x| x.bg(p.muted.opacity(0.8)).width(px(7.)).radius(px(4.))).thumb_active(|x| x.bg(p.muted).width(px(7.)).radius(px(4.))))),
                    )
                    .child(hairline(cx))
                    .child(
                        h_flex()
                            .w_full()
                            .px(px(28.))
                            .py(px(18.))
                            .gap(px(10.))
                            .child(div().flex_1().when_some(notice, |d, n| d.child(t(n).size(12.).color(red(cx)).lines(2))))
                            .child(plain_button("meeting.speakers.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| this.close_assign(cx))).content(sheet_button("Cancel", false, cx)))
                            .child(plain_button("meeting.speakers.save", if done { "Done" } else { "Save names" }).disabled(!can_save && !done).disabled_opacity(0.45).on_click(cx.listener(|this, _, w, cx| this.save_assign(w, cx))).content(sheet_button(if done { "Done" } else { "Save names" }, true, cx))),
                    ),
            ),
        )
        .with_priority(3)
    }

    fn section_view(&mut self, position: usize, s: &Section, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let id = s.speaker.id.clone();
        let a = self.assign.as_ref().expect("assign");
        let input = a.inputs.get(&id).cloned();
        let focused = a.focused.as_deref() == Some(id.as_str());
        let suggestions = if focused { a.model.suggestions.clone() } else { vec![] };
        let duplicate = a.model.duplicate(&id).map(|d| (d.speaker.id.clone(), d.preview()));
        let block = a.model.identity_block(&id);
        let error = s.error();
        let label = s.speaker.anonymous();
        let mut column = v_flex().w_full().gap(px(12.)).child(h_flex().gap(px(9.)).child(div().size(px(10.)).rounded_full().bg(speaker_dot(s.speaker.color, cx))).child(t(label.to_uppercase()).font(12., 600.).tracking(1.4)));
        for merged in s.speaker.includes.clone() {
            let includes = format!("Includes {}", merged.label);
            column = column.child(h_flex().gap(px(8.)).child(t(includes).size(13.).color(p.muted)).child(plain_button(sid(format!("meeting.speakers.unmerge.{}", merged.id)), "Undo merge").a11y_label(sid(format!("Undo merge of {}", merged.label))).on_click(cx.listener(move |this, _, _, cx| {
                if let (Some(db), Some(a)) = (db_of(cx), &mut this.assign) {
                    a.model.unmerge(db, &merged.id);
                }
                cx.notify();
            })).content(t("Undo merge").font(13., 500.).a11y_hidden())));
        }
        if !s.speaker.quotes.is_empty() {
            let mut quotes = v_flex().w_full().gap(px(8.));
            for quote in &s.speaker.quotes {
                quotes = quotes.child(h_flex().w_full().items_stretch().gap(px(12.)).child(div().w(px(2.)).rounded(px(1.)).bg(p.line)).child(div().flex_1().child(t(format!("\u{201C}{quote}\u{201D}")).size(14.).line_spacing(4.).color(p.ink.opacity(0.85)).lines(3))));
            }
            column = column.child(quotes);
        }
        if let Some(input) = input {
            column = column.child(
                div()
                    .w_full()
                    .h(px(46.))
                    .px(px(10.))
                    .flex()
                    .items_center()
                    .rounded(px(12.))
                    .when(focused, |d| d.border_2().border_color(p.ink))
                    .when(!focused, |d| d.border_1().border_color(p.line))
                    .text_size(px(15.))
                    .child(Input::new(&input).appearance(false).aria_label(sid(format!("Name for {label}"))).accessibility_id(sid(format!("meeting.speakers.name.{position}")))),
            );
        }
        if !suggestions.is_empty() {
            let mut list = v_flex().w_full().gap(px(2.)).p(px(6.)).rounded(px(12.)).border_1().border_color(p.line);
            for (i, name) in suggestions.into_iter().enumerate() {
                let (speaker, pick) = (id.clone(), name.clone());
                list = list.child(plain_button(sid(format!("meeting.speakers.suggestion.{i}")), sid(format!("Use name {name}"))).full_width().on_click(cx.listener(move |this, _, w, cx| {
                    if let Some(a) = &mut this.assign {
                        a.model.pick(&pick, &speaker);
                        if let Some(input) = a.inputs.get(&speaker) {
                            let picked = pick.clone();
                            input.update(cx, |s, cx| s.set_value(picked, w, cx));
                        }
                    }
                    cx.notify();
                })).content(div().w_full().px(px(12.)).py(px(10.)).rounded(px(8.)).hover(|d| d.bg(p.canvas)).child(t(name).size(15.).a11y_hidden())));
            }
            column = column.child(list);
        }
        if let Some(b) = block {
            column = column.child(self.identity_view(&id, s, b, cx));
        }
        let error_shown = error.clone();
        if let Some(e) = error {
            column = column.child(t(e).size(12.).color(red(cx)));
        }
        if let (None, Some((target, name))) = (error_shown, duplicate) {
            let speaker = id.clone();
            column = column.child(h_flex().gap(px(8.)).child(t(format!("Same name as {name}.")).size(12.).color(p.muted)).child(plain_button(sid(format!("meeting.speakers.merge.{position}")), "Merge").a11y_label(sid(format!("Merge into {name}"))).on_click(cx.listener(move |this, _, _, cx| this.merge_into(&speaker, &target, cx))).content(t("Merge").font(12., 500.).a11y_hidden())));
        }
        column
    }

    fn identity_view(&mut self, id: &str, s: &Section, b: IdentityBlock, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let id = id.to_string();
        let mut out = v_flex().id(sid(format!("identity.block.{id}"))).w_full().items_start().gap(px(8.));
        if let Some(remembered) = b.local_remembered {
            if !remembered {
                if s.action == IdentityAction::RememberLocal {
                    out = out.child(t("Your voice will be remembered from this Mac's microphone.").size(12.).color(p.muted));
                } else {
                    let speaker = id.clone();
                    out = out.child(plain_button("identity.rememberLocal", "Remember my voice").on_click(cx.listener(move |this, _, _, cx| this.set_identity(&speaker, IdentityAction::RememberLocal, cx))).content(t("Remember my voice").font(12., 500.).a11y_hidden()));
                }
            }
        } else {
            if b.needs_choice {
                out = out.child(t(b.match_state.clone()).font(12., 500.).color(orange(cx)).id("identity.matchState"));
            }
            if !b.picker.is_empty() && !b.needs_choice {
                out = out.child(self.known_menu("identity.picker", "Known speakers…", &b.picker, &id, cx));
            }
            if b.needs_choice {
                let (speaker, page) = (id.clone(), cx.entity().downgrade());
                let picker = b.picker.clone();
                let chooser = id.clone();
                out = out.child(
                    h_flex()
                        .gap(px(10.))
                        .child(text_menu("identity.mergedPicker", "Choose a known speaker…", 13., cx).dropdown_menu(move |mut menu, _, _| {
                            for k in &picker {
                                let (speaker, known) = (chooser.clone(), k.id.clone());
                                menu = menu.item(PopupMenuItem::new(k.name.clone()).on_click(act(&page, move |this, _, cx| this.set_identity(&speaker, IdentityAction::ResolveMerged(Some(known.clone())), cx))));
                            }
                            menu
                        }))
                        .child(identity_button("identity.mergedKeepUnknown", "Keep Unknown", false, cx, move |this, cx| this.set_identity(&speaker, IdentityAction::ResolveMerged(None), cx))),
                );
            } else if b.shows_suggestion_actions {
                let (a1, a3) = (id.clone(), id.clone());
                out = out.child(
                    h_flex()
                        .gap(px(10.))
                        .child(identity_button("identity.confirm", "Confirm", s.action == IdentityAction::Confirm, cx, move |this, cx| this.set_identity(&a1, IdentityAction::Confirm, cx)))
                        .child(self.known_menu("identity.chooseAnother", "Choose another…", &b.picker, &id, cx))
                        .child(identity_button("identity.keepUnknown", "Keep Unknown", s.action == IdentityAction::KeepUnknown, cx, move |this, cx| this.set_identity(&a3, IdentityAction::KeepUnknown, cx))),
                );
            }
            if let Some(k) = b.duplicate_of.clone() {
                let (a1, a2) = (id.clone(), id.clone());
                out = out.child(
                    h_flex()
                        .w_full()
                        .gap(px(10.))
                        .child(div().flex_1().min_w_0().child(t(format!("Is this {} you already remember?", k.name)).font(13., 500.)))
                        .child(identity_button("identity.samePerson", "Same person", true, cx, move |this, cx| this.set_identity(&a1, IdentityAction::SamePerson(k.id.clone()), cx)))
                        .child(identity_button("identity.someoneNew", "Someone new", false, cx, move |this, cx| this.set_identity(&a2, IdentityAction::RememberNew, cx))),
                );
            } else if b.shows_remember {
                let (a1, a2) = (id.clone(), id.clone());
                let not_now = s.action == IdentityAction::NotNow;
                out = out.child(
                    v_flex()
                        .w_full()
                        .gap(px(6.))
                        .child(
                            h_flex()
                                .w_full()
                                .gap(px(10.))
                                .child(div().flex_1().min_w_0().child(t(REMEMBER_QUESTION).font(13., 500.)))
                                .child(identity_button("identity.remember", "Remember", s.action == IdentityAction::Remember, cx, move |this, cx| this.set_identity(&a1, IdentityAction::Remember, cx)))
                                .child(div().opacity(if not_now { 1. } else { 0.7 }).child(identity_button("identity.notNow", "Not now", false, cx, move |this, cx| this.set_identity(&a2, IdentityAction::NotNow, cx)))),
                        )
                        .child(t(REMEMBER_SENTENCE).size(12.).color(p.muted).id("identity.rememberSentence")),
                );
            }
            if b.shows_also_remember {
                let (speaker, on) = (id.clone(), s.also_remember);
                out = out.child(plain_button("identity.alsoRemember", "Also remember this voice sample").toggled(on).on_click(cx.listener(move |this, _, _, cx| {
                    if let Some(a) = &mut this.assign {
                        a.model.set_also_remember(&speaker, !on);
                    }
                    cx.notify();
                })).content(library::checkbox_row("Also remember this voice sample", on, cx)));
            }
        }
        if let Some(r) = s.enrollment_result.clone() {
            out = out.child(t(r).size(12.).color(p.muted).id("identity.enrollmentResult"));
        }
        out
    }
    /// `pickerMenu`: name, sample count and the re-enrollment tag; never scores.
    fn known_menu(&mut self, accessibility: &'static str, title: &'static str, known: &[KnownSpeaker], id: &str, cx: &mut Context<Self>) -> impl IntoElement {
        let (known, id, page) = (known.to_vec(), id.to_string(), cx.entity().downgrade());
        text_menu(accessibility, title, 12., cx).dropdown_menu(move |mut menu, _, _| {
            for k in &known {
                let noun = if k.samples == 1 { "voice sample" } else { "voice samples" };
                let tag = if k.samples == 0 { " · needs re-enrollment" } else { "" };
                let (speaker, known_id, name) = (id.clone(), k.id.clone(), k.name.clone());
                menu = menu.item(PopupMenuItem::new(format!("{} \u{2014} {} {noun}{tag}", k.name, k.samples)).on_click(act(&page, move |this, w, cx| {
                    if let Some(a) = &mut this.assign {
                        a.model.pick_known(&known_id, &speaker);
                        if let Some(input) = a.inputs.get(&speaker) {
                            let name = name.clone();
                            input.update(cx, |s, cx| s.set_value(name, w, cx));
                        }
                    }
                    cx.notify();
                })));
            }
            menu
        })
    }
}

/// A `.borderlessButton` `Menu`: accent title and chevron.
fn text_menu(id: &'static str, title: &'static str, size: f32, cx: &App) -> Button {
    let p = pal(cx);
    Button::new(id).ghost().p_0().h_auto().accessibility_label(title).child(h_flex().pl(px(3.)).gap(px(4.)).child(t(title).size(size).color(p.accent).a11y_hidden()).child(icon("chevron.down", 9., p.accent)))
}
fn sheet_button(title: &'static str, primary: bool, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    let (fill, text) = if primary { (p.ink, p.surface) } else { (p.canvas, p.ink) };
    div().h(px(38.)).px(px(18.)).flex().items_center().rounded(px(9.)).bg(fill).child(t(title).font(14., 500.).color(text).a11y_hidden())
}
fn identity_button(id: &'static str, title: &'static str, prominent: bool, cx: &mut Context<NotetakerPage>, on: impl Fn(&mut NotetakerPage, &mut Context<NotetakerPage>) + 'static) -> impl IntoElement {
    plain_button(id, title).a11y_selected(prominent).on_click(cx.listener(move |this, _, _, cx| on(this, cx))).content(sheet_button(title, prominent, cx))
}
