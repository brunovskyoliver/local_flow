//! `MeetingLibraryView` with `NoteListRow` and `NotePreview`.
use super::*;
use std::time::Duration;

impl NotetakerPage {
    pub(crate) fn library_view(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        // ponytail: Swift measures its own frame; the page is the window less the 220 sidebar.
        let compact = window.viewport_size().width.as_f32() - 220. < 800.;
        h_flex()
            .size_full()
            .items_start()
            .child(
                div().id("notetaker.library").flex_1().min_w_0().h_full().overflow_y_scroll().flex().flex_col().items_center().px(px(30.)).py(px(32.)).child(
                    v_flex()
                        .w_full()
                        .max_w(px(760.))
                        .flex_none()
                        .child(self.library_header(compact, cx))
                        .child(self.today_card(window, cx))
                        .when_some(self.lib.notice.clone().or(self.lib.detail_notice.clone()), |d, n| d.child(div().pb(px(12.)).child(t(n).size(13.).color(red(cx)))))
                        .child(self.tab_row(cx))
                        .when(self.show_search, |d| d.child(div().mt(px(12.)).p(px(10.)).bg(p.canvas).rounded(px(8.)).text_size(px(14.)).child(Input::new(&self.query).appearance(false).aria_label("Search").accessibility_id("notetaker.search"))))
                        .child(self.note_list(cx)),
                ),
            )
            .when(!compact, |d| d.child(div().w(px(1.)).h_full().bg(p.line)).child(div().w(px(230.)).h_full().flex_none().child(self.preview_view(cx))))
    }

    fn library_header(&mut self, compact: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let open = self.menu.clone();
        h_flex()
            .w_full()
            .gap(px(6.))
            .pb(px(20.))
            .child(t("Notetaker").font(26., 500.).tracking(-0.4))
            .child(div().flex_1())
            .when(compact, |d| {
                d.child(
                    div()
                        .relative()
                        .child(note_icon("notetaker.overview", "sidebar.right", "Show note overview", p.ink).on_click(cx.listener(|this, _, _, cx| this.toggle_menu("overview", cx))))
                        .when(open.as_deref() == Some("overview"), |d| {
                            let preview = self.preview_view(cx);
                            d.child(popover_panel(250., 32., cx, div().h(px(380.)).child(preview)))
                        }),
                )
            })
            .child(
                div()
                    .relative()
                    .child(note_icon("notetaker.options", "gearshape", "Recording options", p.ink).on_click(cx.listener(|this, _, _, cx| this.toggle_menu("options", cx))))
                    .when(open.as_deref() == Some("options"), |d| {
                        let on = self.transcribe;
                        let can = self.can_start;
                        d.child(popover_panel(
                            260.,
                            32.,
                            cx,
                            div().p(px(20.)).child(
                                plain_button("notetaker.transcribeNew", "Transcribe new recordings").disabled(!can).toggled(on).on_click(cx.listener(|this, _, _, cx| {
                                    this.transcribe = !this.transcribe;
                                    cx.notify();
                                })).content(checkbox_row("Transcribe new recordings", on, cx)),
                            ),
                        ))
                    }),
            )
            .child(prototype_button("meeting.start", "New note").symbol("plus", 13.).disabled(!self.can_start).on_click(cx.listener(|this, _, w, cx| this.start_note(w, cx))))
    }

    pub(crate) fn toggle_menu(&mut self, key: &str, cx: &mut Context<Self>) {
        self.menu = if self.menu.as_deref() == Some(key) { None } else { Some(key.to_string()) };
        cx.notify();
    }

    /// `coordinator.start` lives in the Mac app; here it refuses, and the Today card says why.
    fn start_note(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if let Err(message) = Self::worker("Meeting recording", cx) {
            self.refusal = Some(message);
        }
        cx.notify();
    }

    fn today_card(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let attention = self.refusal.is_some() || self.status.as_ref().is_some_and(|s| matches!(s.state.as_str(), "failed" | "interrupted"));
        let now = now_ms();
        let today = local_day(now, offset_at(now, cx));
        let count = self.lib.rows.iter().filter(|r| local_day(r.created_at, offset_at(r.created_at, cx)) == today).count();
        let active = self.active_id().and(self.status.as_ref().map(|s| s.state.clone()));
        v_flex()
            .w_full()
            .mb(px(24.))
            .gap(px(16.))
            .px(px(20.))
            .py(px(12.))
            .bg(p.canvas)
            .rounded(px(16.))
            .child(h_flex().w_full().child(t("TODAY").font(12., 500.).tracking(1.2)).child(div().flex_1()).child(note_icon("notetaker.refresh", "arrow.clockwise", "Refresh notes", p.muted).on_click(cx.listener(|this, _, _, cx| this.refresh(cx)))))
            .map(|d| {
                if attention {
                    d.child(self.active_card(window, cx).into_any_element())
                } else {
                    d.child(div().w_full().pb(px(14.)).child(t(today_summary(active.as_deref(), count)).size(15.).center().id("meeting.today.summary")))
                }
            })
    }

    fn tab_row(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        h_flex()
            .relative()
            .w_full()
            .gap(px(20.))
            .child(note_tab("notetaker.pastNotes", "Past notes", true, cx))
            .child(div().flex_1())
            .child(note_icon("notetaker.searchToggle", "magnifyingglass", "Search loaded notes", p.ink).on_click(cx.listener(|this, _, w, cx| {
                this.show_search = !this.show_search;
                if this.show_search {
                    this.query.read(cx).focus_handle(cx).focus(w, cx);
                }
                cx.notify();
            })))
            .child(div().absolute().bottom_0().left_0().right_0().h(px(1.)).bg(p.line))
    }

    fn note_list(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        if self.lib.rows.is_empty() {
            return empty_line("No notes yet", cx).into_any_element();
        }
        let query = self.query.read(cx).value().to_string();
        let rows: Vec<MeetingRow> = self.lib.rows.iter().filter(|r| query.is_empty() || contains(&r.display_title(offset_at(r.created_at, cx)), &query)).cloned().collect();
        let now = now_ms();
        let today = local_day(now, offset_at(now, cx));
        let mut list = v_flex().w_full().pt(px(25.)).gap(px(3.));
        if self.lib.evicted_newest {
            list = list.child(div().pb(px(12.)).child(prototype_button("notetaker.showNewest", "Show newest").on_click(cx.listener(|this, _, _, cx| this.refresh(cx)))));
        }
        let mut previous = None;
        for (index, row) in rows.iter().enumerate() {
            let offset = offset_at(row.created_at, cx);
            let day = local_day(row.created_at, offset);
            if previous != Some(day) {
                list = list.child(div().pt(px(if index == 0 { 0. } else { 24. })).pb(px(6.)).pl(px(4.)).child(t(day_heading(row.created_at, offset, today)).font(12., 500.).tracking(1.2).color(p.muted)));
            }
            previous = Some(day);
            list = list.child(self.note_row(row, offset, cx));
        }
        if rows.is_empty() {
            list = list.child(empty_line("No matches", cx));
        }
        if self.lib.has_older {
            list = list.child(div().pt(px(20.)).child(prototype_button("notetaker.loadOlder", "Load older notes").disabled(self.lib.is_loading).on_click(cx.listener(|this, _, _, cx| {
                if let Some(db) = db_of(cx) {
                    this.lib.load_older(db);
                }
                cx.notify();
            }))));
        }
        list.into_any_element()
    }

    fn note_row(&mut self, row: &MeetingRow, offset: i32, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let id = row.id.clone();
        let group = sid(format!("notetaker.row.{id}"));
        let title = row.display_title(offset);
        let waiting = self.waiting.contains(&id);
        let live = self.status.as_ref().filter(|s| s.id == id).cloned();
        let pending = self.lib.deletion_pending.contains(&id);
        let key = format!("row.{id}");
        let open_menu = self.menu.as_deref() == Some(key.as_str());
        let (open_id, hover_id, run_id, delete_id, revision) = (id.clone(), id.clone(), id.clone(), id.clone(), row.revision);
        let terminal = is_terminal(&row.state);
        let mut row_label = format!("{title}, {}", time_text(row.created_at, offset));
        if row.origin == "iphone" {
            row_label += ", From iPhone";
        }
        if waiting {
            row_label += ", Waiting for your server";
        } else if live.is_none() && row.state != "completed" {
            row_label = format!("{row_label}, {}", state_badge(&row.state));
        }
        if row.warning {
            row_label += ", Recording needs attention";
        }
        h_flex()
            .id(sid(format!("notetaker.rowContainer.{id}")))
            .group(group.clone())
            .w_full()
            .rounded(px(10.))
            .hover(|s| s.bg(p.canvas))
            .when(open_menu, |d| d.bg(p.canvas))
            .on_hover(cx.listener(move |this, inside: &bool, _, cx| {
                if *inside {
                    this.request_preview(&hover_id, cx);
                }
            }))
            .child(div().flex_1().min_w_0().child(
                plain_button(sid(format!("notetaker.note.{id}")), sid(title.clone())).a11y_label(sid(row_label)).full_width().on_click(cx.listener(move |this, _, w, cx| this.open_note(&open_id, Tab::Thoughts, w, cx))).content(
                    h_flex()
                        .flex_1()
                        .min_w_0()
                        .w_full()
                        .gap(px(12.))
                        .py(px(11.5))
                        .pl(px(10.))
                        .child(div().size(px(36.)).flex_none().flex().items_center().justify_center().bg(p.tint).rounded(px(8.)).child(icon("doc.text", 15., p.muted)))
                        .child(
                            v_flex()
                                .min_w_0()
                                .gap(px(4.))
                                .child(t(title.clone()).size(15.).lines(1).a11y_hidden())
                                .child(h_flex().gap(px(6.)).child(t(time_text(row.created_at, offset)).size(12.).color(p.muted).a11y_hidden()).when(row.origin == "iphone", |d| d.child(div().id(sid(format!("notetaker.fromIPhone.{id}"))).child(sf_label("iphone", "From iPhone", 12., p.muted))))),
                        )
                        .child(div().flex_1())
                        .map(|d| {
                            if let Some(s) = &live {
                                d.child(div().pr(px(6.)).child(live_badge(&s.state, s.elapsed_ms, 13., cx)))
                            } else if waiting {
                                d.child(t("Waiting for your server").size(12.).color(p.muted).a11y_hidden())
                            } else if row.state != "completed" {
                                d.child(t(state_badge(&row.state)).size(12.).color(p.muted).a11y_hidden())
                            } else {
                                d
                            }
                        })
                        .when(row.warning || pending, |d| d.child(icon("exclamationmark.triangle", 13., orange(cx)))),
                ),
            ))
            .when(waiting, |d| {
                d.child(plain_button(sid(format!("notetaker.runOnThisMac.{id}")), "Run on this Mac").a11y_label(sid(format!("Run {title} on this Mac"))).on_click(cx.listener(move |this, _, _, cx| this.run_on_this_mac(&run_id, cx))).content(t("Run on this Mac").size(12.).a11y_hidden()))
            })
            .child(
                div()
                    .px(px(8.))
                    .relative()
                    .child(hover_revealed(group, open_menu, div()).child(note_icon(sid(format!("notetaker.overflow.{id}")), "ellipsis", "Note options", p.ink).on_click({
                        let key = key.clone();
                        cx.listener(move |this, _, _, cx| this.toggle_menu(&key, cx))
                    })))
                    .when(open_menu, |d| {
                        let on = cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.menu = None;
                            this.confirm = Some(Confirm::DeleteRow(delete_id.clone(), revision));
                            cx.notify();
                        });
                        let color = red(cx);
                        d.child(popover_panel(190., 32., cx, v_flex().p(px(8.)).gap(px(2.)).child(menu_row("notetaker.overflow.delete", "Delete", Some("trash"), color, Box::new(on)).disabled(!terminal))))
                    }),
            )
    }

    pub(crate) fn run_on_this_mac(&mut self, id: &str, cx: &mut Context<Self>) {
        let server_only = cx.global::<Core>().prefs.bool_or("serverOnly", false);
        if let Some(db) = db_of(cx) {
            self.lib.run_locally(db, id, server_only);
            // The queue moves it over once the Mac worker exists; until then the row keeps waiting.
            if !server_only && self.lib.detail_notice.is_none() {
                self.waiting.remove(id);
            }
        }
        cx.notify();
    }

    /// 120 ms after the pointer settles, as Swift's `.task(id:)` does.
    pub(crate) fn request_preview(&mut self, id: &str, cx: &mut Context<Self>) {
        self.preview_epoch += 1;
        let epoch = self.preview_epoch;
        let id = id.to_string();
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(120)).await;
            this.update(cx, |this, cx| {
                if this.preview_epoch == epoch {
                    if let Some(db) = db_of(cx) {
                        this.lib.preview(db, &id);
                    }
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    fn preview_view(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = pal(cx);
        let row = self.lib.rows.iter().find(|r| Some(&r.id) == self.lib.preview_id.as_ref()).cloned();
        let notes = self.lib.preview.as_ref().map(|d| d.notes.chars().take(PREVIEW_CHARS).collect::<String>()).filter(|n| !n.is_empty());
        let notice = self.lib.preview_notice.clone();
        v_flex().id("notetaker.preview").test_support().size_full().when_some(row, |d, row| {
            let offset = offset_at(row.created_at, cx);
            d.child(v_flex().p(px(20.)).gap(px(8.)).child(t(row.display_title(offset)).font(18., 500.)).child(t(format!("{} · {}", date_time_text(row.created_at, offset), duration_text(row.recorded_ms))).size(14.).color(p.muted).mono_digits()))
                .child(hairline(cx))
                .child(
                    div().id("notetaker.preview.scroll").flex_1().min_h_0().overflow_y_scroll().child(
                        v_flex()
                            .w_full()
                            .p(px(20.))
                            .gap(px(16.))
                            .when_some(notes, |d, n| d.child(t("MY THOUGHTS").font(12., 500.).tracking(1.2).color(p.muted)).child(t(n).size(14.).line_spacing(6.)))
                            .when_some(notice, |d, n| d.child(t(n).size(14.).color(red(cx)))),
                    ),
                )
        })
        .into_any_element()
    }
}

pub(crate) fn empty_line(title: &'static str, cx: &App) -> impl IntoElement {
    div().w_full().py(px(60.)).child(t(title).size(15.).color(pal(cx).muted).center())
}
/// `.toggleStyle(.checkbox)` as content for a real button.
pub(crate) fn checkbox_row(title: &'static str, on: bool, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    h_flex()
        .gap(px(6.))
        .child(div().size(px(14.)).flex().items_center().justify_center().rounded(px(3.)).when(on, |d| d.bg(p.accent)).when(!on, |d| d.border_1().border_color(p.line)).when(on, |d| d.child(icon("checkmark", 10., p.on_accent))))
        .child(t(title).size(13.).a11y_hidden())
}
/// `LiveRecordingBadge`.
pub(crate) fn live_badge(state: &str, elapsed: i64, size: f32, cx: &App) -> impl IntoElement {
    let color = if state == "paused" { pal(cx).muted } else { green(cx) };
    let text = duration_text(elapsed);
    h_flex().id("meeting.elapsed").gap(px(8.)).child(icon(if state == "paused" { "pause.fill" } else { "waveform" }, size - 1., color)).child(t(text).size(size).mono_digits().color(color))
}
