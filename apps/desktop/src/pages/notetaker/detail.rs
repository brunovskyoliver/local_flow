//! `MeetingDetailView`: toolbar, title, tabs, thoughts and the footer.
use super::*;
use std::time::Duration;

impl NotetakerPage {
    pub(crate) fn open_note(&mut self, id: &str, tab: Tab, window: &mut Window, cx: &mut Context<Self>) {
        let Some(db) = db_of(cx) else { return };
        self.lib.open(db, id);
        let Some(d) = self.lib.detail.clone() else {
            cx.notify();
            return;
        };
        self.tab = tab;
        self.provenance = provenance(db, id).ok().flatten();
        let mut pager = Pager::new(id);
        pager.load_first(db);
        self.pager = Some(pager);
        self.editor = Some(NotesEditor::new(id, &d.notes, d.notes_revision));
        let run = |table, pointer| {
            run_status(db, table, pointer, id).ok().flatten().filter(|r| matches!(r.0.as_str(), "pending" | "running" | "failed" | "interrupted")).map(|(state, failure)| RunLine { state, failure, percent: 0 })
        };
        self.speaker_run = run("diarization_runs", "meeting_diarization");
        self.identify_run = run("identification_runs", "meeting_identification");
        self.past_search = None;
        self.past_prompt = None;
        self.enrolling = false;
        self.transcript_notice = None;
        self.search_open = false;
        self.playing = false;
        self.play_notice = None;
        self.menu = None;
        let display = d.meeting.display_title(offset_at(d.meeting.created_at, cx));
        self.title.update(cx, |s, cx| s.set_value(display, window, cx));
        self.thoughts.update(cx, |s, cx| s.set_value(d.notes.clone(), window, cx));
        self.search.update(cx, |s, cx| s.set_value("", window, cx));
        self.summary.reset();
        self.summary_refresh(cx);
        self.poll_finalizing(cx);
        cx.notify();
    }
    /// `onDisappear`: whatever closes the note saves it first.
    pub(crate) fn close_note_state(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.flushed(cx);
        self.editor = None;
        self.pager = None;
        self.assign = None;
    }
    fn flushed(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(db) = db_of(cx) else { return false };
        let Some(e) = &mut self.editor else { return true };
        let saves = e.save_count;
        e.flush(db);
        let (saved, clean) = (e.save_count != saves, !e.is_dirty);
        if saved {
            // `evidenceDidChange` after a notes save.
            self.summary_refresh(cx);
        }
        clean
    }
    /// `flushMeetingNotes`: the window is closing or the app is quitting.
    pub(crate) fn flush_notes(&mut self, cx: &mut Context<Self>) {
        self.flushed(cx);
    }
    /// Flush first; a note that couldn't save stays open with its notice.
    fn go_back(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.flushed(cx) {
            self.lib.close_detail();
            self.close_note_state(window, cx);
            self.refresh(cx);
        }
        cx.notify();
    }
    fn navigate(&mut self, offset: i64, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.lib.detail.as_ref().and_then(|d| self.lib.adjacent(&d.meeting.id, offset)) else { return };
        if self.flushed(cx) {
            let tab = self.tab;
            self.open_note(&id, tab, window, cx);
        }
        cx.notify();
    }
    pub(crate) fn save_title(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(m) = self.lib.detail.as_ref().map(|d| d.meeting.clone()) else { return };
        let draft = self.title.read(cx).value().to_string();
        // The field starts on the generated title; leaving it untouched stores nothing.
        if draft == m.title.clone().unwrap_or_default() || draft == m.display_title(offset_at(m.created_at, cx)) {
            return;
        }
        let active = self.active_id();
        if let Some(db) = db_of(cx) {
            self.lib.set_title(db, &m.id, &draft, m.revision, active.as_deref());
        }
        if let Some(d) = self.lib.detail.clone() {
            let shown = d.meeting.display_title(offset_at(d.meeting.created_at, cx));
            if self.lib.detail_notice.is_none() && shown != draft {
                self.title.update(cx, |s, cx| s.set_value(shown, window, cx));
            }
        }
        cx.notify();
    }
    pub(crate) fn thoughts_changed(&mut self, value: &str, input: Entity<TextareaState>, window: &mut Window, cx: &mut Context<Self>) {
        let Some(editor) = &mut self.editor else { return };
        if !editor.edit(value) {
            let kept = editor.text.clone();
            input.update(cx, |s, cx| s.set_value(kept, window, cx));
            cx.notify();
            return;
        }
        if !editor.is_dirty {
            cx.notify();
            return;
        }
        self.schedule_save(cx);
        cx.notify();
    }
    /// 2 s after the last edit, at most 10 s after the first unsaved one. A save that fails
    /// tries again on the same timers, as `save()` reschedules while the text stays dirty.
    fn schedule_save(&mut self, cx: &mut Context<Self>) {
        self.save_epoch += 1;
        let epoch = self.save_epoch;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            this.update(cx, |this, cx| {
                if this.save_epoch == epoch {
                    if !this.flushed(cx) {
                        this.schedule_save(cx);
                    }
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
        if !self.force_pending {
            self.force_pending = true;
            cx.spawn(async move |this, cx| {
                cx.background_executor().timer(Duration::from_secs(10)).await;
                this.update(cx, |this, cx| {
                    this.force_pending = false;
                    this.flushed(cx);
                    cx.notify();
                })
                .ok();
            })
            .detach();
        }
    }
    /// View source on a note: switch tabs and select the paragraph, or say it changed.
    pub(crate) fn reveal_note(&mut self, ordinal: i64, hash: &str, cx: &mut Context<Self>) {
        self.tab = Tab::Thoughts;
        if let Some(e) = &mut self.editor {
            e.reveal(ordinal, hash);
            if let Some((a, b)) = e.reveal.take() {
                self.thoughts.update(cx, |s, cx| s.set_selected_range(a..b, cx));
            }
        }
        cx.notify();
    }
    /// `FooterPlayer` and `seek(to:)`: the queue is real, the player is the Mac's.
    pub(crate) fn play(&mut self, cx: &mut Context<Self>) {
        let queue = self.lib.detail.as_ref().and_then(|d| d.track("microphone").or(d.track("system")).map(|t| playback_queue(t, &Self::meetings_root(cx)))).unwrap_or_default();
        self.playing = true;
        self.play_total = queue.duration_ms;
        self.play_notice = queue.notice.map(String::from).or_else(|| Self::worker("Playback", cx).err());
        cx.notify();
    }
    /// `finalizingPollKey`: reloads every 5 s while the open note's transcript is finalizing.
    pub(crate) fn poll_finalizing(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()) else { return };
        if self.pager.as_ref().and_then(|p| p.row.as_ref()).is_none_or(|r| r.state != "finalizing") {
            return;
        }
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(5)).await;
                let going = this
                    .update(cx, |this, cx| {
                        let same = this.lib.detail.as_ref().is_some_and(|d| d.meeting.id == id);
                        let (Some(db), Some(p), true) = (db_of(cx), &mut this.pager, same) else { return false };
                        p.load_first(db);
                        // `ProvenanceKey` follows the transcript state.
                        this.provenance = provenance(db, &id).ok().flatten();
                        cx.notify();
                        p.row.as_ref().is_some_and(|r| r.state == "finalizing")
                    })
                    .unwrap_or(false);
                if !going {
                    break;
                }
            }
        })
        .detach();
    }

    pub(crate) fn detail_view(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let d = self.lib.detail.clone().expect("detail");
        let m = d.meeting.clone();
        let live = self.status.clone().filter(|s| s.id == m.id);
        let tab = self.tab;
        let notice = self.lib.detail_notice.clone();
        let pending = self.lib.deletion_pending.contains(&m.id);
        let waits = self.waiting.contains(&m.id);
        let produced = self.provenance.clone();
        let (retry_id, retry_rev) = (m.id.clone(), m.revision);
        let wait_id = m.id.clone();
        let body = match tab {
            Tab::Thoughts => self.thoughts_section(cx).into_any_element(),
            Tab::Transcript => self.transcript_section(&d, live.as_ref(), cx).into_any_element(),
            Tab::Summary => self.summary_section(&m, cx).into_any_element(),
        };
        // Swift's page reaches under the panel's 1 pt stroke, which a compact width shows.
        v_flex()
            .absolute()
            .top_0()
            .bottom_0()
            .left(px(-1.))
            .right(px(-1.))
            .items_center()
            .text_size(px(15.))
            .child(div().w_full().flex().justify_center().px(px(20.)).pt(px(17.)).pb(px(17.)).child(self.toolbar(&d, cx)))
            .child(
                div().w_full().flex().justify_center().px(px(30.)).child(
                    v_flex()
                        .w_full()
                        .max_w(px(600.))
                        .child(self.note_header(&d, live.as_ref(), window, cx))
                        .child(h_flex().id("meeting.tabs").test_support().gap(px(20.)).child(tab_button("meeting.tab.thoughts", "My thoughts", tab == Tab::Thoughts, Tab::Thoughts, cx)).child(tab_button("meeting.tab.transcript", "Transcript", tab == Tab::Transcript, Tab::Transcript, cx)).child(tab_button("meeting.tab.summary", "Summary", tab == Tab::Summary, Tab::Summary, cx))),
                ),
            )
            .child(div().id("meeting.rule").test_support().w_full().max_w(px(860.)).child(hairline(cx)))
            .when_some(notice, |d, n| {
                d.child(div().id("meeting.notice").test_support().child(h_flex().gap(px(8.)).p(px(12.)).child(t(n).size(12.).color(red(cx))).when(pending, |d| {
                    d.child(small_native("meeting.retryDeletion", "Retry deletion", cx).on_click(cx.listener(move |this, _, w, cx| this.delete(&retry_id, retry_rev, w, cx))))
                })))
            })
            .when(waits, |d| {
                d.child(div().id("meeting.waiting").test_support().child(h_flex().gap(px(12.)).p(px(12.)).child(t("Waiting for your server").size(12.).color(p.muted)).child(small_native("notetaker.detail.runOnThisMac", "Run on this Mac", cx).a11y_label("Run this meeting on this Mac").on_click(cx.listener(move |this, _, _, cx| this.run_on_this_mac(&wait_id, cx))))))
            })
            .child(
                div()
                    .id("meeting.body")
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .on_scroll_wheel(cx.listener(|this, _: &ScrollWheelEvent, _, cx| this.page_on_scroll(cx)))
                    .flex()
                    .flex_col()
                    .items_center()
                    .child(
                        v_flex()
                            .id("meeting.column")
                            .test_support()
                            .w_full()
                            .max_w(px(660.))
                            .flex_none()
                            .px(px(30.))
                            .pt(px(20.))
                            .pb(px(24.))
                            .gap(px(16.))
                            .when_some(produced, |d, text| {
                                let spoken = format!("Produced on: {text}");
                                d.child(t(text).size(12.).swift_lines().color(p.muted).a11y_value(spoken))
                            })
                            .child(body),
                    ),
            )
            .child(div().id("meeting.footer.frame").test_support().w_full().flex().justify_center().px(px(30.)).pt(px(12.)).pb(px(20.)).child(self.footer(&d, live.as_ref(), cx)))
    }

    fn toolbar(&mut self, d: &Detail, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let m = &d.meeting;
        let (previous, next) = (self.lib.adjacent(&m.id, -1).is_some(), self.lib.adjacent(&m.id, 1).is_some());
        let open = self.menu.as_deref() == Some("note");
        let action = self.transcript_menu_action(m);
        let terminal = is_terminal(&m.state);
        // ponytail: `leaving` has no Rust state; the flush is synchronous, so no frame sees it.
        h_flex()
            .id("meeting.toolbar")
            .test_support()
            .w_full()
            .max_w(px(860.))
            .gap(px(4.))
            .child(div().bg(p.button).rounded(px(6.)).child(note_icon("meeting.back", "chevron.left", "Back to past notes", p.ink).on_click(cx.listener(|this, _, w, cx| this.go_back(w, cx)))))
            .child(div().flex_1())
            .child(
                div()
                    .relative()
                    .child(note_icon("meeting.options", "ellipsis", "Note options", p.ink).on_click(cx.listener(|this, _, _, cx| this.toggle_menu("note", cx))))
                    .when(open, |w| {
                        let mut items = v_flex().p(px(8.)).gap(px(2.));
                        if let Some((title, id)) = action {
                            let on = cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.menu = None;
                                this.request_transcript(cx);
                                cx.notify();
                            });
                            items = items.child(menu_row(id, title, Some("arrow.clockwise"), p.ink, Box::new(on)));
                        }
                        let on = cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.menu = None;
                            this.confirm = Some(Confirm::DeleteOpen);
                            cx.notify();
                        });
                        items = items.child(menu_row("meeting.delete", "Delete", Some("trash"), red(cx), Box::new(on)).disabled(!terminal));
                        w.child(popover_panel(190., 32., cx, items))
                    }),
            )
            .child(note_icon("meeting.previous", "chevron.left", "Previous note", p.ink).disabled(!previous).on_click(cx.listener(|this, _, w, cx| this.navigate(-1, w, cx))))
            .child(note_icon("meeting.next", "chevron.right", "Next note", p.ink).disabled(!next).on_click(cx.listener(|this, _, w, cx| this.navigate(1, w, cx))))
    }

    /// `requestFinalization`: admission first, then the worker.
    pub(crate) fn request_transcript(&mut self, cx: &mut Context<Self>) {
        let id = self.lib.detail.as_ref().map(|d| d.meeting.id.clone()).unwrap_or_default();
        self.transcript_notice = if admit(&mut self.transcript_queue, &id, false, QUEUE_CAPACITY) {
            let refused = Self::worker("Transcription", cx).err();
            if refused.is_some() {
                self.transcript_queue.retain(|q| q != &id);
            }
            refused
        } else {
            Some("Too many transcripts waiting".into())
        };
        cx.notify();
    }

    fn transcript_menu_action(&self, m: &MeetingRow) -> Option<(&'static str, &'static str)> {
        if !is_terminal(&m.state) {
            return None;
        }
        match self.pager.as_ref()?.row.as_ref()?.state.as_str() {
            "not_requested" => Some(("Transcribe", "meeting.transcript.transcribe")),
            "failed" | "interrupted" => Some(("Retry transcription", "meeting.transcript.retry")),
            "final" => Some(("Re-transcribe", "meeting.transcript.retranscribe")),
            _ => None,
        }
    }

    fn note_header(&mut self, d: &Detail, live: Option<&LiveStatus>, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let m = &d.meeting;
        let dropped = live.is_some_and(|s| s.dropped_frames > 0) || d.tracks.iter().any(|t| t.dropped_frames > 0);
        let drift = d.tracks.iter().any(|t| t.duration_warning);
        let offset = offset_at(m.created_at, cx);
        let track_kind = d.tracks.iter().find(|t| t.failure_reason.as_deref() == m.failure_reason.as_deref()).map(|t| t.kind.clone());
        v_flex()
            .w_full()
            .gap(px(8.))
            .pb(px(4.))
            .child(div().id("meeting.title.frame").test_support().w_full().ml(px(-10.)).font_family(GARAMOND).child(Textarea::new(&self.title).appearance(false).bordered(false).my(px(-7.)).text_size(px(38.)).line_height(px(46.)).aria_label("Note title").accessibility_id("meeting.title")))
            .child(t(date_time_text(m.created_at, offset)).size(15.).color(p.muted))
            .when(dropped, |w| w.child(div().id("meeting.captureLoss").test_support().child(h_flex().gap(px(6.)).child(icon("exclamationmark.triangle.fill", 13., orange(cx))).child(t("Some audio was lost during recording. The transcript may be incomplete.").size(13.).swift_lines().color(orange(cx))))))
            .when(!dropped && drift, |w| w.child(div().id("meeting.durationWarning").test_support().child(h_flex().gap(px(6.)).child(icon("exclamationmark.triangle.fill", 13., orange(cx))).child(t("A recording track does not match the meeting duration. Some audio may be missing.").size(13.).swift_lines().color(orange(cx))))))
            .when_some(m.failure_reason.clone(), |w, r| w.child(t(failure_reason_text(&r, track_kind.as_deref())).size(13.).swift_lines().color(red(cx)).id("meeting.reason")))
    }

    fn thoughts_section(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let empty = self.editor.as_ref().is_none_or(|e| e.text.is_empty());
        let notice = self.editor.as_ref().and_then(|e| e.notice.clone());
        v_flex()
            .w_full()
            .gap(px(12.))
            .child(
                div()
                    .id("meeting.thoughts.frame")
                    .test_support()
                    .relative()
                    .w_full()
                    .h(px(420.))
                    .ml(px(-10.))
                    .mt(px(-7.))
                    // Swift's editor is an NSTextView set to the system font, not the app font.
                    .font_family(".SystemUIFont")
                    .child(Textarea::new(&self.thoughts).appearance(false).bordered(false).h_full().text_size(px(14.)).line_height(px(23.)).aria_label("My thoughts").accessibility_id("meeting.thoughts"))
                    .when(empty, |d| d.child(div().id("meeting.thoughts.placeholder").test_support().absolute().top(px(4.)).left(px(10.)).child(t("Capture your thoughts here").size(14.).color(p.muted.opacity(0.7)).a11y_hidden()))),
            )
            .when_some(notice, |d, n| {
                d.child(h_flex().gap(px(8.)).child(t(n).size(12.).color(red(cx))).child(small_native("meeting.retrySave", "Retry save", cx).on_click(cx.listener(|this, _, _, cx| {
                    this.flushed(cx);
                    cx.notify();
                }))))
            })
    }

    fn footer(&mut self, d: &Detail, live: Option<&LiveStatus>, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let row = h_flex().w_full().max_w(px(600.)).gap(px(8.)).justify_center();
        if let Some(s) = live {
            return row
                .when(s.state == "paused", |d| d.child(symbol_button("meeting.resume", "Resume", "play.fill", 13., p.ink).on_click(cx.listener(|this, _, _, cx| this.live_action("Resume", cx)))))
                .when(s.state == "recording", |d| d.child(symbol_button("meeting.pause", "Pause", "pause.fill", 13., p.ink).on_click(cx.listener(|this, _, _, cx| this.live_action("Pause", cx)))))
                .child(symbol_button("meeting.stop", "Stop", "stop.fill", 13., green(cx)).on_click(cx.listener(|this, _, _, cx| this.live_action("Stop", cx))));
        }
        let track = d.track("microphone").or(d.track("system")).is_some();
        let playable = is_terminal(&d.meeting.state) && track;
        row.child(symbol_button("meeting.playback", "Playback", "play.circle", 14., p.ink).disabled(!playable).on_click(cx.listener(|this, _, _, cx| this.play(cx)))).when(self.playing, |w| {
            w.child(t(format!("0:00 / {}", duration_text(self.play_total))).size(12.).mono_digits().color(p.muted))
                .child(prototype_button("meeting.playback.stop", "Stop").on_click(cx.listener(|this, _, _, cx| {
                    this.playing = false;
                    this.play_notice = None;
                    cx.notify();
                })))
                .when_some(self.play_notice.clone(), |w, n| w.child(t(n).size(12.).color(p.muted).lines(1)))
        })
    }
}

/// A default `Button` under `.font(.flow(size: 12))`.
fn small_native(id: &'static str, label: &'static str, cx: &App) -> FlowButton {
    let (.., text, _, _, _, _) = ButtonKind::Native.style(&pal(cx));
    native_button(id, label).content(t(label).size(12.).color(text).a11y_hidden())
}

fn tab_button(id: &'static str, title: &'static str, selected: bool, tab: Tab, cx: &mut Context<NotetakerPage>) -> impl IntoElement {
    note_tab(id, title, selected, cx).on_click(cx.listener(move |this, _, _, cx| {
        this.tab = tab;
        this.summary_refresh(cx);
        cx.notify();
    }))
}

#[cfg(test)]
mod close_tests {
    use crate::core::Core;
    use crate::pages::notetaker::Tab;
    use flow_core::meetings::SEED_FULL;
    use crate::shell::Shell;
    use crate::testing::boot;
    use flow_ui::prelude::*;
    use flow_ui::test::TestAppContext;

    // parity: SHELL-036
    /// Autosave is two seconds off; the closing window can't wait for it.
    #[flow_ui::gpui::test]
    async fn closing_the_window_saves_the_notes(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| cx.global_mut::<Core>().prefs.set("setupVersion", 1));
        let window = cx.add_window(|w, cx| Shell::new(w, cx));
        cx.run_until_parked();
        window
            .update(cx, |shell, w, cx| {
                shell.meetings.clone().update(cx, |page, cx| {
                    page.open_note(SEED_FULL, Tab::Transcript, w, cx);
                    page.editor.as_mut().unwrap().edit("Typed just before closing.");
                });
            })
            .unwrap();
        window.update(cx, |_, w, _| w.remove_window()).unwrap();
        cx.run_until_parked();
        let saved = cx.update(|cx| flow_core::meetings::notes(cx.global::<Core>().db.as_ref().unwrap(), SEED_FULL).unwrap().unwrap().0);
        assert_eq!(saved, "Typed just before closing.");
    }
}
