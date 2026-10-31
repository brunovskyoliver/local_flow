//! Ports of the shared SwiftUI styles in `UI/Appearance.swift`.
use crate::icons::icon;
use crate::tokens::pal;
use crate::txt::{Txt, t};
use gpui_kit::component::button::{Button, ButtonCustomVariant, ButtonVariants};
use gpui_kit::component::{Disableable, Sizable};
use gpui_kit::prelude::*;
use gpui_kit::*;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ButtonKind {
    /// `PrototypeButtonStyle`: 13 medium, padding 12 and 7, `tint`, pressed `button`.
    Prototype,
    /// `PrimaryButtonStyle`: 14 medium, padding 16 and 9, `primary`, pressed at 80 percent.
    Primary,
    /// `.buttonStyle(.plain)` with no chrome.
    Plain,
}

/// A real button: role, name, Invoke action and keyboard focus come from Kit's `Button`.
#[derive(IntoElement)]
pub struct FlowButton {
    id: ElementId,
    kind: ButtonKind,
    label: SharedString,
    a11y_label: Option<SharedString>,
    disabled: bool,
    min_width: f32,
    full_width: bool,
    leading: Option<(&'static str, f32)>,
    custom: Option<AnyElement>,
    text_color: Option<Hsla>,
    fill: Option<Hsla>,
    toggled: Option<bool>,
    disabled_opacity: f32,
    tooltip: Option<SharedString>,
    on_click: Option<Box<dyn Fn(&ClickEvent, &mut Window, &mut App) + 'static>>,
}

pub fn prototype_button(id: impl Into<ElementId>, label: impl Into<SharedString>) -> FlowButton {
    FlowButton::new(id, ButtonKind::Prototype, label)
}
pub fn primary_button(id: impl Into<ElementId>, label: impl Into<SharedString>) -> FlowButton {
    FlowButton::new(id, ButtonKind::Primary, label)
}
pub fn plain_button(id: impl Into<ElementId>, label: impl Into<SharedString>) -> FlowButton {
    FlowButton::new(id, ButtonKind::Plain, label)
}

impl FlowButton {
    pub fn new(id: impl Into<ElementId>, kind: ButtonKind, label: impl Into<SharedString>) -> Self {
        FlowButton {
            id: id.into(),
            kind,
            label: label.into(),
            a11y_label: None,
            disabled: false,
            min_width: 0.,
            full_width: false,
            leading: None,
            custom: None,
            text_color: None,
            fill: None,
            toggled: None,
            disabled_opacity: 0.45,
            tooltip: None,
            on_click: None,
        }
    }
    /// SwiftUI's `.isSelected` trait, exposed as a toggle's pressed state.
    pub fn toggled(mut self, on: bool) -> Self {
        self.toggled = Some(on);
        self
    }
    /// Opacity when disabled, 0.45 unless a style says otherwise.
    pub fn disabled_opacity(mut self, o: f32) -> Self {
        self.disabled_opacity = o;
        self
    }
    pub fn disabled_level(&self) -> f32 {
        self.disabled_opacity
    }
    pub fn disabled(mut self, d: bool) -> Self {
        self.disabled = d;
        self
    }
    pub fn min_width(mut self, w: f32) -> Self {
        self.min_width = w;
        self
    }
    pub fn full_width(mut self) -> Self {
        self.full_width = true;
        self
    }
    /// A leading SF Symbol at `size`, spaced 6 from the label.
    pub fn symbol(mut self, name: &'static str, size: f32) -> Self {
        self.leading = Some((name, size));
        self
    }
    pub fn text_color(mut self, c: impl Into<Hsla>) -> Self {
        self.text_color = Some(c.into());
        self
    }
    /// A fill other than the kind's, such as `.borderedProminent`'s accent.
    pub fn fill(mut self, c: impl Into<Hsla>) -> Self {
        self.fill = Some(c.into());
        self
    }
    /// Swift's `.isSelected` accessibility trait; it changes no pixels.
    pub fn a11y_selected(mut self, selected: bool) -> Self {
        self.toggled = Some(selected);
        self
    }
    pub fn tooltip(mut self, text: impl Into<SharedString>) -> Self {
        self.tooltip = Some(text.into());
        self
    }
    /// The accessible name when the visible label isn't enough.
    pub fn a11y_label(mut self, l: impl Into<SharedString>) -> Self {
        self.a11y_label = Some(l.into());
        self
    }
    /// Replaces the label with custom content; the label stays the accessible name.
    pub fn content(mut self, e: impl IntoElement) -> Self {
        self.custom = Some(e.into_any_element());
        self
    }
    pub fn on_click(mut self, f: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_click = Some(Box::new(f));
        self
    }
}

impl ButtonKind {
    /// (fill, pressed fill, text, font size, weight, horizontal padding, vertical padding).
    pub fn style(self, p: &crate::tokens::Palette) -> (Hsla, Hsla, Hsla, f32, f32, f32, f32) {
        let transparent = gpui_kit::transparent_black();
        match self {
            ButtonKind::Prototype => (p.tint, p.button, p.ink, 13., 500., 12., 7.),
            ButtonKind::Primary => (p.primary, p.primary.opacity(0.8), p.on_primary, 14., 500., 16., 9.),
            ButtonKind::Plain => (transparent, transparent, p.ink, 13., 400., 0., 0.),
        }
    }
}

impl RenderOnce for FlowButton {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let p = pal(cx);
        let (bg, active, fg, size, weight, px_x, px_y) = self.kind.style(&p);
        let fg = self.text_color.unwrap_or(fg);
        let (bg, active) = self.fill.map_or((bg, active), |f| (f, f.opacity(0.8)));
        let variant = ButtonCustomVariant::new(cx).color(bg).foreground(fg).hover(bg).active(active).shadow(false);
        let label = self.a11y_label.unwrap_or_else(|| self.label.clone());
        let content = match self.custom {
            Some(c) => c,
            None => div()
                .flex()
                .items_center()
                .justify_center()
                .gap(px(6.))
                .when_some(self.leading, |d, (s, z)| d.child(icon(s, z, fg)))
                .child(t(self.label).font(size, weight).color(fg).a11y_hidden())
                .into_any_element(),
        };
        let mut b = Button::new(self.id)
            .custom(variant)
            .accessibility_label(label)
            .child(content)
            .disabled(self.disabled)
            .h_auto()
            .px(px(px_x))
            .py(px(px_y))
            .rounded(px(if self.kind == ButtonKind::Plain { 0. } else { 8. }))
            .border_0()
            .when(self.min_width > 0., |b| b.min_w(px(self.min_width)))
            .when(self.full_width, |b| b.w_full());
        // Kit's custom variant fades its fill, so the real color goes on the instance style.
        b = b.bg(bg);
        if let Some(tip) = self.tooltip {
            b = b.tooltip(tip);
        }
        if self.disabled {
            b = b.opacity(self.disabled_opacity);
        }
        if let Some(on) = self.toggled {
            b = b.toggled(on);
        }
        if let Some(f) = self.on_click {
            b = b.on_click(move |e, w, cx| f(e, w, cx));
        }
        b.with_size(gpui_kit::component::Size::Small)
    }
}

/// `PrototypePage`: a centered column in a scroll view, 48 or 24 horizontal padding by width.
pub fn prototype_page(id: impl Into<ElementId>, max_width: f32, cx: &App, content: impl IntoElement) -> impl IntoElement {
    let compact = cx.global::<crate::tokens::Flow>().compact;
    let p = pal(cx);
    div()
        .id(id)
        .size_full()
        .overflow_y_scroll()
        .flex()
        .flex_col()
        .items_center()
        .text_color(p.ink)
        .text_size(px(14.))
        .child(
            div()
                .w_full()
                .max_w(px(max_width))
                .px(px(if compact { 24. } else { 48. }))
                .pt(px(if compact { 32. } else { 48. }))
                .pb(px(64.))
                .flex_none()
                .child(content),
        )
}

/// A one-point line, SwiftUI's `Rectangle().fill(line).frame(height: 1)`.
pub fn hairline(cx: &App) -> Div {
    div().h(px(1.)).w_full().flex_none().bg(pal(cx).line)
}

/// Small caps-style label shared across pages: Figtree 11 semibold with tracking.
pub fn caps_label(text: impl Into<SharedString>) -> Txt {
    t(text).font(11., 600.).tracking(0.6)
}

/// The rounded card used across pages.
pub fn card(cx: &App, radius: f32, padding: f32) -> Div {
    let p = pal(cx);
    div().bg(p.card).border_1().border_color(p.card_line).rounded(px(radius)).p(px(padding))
}

/// `.hoverRevealed`: stays in the accessibility tree and focus order, invisible until shown.
pub fn hover_revealed(group: impl Into<SharedString>, keep: bool, d: Div) -> Div {
    let g: SharedString = group.into();
    d.when(!keep, |d| d.invisible_until_group_hover(g))
}

/// Also shown while keyboard focus is inside `d`, as Swift's `@FocusState` row actions are.
pub fn hover_or_focus_revealed(group: impl Into<SharedString>, keep: bool, focus: &FocusHandle, d: Div) -> Div {
    hover_revealed(group, keep, d).track_focus(focus).in_focus(|s| s.opacity(1.))
}

trait InvisibleUntil {
    fn invisible_until_group_hover(self, g: SharedString) -> Self;
}
impl InvisibleUntil for Div {
    fn invisible_until_group_hover(self, g: SharedString) -> Self {
        self.opacity(0.).group_hover(g, |s| s.opacity(1.))
    }
}

/// The sidebar row: 16 icon in a 20 frame, 15 title, 35 high, `tint` when selected.
pub fn prototype_nav(id: &'static str, title: &'static str, symbol: &'static str, selected: bool, tint: Hsla, ink: Hsla) -> FlowButton {
    plain_button(id, title)
        .full_width()
        .a11y_selected(selected)
        .content(
            div()
                .flex()
                .items_center()
                .gap(px(10.))
                .px(px(10.))
                .h(px(35.))
                .w_full()
                .rounded(px(8.))
                .when(selected, |d| d.bg(tint))
                .child(div().w(px(20.)).flex().justify_center().child(icon(symbol, 16., ink)))
                .child(t(title).size(15.).lines(1).a11y_hidden())
                .into_any_element(),
        )
}

/// SwiftUI's `Label`: a symbol and text, spaced as AppKit spaces them.
pub fn sf_label(symbol: &'static str, text: impl Into<SharedString>, size: f32, color: Hsla) -> Div {
    h_flex().gap(px(6.)).child(icon(symbol, size, color)).child(t(text).size(size).color(color))
}

pub fn h_flex() -> Div {
    div().flex().flex_row().items_center()
}
pub fn v_flex() -> Div {
    div().flex().flex_col()
}

/// SwiftUI's `.toggleStyle(.switch)`: NSSwitch's geometry on macOS 26, measured from the reference
/// app and `NSSwitch.fittingSize`. Regular 54x24 with a 32x20 capsule knob, small 44x20 with 26x16.
/// Takes the same builder calls as Kit's `Switch`. `ControlSize::Small` is `.controlSize(.small)`;
/// every other size is regular. The track is the accent while the window is key and grey when it isn't.
#[derive(IntoElement)]
pub struct FlowSwitch {
    id: ElementId,
    checked: bool,
    disabled: bool,
    label: Option<SharedString>,
    size: gpui_kit::component::Size,
    on_change: Option<std::rc::Rc<dyn Fn(&bool, &mut Window, &mut App)>>,
}

impl FlowSwitch {
    pub fn new(id: impl Into<ElementId>) -> Self {
        FlowSwitch { id: id.into(), checked: false, disabled: false, label: None, size: gpui_kit::component::Size::Medium, on_change: None }
    }
    pub fn checked(mut self, checked: bool) -> Self {
        self.checked = checked;
        self
    }
    pub fn accessibility_label(mut self, label: impl Into<SharedString>) -> Self {
        self.label = Some(label.into());
        self
    }
    pub fn on_click(mut self, f: impl Fn(&bool, &mut Window, &mut App) + 'static) -> Self {
        self.on_change = Some(std::rc::Rc::new(f));
        self
    }
    /// (track width, track height, knob width, knob height) in points.
    pub fn geometry(small: bool) -> (f32, f32, f32, f32) {
        if small { (44., 20., 26., 16.) } else { (54., 24., 32., 20.) }
    }
    /// The track colour measured from the reference app.
    pub fn track_color(checked: bool, key_window: bool, p: &crate::tokens::Palette) -> Hsla {
        let wash = |a: f32| if p.mode.is_dark() { gpui_kit::white().opacity(a) } else { gpui_kit::black().opacity(a) };
        match (checked, key_window) {
            (true, true) => p.accent,
            (true, false) => wash(0.14),
            (false, _) => wash(if p.mode.is_dark() { 0.09 } else { 0.11 }),
        }
    }
}

impl Sizable for FlowSwitch {
    fn with_size(mut self, size: impl Into<gpui_kit::component::Size>) -> Self {
        self.size = size.into();
        self
    }
}

impl Disableable for FlowSwitch {
    fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }
}

impl RenderOnce for FlowSwitch {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        use gpui_kit::base::{Switch as BaseSwitch, SwitchThumb, SwitchTrack, spring};
        use gpui_kit::component::{ActiveTheme, Size};
        let p = pal(cx);
        let small = matches!(self.size, Size::Small | Size::XSmall);
        let (w, h, kw, kh) = Self::geometry(small);
        let inset = (h - kh) / 2.;
        let focus = window.use_keyed_state(self.id.clone(), cx, |_, cx| cx.focus_handle()).read(cx).clone();
        let focused = focus.is_focused(window);
        let policy = cx.theme().motion_tokens().spring_move;
        let x = spring((self.id.clone(), "knob"), px(if self.checked { w - kw - inset } else { inset }), policy, window, cx);
        let track = Self::track_color(self.checked, window.is_window_active(), &p);
        let on_change = self.on_change;
        BaseSwitch::new(self.id.clone())
            .checked(self.checked)
            .disabled(self.disabled)
            .when_some(self.label, |s, l| s.accessibility_label(l))
            .when_some(on_change, |s, f| s.on_change(move |next, _, w, cx| f(&next, w, cx)))
            .track_focus(&focus)
            .flex()
            .flex_none()
            .w(px(w))
            .h(px(h))
            .when(self.disabled, |s| s.opacity(0.5))
            .child(
                SwitchTrack::new((self.id.clone(), "track"))
                    .checked(self.checked)
                    .disabled(self.disabled)
                    .relative()
                    .w(px(w))
                    .h(px(h))
                    .rounded(px(h / 2.))
                    .bg(track)
                    .when(focused, |t| t.border_2().border_color(p.accent.opacity(0.5)))
                    .child(
                        SwitchThumb::new(self.checked)
                            .absolute()
                            .top(px(inset))
                            .left(x)
                            .w(px(kw))
                            .h(px(kh))
                            .rounded(px(kh / 2.))
                            .bg(gpui_kit::white())
                            .shadow(vec![BoxShadow { color: gpui_kit::black().opacity(0.22), offset: point(px(0.), px(1.)), blur_radius: px(2.), spread_radius: px(0.), inset: false }]),
                    ),
            )
    }
}

/// A value springing to `target`, for SwiftUI's `.animation(.spring(response, damping), value:)`.
/// `.smooth` is response 0.5, damping 1. Reduce Motion lands on the target at once.
pub fn spring_value(id: impl Into<ElementId>, target: f32, response: f32, damping: f32, window: &mut Window, cx: &mut App) -> f32 {
    if cx.global::<crate::tokens::Flow>().reduce_motion {
        return target;
    }
    let policy = gpui_kit::base::Spring::new(std::time::Duration::from_secs_f32(response)).with_damping(damping).with_epsilon(0.001);
    f32::from(gpui_kit::base::spring(id.into(), px(target), policy, window, cx))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tokens::{Mode, Palette};

    // Measured from the Swift reference at 2x.
    #[::core::prelude::v1::test]
    fn switch_matches_nsswitch_geometry_and_colours() {
        assert_eq!(FlowSwitch::geometry(false), (54., 24., 32., 20.));
        assert_eq!(FlowSwitch::geometry(true), (44., 20., 26., 16.));
        let (light, dark) = (Palette::new(Mode::Light), Palette::new(Mode::Dark));
        assert_eq!(FlowSwitch::track_color(true, true, &light), light.accent);
        assert_eq!((FlowSwitch::track_color(false, true, &light).a, FlowSwitch::track_color(false, true, &dark).a), (0.11, 0.09));
        assert_eq!(FlowSwitch::track_color(true, false, &dark).a, 0.14);
    }
}

/// What a native sheet does to its parent, measured from the Swift reference: a 60 percent wash.
pub fn sheet_scrim(cx: &App) -> Hsla {
    let level = if pal(cx).mode.is_dark() { 21. / 255. } else { 171. / 255. };
    gpui_kit::hsla(0., 0., level, 0.6)
}

/// A native sheet's own fill: white, or 0x1E gray in dark, with no border.
pub fn sheet_fill(cx: &App) -> Hsla {
    gpui_kit::hsla(0., 0., if pal(cx).mode.is_dark() { 30. / 255. } else { 1. }, 1.)
}
