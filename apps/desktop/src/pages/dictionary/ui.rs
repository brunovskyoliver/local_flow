//! Pieces shared by the Dictionary, Insights and Transcriptions pages.
use flow_ui::prelude::*;

/// `DictionaryPillButtonStyle`: small gray button, or the dark filled one for primary actions.
pub fn pill(id: impl Into<ElementId>, label: impl Into<SharedString>, prominent: bool, cx: &App) -> FlowButton {
    let p = pal(cx);
    let label: SharedString = label.into();
    let (fill, fg, size, weight, kind) = if prominent { (p.ink, p.surface, 15., 500., ButtonKind::Primary) } else { (p.button, p.ink, 13., 400., ButtonKind::Prototype) };
    // Primary's padding is 16 by 9; Swift's prominent pill is 18 by 10.
    let pad = if prominent { (2., 1.) } else { (0., 0.) };
    FlowButton::new(id, kind, label.clone())
        .fill(fill)
        .text_color(fg)
        .disabled_opacity(0.45)
        .content(div().mx(px(pad.0)).my(px(pad.1)).child(t(label).font(size, weight).color(fg).a11y_hidden()))
}

/// SwiftUI's `.help`: the tooltip on any element.
pub fn help(id: impl Into<ElementId>, text: impl Into<SharedString>, child: impl IntoElement) -> Stateful<Div> {
    let text: SharedString = text.into();
    div().id(id).child(child).tooltip(move |w, cx| Tooltip::new(text.clone()).build(w, cx))
}

/// A sheet or confirmation. The shell has no Kit `Root`, so Kit dialogs can't open; this dims the
/// whole window, sidebar included, and blocks what's under it, as an AppKit sheet does. Measured on
/// the reference: canvas (247,246,243) becomes (201,201,199).
pub fn overlay(id: impl Into<ElementId>, window: &Window, cx: &App, content: impl IntoElement) -> Deferred {
    let dim = if pal(cx).ink.l > 0.5 { SHEET_DIM_DARK } else { SHEET_DIM };
    let viewport = window.viewport_size();
    let scrim = div().id(id).w(viewport.width).h(viewport.height).occlude().flex().items_center().justify_center().bg(black().opacity(dim)).child(content);
    deferred(anchored().position(point(px(0.), px(0.))).snap_to_window().child(scrim)).with_priority(1)
}

pub const SHEET_DIM: f32 = 0.186;
pub const SHEET_DIM_DARK: f32 = 0.186;

/// The sheet's card: surface fill, rounded, no border, as an AppKit sheet shows it.
pub fn sheet_card(width: f32, cx: &App) -> Div {
    let p = pal(cx);
    div().w(px(width)).bg(p.surface).rounded(px(16.)).shadow_lg().flex().flex_col()
}

/// macOS `confirmationDialog`: title, message, destructive action, Cancel.
pub fn confirm_dialog(
    prefix: &str,
    title: &str,
    message: &str,
    action: &str,
    cx: &App,
    on_action: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_cancel: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> Div {
    let p = pal(cx);
    sheet_card(300., cx)
        .p(px(18.))
        .gap(px(10.))
        .child(t(title.to_string()).font(15., 600.))
        .when(!message.is_empty(), |d| d.child(t(message.to_string()).size(13.).color(p.muted).line_spacing(2.)))
        .child(
            h_flex()
                .w_full()
                .justify_end()
                .gap(px(8.))
                .pt(px(4.))
                .child(pill(format!("{prefix}.cancel"), "Cancel", false, cx).on_click(on_cancel))
                .child(pill(format!("{prefix}.confirm"), action.to_string(), false, cx).text_color(p.warning).content(t(action.to_string()).font(13., 500.).color(p.warning).a11y_hidden()).on_click(on_action)),
        )
}
