//! Pieces shared by the Dictionary, Insights and Transcriptions pages.
use flow_ui::prelude::*;

/// `DictionaryPillButtonStyle`: small gray button, or the dark filled one for primary actions.
pub fn pill(id: impl Into<ElementId>, label: impl Into<SharedString>, prominent: bool, cx: &App) -> FlowButton {
    let p = pal(cx);
    let label: SharedString = label.into();
    let (fill, fg, size, weight, kind) = if prominent { (p.ink, p.surface, 15., 500., ButtonKind::Primary) } else { (p.button, p.ink, 13., 400., ButtonKind::Prototype) };
    // Primary's padding is 16 by 9; Swift's prominent pill is 18 by 10.
    // Plain: `Txt` rounds a 13 line up to 16; Swift's is 15.6, so its pill is 28, not 29.
    let pad = if prominent { (2., 1.) } else { (0., -0.5) };
    FlowButton::new(id, kind, label.clone())
        .fill(fill)
        .text_color(fg)
        .disabled_opacity(0.45)
        .when(!prominent, |b| b.pressed(p.tint))
        .content(div().mx(px(pad.0)).my(px(pad.1)).child(t(label).font(size, weight).color(fg).a11y_hidden()))
}

/// `.overlay(RoundedRectangle(...).stroke(line))`: an outline that takes no layout. Goes last in a
/// `relative` parent.
pub fn outline(cx: &App) -> Div {
    div().absolute().inset_0().border_1().border_color(pal(cx).line).rounded(px(12.))
}

/// SwiftUI's `.help`: the tooltip on any element.
pub fn help(id: impl Into<ElementId>, text: impl Into<SharedString>, child: impl IntoElement) -> Stateful<Div> {
    let text: SharedString = text.into();
    div().id(id).child(child).tooltip(move |w, cx| Tooltip::new(text.clone()).build(w, cx))
}

/// A menu row with `symbol` before its label: `Label` in a SwiftUI `Menu`.
pub fn menu_item(label: &'static str, symbol: &'static str) -> PopupMenuItem {
    PopupMenuItem::element(move |_, cx| h_flex().id(SharedString::new_static(symbol)).test_support().gap(px(6.)).child(icon(symbol, 13., pal(cx).ink)).child(t(label).size(13.).color(pal(cx).ink)))
}

/// The same row with its own accessibility identifier.
pub fn identified_item(id: &'static str, label: &'static str, symbol: &'static str) -> PopupMenuItem {
    PopupMenuItem::element(move |_, cx| h_flex().id(SharedString::new_static(id)).test_support().gap(px(6.)).child(icon(symbol, 13., pal(cx).ink)).child(t(label).size(13.).color(pal(cx).ink)))
}

/// `Button(role: .destructive)` in a menu: the system red, with its symbol when it has one.
pub fn destructive_item(label: &'static str, symbol: Option<&'static str>) -> PopupMenuItem {
    PopupMenuItem::element(move |_, cx| {
        let red = pal(cx).destructive();
        h_flex().gap(px(6.)).when_some(symbol, |d, s| d.child(icon(s, 13., red))).child(t(label).size(13.).color(red))
    })
}

/// The shell's card border takes a point of layout where Swift's is an overlay; this gives it back
/// so page content sits and wraps where Swift's does.
pub fn under_card_border(content: impl IntoElement) -> Div {
    div().relative().size_full().child(div().absolute().top(px(-1.)).bottom(px(-1.)).left(px(-1.)).right(px(-1.)).child(content))
}

/// The sheet's card: surface fill, rounded, no border, as an AppKit sheet shows it.
pub fn sheet_card(width: f32, cx: &App) -> Div {
    let p = pal(cx);
    div().w(px(width)).bg(p.surface).rounded(px(16.)).shadow_lg().flex().flex_col()
}

/// macOS `confirmationDialog`: an AppKit alert on the window. Its glass can't be drawn here, so the
/// fill is what it averages to over the dimmed window; the type is Figtree where AppKit's is SF.
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
    let dark = p.ink.l > 0.5;
    // ponytail: GPUI has no backdrop blur, so the glass is its measured colour over a plain page, opaque enough to hide what's behind. Real blur needs a native NSVisualEffectView.
    let fill = if dark { hsla(0., 0., 0.165, 0.97) } else { hsla(0., 0., 0.859, 0.97) };
    // A native alert centers a short message and left-aligns one that wraps, at about 180 wide.
    let centered = !message.is_empty() && message.len() <= 24;
    v_flex()
        .w(px(260.))
        .when(centered, |d| d.items_center())
        .px(px(21.))
        .font_family(".SystemUIFont")
        .pt(px(19.5))
        .pb(px(8.))
        .gap(px(10.))
        .bg(fill)
        .rounded(px(26.))
        .shadow(vec![
            BoxShadow { color: black().opacity(0.25), offset: point(px(0.), px(0.)), blur_radius: px(0.5), spread_radius: px(0.5), inset: false },
            BoxShadow { color: black().opacity(0.14), offset: point(px(0.), px(6.)), blur_radius: px(16.), spread_radius: px(0.), inset: false },
        ])
        .child(t(title.to_string()).font(13., 600.).color(p.ink))
        .when(!message.is_empty(), |d| d.child(div().max_w(px(170.)).child(t(message.to_string()).size(13.).color(p.ink))))
        .child(
            h_flex()
                // A native alert's buttons sit 16 from the edge and 8 apart, wider than its text.
                .w(px(228.))
                .flex_none()
                .mx(px(-5.))
                .justify_between()
                .pt(px(6.5))
                .pb(px(7.5))
                .child(prompt_button(format!("{prefix}.cancel"), "Cancel").on_click(on_cancel))
                .child(destructive_prompt_button(format!("{prefix}.confirm"), action.to_string()).on_click(on_action)),
        )
}
