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
            on_click: None,
        }
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

impl RenderOnce for FlowButton {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let p = pal(cx);
        let transparent = gpui_kit::transparent_black();
        let (bg, active, fg, size, weight, px_x, px_y) = match self.kind {
            ButtonKind::Prototype => (p.tint, p.button, p.ink, 13., 500., 12., 7.),
            ButtonKind::Primary => (p.primary, p.primary.opacity(0.8), p.on_primary, 14., 500., 16., 9.),
            ButtonKind::Plain => (transparent, transparent, p.ink, 13., 400., 0., 0.),
        };
        let fg = self.text_color.unwrap_or(fg);
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
        if self.disabled {
            b = b.opacity(0.45);
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

trait InvisibleUntil {
    fn invisible_until_group_hover(self, g: SharedString) -> Self;
}
impl InvisibleUntil for Div {
    fn invisible_until_group_hover(self, g: SharedString) -> Self {
        self.opacity(0.).group_hover(g, |s| s.opacity(1.))
    }
}
