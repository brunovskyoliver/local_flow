//! `SummaryTabView`. Generation is a worker; everything here reads and edits stored rows.
use super::*;
use std::time::Duration;

pub(crate) struct SummaryState {
    pub model: Option<ReadModel>,
    pub header: SummaryHeader,
    pub forced: Option<SummaryHeader>,
    pub forced_stale: bool,
    pub load_error: bool,
    pub copied: bool,
    pub error: Option<String>,
    pub editing_summary: bool,
    pub summary_input: Entity<TextareaState>,
    /// (item id, field) while its text or owner or due date is being typed.
    pub editing: Option<(String, &'static str)>,
    pub item_input: Entity<InputState>,
    pub shown_ai: Option<String>,
    pub roots: Vec<SpeakerSummary>,
}
impl SummaryState {
    pub fn new(window: &mut Window, cx: &mut Context<NotetakerPage>) -> Self {
        SummaryState {
            model: None,
            header: SummaryHeader::Eligible,
            forced: None,
            forced_stale: false,
            load_error: false,
            copied: false,
            error: None,
            editing_summary: false,
            summary_input: cx.new(|cx| TextareaState::new(window, cx)),
            item_input: cx.new(|cx| InputState::new(window, cx)),
            editing: None,
            shown_ai: None,
            roots: vec![],
        }
    }
    pub fn reset(&mut self) {
        self.forced = None;
        self.forced_stale = false;
        self.copied = false;
        self.error = None;
        self.editing_summary = false;
        self.editing = None;
        self.shown_ai = None;
    }
    pub fn apply_scenario(&mut self, name: &str) {
        match name {
            "eligible" => self.forced = Some(SummaryHeader::Eligible),
            "pending" => self.forced = Some(SummaryHeader::Pending(2)),
            "running" => self.forced = Some(SummaryHeader::Running("Summarizing with your server…".into())),
            "failed" => self.forced = Some(SummaryHeader::Failed("The summary could not be generated.".into())),
            "not-finished" => self.forced = Some(SummaryHeader::NotEligible(NOT_FINISHED)),
            "stale" => self.forced_stale = true,
            _ => {}
        }
    }
    fn header(&self) -> SummaryHeader {
        self.forced.clone().unwrap_or_else(|| self.header.clone())
    }
    /// With a forced header the stored summary only shows when the state keeps it on screen.
    fn visible(&self) -> Option<&ReadModel> {
        match self.forced {
            Some(SummaryHeader::Eligible | SummaryHeader::NotEligible(_)) => None,
            _ => self.model.as_ref(),
        }
    }
}

impl NotetakerPage {
    pub(crate) fn summary_refresh(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()) else { return };
        let Some(db) = db_of(cx) else { return };
        self.summary.header = summary_header(db, &id).unwrap_or(SummaryHeader::Failed("The summary could not be loaded.".into()));
        match read_model(db, &id) {
            Ok(m) => {
                self.summary.model = m;
                self.summary.load_error = false;
            }
            Err(_) => {
                self.summary.model = None;
                self.summary.load_error = true;
            }
        }
        self.summary.roots = speaker_summaries(db, &id).unwrap_or_default();
    }
    /// `model.highlighted`: speaker names in their palette color.
    fn spans(&self, text: &str, cx: &App) -> Vec<Span> {
        let speakers: Vec<(String, String, usize)> = self.summary.roots.iter().map(|r| (r.id.clone(), r.label(), r.color)).collect();
        let mut out = vec![];
        let mut at = 0;
        for (start, end, _, color) in speaker_mentions(text, &speakers) {
            if start < at {
                continue;
            }
            out.push(span(text[at..start].to_string()));
            out.push(span(text[start..end].to_string()).color(speaker_text(color, cx)));
            at = end;
        }
        out.push(span(text[at..].to_string()));
        out
    }
    fn highlighted(&self, text: &str, cx: &App) -> Txt {
        rich(self.spans(text, cx))
    }
    fn generate(&mut self, cx: &mut Context<Self>) {
        self.menu = None;
        self.summary.error = Self::worker("Summary generation", cx).err();
        cx.notify();
    }
    fn write(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&Db, &str) -> Res<()>) {
        let Some(id) = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()) else { return };
        let Some(db) = db_of(cx) else { return };
        self.summary.error = f(db, &id).err().map(|_| "The edit could not be saved.".to_string());
        self.menu = None;
        self.summary_refresh(cx);
        cx.notify();
    }
    pub(crate) fn remove_all_edits(&mut self, cx: &mut Context<Self>) {
        self.write(cx, |db, id| remove_all_overlays(db, id));
    }
    fn copy_report(&mut self, cx: &mut Context<Self>) {
        let (Some(m), Some(d)) = (self.summary.model.clone(), self.lib.detail.clone()) else { return };
        let offset = offset_at(d.meeting.created_at, cx);
        cx.write_to_clipboard(ClipboardItem::new_string(report_text(&m, &d.meeting.display_title(offset), &report_date(d.meeting.created_at, offset))));
        self.summary.copied = true;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            this.update(cx, |this, cx| {
                this.summary.copied = false;
                cx.notify();
            })
            .ok();
        })
        .detach();
        cx.notify();
    }
    fn begin_summary_edit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.summary.model.as_ref().map_or(String::new(), |m| m.summary.clone());
        self.summary.summary_input.update(cx, |s, cx| s.set_value(text, window, cx));
        self.summary.editing_summary = true;
        self.menu = None;
        cx.notify();
    }
    fn save_summary_edit(&mut self, cx: &mut Context<Self>) {
        let value = self.summary.summary_input.read(cx).value().to_string();
        let Some(m) = self.summary.model.clone() else { return };
        self.summary.editing_summary = false;
        let key = source_key(&m.summary_sources);
        self.write(cx, |db, id| set_overlay(db, id, OverlayTarget::Summary, "summary_text", &value, Some(&m.ai_summary), Some(&m.ai_summary), &key, now_ms()));
    }
    fn begin_item_edit(&mut self, item: &Item, field: &'static str, initial: String, window: &mut Window, cx: &mut Context<Self>) {
        self.summary.item_input.update(cx, |s, cx| s.set_value(initial, window, cx));
        self.summary.editing = Some((item.id.clone(), field));
        self.menu = None;
        cx.notify();
    }
    fn set_item(&mut self, item: &Item, field: &str, value: &str, ai: Option<String>, cx: &mut Context<Self>) {
        let key = source_key(&item.sources);
        self.summary.editing = None;
        self.write(cx, |db, id| set_overlay(db, id, OverlayTarget::Item(&item.id), field, value, ai.as_deref(), Some(&item.ai_text), &key, now_ms()));
    }
    fn save_item_edit(&mut self, item: &Item, cx: &mut Context<Self>) {
        let Some((_, field)) = self.summary.editing.clone() else { return };
        let value = self.summary.item_input.read(cx).value().trim().to_string();
        match field {
            "owner" => self.set_item(item, "owner", &owner_value_mentioned(&value), Some(owner_json(&item.ai_owner)), cx),
            "due_date" => {
                if !valid_date(&value) {
                    self.summary.error = Some("Enter the date as YYYY-MM-DD.".into());
                    cx.notify();
                    return;
                }
                self.set_item(item, "due_date", &due_value(Some(&value)), Some(due_value(item.ai_due_date.as_deref())), cx)
            }
            f => self.set_item(item, f, &value, Some(item.ai_text.clone()), cx),
        }
    }
    fn view_source(&mut self, source: &SourceRef, cx: &mut Context<Self>) {
        match source {
            SourceRef::Segment(id) => self.reveal_segment(id, cx),
            SourceRef::Note(ordinal, hash) => self.reveal_note(*ordinal, hash, cx),
        }
    }

    pub(crate) fn summary_section(&mut self, m: &MeetingRow, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let header = self.summary.header();
        let model = self.summary.visible().cloned();
        let stale = model.as_ref().is_some_and(|x| x.stale) || self.summary.forced_stale;
        let mut out = v_flex().id("meeting.summary").w_full().gap(px(20.)).child(self.summary_header_row(m, &header, model.as_ref(), cx));
        if stale && model.is_some() {
            out = out.child(
                h_flex()
                    .id("meeting.summary.stale")
                    .w_full()
                    .gap(px(8.))
                    .p(px(10.))
                    .gap(px(10.))
                    .bg(p.warning.opacity(0.12))
                    .rounded(px(6.))
                    .child(icon("exclamationmark.triangle", 12., p.warning))
                    .child(div().flex_1().child(t("The transcript, speakers or notes changed after this summary.").size(12.)))
                    .child(prototype_button("meeting.summary.stale.regenerate", "Regenerate").on_click(cx.listener(|this, _, _, cx| this.generate(cx)))),
            );
        }
        if let Some(e) = self.summary.error.clone() {
            out = out.child(t(e).size(11.).color(red(cx)).id("meeting.summary.editError"));
        }
        let Some(model) = model else {
            let text = if self.summary.load_error {
                "The summary could not be loaded.".to_string()
            } else {
                match &header {
                    SummaryHeader::NotEligible(reason) => reason.to_string(),
                    SummaryHeader::Pending(_) | SummaryHeader::Running(_) => "Summarizing…".to_string(),
                    _ => "No summary yet.".to_string(),
                }
            };
            return out.child(v_flex().w_full().items_center().gap(px(8.)).py(px(40.)).child(t(text).size(14.).color(p.muted).center()).child(plain_button("meeting.summary.readTranscript", "Read transcript").on_click(cx.listener(|this, _, _, cx| {
                this.tab = Tab::Transcript;
                cx.notify();
            })).content(t("Read transcript").size(13.).color(p.accent).a11y_hidden())));
        };
        out = out.child(self.summary_body(&model, cx));
        for topic in &model.topics {
            let mut column = v_flex().w_full().gap(px(9.)).pt(px(14.)).child(t(topic.title.clone()).font(15., 600.));
            for bullet in &topic.bullets {
                column = column.child(h_flex().items_start().gap(px(8.)).pl(px(6.)).child(t("•").size(15.)).child(div().flex_1().child(self.highlighted(bullet, cx).size(15.).line_spacing(5.))));
            }
            out = out.child(column);
        }
        for (title, id, items) in [("Action items", "meeting.summary.actionItems", &model.action_items), ("Next steps", "meeting.summary.nextSteps", &model.next_steps), ("Decisions", "meeting.summary.decisions", &model.decisions), ("Open questions", "meeting.summary.openQuestions", &model.open_questions), ("Risks", "meeting.summary.risks", &model.risks)] {
            if items.is_empty() {
                continue;
            }
            let mut column = v_flex().id(id).w_full().gap(px(9.)).pt(px(14.)).child(t(title).font(15., 600.));
            for item in items {
                column = column.child(self.item_row(item, cx));
            }
            out = out.child(column);
        }
        out
    }

    fn summary_header_row(&mut self, m: &MeetingRow, header: &SummaryHeader, model: Option<&ReadModel>, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let label = model.map_or("SUMMARY".to_string(), |x| format!("{} MIN READ", x.reading_minutes));
        let open = self.menu.as_deref() == Some("summary.options");
        let copied = self.summary.copied;
        let offset = offset_at(m.created_at, cx);
        let has_previous = model.is_some_and(|x| !x.previous_edits.is_empty());
        let has_edits = model.is_some_and(|x| x.summary_overlay.is_some() || !x.previous_edits.is_empty() || [&x.action_items, &x.next_steps, &x.decisions].iter().any(|l| l.iter().any(|i| !i.overlays.is_empty())));
        let edits_open = self.menu.as_deref() == Some("summary.edits");
        let generated = model.map(|x| generated_text(x.generated_at, offset));
        let edits = model.map(|x| x.previous_edits.clone()).unwrap_or_default();
        h_flex()
            .w_full()
            .h(px(44.))
            .pl(px(14.))
            .pr(px(6.))
            .gap(px(10.))
            .bg(p.canvas)
            .rounded(px(8.))
            .child(h_flex().gap(px(6.)).child(icon("lightbulb", 13., p.muted)).child(t(label).font(12., 500.).tracking(1.2).color(p.muted).id("meeting.summary.readingTime")))
            .child(div().flex_1())
            .map(|d| match header {
                SummaryHeader::Eligible => d.child(prototype_button("meeting.summary.generate", "Generate summary").on_click(cx.listener(|this, _, _, cx| this.generate(cx)))),
                SummaryHeader::Pending(_) => d.child(t("Queued").size(13.).color(p.muted)).child(plain_button("meeting.summary.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| this.generate(cx))).content(t("Cancel").size(13.).color(p.accent).a11y_hidden())),
                SummaryHeader::Running(text) => d.child(Spinner::new().small()).child(t(text.clone()).size(13.).color(p.muted).lines(1)).child(plain_button("meeting.summary.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| this.generate(cx))).content(t("Cancel").size(13.).color(p.accent).a11y_hidden())),
                SummaryHeader::Failed(text) => d.child(t(text.clone()).size(13.).color(red(cx)).lines(1)).child(plain_button("meeting.summary.retry", "Retry").on_click(cx.listener(|this, _, _, cx| this.generate(cx))).content(t("Retry").size(13.).color(p.accent).a11y_hidden())),
                _ => d,
            })
            .when(model.is_some(), |d| {
                d.child(note_icon("meeting.summary.copy", if copied { "checkmark" } else { "doc.on.doc" }, if copied { "Copied" } else { "Copy summary" }, p.muted).on_click(cx.listener(|this, _, _, cx| this.copy_report(cx)))).child(
                    div()
                        .relative()
                        .child(note_icon("meeting.summary.options", "ellipsis", "Summary options", p.accent).on_click(cx.listener(|this, _, _, cx| this.toggle_menu("summary.options", cx))))
                        .when(open, |w| {
                            let items_base = v_flex().p(px(8.)).gap(px(2.)).child(menu_row("meeting.summary.regenerate", "Regenerate", None, p.ink, Box::new(cx.listener(|this, _: &ClickEvent, _, cx| this.generate(cx)))))
                                .child(menu_row("meeting.summary.showPrevious", "Previous edits", None, p.ink, Box::new(cx.listener(|this, _: &ClickEvent, _, cx| {
                                    this.menu = Some("summary.edits".into());
                                    cx.notify();
                                }))).disabled(!has_previous))
                                .child(menu_row("meeting.summary.removeEdits", "Remove all edits…", None, red(cx), Box::new(cx.listener(|this, _: &ClickEvent, _, cx| {
                                    this.menu = None;
                                    this.confirm = Some(Confirm::RemoveEdits);
                                    cx.notify();
                                }))).disabled(!has_edits));
                            let mut items = items_base;
                            if let Some(g) = generated.clone() {
                                items = items.child(div().px(px(10.)).py(px(6.)).child(t(g).size(11.).color(p.muted)));
                            }
                            w.child(popover_panel(240., 32., cx, items))
                        })
                        .when(edits_open, |w| {
                            let mut list = v_flex().id("meeting.summary.previousEdits").p(px(14.)).gap(px(10.)).child(t("Previous edits").font(13., 600.));
                            for e in edits.clone() {
                                let overlay = e.id.clone();
                                list = list.child(plain_button(sid(format!("meeting.summary.previous.delete.{}", e.id)), "Delete").on_click(cx.listener(move |this, _, _, cx| {
                                    let overlay = overlay.clone();
                                    this.write(cx, move |db, _| remove_overlay(db, &overlay));
                                })).content(t("Delete").size(11.).color(p.accent).a11y_hidden()));
                                list = list.child(v_flex().gap(px(2.)).when_some(e.item_text.clone(), |d, x| d.child(t(x).size(11.).color(p.muted))).child(t(e.user_value.clone()).size(13.)).when_some(e.ai_value.clone(), |d, x| d.child(t(format!("AI: {x}")).size(11.).color(p.muted))));
                            }
                            w.child(popover_panel(280., 32., cx, list))
                        }),
                )
            })
    }

    fn summary_body(&mut self, model: &ReadModel, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        if self.summary.editing_summary {
            return v_flex()
                .w_full()
                .gap(px(8.))
                .child(div().w_full().h(px(180.)).text_size(px(14.)).child(Textarea::new(&self.summary.summary_input).h_full().aria_label("Summary").accessibility_id("meeting.summary.editor")))
                .child(h_flex().gap(px(8.)).child(prototype_button("meeting.summary.edit.save", "Save").on_click(cx.listener(|this, _, _, cx| this.save_summary_edit(cx)))).child(prototype_button("meeting.summary.edit.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| {
                    this.summary.editing_summary = false;
                    cx.notify();
                }))))
                .into_any_element();
        }
        let group: SharedString = "meeting.summary.body".into();
        let open = self.menu.as_deref() == Some("summary.body");
        let mut paragraphs = v_flex().flex_1().gap(px(10.));
        for part in model.summary.split("\n\n") {
            paragraphs = paragraphs.child(self.highlighted(part, cx).size(15.).line_spacing(6.));
        }
        let ai_shown = self.summary.shown_ai.as_deref() == Some("summary");
        let overlay = model.summary_overlay.clone();
        let ai = model.ai_summary.clone();
        h_flex()
            .group(group.clone())
            .w_full()
            .items_start()
            .gap(px(4.))
            .child(div().id("meeting.summary.text").flex_1().on_click(cx.listener(|this, e: &ClickEvent, w, cx| {
                if e.click_count() == 2 {
                    this.begin_summary_edit(w, cx);
                }
            })).child(paragraphs).when(ai_shown, |d| d.child(t(ai).size(12.).color(p.muted))))
            .child(
                div()
                    .relative()
                    .child(hover_revealed(group, open, div()).child(plain_button("meeting.summary.editMenu", "Edit summary").tooltip("Edit summary").on_click(cx.listener(|this, _, _, cx| this.toggle_menu("summary.body", cx))).content(div().size(px(20.)).flex().items_center().justify_center().child(icon("ellipsis", 11., p.muted)))))
                    .when(open, |w| {
                        let mut items = v_flex().p(px(8.)).gap(px(2.)).child(menu_row("meeting.summary.edit", "Edit summary", None, p.ink, Box::new(cx.listener(|this, _: &ClickEvent, w, cx| this.begin_summary_edit(w, cx)))));
                        if let Some(id) = overlay {
                            items = items.child(menu_row("meeting.summary.showAI", if ai_shown { "Hide AI value" } else { "Show AI value" }, None, p.ink, Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.summary.shown_ai = if ai_shown { None } else { Some("summary".into()) };
                                this.menu = None;
                                cx.notify();
                            })))).child(menu_row("meeting.summary.removeText", "Remove text edit", None, p.ink, Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                let id = id.clone();
                                this.write(cx, move |db, _| remove_overlay(db, &id));
                            }))));
                        }
                        w.child(popover_panel(220., 24., cx, items))
                    }),
            )
            .into_any_element()
    }

    fn item_row(&mut self, item: &Item, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let action = item.kind == "action_item";
        let key = format!("item.{}", item.id);
        let group = sid(format!("meeting.summary.group.{}", item.id));
        let open = self.menu.as_deref() == Some(key.as_str());
        let done = item.status != "open";
        let ai_shown = self.summary.shown_ai.as_deref() == Some(&item.id);
        let editing = self.summary.editing.as_ref().filter(|e| e.0 == item.id).map(|e| e.1);
        let attribution = item.attribution.clone().filter(|a| !item.text.contains(a.as_str()));
        // Action items carry their owner in a chip.
        let attribution = attribution.filter(|_| !action);
        let attribution_text = attribution.map_or(String::new(), |a| format!(" \u{2014} {a}"));
        let text = item.text.clone();
        let mut body = v_flex().flex_1().min_w_0().gap(px(6.));
        if let Some(field) = editing {
            let (save, placeholder) = (item.clone(), if field == "due_date" { "YYYY-MM-DD" } else if field == "owner" { "Owner name" } else { "Text" });
            body = body.child(
                h_flex()
                    .w_full()
                    .gap(px(8.))
                    .child(div().flex_1().text_size(px(13.)).child(Input::new(&self.summary.item_input).aria_label(placeholder).accessibility_id(if field == "due_date" { "meeting.summary.due" } else { "meeting.summary.editor.item" })))
                    .child(prototype_button("meeting.summary.item.save", "Save").on_click(cx.listener(move |this, _, _, cx| this.save_item_edit(&save, cx))))
                    .when(field == "due_date", |d| {
                        let clear = item.clone();
                        d.child(prototype_button("meeting.summary.due.clear.inline", "Clear").on_click(cx.listener(move |this, _, _, cx| this.set_item(&clear, "due_date", &due_value(None), Some(due_value(clear.ai_due_date.as_deref())), cx))))
                    })
                    .child(prototype_button("meeting.summary.item.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| {
                        this.summary.editing = None;
                        cx.notify();
                    }))),
            );
        } else {
            body = body.child(if done && action { rich(vec![span(text.clone()).strike()]).size(15.).line_spacing(5.).color(p.muted).into_any_element() } else { {
                let mut spans = self.spans(&text, cx);
                if !attribution_text.is_empty() {
                    spans.push(span(attribution_text.clone()).color(p.muted));
                }
                rich(spans).size(15.).line_spacing(5.).into_any_element()
            } });
        }
        if ai_shown {
            body = body.child(t(format!("AI: {}", item.ai_text)).size(12.).color(p.muted));
        }
        if action {
            let mut chips = h_flex().gap(px(8.)).child(self.owner_chip(item, cx));
            if let Some(date) = &item.due_date {
                chips = chips.child(t(format!("Due {}", due_text(date))).size(11.).color(p.muted));
            } else if item.due_state == "unresolved" {
                chips = chips.child(t(format!("Due: unclear (\"{}\")", item.due_original.clone().unwrap_or_default())).size(11.).color(p.muted));
            }
            body = body.child(chips);
        }
        let status_item = item.clone();
        let source = item.sources.first().cloned();
        h_flex()
            .id(sid(format!("meeting.summary.item.{}.{}", item.kind, item.ordinal)))
            .group(group.clone())
            .w_full()
            .items_start()
            .gap(px(8.))
            .when(!action, |d| d.pl(px(6.)))
            .map(|d| {
                if action {
                    d.child(plain_button(sid(format!("meeting.summary.status.{}", item.ordinal)), if done { "Mark open" } else { "Mark completed" }).on_click(cx.listener(move |this, _, _, cx| {
                        let next = if status_item.status == "open" { "completed" } else { "open" };
                        this.set_item(&status_item, "status", next, Some("open".into()), cx);
                    })).content(div().pt(px(3.)).child(icon(if done { "checkmark.circle.fill" } else { "circle" }, 13., if done { p.accent } else { p.muted }))))
                } else {
                    d.child(t("•").size(15.))
                }
            })
            .child(body)
            .when_some(source, |d, s| {
                d.child(hover_revealed(group.clone(), false, div()).child(plain_button(sid(format!("meeting.summary.source.{}.{}", item.kind, item.ordinal)), "View source").tooltip("View source").on_click(cx.listener(move |this, _, _, cx| this.view_source(&s, cx))).content(div().size(px(20.)).flex().items_center().justify_center().child(icon("arrow.up.right.square", 11., p.muted)))))
            })
            .when(editable_field(&item.kind).is_some(), |d| d.child(
                div()
                    .relative()
                    .child(hover_revealed(group, open, div()).child(plain_button(sid(format!("meeting.summary.editMenu.{}.{}", item.kind, item.ordinal)), if action { "Edit action item" } else { "Edit item" }).on_click({
                        let key = key.clone();
                        cx.listener(move |this, _, _, cx| this.toggle_menu(&key, cx))
                    }).content(div().size(px(20.)).flex().items_center().justify_center().child(icon("ellipsis", 11., p.muted)))))
                    .when(open, |w| {
                        let items = self.item_menu(item, ai_shown, cx);
                        w.child(popover_panel(230., 24., cx, items))
                    }),
            ))
    }

    fn item_menu(&mut self, item: &Item, ai_shown: bool, cx: &mut Context<Self>) -> AnyElement {
        let p = pal(cx);
        let field: &'static str = editable_field(&item.kind).unwrap_or("");
        let mut items = v_flex().p(px(8.)).gap(px(2.));
        let row = |id: SharedString, title: String, on: Click| menu_row(id, title, None, p.ink, on);
        let it = item.clone();
        items = items.child(row("meeting.summary.edit".into(), if item.kind == "action_item" { "Edit text".into() } else { "Edit item".into() }, Box::new(cx.listener(move |this, _: &ClickEvent, w, cx| this.begin_item_edit(&it, field, it.text.clone(), w, cx)))));
        if item.kind == "action_item" {
            for (i, (id, name, _)) in owner_choices(&self.summary.roots).into_iter().enumerate() {
                let it = item.clone();
                let ai = owner_json(&item.ai_owner);
                items = items.child(row(sid(format!("meeting.summary.owner.choice.{i}")), format!("Owner: {name}"), Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| this.set_item(&it, "owner", &owner_value_participant(&id), Some(ai.clone()), cx)))));
            }
            let it = item.clone();
            items = items.child(row("meeting.summary.owner.other".into(), "Someone else…".into(), Box::new(cx.listener(move |this, _: &ClickEvent, w, cx| this.begin_item_edit(&it, "owner", String::new(), w, cx)))));
            let it = item.clone();
            let ai = owner_json(&item.ai_owner);
            items = items.child(row("meeting.summary.owner.none".into(), "No owner".into(), Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| this.set_item(&it, "owner", OWNER_VALUE_NONE, Some(ai.clone()), cx)))));
            let it = item.clone();
            items = items.child(row("meeting.summary.due.pick".into(), "Set due date…".into(), Box::new(cx.listener(move |this, _: &ClickEvent, w, cx| this.begin_item_edit(&it, "due_date", it.due_date.clone().unwrap_or_default(), w, cx)))));
            if item.due_date.is_some() {
                let it = item.clone();
                items = items.child(row("meeting.summary.due.clear".into(), "Clear due date".into(), Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| this.set_item(&it, "due_date", &due_value(None), Some(due_value(it.ai_due_date.as_deref())), cx)))));
            }
            let it = item.clone();
            let dismissed = item.status == "dismissed";
            items = items.child(row("meeting.summary.dismiss".into(), if dismissed { "Reopen".into() } else { "Dismiss".into() }, Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| this.set_item(&it, "status", if dismissed { "open" } else { "dismissed" }, Some("open".into()), cx)))));
        }
        if !item.overlays.is_empty() {
            let id = item.id.clone();
            items = items.child(row("meeting.summary.showAI".into(), if ai_shown { "Hide AI value".into() } else { "Show AI value".into() }, Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.summary.shown_ai = if ai_shown { None } else { Some(id.clone()) };
                this.menu = None;
                cx.notify();
            }))));
            for (i, (field, overlay)) in item.overlays.iter().cloned().enumerate() {
                let name = match field.as_str() {
                    "owner" => "owner",
                    "due_date" => "due-date",
                    "status" => "status",
                    _ => "text",
                };
                items = items.child(row(sid(format!("meeting.summary.removeEdit.{i}")), format!("Remove {name} edit"), Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    let overlay = overlay.clone();
                    this.write(cx, move |db, _| remove_overlay(db, &overlay));
                }))));
            }
        }
        items.into_any_element()
    }

    fn owner_chip(&mut self, item: &Item, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let chip = h_flex().id("meeting.summary.owner").gap(px(5.)).px(px(8.)).py(px(3.)).rounded_full();
        match item.owner.clone() {
            Owner::Participant(name, color, local) => chip.bg(p.button).child(div().size(px(8.)).rounded_full().bg(speaker_dot(color, cx))).child(t(if local { "You".to_string() } else { name }).size(11.)).into_any_element(),
            Owner::Mentioned(name, known) => {
                let it = item.clone();
                let ai = owner_json(&item.ai_owner);
                chip.border_1()
                    .border_color(p.line)
                    .child(t(name).size(11.))
                    .child(t("mentioned").size(9.).color(p.muted))
                    .when_some(known, |d, (id, known_name)| {
                        d.child(t(format!("might be {known_name}?")).size(9.).color(p.muted)).child(plain_button("meeting.summary.owner.accept", "Accept").on_click(cx.listener(move |this, _, _, cx| this.set_item(&it, "owner", &owner_value_participant(&id), Some(ai.clone()), cx))).content(t("Accept").size(9.).color(p.accent).a11y_hidden()))
                    })
                    .into_any_element()
            }
            Owner::Unresolved(label) => chip.border_1().border_dashed().border_color(p.line).child(t(label).size(11.).color(p.muted)).into_any_element(),
        }
    }
}

/// `OverlayField` has text edits for these kinds only; questions and risks read-only.
fn editable_field(kind: &str) -> Option<&'static str> {
    match kind {
        "action_item" => Some("task_text"),
        "decision" => Some("decision_text"),
        "next_step" => Some("next_step_text"),
        _ => None,
    }
}
fn owner_json(owner: &Owner) -> String {
    match owner {
        Owner::Participant(name, ..) | Owner::Mentioned(name, _) => owner_value_mentioned(name),
        Owner::Unresolved(_) => OWNER_VALUE_NONE.to_string(),
    }
}
fn valid_date(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() == 10 && b[4] == b'-' && b[7] == b'-' && text.split('-').all(|p| p.bytes().all(|c| c.is_ascii_digit()))
}
