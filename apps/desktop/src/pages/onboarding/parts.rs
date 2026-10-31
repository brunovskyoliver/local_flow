//! `OnboardingView`'s private components.
use flow_core::onboarding::{RowState, bytes};
use flow_ui::prelude::*;
use std::time::Duration;

pub type Click = Box<dyn Fn(&ClickEvent, &mut Window, &mut App) + 'static>;

/// Every text on these pages lays out at SwiftUI's whole-point line heights.
#[track_caller]
pub fn t(text: impl Into<SharedString>) -> Txt {
    flow_ui::prelude::t(text).swift_lines()
}

pub fn headline(lead: &str, emphasis: &str, tail: &str) -> Txt {
    rich(vec![span(lead.to_string()), span(emphasis.to_string()).italic(), span(tail.to_string())]).serif().font(38., 400.).tracking(-0.4).swift_lines()
}

pub fn lede(text: String, cx: &App) -> Txt {
    t(text).size(16.).color(pal(cx).muted).line_spacing(3.)
}

pub fn field_label(text: &'static str, cx: &App) -> Txt {
    t(text).font(12., 600.).color(pal(cx).muted)
}

pub fn eyebrow(text: &str, cx: &App) -> Txt {
    t(text.to_uppercase()).font(11., 600.).tracking(1.2).color(pal(cx).accent)
}

pub fn setup_card(cx: &App) -> Div {
    let p = pal(cx);
    // SwiftUI strokes inside the padding, GPUI adds the border to it.
    v_flex().w_full().gap(px(18.)).p(px(19.)).bg(p.surface).rounded(px(14.)).border_1().border_color(p.card_line)
}

pub fn row_icon(symbol: &str, cx: &App) -> Div {
    let p = pal(cx);
    h_flex().flex_none().justify_center().size(px(34.)).bg(p.tint).rounded(px(9.)).child(icon(symbol, 17., p.accent))
}

pub fn title_detail(title: impl Into<SharedString>, detail: impl Into<SharedString>, cx: &App) -> Div {
    v_flex().flex_1().min_w_0().gap(px(3.)).child(t(title).font(14., 600.)).child(t(detail).size(13.).color(pal(cx).muted))
}

pub fn feature_row(symbol: &str, title: &'static str, detail: String, cx: &App) -> Div {
    h_flex().w_full().items_start().gap(px(14.)).child(row_icon(symbol, cx)).child(title_detail(title, detail, cx))
}

/// SwiftUI's `Label` at Figtree 13 `muted`.
pub fn note(symbol: &str, text: String, cx: &App) -> Div {
    let m = pal(cx).muted;
    h_flex().w_full().items_start().gap(px(7.)).child(div().pt(px(0.5)).child(icon(symbol, 15., m))).child(div().flex_1().min_w_0().child(t(text).size(13.).color(m)))
}

pub fn badge(text: &'static str, cx: &App) -> Div {
    let a = pal(cx).accent;
    div().flex_none().px(px(7.)).py(px(2.)).bg(a.opacity(0.12)).rounded_full().child(t(text).font(11., 600.).color(a))
}

/// `largecircle.fill.circle` and `circle`: drawn, since Lucide's dot is much smaller than the SF one.
/// The glyph is 17 across in a layout box 20 wide, as the SF one at this size is.
fn radio(selected: bool, cx: &App) -> Div {
    let p = pal(cx);
    let ring = h_flex().flex_none().justify_center().size(px(17.)).mt(px(1.)).rounded_full().border(px(1.2));
    let ring = if selected { ring.border_color(p.accent).child(div().size(px(10.5)).rounded_full().bg(p.accent)) } else { ring.border_color(p.rule) };
    h_flex().flex_none().w(px(20.)).justify_center().items_start().child(ring)
}

/// A radio-style card; the whole card is the button.
pub fn selectable_card(id: impl Into<ElementId>, label: String, selected: bool, available: bool, choose: Click, content: Div, cx: &App) -> FlowButton {
    let p = pal(cx);
    plain_button(id, label)
        .full_width()
        .toggled(selected)
        .disabled(!available)
        .disabled_opacity(0.55)
        .on_click(choose)
        .content(
            h_flex()
                .w_full()
                .items_start()
                .gap(px(14.))
                .p(px(if selected { 14.5 } else { 15. }))
                .bg(if selected { p.accent.opacity(0.07) } else { p.surface })
                .rounded(px(12.))
                .border(px(if selected { 1.5 } else { 1. }))
                .border_color(if selected { p.accent } else { p.card_line })
                .child(radio(selected, cx))
                .child(content),
        )
}

pub fn choice_label(symbol: &str, title: &str, badge_text: Option<&'static str>, detail: String, cx: &App) -> Div {
    let m = pal(cx).muted;
    h_flex()
        .flex_1()
        .min_w_0()
        .items_start()
        .gap(px(14.))
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(4.))
                .child(h_flex().gap(px(8.)).child(t(title.to_string()).font(15., 600.)).when_some(badge_text, |d, b| d.child(badge(b, cx))))
                .child(t(detail).size(13.).color(m)),
        )
        // `Spacer(minLength: 12)` with the stack's 14 on both sides: 40 from the text.
        .child(div().flex_none().pl(px(26.)).pt(px(1.)).child(icon(symbol, 21., m)))
}

/// Drawn, as Swift's is. Nil sweeps a segment; with Reduce Motion it holds a dimmed full track.
pub fn bar(fraction: Option<f64>, _: &App) -> impl IntoElement {
    Bar { fraction }
}

#[derive(IntoElement)]
struct Bar {
    fraction: Option<f64>,
}

impl RenderOnce for Bar {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let p = pal(cx);
        let reduce = cx.global::<Flow>().reduce_motion;
        let track = div().id("onboarding.bar").relative().w_full().h(px(5.)).flex_none().bg(p.line).rounded_full().overflow_hidden().role(flow_ui::gpui::accesskit::Role::ProgressIndicator).aria_label("Progress").aria_value(RowState::percent(self.fraction));
        match self.fraction {
            Some(f) => {
                // `.animation(.smooth, value: fraction)`.
                let f = spring_value("onboarding.bar.tween", f.clamp(0., 1.) as f32, 0.5, 1., window, cx);
                track.child(div().id("onboarding.bar.fill").h_full().min_w(px(6.)).w(relative(f)).bg(p.accent).rounded_full().test_support()).test_support().into_any_element()
            }
            None if reduce => track.child(div().size_full().bg(p.accent.opacity(0.45)).rounded_full()).test_support().into_any_element(),
            None => track
                .child(
                    div().absolute().top_0().bottom_0().w(relative(0.28)).bg(p.accent).rounded_full().with_animation("onboarding.sweep", Animation::new(Duration::from_millis(1600)).repeat(), |d, phase| d.left(relative(1.28 * phase - 0.28))),
                )
                .test_support()
                .into_any_element(),
        }
    }
}

pub fn download_row(symbol: &str, title: &'static str, detail: String, state: RowState, retry: Option<Click>, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    let trailing = match &state {
        RowState::Waiting(s) | RowState::Working(s) => t(s.clone()).size(12.).color(p.muted).into_any_element(),
        RowState::Progress(c, total) => t(format!("{} of {}", bytes(*c), bytes(*total))).size(12.).mono_digits().color(p.muted).into_any_element(),
        RowState::Done => h_flex().gap(px(5.)).child(icon("checkmark.circle.fill", 13., p.accent)).child(t("Ready").font(12., 500.).color(p.accent)).into_any_element(),
        RowState::Failed(_) => h_flex().gap(px(5.)).child(icon("exclamationmark.circle", 13., p.warning)).child(t("Stopped").size(12.).color(p.warning)).into_any_element(),
    };
    let below = match state {
        RowState::Progress(c, total) => Some(bar(Some(RowState::fraction(c, total)), cx).into_any_element()),
        RowState::Working(_) => Some(bar(None, cx).into_any_element()),
        RowState::Failed(message) => Some(
            h_flex()
                .w_full()
                .items_start()
                .gap(px(8.))
                .child(div().flex_1().min_w_0().child(t(message).size(12.).color(p.warning)))
                .when_some(retry, |d, r| d.child(prototype_button(SharedString::from(format!("onboarding.retry.{title}")), "Retry").on_click(r)))
                .into_any_element(),
        ),
        _ => None,
    };
    h_flex()
        .id(SharedString::from(format!("onboarding.row.{title}")))
        .w_full()
        .items_start()
        .gap(px(14.))
        .child(row_icon(symbol, cx))
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(8.))
                .child(h_flex().w_full().items_start().gap(px(12.)).child(title_detail(title, detail, cx)).child(div().flex_none().pt(px(2.)).child(trailing)))
                .children(below),
        )
}

pub fn allowed_label(cx: &App) -> Div {
    let a = pal(cx).accent;
    h_flex().gap(px(6.)).child(icon("checkmark.circle.fill", 15., a)).child(t("Everything is allowed.").font(14., 500.).color(a))
}

/// `SettingsRow` as `RemoteDictationView` and the permissions group use it.
pub fn settings_row(title: impl Into<SharedString>, detail: Option<String>, control: impl IntoElement, cx: &App) -> Div {
    let m = pal(cx).muted;
    h_flex()
        .w_full()
        .gap(px(22.))
        .py(px(19.))
        .child(v_flex().flex_1().min_w_0().gap(px(5.)).child(t(title).size(14.)).when_some(detail, |d, s| d.child(div().py(px(1.)).child(t(s).size(12.).color(m).line_spacing(4.)))))
        .child(div().flex_none().child(control))
}

/// `InputField`: a 38 high box with a leading icon around a Kit input. `placeholder` is drawn here
/// since Kit's has one colour, and Swift's address placeholder is a link (see `Palette`).
pub fn input_field(symbol: &str, input: Input, placeholder: Option<Txt>, cx: &App) -> Div {
    let p = pal(cx);
    h_flex()
        .w_full()
        .h(px(38.))
        // SwiftUI strokes inside the padding, GPUI adds the border to it.
        .px(px(11.))
        .gap(px(10.))
        .bg(p.canvas)
        .rounded(px(9.))
        .border_1()
        .border_color(p.card_line)
        .child(icon(symbol, 16., p.muted))
        .child(
            h_flex()
                .relative()
                .flex_1()
                .min_w_0()
                .when_some(placeholder, |d, text| d.child(div().absolute().left_0().child(text.a11y_hidden())))
                .child(div().w_full().child(input.appearance(false).px(px(0.)))),
        )
}

/// A miniature window in fixed colors, so a card previews its theme whatever the current one is.
fn paint_mini(b: Bounds<Pixels>, dark: bool, window: &mut Window) {
    let hex = |light: u32, dark_value: u32| -> Hsla { rgb(if dark { dark_value } else { light }).into() };
    let (canvas, surface, ink, line, accent) = (hex(0xF7F6F3, 0x1F1F1E), hex(0xFCFCFB, 0x141414), hex(0x2B2A28, 0xE8E6E1), hex(0xE4E1D9, 0x333331), hex(0x247872, 0x68BDB0));
    let (w, h) = (f32::from(b.size.width), f32::from(b.size.height));
    let mut rect = |x: f32, y: f32, width: f32, height: f32, radius: f32, color: Hsla| {
        let r = Bounds { origin: b.origin + point(px(x), px(y)), size: size(px(width), px(height)) };
        window.paint_quad(fill(r, color).corner_radii(px(radius)));
    };
    rect(0., 0., w, h, 8., canvas);
    rect(8., 10., 26., 4., 2., ink);
    for i in 0..3 {
        rect(8., 19. + 8. * i as f32, 22., 3., 1.5, line);
    }
    let (x, pane_w, pane_h) = (40., w - 46., h - 12.);
    rect(x, 6., pane_w, pane_h, 5., surface);
    rect(x + 10., 16., 48., 5., 2.5, ink);
    rect(x + 10., 27., pane_w - 20., 3., 1.5, line);
    rect(x + 10., 36., 56., 3., 1.5, line);
    rect(x + 10., h - 24., 30., 8., 4., accent);
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mini {
    System,
    Light,
    Dark,
}

pub fn mini_window(kind: Mini) -> impl IntoElement {
    canvas(
        |_, _, _| (),
        move |b, _, window, _| match kind {
            Mini::Light => paint_mini(b, false, window),
            Mini::Dark => paint_mini(b, true, window),
            Mini::System => {
                paint_mini(b, false, window);
                // ponytail: GPUI masks are rectangles, so half-point strips stair-step the diagonal
                // (0.62w,0) to (0.38w,h). Costs about 200 masks of ten quads on one small card.
                let (w, h) = (f32::from(b.size.width), f32::from(b.size.height));
                for row in 0..(h * 2.) as usize {
                    let y = row as f32 / 2.;
                    let left = w * (0.62 - 0.24 * y / h);
                    let strip = Bounds { origin: b.origin + point(px(left), px(y)), size: size(px(w - left), px(0.5)) };
                    window.with_content_mask(Some(ContentMask { bounds: strip }), |window| paint_mini(b, true, window));
                }
            }
        },
    )
    .w_full()
    .h(px(96.))
    .flex_none()
}

pub fn theme_card(id: &'static str, title: &'static str, a11y: &'static str, kind: Mini, selected: bool, choose: Click, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    div().flex_1().min_w_0().child(
        plain_button(id, a11y)
            .full_width()
            .toggled(selected)
            .on_click(choose)
            .content(
                v_flex()
                    .w_full()
                    .gap(px(10.))
                    .p(px(10.))
                    .bg(p.surface)
                    .rounded(px(12.))
                    .border(px(if selected { 2. } else { 1. }))
                    .border_color(if selected { p.accent } else { p.card_line })
                    .child(mini_window(kind))
                    .child(h_flex().w_full().justify_between().h(px(16.)).child(t(title).font(13., 500.).a11y_hidden()).when(selected, |d| d.child(icon("checkmark.circle.fill", 15., p.accent)))),
            ),
    )
}
