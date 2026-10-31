//! `SummaryTabView`. Generation is a worker; everything here reads and edits stored rows.
use super::*;
use std::collections::HashSet;
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
    /// Rows (`"summary"` or an item id) showing the AI's value.
    pub shown_ai: HashSet<String>,
    pub due: Entity<CalendarState>,
    pub roots: Vec<SpeakerSummary>,
    _subs: Vec<Subscription>,
}
impl SummaryState {
    pub fn new(window: &mut Window, cx: &mut Context<NotetakerPage>) -> Self {
        let item_input = cx.new(|cx| InputState::new(window, cx));
        let subs = vec![cx.subscribe_in(&item_input, window, |this: &mut NotetakerPage, _, e: &TextInputEvent, _, cx| match e {
            TextInputEvent::PressEnter { .. } => this.save_editing_item(cx),
            TextInputEvent::Change => cx.notify(),
            _ => {}
        })];
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
            due: cx.new(|cx| CalendarState::new(window, cx)),
            item_input,
            editing: None,
            shown_ai: HashSet::new(),
            roots: vec![],
            _subs: subs,
        }
    }
    pub fn reset(&mut self) {
        self.forced = None;
        self.forced_stale = false;
        self.copied = false;
        self.error = None;
        self.editing_summary = false;
        self.editing = None;
        self.shown_ai.clear();
    }
    pub fn apply_scenario(&mut self, name: &str) {
        match name {
            "eligible" => self.forced = Some(SummaryHeader::Eligible),
            "pending" => self.forced = Some(SummaryHeader::Pending(2)),
            "running" => self.forced = Some(SummaryHeader::Running("Analyzing".into())),
            "failed" => self.forced = Some(SummaryHeader::Failed(analysis_failure_text("backend_unavailable").into())),
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
    /// `model.highlighted`: speaker names in their palette color, each a link to Assign speakers.
    fn spans(&self, text: &str, cx: &App) -> Vec<Span> {
        let speakers: Vec<(String, String, usize)> = self.summary.roots.iter().map(|r| (r.id.clone(), r.label(), r.color)).collect();
        let mut out = vec![];
        let mut at = 0;
        for (start, end, id, color) in speaker_mentions(text, &speakers) {
            if start < at {
                continue;
            }
            out.push(span(text[at..start].to_string()));
            out.push(span(text[start..end].to_string()).color(speaker_text(color, cx)).link(id));
            at = end;
        }
        out.push(span(text[at..].to_string()));
        out
    }
    #[track_caller]
    fn linked(spans: Vec<Span>, cx: &Context<Self>) -> Txt {
        let page = cx.entity().downgrade();
        rich(spans).on_link(move |id, window, cx| {
            page.update(cx, |this, cx| this.open_assign(Some(id.to_string()), window, cx)).ok();
        })
    }
    #[track_caller]
    fn highlighted(&self, text: &str, cx: &Context<Self>) -> Txt {
        Self::linked(self.spans(text, cx), cx)
    }
    fn generate(&mut self, cx: &mut Context<Self>) {
        self.menu = None;
        let id = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()).unwrap_or_default();
        self.summary.error = if admit(&mut self.summary_queue, &id, false, QUEUE_CAPACITY) {
            let refused = Self::worker("Summary generation", cx).err();
            if refused.is_some() {
                self.summary_queue.retain(|q| q != &id);
            }
            refused
        } else {
            Some("Summary queue is full".into())
        };
        cx.notify();
    }
    fn write(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&Db, &str) -> Res<()>) {
        let Some(id) = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()) else { return };
        let Some(db) = db_of(cx) else { return };
        // `writeOverlay`: a capacity refusal reads as the persistence message too.
        self.summary.error = f(db, &id).err().map(|_| analysis_failure_text("persistence_failure").to_string());
        self.menu = None;
        self.summary_refresh(cx);
        cx.notify();
    }
    /// `removeAllEdits` and `removeEdit` use `try?`: a failure shows nothing (SUM-038).
    fn remove_quietly(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&Db, &str) -> Res<()>) {
        let Some(id) = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()) else { return };
        let Some(db) = db_of(cx) else { return };
        f(db, &id).ok();
        self.menu = None;
        self.summary_refresh(cx);
        cx.notify();
    }
    pub(crate) fn remove_all_edits(&mut self, cx: &mut Context<Self>) {
        self.remove_quietly(cx, |db, id| remove_all_overlays(db, id));
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
        self.summary.item_input.update(cx, |s, cx| {
            s.set_placeholder(if field == "owner" { "Name" } else { "Edit" }, window, cx);
            s.set_value(initial, window, cx);
        });
        self.summary.item_input.read(cx).focus_handle(cx).focus(window, cx);
        self.summary.editing = Some((item.id.clone(), field));
        self.menu = if field == "owner" { Some(format!("owner.{}", item.id)) } else { None };
        cx.notify();
    }
    pub(super) fn set_item(&mut self, item: &Item, field: &str, value: &str, ai: Option<String>, cx: &mut Context<Self>) {
        let key = source_key(&item.sources);
        self.summary.editing = None;
        self.write(cx, |db, id| set_overlay(db, id, OverlayTarget::Item(&item.id), field, value, ai.as_deref(), Some(&item.ai_text), &key, now_ms()));
    }
    /// Save on the open text or owner field. A blank owner stays open, as its disabled Save does.
    pub(crate) fn save_editing_item(&mut self, cx: &mut Context<Self>) {
        let Some((id, field)) = self.summary.editing.clone() else { return };
        let Some(item) = self.summary.model.as_ref().and_then(|m| [&m.action_items, &m.next_steps, &m.decisions].into_iter().flatten().find(|i| i.id == id).cloned()) else { return };
        let value = self.summary.item_input.read(cx).value().trim().to_string();
        match field {
            "owner" if value.is_empty() => {}
            "owner" => self.set_item(&item, "owner", &owner_value_mentioned(&value), Some(owner_text(&item.ai_owner)), cx),
            f => self.set_item(&item, f, &value, Some(item.ai_text.clone()), cx),
        }
    }
    fn begin_due(&mut self, item: &Item, window: &mut Window, cx: &mut Context<Self>) {
        let offset = offset_at(now_ms(), cx);
        let (y, m, d) = flow_core::history::civil_from_days((now_ms() / 1000 + offset as i64).div_euclid(86_400));
        let today = format!("{y:04}-{m:02}-{d:02}");
        let date = calendar_date(item.due_date.as_deref().unwrap_or(&today));
        self.summary.due.update(cx, |s, cx| s.set_date(date, window, cx));
        self.menu = Some(format!("due.{}", item.id));
        cx.notify();
    }
    fn set_due(&mut self, item: &Item, date: Option<&str>, cx: &mut Context<Self>) {
        self.set_item(item, "due_date", &due_value(date), item.ai_due_date.clone(), cx);
    }
    fn toggle_ai(&mut self, key: &str, cx: &mut Context<Self>) {
        if !self.summary.shown_ai.remove(key) {
            self.summary.shown_ai.insert(key.to_string());
        }
        cx.notify();
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
                    .test_support()
                    .w_full()
                    .gap(px(10.))
                    .p(px(10.))
                    .bg(p.warning.opacity(0.12))
                    .rounded(px(6.))
                    .child(icon("exclamationmark.triangle", 12., p.warning))
                    .child(div().flex_1().child(t(STALE_TEXT).size(12.).swift_lines().color(p.ink)))
                    .child(prototype_button("meeting.summary.stale.regenerate", "Regenerate").on_click(cx.listener(|this, _, _, cx| this.generate(cx)))),
            );
        }
        if let Some(e) = self.summary.error.clone() {
            out = out.child(div().id("meeting.summary.editError").test_support().child(t(e).size(11.).color(red(cx))));
        }
        let Some(model) = model else {
            let (text, read_transcript) = if self.summary.load_error {
                ("The summary could not be loaded.".to_string(), false)
            } else {
                match &header {
                    SummaryHeader::NotEligible(reason) => (reason.to_string(), true),
                    SummaryHeader::Eligible => ("No summary yet.".to_string(), false),
                    _ => ("Summarizing…".to_string(), false),
                }
            };
            return out.child(v_flex().w_full().items_start().gap(px(12.)).child(t(text).line_spacing(6.).color(p.muted)).when(read_transcript, |d| {
                d.child(plain_button("meeting.summary.readTranscript", "Read transcript").on_click(cx.listener(|this, _, _, cx| {
                    this.tab = Tab::Transcript;
                    cx.notify();
                })).content(t("Read transcript").size(15.).color(p.accent).a11y_hidden()))
            }));
        };
        out = out.child(self.summary_body(&model, cx));
        for topic in &model.topics {
            let mut column = v_flex().w_full().gap(px(9.)).pt(px(14.)).child(t(topic.title.clone()).font(15., 600.));
            for bullet in &topic.bullets {
                column = column.child(h_flex().items_start().gap(px(8.)).pl(px(6.)).child(t("•").size(15.).a11y_hidden()).child(div().flex_1().child(self.highlighted(bullet, cx).size(15.).line_spacing(5.))));
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
        let copied = self.summary.copied;
        let offset = offset_at(m.created_at, cx);
        let page = cx.entity().downgrade();
        let has_previous = model.is_some_and(|x| !x.previous_edits.is_empty());
        let has_edits = model.is_some_and(|x| x.summary_overlay.is_some() || !x.previous_edits.is_empty() || [&x.action_items, &x.next_steps, &x.decisions, &x.open_questions, &x.risks].iter().any(|l| l.iter().any(|i| !i.overlays.is_empty())));
        let edits_open = self.menu.as_deref() == Some("summary.edits");
        let generated = model.map(|x| generated_text(x.generated_at, offset));
        let edits = model.map(|x| x.previous_edits.clone()).unwrap_or_default();
        let plain_ink = |id: &'static str, title: &'static str, cx: &mut Context<Self>| plain_button(id, title).on_click(cx.listener(|this, _, _, cx| this.generate(cx))).content(t(title).size(13.).color(p.ink).a11y_hidden());
        h_flex()
            .id("meeting.summary.header")
            .test_support()
            .w_full()
            .h(px(44.))
            .pl(px(14.))
            .pr(px(6.))
            .gap(px(10.))
            .bg(p.canvas)
            .rounded(px(8.))
            .child(h_flex().gap(px(6.)).child(icon("lightbulb", 12., p.muted)).child(t(label).font(12., 500.).tracking(1.2).swift_lines().mono_digits().color(p.muted).id("meeting.summary.readingTime")))
            .child(div().flex_1())
            .map(|d| match header {
                SummaryHeader::NotEligible(_) => d,
                SummaryHeader::Eligible => d.child(plain_ink("meeting.summary.generate", "Generate", cx)),
                SummaryHeader::Pending(_) => d.child(t("Queued").size(13.).color(p.muted)).child(plain_ink("meeting.summary.cancel", "Cancel", cx)),
                SummaryHeader::Running(text) => d.child(t(text.clone()).size(13.).color(p.muted).lines(1)).child(plain_ink("meeting.summary.cancel", "Cancel", cx)),
                SummaryHeader::Failed(text) => d.child(t(text.clone()).size(13.).color(red(cx)).lines(1)).child(plain_ink("meeting.summary.retry", "Retry", cx)),
                SummaryHeader::Succeeded => d
                    .child(note_icon("meeting.summary.copy", if copied { "checkmark" } else { "square.on.square" }, if copied { "Copied" } else { "Copy summary" }, p.muted).on_click(cx.listener(|this, _, _, cx| this.copy_report(cx))))
                    .child(
                        div()
                            .relative()
                            .child(menu_trigger("meeting.summary.options", "Summary options", "ellipsis", 13., 20., p.accent).dropdown_menu(move |menu, _, _| {
                                let mut menu = menu
                                    .item(menu_entry("Regenerate").on_click(act(&page, |this, _, cx| this.generate(cx))))
                                    .item(menu_entry("Previous edits").disabled(!has_previous).on_click(act(&page, |this, _, cx| {
                                        this.menu = Some("summary.edits".into());
                                        cx.notify();
                                    })))
                                    .item(menu_entry("Remove all edits…").disabled(!has_edits).on_click(act(&page, |this, _, cx| {
                                        this.confirm = Some(Confirm::RemoveEdits);
                                        cx.notify();
                                    })));
                                if let Some(g) = generated.clone() {
                                    menu = menu.separator().label(menu_title(g));
                                }
                                menu
                            }))
                            .when(edits_open, |w| {
                                let mut list = v_flex().id("meeting.summary.previousEdits").p(px(14.)).gap(px(10.)).child(t("Previous edits").font(12., 600.));
                                for e in edits.clone() {
                                    let overlay = e.id.clone();
                                    list = list.child(
                                        v_flex()
                                            .gap(px(3.))
                                            .when_some(e.item_text.clone(), |d, x| d.child(t(x).size(11.).color(p.muted).lines(2)))
                                            .child(h_flex().gap(px(8.)).child(div().flex_1().min_w_0().child(t(e.user_value.clone()).size(11.).lines(1))).child(plain_button(sid(format!("meeting.summary.previous.delete.{}", e.id)), "Delete").on_click(cx.listener(move |this, _, _, cx| {
                                                let overlay = overlay.clone();
                                                this.remove_quietly(cx, move |db, _| remove_overlay(db, &overlay));
                                            })).content(t("Delete").size(11.).color(red(cx)).a11y_hidden()))),
                                    );
                                }
                                w.child(popover_panel(280., 32., cx, list))
                            }),
                    ),
            })
    }

    fn summary_body(&mut self, model: &ReadModel, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        if self.summary.editing_summary {
            return v_flex()
                .w_full()
                .gap(px(8.))
                .on_key_down(cx.listener(|this, e: &KeyDownEvent, _, cx| {
                    if e.keystroke.key == "escape" {
                        this.summary.editing_summary = false;
                        cx.notify();
                    }
                }))
                .child(div().id("meeting.summary.edit.frame").test_support().w_full().h(px(90.)).text_size(px(14.)).border_1().border_color(p.line).rounded(px(4.)).child(Textarea::new(&self.summary.summary_input).appearance(false).bordered(false).h_full().aria_label("Summary").accessibility_id("meeting.summary.editor")))
                .child(h_flex().gap(px(8.)).child(prototype_button("meeting.summary.edit.save", "Save").on_click(cx.listener(|this, _, _, cx| this.save_summary_edit(cx)))).child(plain_button("meeting.summary.edit.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| {
                    this.summary.editing_summary = false;
                    cx.notify();
                })).content(t("Cancel").color(p.muted).a11y_hidden())))
                .into_any_element();
        }
        let ai_shown = self.summary.shown_ai.contains("summary");
        let mut paragraphs = v_flex().w_full().gap(px(10.)).pb(px(4.));
        for part in if ai_shown { &model.ai_summary } else { &model.summary }.split("\n\n") {
            paragraphs = paragraphs.child(self.highlighted(part, cx).size(15.).line_spacing(6.).no_widow());
        }
        let overlay = model.summary_overlay.clone();
        let page = cx.entity().downgrade();
        div()
            .id("meeting.summary.text")
            .test_support()
            .w_full()
            .on_click(cx.listener(|this, e: &ClickEvent, w, cx| {
                if e.click_count() == 2 {
                    this.begin_summary_edit(w, cx);
                }
            }))
            .child(paragraphs)
            .context_menu(move |menu, _, _| {
                let menu = menu.item(menu_entry("Edit summary").on_click(act(&page, |this, w, cx| this.begin_summary_edit(w, cx))));
                let Some(id) = overlay.clone() else { return menu };
                menu.item(menu_entry(if ai_shown { "Hide AI value" } else { "Show AI value" }).on_click(act(&page, |this, _, cx| this.toggle_ai("summary", cx)))).item(menu_entry("Remove text edit").on_click(act(&page, move |this, _, cx| {
                    let id = id.clone();
                    this.remove_quietly(cx, move |db, _| remove_overlay(db, &id));
                })))
            })
            .into_any_element()
    }

    /// Scopes the ids that repeat per item, which accessibility requires to be unique.
    fn item_row(&mut self, item: &Item, cx: &mut Context<Self>) -> impl IntoElement {
        div().id(sid(format!("meeting.summary.item.{}.{}", item.kind, item.ordinal))).w_full().child(self.item_row_body(item, cx))
    }
    fn item_row_body(&mut self, item: &Item, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let action = item.kind == "action_item";
        let row_id = sid(format!("meeting.summary.item.{}.{}", item.kind, item.ordinal));
        let group = sid(format!("meeting.summary.group.{}", item.id));
        let ai_shown = self.summary.shown_ai.contains(&item.id);
        let (owner_key, due_key) = (format!("owner.{}", item.id), format!("due.{}", item.id));
        let popover = self.menu.as_deref() == Some(owner_key.as_str()) || self.menu.as_deref() == Some(due_key.as_str());
        let editing = self.summary.editing.as_ref().is_some_and(|e| e.0 == item.id && e.1 != "owner");
        let status_item = item.clone();
        let completed = item.status == "completed";
        let status_button = plain_button(sid(format!("meeting.summary.status.{}", item.ordinal)), if completed { "Mark open" } else { "Mark completed" }).on_click(cx.listener(move |this, _, _, cx| {
            let next = if status_item.status == "open" { "completed" } else { "open" };
            this.set_item(&status_item, "status", next, Some(status_item.status.clone()), cx);
        })).content(div().w(px(15.)).pt(px(3.)).child(if completed {
            // ponytail: the Kit icon set has no filled check, so the fill is drawn here.
            div().size(px(13.)).rounded_full().bg(p.success).flex().items_center().justify_center().child(icon("checkmark", 9., gpui::white())).into_any_element()
        } else {
            icon("circle", 13., p.muted).into_any_element()
        }));
        if editing {
            return h_flex()
                .id(row_id)
                .w_full()
                .gap(px(8.))
                .when(action, |d| d.py(px(3.)).child(status_button))
                .on_key_down(cx.listener(|this, e: &KeyDownEvent, _, cx| {
                    if e.keystroke.key == "escape" {
                        this.summary.editing = None;
                        cx.notify();
                    }
                }))
                .child(div().flex_1().child(Input::new(&self.summary.item_input).aria_label("Edit").accessibility_id("meeting.summary.editor.item")))
                .child(native_button("meeting.summary.edit.save", "Save").on_click(cx.listener(|this, _, _, cx| this.save_editing_item(cx))))
                .into_any_element();
        }
        let text = if ai_shown { item.ai_text.clone() } else { item.text.clone() };
        let edit_field = editable_field(&item.kind);
        let open_edit = item.clone();
        let text_id = sid(format!("meeting.summary.text.{}.{}", item.kind, item.ordinal));
        let done = item.status != "open";
        let text_el = if action {
            let spans = self.spans(&text, cx).into_iter().map(|s| if done { s.strike() } else { s }).collect();
            Self::linked(spans, cx).size(15.).line_spacing(5.).color(if done { p.muted } else { p.ink })
        } else {
            let mut spans = self.spans(&text, cx);
            // `ItemRow` drops an attribution the sentence already names.
            if let Some(a) = item.attribution.clone().filter(|a| !text.to_lowercase().contains(&a.to_lowercase())) {
                spans.push(span(" \u{2014} ").color(p.muted));
                spans.extend(self.spans(&a, cx));
            }
            Self::linked(spans, cx).size(15.).line_spacing(5.)
        };
        let body = div().id(text_id).test_support().w_full().on_click(cx.listener(move |this, e: &ClickEvent, w, cx| {
            if let (2, Some(f)) = (e.click_count(), edit_field) {
                this.begin_item_edit(&open_edit, f, open_edit.text.clone(), w, cx);
            }
        })).child(text_el);
        let mut controls = h_flex().gap(px(8.)).items_center();
        if edit_field.is_some() || !item.overlays.is_empty() {
            let label = if action { "Edit action item" } else { "Edit item" };
            let trigger = menu_trigger(sid(format!("meeting.summary.editMenu.{}.{}", item.kind, item.ordinal)), label, "ellipsis", 11., 20., p.muted);
            let (page, it, choices) = (cx.entity().downgrade(), item.clone(), owner_choices(&self.summary.roots));
            controls = controls.child(trigger.dropdown_menu(move |menu, w, cx| item_menu(menu, &page, &it, ai_shown, &choices, w, cx)));
        }
        if let Some(s) = item.sources.first().cloned() {
            controls = controls.child(plain_button(sid(format!("meeting.summary.source.{}.{}", item.kind, item.ordinal)), "View source").tooltip("View source").on_click(cx.listener(move |this, _, _, cx| this.view_source(&s, cx))).content(icon("arrow.up.right.square", 11., p.muted)));
        }
        let controls = hover_revealed(group.clone(), popover, div()).relative().child(controls).when(popover, |d| {
            let it = item.clone();
            if self.menu.as_deref() == Some(owner_key.as_str()) {
                let body = self.owner_popover(cx);
                d.child(popover_panel(220., 24., cx, body))
            } else {
                let body = self.due_popover(&it, cx);
                d.child(popover_panel(290., 24., cx, body))
            }
        });
        if !action {
            return h_flex().id(row_id).group(group).w_full().items_start().gap(px(8.)).pl(px(6.)).child(t("•").size(15.)).child(div().flex_1().min_w_0().child(body)).child(controls).into_any_element();
        }
        let owner = if ai_shown { item.ai_owner.clone() } else { item.owner.clone() };
        let due_date = if ai_shown { item.ai_due_date.clone() } else { item.due_date.clone() };
        let mut chips = h_flex().gap(px(8.)).child(self.owner_chip(item, owner, cx));
        if let Some(date) = due_date {
            chips = chips.child(t(format!("Due {}", due_text(&date))).size(11.).swift_lines().color(p.muted));
        } else if item.due_state == "unresolved" {
            let text = item.due_original.as_ref().map_or("Due: unclear".to_string(), |o| format!("Due: unclear (\"{o}\")"));
            chips = chips.child(t(text).size(11.).swift_lines().color(p.muted));
        }
        h_flex()
            .id(row_id)
            .group(group)
            .w_full()
            .items_start()
            .gap(px(8.))
            .py(px(3.))
            .child(status_button)
            .child(v_flex().flex_1().min_w_0().gap(px(5.)).child(body).child(chips))
            .child(controls)
            .into_any_element()
    }

    /// `Someone else…`: padding 12, width 220.
    fn owner_popover(&mut self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let blank = self.summary.item_input.read(cx).value().trim().is_empty();
        v_flex()
            .p(px(12.))
            .gap(px(8.))
            .child(t("Owner name").font(11., 600.))
            .child(Input::new(&self.summary.item_input).aria_label("Name").accessibility_id("meeting.summary.owner.name"))
            .child(h_flex().w_full().justify_end().child(native_button("meeting.summary.owner.save", "Save").disabled(blank).on_click(cx.listener(|this, _, _, cx| this.save_editing_item(cx)))))
    }

    /// `Pick date…`: the graphical date picker.
    fn due_popover(&mut self, item: &Item, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let (clear, save) = (item.clone(), item.clone());
        v_flex()
            .id("meeting.summary.due")
            .test_support()
            .w(px(220.))
            .py(px(12.))
            .gap(px(8.))
            // The small calendar already fills Swift's 220 frame, so only the buttons take its 12 inset.
            .child(Calendar::new(&self.summary.due).small())
            .child(
                h_flex()
                    .w_full()
                    .px(px(12.))
                    .child(native_button("meeting.summary.due.popover.clear", "Clear").on_click(cx.listener(move |this, _, _, cx| this.set_due(&clear, None, cx))))
                    .child(div().flex_1())
                    .child(native_button("meeting.summary.due.save", "Save").on_click(cx.listener(move |this, _, _, cx| {
                        let picked = calendar_text(&this.summary.due.read(cx).date());
                        this.set_due(&save, picked.as_deref(), cx);
                    }))),
            )
    }

    fn owner_chip(&mut self, item: &Item, owner: Owner, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let chip = h_flex().id("meeting.summary.owner").px(px(8.)).py(px(3.)).rounded_full();
        match owner {
            Owner::Participant(name, color, local) => chip.gap(px(6.)).bg(p.button).child(div().size(px(8.)).rounded_full().bg(speaker_dot(color, cx))).child(t(if local { "You".to_string() } else { name }).size(11.).swift_lines()).into_any_element(),
            Owner::Mentioned(name, known) => {
                let it = item.clone();
                let ai = owner_text(&item.ai_owner);
                // `acceptSuggestion`: the meeting speaker linked to that profile, else the profile.
                let roots = self.summary.roots.clone();
                h_flex()
                    .gap(px(6.))
                    // Swift strokes an overlay, which takes no layout: the border comes out of the padding.
                    .child(chip.px(px(7.)).py(px(2.)).border_1().border_color(p.line).child(v_flex().child(t(name).size(11.)).child(t("mentioned").size(9.).color(p.muted))))
                    .when_some(known, |d, (id, known_name)| {
                        let root = roots.iter().find(|r| r.identity.as_ref().and_then(|i| i.known_id.as_deref()) == Some(id.as_str())).map_or(id.clone(), |r| r.id.clone());
                        d.child(h_flex().gap(px(4.)).child(t(format!("might be {known_name}?")).size(9.).color(p.muted)).child(native_button("meeting.summary.owner.accept", "Accept").on_click(cx.listener(move |this, _, _, cx| this.set_item(&it, "owner", &owner_value_participant(&root), Some(ai.clone()), cx)))))
                    })
                    .into_any_element()
            }
            Owner::Unresolved(label) => chip.id("meeting.summary.owner.unresolved").test_support().px(px(7.)).py(px(2.)).border_1().border_dashed().border_color(p.muted).child(t(label).size(11.).color(p.muted)).into_any_element(),
        }
    }
}

/// `ItemEditMenu`: a native menu with Owner and Due date submenus for action items.
fn item_menu(menu: PopupMenu, page: &WeakEntity<NotetakerPage>, item: &Item, ai_shown: bool, choices: &[(String, String, usize)], window: &mut Window, cx: &mut Context<PopupMenu>) -> PopupMenu {
    let action = item.kind == "action_item";
    let mut menu = menu;
    if let Some(field) = editable_field(&item.kind) {
        let it = item.clone();
        menu = menu.item(menu_entry("Edit text").on_click(act(page, move |this, w, cx| this.begin_item_edit(&it, field, it.text.clone(), w, cx))));
    }
    if action {
        let (page2, it, list) = (page.clone(), item.clone(), choices.to_vec());
        menu = menu.submenu(menu_title("Owner"), window, cx, move |menu, _, _| {
            let mut menu = menu;
            for (id, name, color) in list.clone() {
                let it2 = it.clone();
                let page3 = page2.clone();
                menu = menu.item(
                    PopupMenuItem::element(move |_, cx| h_flex().gap(px(6.)).child(div().size(px(8.)).rounded_full().bg(speaker_dot(color, cx))).child(t(name.clone()).size(13.)))
                        .on_click(act(&page3, move |this, _, cx| this.set_item(&it2, "owner", &owner_value_participant(&id), Some(owner_text(&it2.ai_owner)), cx))),
                );
            }
            let (other, none) = (it.clone(), it.clone());
            menu.separator()
                .item(menu_entry("Someone else…").on_click(act(&page2, move |this, w, cx| this.begin_item_edit(&other, "owner", String::new(), w, cx))))
                .item(menu_entry("No owner").on_click(act(&page2, move |this, _, cx| this.set_item(&none, "owner", OWNER_VALUE_NONE, Some(owner_text(&none.ai_owner)), cx))))
        });
        let (page2, it) = (page.clone(), item.clone());
        menu = menu.submenu(menu_title("Due date"), window, cx, move |menu, _, _| {
            let pick = it.clone();
            let menu = menu.item(menu_entry("Pick date…").on_click(act(&page2, move |this, w, cx| this.begin_due(&pick, w, cx))));
            if it.due_date.is_some() || it.overlay("due_date").is_some() {
                let clear = it.clone();
                menu.item(menu_entry("Clear").on_click(act(&page2, move |this, _, cx| this.set_due(&clear, None, cx))))
            } else {
                menu
            }
        });
        let it = item.clone();
        let dismissed = it.status == "dismissed";
        menu = menu.item(menu_entry(if dismissed { "Reopen" } else { "Dismiss" }).on_click(act(page, move |this, _, cx| this.set_item(&it, "status", if dismissed { "open" } else { "dismissed" }, Some(it.status.clone()), cx))));
    }
    if !item.overlays.is_empty() {
        let id = item.id.clone();
        if editable_field(&item.kind).is_some() {
            menu = menu.separator();
        }
        menu = menu.item(menu_entry(if ai_shown { "Hide AI value" } else { "Show AI value" }).on_click(act(page, move |this, _, cx| this.toggle_ai(&id, cx))));
        let mut overlays = item.overlays.clone();
        overlays.sort();
        for (field, overlay) in overlays {
            let name = match field.as_str() {
                "owner" => "owner",
                "due_date" => "due-date",
                "status" => "status",
                _ => "text",
            };
            menu = menu.item(menu_entry(format!("Remove {name} edit")).on_click(act(page, move |this, _, cx| {
                let overlay = overlay.clone();
                this.remove_quietly(cx, move |db, _| remove_overlay(db, &overlay));
            })));
        }
    }
    menu
}

const STALE_TEXT: &str = "The transcript, speakers or notes changed after this summary.";

/// `OverlayField` has text edits for these kinds only; questions and risks read-only.
fn editable_field(kind: &str) -> Option<&'static str> {
    match kind {
        "action_item" => Some("task_text"),
        "decision" => Some("decision_text"),
        "next_step" => Some("next_step_text"),
        _ => None,
    }
}
/// `ownerText`: the overlay's AI snapshot is the owner's visible text.
fn owner_text(owner: &Owner) -> String {
    owner.text().to_string()
}
