//! `AssignSpeakersView`.
use super::*;
use std::collections::HashMap;

pub(crate) struct AssignState {
    pub model: AssignModel,
    pub inputs: HashMap<String, Entity<InputState>>,
    pub focused: Option<String>,
    pub picker: Option<String>,
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
        self.assign = Some(AssignState { model, inputs, focused: first, picker: None, _subs: subs });
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
        if !a.model.can_save() {
            return;
        }
        // Voice samples come from the Mac's embedding worker; names and links still save.
        let closed = a.model.save(db, "The voice sample could not be stored on this Mac.");
        if let Some(p) = &mut self.pager {
            p.refresh_labels(db);
        }
        if closed {
            self.assign = None;
        }
        self.summary_refresh(cx);
        cx.notify();
    }
    fn set_identity(&mut self, speaker: &str, action: IdentityAction, cx: &mut Context<Self>) {
        if let Some(a) = &mut self.assign {
            a.model.set_action(speaker, action);
            a.picker = None;
        }
        cx.notify();
    }
    fn merge_into(&mut self, id: &str, target: &str, cx: &mut Context<Self>) {
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
        let mut scroll = v_flex().w_full().gap(px(28.)).pl(px(32.)).pr(px(49.)).pt(px(20.)).pb(px(28.));
        if none {
            scroll = scroll.child(t("There are no speakers to name.").size(14.).color(p.muted));
        }
        for (id, text) in reviews {
            scroll = scroll.child(
                h_flex()
                    .id("meeting.speakers.review")
                    .w_full()
                    .gap(px(8.))
                    .p(px(12.))
                    .bg(p.canvas)
                    .rounded(px(10.))
                    .child(icon("exclamationmark.triangle.fill", 13., orange(cx)))
                    .child(div().flex_1().child(t(text).size(13.)))
                    .child(plain_button("meeting.speakers.review.dismiss", "Dismiss").on_click(cx.listener(move |this, _, _, cx| {
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
                    this.assign = None;
                    cx.notify();
                }
            })).child(
                v_flex()
                    .id("meeting.speakers.assign")
                    .relative()
                    .w(px(560.))
                    .bg(p.surface)
                    .rounded(px(14.))
                    .shadow_lg()
                    .child(div().px(px(32.)).pt(px(28.)).pb(px(12.)).child(t("Assign speakers").font(28., 400.).serif()))
                    .child(div().absolute().top(px(22.)).right(px(22.)).child(plain_button("meeting.speakers.close", "Close").on_click(cx.listener(|this, _, _, cx| {
                        this.assign = None;
                        cx.notify();
                    })).content(div().size(px(30.)).flex().items_center().justify_center().child(icon("xmark", 19., p.ink)))))
                    .child(div().id("meeting.speakers.scroll").w_full().min_h(px(160.)).max_h(px(480.)).overflow_y_scrollbar().child(scroll))
                    .child(hairline(cx))
                    .child(
                        h_flex()
                            .w_full()
                            .px(px(28.))
                            .py(px(18.))
                            .gap(px(10.))
                            .child(div().flex_1().when_some(notice, |d, n| d.child(t(n).size(12.).color(red(cx)).lines(2))))
                            .child(plain_button("meeting.speakers.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| {
                                this.assign = None;
                                cx.notify();
                            })).content(sheet_button("Cancel", false, cx)))
                            .child(plain_button("meeting.speakers.save", if done { "Done" } else { "Save names" }).disabled(!can_save).disabled_opacity(0.45).on_click(cx.listener(|this, _, w, cx| this.save_assign(w, cx))).content(sheet_button(if done { "Done" } else { "Save names" }, true, cx))),
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
            column = column.child(h_flex().gap(px(8.)).child(t(includes).size(13.).color(p.muted)).child(plain_button(sid(format!("meeting.speakers.unmerge.{}", merged.id)), "Undo merge").on_click(cx.listener(move |this, _, _, cx| {
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
                    .px(px(6.))
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
            let mut list = v_flex().w_full().p(px(6.)).rounded(px(12.)).border_1().border_color(p.line);
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
        if let Some(e) = error {
            column = column.child(t(e).size(12.).color(red(cx)));
        }
        if let Some((target, name)) = duplicate {
            let speaker = id.clone();
            column = column.child(h_flex().gap(px(8.)).child(t(format!("Same name as {name}.")).size(12.).color(p.muted)).child(plain_button(sid(format!("meeting.speakers.merge.{position}")), "Merge").a11y_label(sid(format!("Merge into {name}"))).on_click(cx.listener(move |this, _, _, cx| this.merge_into(&speaker, &target, cx))).content(t("Merge").font(12., 500.).a11y_hidden())));
        }
        column
    }

    fn identity_view(&mut self, id: &str, s: &Section, b: IdentityBlock, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let id = id.to_string();
        let mut out = v_flex().id("identity.block").w_full().items_start().gap(px(8.));
        if let Some(remembered) = b.local_remembered {
            if remembered {
                return out.child(t("Your voice is remembered on this Mac.").size(12.).color(p.muted));
            }
            let on = s.action == IdentityAction::RememberLocal;
            return out.child(identity_toggle("identity.rememberLocal", "Remember my voice", on, cx, {
                let id = id.clone();
                move |this, cx| this.set_identity(&id, if on { IdentityAction::None } else { IdentityAction::RememberLocal }, cx)
            })).when(on, |d| d.child(t("Your voice will be remembered from this Mac's microphone.").size(12.).color(p.muted)));
        }
        if b.match_state != "Unknown" {
            out = out.child(t(b.match_state.clone()).size(12.).color(if b.needs_choice { orange(cx) } else { p.muted }).id("identity.matchState"));
        }
        if b.needs_choice {
            let picker_key = format!("merged.{id}");
            out = out.child(self.known_picker("identity.mergedPicker", "Choose a known speaker…", &picker_key, &b.picker, &id, true, cx));
            let speaker = id.clone();
            out = out.child(identity_toggle("identity.mergedKeepUnknown", "Keep Unknown", s.action == IdentityAction::ResolveMerged(None), cx, move |this, cx| this.set_identity(&speaker, IdentityAction::ResolveMerged(None), cx)));
            return out;
        }
        if b.shows_suggestion_actions {
            let identity = s.speaker.identity.clone();
            let second = identity.as_ref().and_then(|i| i.second.clone());
            let (a1, a2, a3) = (id.clone(), id.clone(), id.clone());
            let another = second.as_ref().map_or_else(|| "Choose another…".to_string(), |x| x.1.clone());
            let second_id = second.map(|x| x.0);
            let key = format!("another.{id}");
            let key2 = key.clone();
            out = out.child(
                h_flex()
                    .gap(px(12.))
                    .child(identity_toggle("identity.confirm", "Confirm", s.action == IdentityAction::Confirm, cx, move |this, cx| this.set_identity(&a1, IdentityAction::Confirm, cx)))
                    .child(identity_toggle("identity.chooseAnother", another, matches!(s.action, IdentityAction::ChooseAnother(_)), cx, move |this, cx| match &second_id {
                        Some(k) => this.set_identity(&a2, IdentityAction::ChooseAnother(k.clone()), cx),
                        None => this.toggle_picker(&key2, cx),
                    }))
                    .child(identity_toggle("identity.keepUnknown", "Keep Unknown", s.action == IdentityAction::KeepUnknown, cx, move |this, cx| this.set_identity(&a3, IdentityAction::KeepUnknown, cx))),
            );
            if self.assign.as_ref().is_some_and(|a| a.picker.as_deref() == Some(&key)) {
                out = out.child(self.known_rows(&b.picker, &id, true, cx));
            }
        } else if !b.picker.is_empty() {
            let key = format!("known.{id}");
            out = out.child(self.known_picker("identity.picker", "Known speakers…", &key, &b.picker, &id, false, cx));
        }
        if b.shows_remember {
            let (a1, a2) = (id.clone(), id.clone());
            let chosen = s.action == IdentityAction::Remember;
            let not_now = s.action == IdentityAction::NotNow;
            out = out.child(t(REMEMBER_QUESTION).size(12.)).child(
                h_flex()
                    .gap(px(12.))
                    .child(identity_toggle("identity.remember", "Remember", chosen, cx, move |this, cx| this.set_identity(&a1, IdentityAction::Remember, cx)))
                    .child(div().when(!not_now, |d| d.opacity(0.7)).child(identity_toggle("identity.notNow", "Not now", not_now, cx, move |this, cx| this.set_identity(&a2, IdentityAction::NotNow, cx)))),
            );
            if chosen {
                out = out.child(t(REMEMBER_SENTENCE).size(12.).color(p.muted).id("identity.rememberSentence"));
            }
        }
        if let Some(k) = b.duplicate_of.clone() {
            let (a1, a2) = (id.clone(), id.clone());
            out = out.child(t(format!("Is this {} you already remember?", k.name)).size(12.)).child(
                h_flex()
                    .gap(px(12.))
                    .child(identity_toggle("identity.samePerson", "Same person", false, cx, move |this, cx| this.set_identity(&a1, IdentityAction::SamePerson(k.id.clone()), cx)))
                    .child(identity_toggle("identity.someoneNew", "Someone new", s.action == IdentityAction::RememberNew, cx, move |this, cx| this.set_identity(&a2, IdentityAction::RememberNew, cx))),
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
        if let Some(r) = s.enrollment_result.clone() {
            out = out.child(t(r).size(12.).color(p.muted).id("identity.enrollmentResult"));
        }
        out
    }
    fn toggle_picker(&mut self, key: &str, cx: &mut Context<Self>) {
        if let Some(a) = &mut self.assign {
            a.picker = if a.picker.as_deref() == Some(key) { None } else { Some(key.to_string()) };
        }
        cx.notify();
    }
    #[allow(clippy::too_many_arguments)]
    fn known_picker(&mut self, accessibility: &'static str, title: &'static str, key: &str, known: &[KnownSpeaker], id: &str, merged: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let open = self.assign.as_ref().is_some_and(|a| a.picker.as_deref() == Some(key));
        let k = key.to_string();
        v_flex()
            .w_full()
            .items_start()
            .gap(px(4.))
            .child(plain_button(accessibility, title).on_click(cx.listener(move |this, _, _, cx| this.toggle_picker(&k, cx))).content(h_flex().pl(px(3.)).gap(px(4.)).child(t(title).size(13.).color(p.accent).a11y_hidden()).child(icon("chevron.down", 9., p.accent))))
            .when(open, |d| d.child(self.known_rows(known, id, merged, cx)))
    }
    fn known_rows(&mut self, known: &[KnownSpeaker], id: &str, merged: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let mut list = v_flex().w_full().p(px(6.)).rounded(px(12.)).border_1().border_color(p.line);
        for (i, k) in known.iter().enumerate() {
            let noun = if k.samples == 1 { "voice sample" } else { "voice samples" };
            let title = format!("{} \u{2014} {} {noun}", k.name, k.samples);
            let (speaker, known_id, name) = (id.to_string(), k.id.clone(), k.name.clone());
            list = list.child(menu_row(sid(format!("identity.known.{i}")), title, None, p.ink, Box::new(cx.listener(move |this, _: &ClickEvent, w, cx| {
                if merged {
                    this.set_identity(&speaker, IdentityAction::ResolveMerged(Some(known_id.clone())), cx);
                    return;
                }
                if let Some(a) = &mut this.assign {
                    a.model.pick_known(&known_id, &speaker);
                    a.picker = None;
                    if let Some(input) = a.inputs.get(&speaker) {
                        let name = name.clone();
                        input.update(cx, |s, cx| s.set_value(name, w, cx));
                    }
                }
                cx.notify();
            }))));
        }
        list
    }
}

fn sheet_button(title: &'static str, primary: bool, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    let (fill, text) = if primary { (p.ink, p.surface) } else { (p.canvas, p.ink) };
    div().h(px(38.)).px(px(18.)).flex().items_center().rounded(px(9.)).bg(fill).child(t(title).font(14., 500.).color(text).a11y_hidden())
}
fn identity_toggle(id: &'static str, title: impl Into<SharedString>, selected: bool, cx: &mut Context<NotetakerPage>, on: impl Fn(&mut NotetakerPage, &mut Context<NotetakerPage>) + 'static) -> impl IntoElement {
    let p = pal(cx);
    let title: SharedString = title.into();
    plain_button(id, title.clone()).a11y_selected(selected).on_click(cx.listener(move |this, _, _, cx| on(this, cx))).content(t(title).font(12., if selected { 600. } else { 500. }).color(if selected { p.accent } else { p.ink }).a11y_hidden())
}
