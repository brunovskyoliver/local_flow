//! The Transcript tab: the header, status lines, paged rows and the live list.
use super::*;
use std::time::Duration;

impl NotetakerPage {
    pub(crate) fn search_changed(&mut self, cx: &mut Context<Self>) {
        self.search_epoch += 1;
        let epoch = self.search_epoch;
        let live = self.lib.detail.as_ref().is_some_and(|d| self.status.as_ref().is_some_and(|s| s.id == d.meeting.id));
        if let Some(p) = &mut self.pager {
            p.is_searching = !live;
        }
        cx.notify();
        if live {
            return;
        }
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(250)).await;
            this.update(cx, |this, cx| {
                if this.search_epoch != epoch {
                    return;
                }
                let query = this.search.read(cx).value().to_string();
                if let (Some(db), Some(p)) = (db_of(cx), &mut this.pager) {
                    p.search(db, &query);
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }
    /// Swift's sentinels: the next page loads when its edge scrolls into view, and the reader's
    /// row stays put when a page is evicted on the far side.
    pub(crate) fn page_on_scroll(&mut self, cx: &mut Context<Self>) {
        if self.tab != Tab::Transcript {
            return;
        }
        let (y, max) = (-self.scroll.offset().y.as_f32(), self.scroll.max_offset().y.as_f32());
        let Some(db) = db_of(cx) else { return };
        let Some(p) = &mut self.pager else { return };
        if y >= max - 200. && p.has_next() {
            p.load_next(db);
            cx.notify();
        } else if y < 200. && p.has_previous() {
            p.load_previous(db);
            cx.notify();
        }
    }
    fn close_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search.update(cx, |s, cx| s.set_value("", window, cx));
        self.search_open = false;
        cx.notify();
    }
    fn copy_full(&mut self, cx: &mut Context<Self>) {
        self.menu = None;
        self.transcript_notice = None;
        let Some(db) = db_of(cx) else { return };
        let Some(p) = &self.pager else { return };
        match p.full_text(db) {
            Ok(text) => cx.write_to_clipboard(ClipboardItem::new_string(text)),
            Err(None) => self.transcript_notice = Some("The transcript is too long to copy. Export it to a file instead.".into()),
            Err(Some(_)) => self.transcript_notice = Some("The transcript could not be copied.".into()),
        }
        cx.notify();
    }
    fn correct(&mut self, segment: &str, to: Correction, cx: &mut Context<Self>) {
        self.menu = None;
        let Some(m) = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()) else { return };
        let Some(db) = db_of(cx) else { return };
        if correct_segment(db, &m, segment, &to, now_ms()).is_ok() {
            if let Some(p) = &mut self.pager {
                p.refresh_labels(db);
            }
        }
        cx.notify();
    }
    fn confirm_identity(&mut self, root: &str, known: &str, cx: &mut Context<Self>) {
        let Some(m) = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()) else { return };
        let Some(db) = db_of(cx) else { return };
        match link(db, &m, root, known, "user_confirmation", now_ms()) {
            Ok(()) => {
                if let Some(p) = &mut self.pager {
                    p.refresh_labels(db);
                }
            }
            Err(_) => {
                if let Some(p) = &mut self.pager {
                    p.notice = Some("The speaker could not be confirmed.".into());
                }
            }
        }
        cx.notify();
    }
    /// A View-source jump: switch tabs, load the page, flash for two seconds.
    pub(crate) fn reveal_segment(&mut self, id: &str, cx: &mut Context<Self>) {
        self.tab = Tab::Transcript;
        if let (Some(db), Some(p)) = (db_of(cx), &mut self.pager) {
            p.reveal(db, id);
        }
        self.schedule_highlight_clear(cx);
        cx.notify();
    }
    fn schedule_highlight_clear(&mut self, cx: &mut Context<Self>) {
        let target = self.pager.as_ref().and_then(|p| p.highlighted.clone());
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            this.update(cx, |this, cx| {
                if let Some(p) = &mut this.pager {
                    if p.highlighted == target {
                        p.highlighted = None;
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    pub(crate) fn transcript_section(&mut self, d: &Detail, live: Option<&LiveStatus>, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let row = self.pager.as_ref().and_then(|x| x.row.clone());
        let shows_speakers = live.is_none() && is_terminal(&d.meeting.state) && row.as_ref().is_some_and(|r| r.state == "final");
        let has_speakers = self.pager.as_ref().is_some_and(|x| x.speakers.is_some());
        let identify = shows_speakers && cx.global::<Core>().prefs.bool_or("speakerIdentificationEnabled", true);
        let failure = row.as_ref().and_then(|r| r.failure_category.as_ref().map(|c| transcript_failure_text(c, r.segment_count, r.state == "finalizing", r.engine.as_deref() == Some("whisper.cpp"))));
        let notice = self.pager.as_ref().and_then(|x| x.notice.clone());
        let action = self.transcript_notice.clone();
        let mut out = v_flex().id("meeting.transcript").w_full().gap(px(16.)).child(self.transcript_header(d, live, shows_speakers && has_speakers, cx));
        if shows_speakers && self.speaker_run.is_some() {
            out = out.child(self.speaker_status_line(has_speakers, cx));
        }
        if identify {
            if self.identify_run.is_some() || self.past_search.is_some() || self.enrolling {
                out = out.child(self.identification_status_line(cx));
            }
            if let Some((name, count)) = self.past_prompt.clone() {
                let _ = name;
                let noun = if count == 1 { "meeting" } else { "meetings" };
                out = out.child(
                    h_flex()
                        .id("identity.pastSearchPrompt")
                        .gap(px(10.))
                        .p(px(10.))
                        .bg(p.canvas)
                        .rounded(px(6.))
                        .child(t(format!("Look for this voice in past meetings? {count} {noun} would be checked.")).size(12.))
                        .child(plain_button("identity.pastSearch", "Look").on_click(cx.listener(|this, _, _, cx| {
                            this.past_prompt = None;
                            this.transcript_notice = Self::worker("Searching past meetings", cx).err();
                            cx.notify();
                        })).content(t("Look").size(12.).color(p.accent).a11y_hidden()))
                        .child(plain_button("identity.pastSearch.notNow", "Not now").on_click(cx.listener(|this, _, _, cx| {
                            this.past_prompt = None;
                            cx.notify();
                        })).content(t("Not now").size(12.).color(p.accent).a11y_hidden())),
                );
            }
        }
        for text in [failure, notice, action].into_iter().flatten() {
            out = out.child(t(text).size(15.).color(red(cx)));
        }
        if let Some(s) = live {
            return out.child(self.live_list(s, cx));
        }
        out.child(self.transcript_rows(d, cx))
    }

    fn transcript_header(&mut self, d: &Detail, live: Option<&LiveStatus>, assign: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let row = self.pager.as_ref().and_then(|x| x.row.clone());
        let badge = (live.is_none() && row.as_ref().map(|r| r.state.as_str()) != Some("final")).then(|| match &row {
            Some(r) => badge_text(&r.state, r.progress()),
            None => "Not requested".into(),
        });
        let query = self.search.read(cx).value().to_string();
        let open = self.search_open;
        let copy = live.is_none() && self.pager.as_ref().is_some_and(|x| x.count() > 0 || x.rows().next().is_some());
        let copy_open = self.menu.as_deref() == Some("copy");
        let elapsed = live.map_or(d.meeting.recorded_ms, |s| s.elapsed_ms);
        h_flex()
            .w_full()
            .h(px(32.))
            .pl(px(12.))
            .pr(px(4.))
            .gap(px(10.))
            .bg(p.canvas)
            .rounded(px(6.))
            .child(h_flex().gap(px(6.)).child(icon("clock", 11., p.muted)).child(t(duration_text(elapsed)).size(11.).mono_digits().color(p.muted)))
            .when_some(badge, |w, b| w.child(t(format!("· {b}")).size(11.).color(p.muted)))
            .child(div().flex_1())
            .map(|w| {
                if open {
                    w.child(
                        h_flex()
                            .gap(px(6.))
                            .child(icon("magnifyingglass", 11., p.muted))
                            .child(div().w(px(170.)).text_size(px(11.)).on_key_down(cx.listener(|this, e: &KeyDownEvent, w, cx| {
                                if e.keystroke.key == "escape" {
                                    this.close_search(w, cx);
                                }
                            })).child(Input::new(&self.search).appearance(false).aria_label("Search").accessibility_id("meeting.transcript.search")))
                            .when(live.is_none() && !query.is_empty(), |w| w.child(self.match_navigator(cx))),
                    )
                } else {
                    w.child(note_icon("meeting.transcript.search.open", "magnifyingglass", "Search transcript", p.muted).on_click(cx.listener(|this, _, w, cx| {
                        this.search_open = true;
                        this.search.read(cx).focus_handle(cx).focus(w, cx);
                        cx.notify();
                    })))
                }
            })
            .when(copy, |w| {
                w.child(
                    div()
                        .relative()
                        .child(note_icon("meeting.transcript.copy", "doc.on.doc", "Copy or export transcript", p.accent).on_click(cx.listener(|this, _, _, cx| this.toggle_menu("copy", cx))))
                        .when(copy_open, |w| {
                            let selected = self.pager.as_ref().map_or(0, |x| x.selection.len());
                            let title = if selected == 0 { "Copy Selected Segments".to_string() } else { format!("Copy {selected} Selected Segments") };
                            let items = v_flex()
                                .p(px(8.))
                                .gap(px(2.))
                                .child(menu_row("meeting.transcript.copySelection", title, None, p.ink, Box::new(cx.listener(|this, _: &ClickEvent, _, cx| {
                                    this.menu = None;
                                    this.transcript_notice = None;
                                    if let Some(x) = &this.pager {
                                        cx.write_to_clipboard(ClipboardItem::new_string(x.selection_text()));
                                    }
                                    cx.notify();
                                }))).disabled(selected == 0))
                                .child(menu_row("meeting.transcript.copyFull", "Copy Full Transcript", None, p.ink, Box::new(cx.listener(|this, _: &ClickEvent, _, cx| this.copy_full(cx)))))
                                .child(menu_row("meeting.transcript.export", "Export Transcript…", None, p.ink, Box::new(cx.listener(|this, _: &ClickEvent, _, cx| {
                                    this.menu = None;
                                    // The save panel is an OS service; the export itself is `Pager::export`.
                                    this.transcript_notice = Self::worker("Choosing a save location", cx).err().map(|_| "The transcript could not be exported.".to_string());
                                    cx.notify();
                                }))));
                            w.child(popover_panel(240., 32., cx, items))
                        }),
                )
            })
            .when(assign, |w| w.child(note_icon("meeting.speakers.assign.open", "person.badge.plus", "Assign speakers", p.muted).on_click(cx.listener(|this, _, w, cx| this.open_assign(None, w, cx)))))
    }

    fn match_navigator(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let text = self.pager.as_ref().map(|x| x.match_count_text()).unwrap_or_default();
        let none = self.pager.as_ref().and_then(|x| x.search_hits.as_ref()).is_none_or(|h| h.0.is_empty());
        let chevron = |id: &'static str, symbol: &'static str, label: &'static str, forward: bool, cx: &mut Context<Self>| {
            plain_button(id, label).tooltip(label).disabled(none).content(div().size(px(20.)).flex().items_center().justify_center().child(icon(symbol, 11., p.muted))).on_click(cx.listener(move |this, _, _, cx| {
                if let (Some(db), Some(x)) = (db_of(cx), &mut this.pager) {
                    x.show_match(db, forward);
                }
                this.schedule_highlight_clear(cx);
                cx.notify();
            }))
        };
        h_flex().gap(px(2.)).child(t(text).size(11.).mono_digits().color(p.muted).lines(1).id("meeting.transcript.search.count")).child(chevron("meeting.transcript.search.previous", "chevron.up", "Previous match", false, cx)).child(chevron("meeting.transcript.search.next", "chevron.down", "Next match", true, cx))
    }

    fn speaker_status_line(&mut self, has_result: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let run = self.speaker_run.clone();
        let line = h_flex().id("meeting.speakers.status").gap(px(8.));
        match run.as_ref().map(|r| r.state.as_str()) {
            Some("pending") => line.child(t(if has_result { "Updating speaker labels…" } else { "Waiting to label speakers…" }).size(11.).color(p.muted)),
            Some("running") => {
                let text = if has_result { "Updating speaker labels…".to_string() } else { format!("Labeling speakers… {}%", run.as_ref().map_or(0, |r| r.percent)) };
                line.child(t(text).size(11.).color(p.muted))
            }
            Some("failed" | "interrupted") => {
                let category = run.and_then(|r| r.failure).unwrap_or_else(|| "interrupted".into());
                line.child(t(diarization_failure_text(&category)).size(11.).color(red(cx))).when(category != "os_unsupported", |d| {
                    d.child(plain_button("meeting.speakers.retry", "Retry").on_click(cx.listener(|this, _, _, cx| {
                        this.transcript_notice = Self::worker("Speaker labeling", cx).err();
                        cx.notify();
                    })).content(t("Retry").size(11.).color(p.accent).a11y_hidden()))
                })
            }
            _ => line,
        }
    }

    fn identification_status_line(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let line = h_flex().id("meeting.identification.status").gap(px(8.));
        if let Some((name, left)) = self.past_search.clone() {
            return line.child(t(format!("Looking for {name} in past meetings ({left} left)")).size(11.).color(p.muted)).child(plain_button("identity.pastSearch.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| {
                this.past_search = None;
                cx.notify();
            })).content(t("Cancel").size(11.).color(p.accent).a11y_hidden()));
        }
        let run = self.identify_run.clone();
        match run.as_ref().map(|r| r.state.as_str()) {
            Some("pending") => line.child(t("Waiting to identify speakers…").size(11.).color(p.muted)),
            Some("running") => line.child(t(format!("Identifying speakers… {}%", run.as_ref().map_or(0, |r| r.percent))).size(11.).color(p.muted)),
            Some("failed" | "interrupted") => {
                let category = run.and_then(|r| r.failure).unwrap_or_else(|| "interrupted".into());
                line.child(t(format!("Identification failed: {}", identification_failure_text(&category))).size(11.).color(red(cx))).when(category != "os_unsupported", |d| {
                    d.child(plain_button("meeting.identification.retry", "Retry").on_click(cx.listener(|this, _, _, cx| {
                        this.transcript_notice = Self::worker("Speaker identification", cx).err();
                        cx.notify();
                    })).content(t("Retry").size(11.).color(p.accent).a11y_hidden()))
                })
            }
            _ => line.when(self.enrolling, |d| d.child(t("Storing voice sample…").size(11.).color(p.muted))),
        }
    }

    fn transcript_rows(&mut self, d: &Detail, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let query = self.search.read(cx).value().to_string();
        let Some(pager) = &self.pager else { return div().into_any_element() };
        if pager.rows().next().is_none() {
            return div().into_any_element();
        }
        let all: Vec<&TranscriptRow> = pager.rows().filter(|r| Pager::matches(r, &query)).collect();
        let switches: Vec<&Segment> = d.track("microphone").map(|t| t.segments.iter().filter(|s| s.open_reason == "device_changed").collect()).unwrap_or_default();
        let (before, trailing) = microphone_dividers(&switches, &all);
        let seekable = |kind: &str| is_terminal(&d.meeting.state) && d.track(kind).is_some_and(|t| t.segments.iter().any(|s| s.state == "finalized"));
        let (mic, sys) = (seekable("microphone"), seekable("system"));
        let choices: Vec<(String, String)> = pager.speakers.as_ref().map(|s| s.1.iter().filter(|x| x.merged_into.is_none()).map(|x| (x.id.clone(), x.label.clone())).collect()).unwrap_or_default();
        let has_speakers = pager.speakers.is_some();
        let highlighted = pager.highlighted.clone();
        let selection = pager.selection.clone();
        let no_match = pager.no_resident_match_text();
        let rows: Vec<(TranscriptRow, bool)> = all.iter().enumerate().map(|(i, r)| ((*r).clone(), Pager::starts_group(i, &all))).collect();
        let mut list = v_flex().id("meeting.transcript.list").w_full().gap(px(3.));
        if rows.is_empty() {
            list = list.child(t(no_match).size(15.).color(p.muted));
        }
        for (row, group) in rows {
            for name in before.get(&row.id).into_iter().flatten() {
                list = list.child(mic_divider(name.as_deref(), cx));
            }
            let canseek = if row.tracks == "system" { sys } else { mic };
            list = list.child(self.bubble(&row, group, highlighted.as_deref() == Some(&row.id), selection.contains(&row.id), canseek, has_speakers, &choices, cx));
        }
        for name in &trailing {
            list = list.child(mic_divider(name.as_deref(), cx));
        }
        list.into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn bubble(&mut self, row: &TranscriptRow, show_source: bool, highlighted: bool, selected: bool, seek: bool, correctable: bool, choices: &[(String, String)], cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let id = row.id.clone();
        let key = format!("seg.{id}");
        let open = self.menu.as_deref() == Some(key.as_str());
        let fill = if highlighted { p.accent.opacity(0.2) } else if selected { p.tint } else { p.canvas };
        let color = if row.finality == "provisional" { p.muted } else { p.ink };
        let identify = cx.global::<Core>().prefs.bool_or("speakerIdentificationEnabled", true);
        let right_key = key.clone();
        v_flex()
            .id(sid(format!("meeting.transcript.row.{}", row.ordinal)))
            .w_full()
            .gap(px(5.))
            .when(show_source, |d| {
                d.map(|d| match &row.label {
                    Some(label) => {
                        let text_color = label.color.map_or(p.ink, |c| speaker_text(c, cx));
                        let confirm = match (&label.kind, &label.suggested) {
                            (LabelKind::Speaker(root), Some((_, known))) if identify => Some((root.clone(), known.clone())),
                            _ => None,
                        };
                        d.child(h_flex().pt(px(14.)).gap(px(6.)).child(t(label.text.clone()).font(12., 500.).color(text_color)).when_some(confirm, |d, (root, known)| {
                            d.child(plain_button("speaker.confirm", sid(format!("Confirm speaker {}", label.text))).tooltip("Confirm this speaker").content(icon("checkmark.circle", 11., p.muted)).on_click(cx.listener(move |this, _, _, cx| this.confirm_identity(&root, &known, cx))))
                        }))
                    }
                    None => {
                        let color = match row.tracks.as_str() {
                            "mic" => purple(cx),
                            "system" => orange(cx),
                            _ => p.muted,
                        };
                        d.child(div().pt(px(14.)).id(sid(format!("meeting.transcript.source.{}", row.ordinal))).tooltip({
                            let text = source_explanation(&row.tracks);
                            move |w, cx| Tooltip::new(text).build(w, cx)
                        }).child(t(source_label(&row.tracks)).font(12., 500.).color(color)))
                    }
                })
            })
            .child(
                div()
                    .relative()
                    .w_full()
                    .flex()
                    .flex_col()
                    .items_start()
                    .child(div().id(sid(format!("meeting.transcript.bubble.{}", row.ordinal))).max_w_full().px(px(10.)).py(px(7.)).bg(fill).rounded(px(8.)).on_mouse_down(MouseButton::Right, cx.listener(move |this, _, _, cx| this.toggle_menu(&right_key, cx))).child(t(row.text.clone()).size(13.).line_spacing(4.).color(color)))
                    .when(open, |d| {
                        let toggle_id = id.clone();
                        let mut items = v_flex().p(px(8.)).gap(px(2.)).child(menu_row("meeting.transcript.row.select", if selected { "Deselect segment" } else { "Select segment" }, None, p.ink, Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.menu = None;
                            if let Some(x) = &mut this.pager {
                                x.toggle_selection(&toggle_id);
                            }
                            cx.notify();
                        }))));
                        if seek {
                            items = items.child(menu_row("meeting.transcript.row.play", "Play from here", None, p.ink, Box::new(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.menu = None;
                                this.play(cx);
                            }))));
                        }
                        if correctable {
                            items = items.child(div().id("meeting.transcript.row.changeSpeaker").pl(px(10.)).pt(px(6.)).child(t("Change speaker").size(12.).color(p.muted)));
                            for (index, (speaker, label)) in choices.iter().enumerate() {
                                let (segment, speaker) = (id.clone(), speaker.clone());
                                items = items.child(menu_row(sid(format!("meeting.transcript.row.speaker.{index}")), sid(label.clone()), None, p.ink, Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| this.correct(&segment, Correction::Speaker(speaker.clone()), cx)))));
                            }
                            let segment = id.clone();
                            items = items.child(menu_row("meeting.transcript.row.unknown", "Unknown", None, p.ink, Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| this.correct(&segment, Correction::Unknown, cx)))));
                            let segment = id.clone();
                            items = items.child(menu_row("meeting.transcript.row.newSpeaker", "New speaker", None, p.ink, Box::new(cx.listener(move |this, _: &ClickEvent, _, cx| this.correct(&segment, Correction::New, cx)))));
                        }
                        d.child(popover_panel(220., 34., cx, items))
                    }),
            )
    }

    fn live_list(&mut self, s: &LiveStatus, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let query = self.search.read(cx).value().to_string();
        let rows: Vec<&(String, String)> = s.segments.iter().filter(|r| query.is_empty() || contains(&r.0, &query)).collect();
        if rows.is_empty() {
            let text = if s.transcription_requested { "Listening…" } else { "Transcription is off for this note." };
            return div().w_full().py(px(20.)).child(t(text).italic().color(p.muted).center()).into_any_element();
        }
        let mut list = v_flex().id("meeting.transcript.list").w_full().gap(px(3.));
        for (i, (text, tracks)) in rows.iter().map(|r| (&r.0, &r.1)).enumerate() {
            let group = i == 0 || &rows[i - 1].1 != tracks;
            let color = match tracks.as_str() {
                "mic" => purple(cx),
                "system" => orange(cx),
                _ => p.muted,
            };
            list = list.child(
                v_flex()
                    .w_full()
                    .gap(px(5.))
                    .when(group, |d| d.child(div().pt(px(14.)).child(t(source_label(tracks)).font(12., 500.).color(color))))
                    .child(div().px(px(10.)).py(px(7.)).bg(p.canvas).rounded(px(8.)).child(t(text.clone()).size(13.).line_spacing(4.).color(p.muted))),
            );
        }
        list.into_any_element()
    }
}

fn mic_divider(name: Option<&str>, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    let text = name.map_or("Microphone changed".to_string(), |n| format!("Microphone changed to {n}"));
    h_flex().id("meeting.transcript.microphoneChanged").w_full().gap(px(10.)).py(px(8.)).child(div().flex_1().child(hairline(cx))).child(sf_label("mic", text, 12., p.muted)).child(div().flex_1().child(hairline(cx)))
}
