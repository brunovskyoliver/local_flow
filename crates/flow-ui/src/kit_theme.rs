//! Maps `Palette` onto GPUI Kit's theme so Kit controls take LocalFlow's colors.
use crate::tokens::pal;
use gpui_kit::component::theme::Theme;
use gpui_kit::{App, px};

pub fn apply(cx: &mut App) {
    let p = pal(cx);
    let mode = if p.mode.is_dark() { gpui_kit::component::theme::ThemeMode::Dark } else { gpui_kit::component::theme::ThemeMode::Light };
    Theme::change(mode, None, cx);
    Theme::update(cx, |t| {
        t.radius = px(8.);
        let c = &mut t.colors;
        c.background = p.surface;
        c.foreground = p.ink;
        c.border = p.line;
        c.input = p.line;
        c.ring = p.accent;
        c.caret = p.accent;
        c.selection = p.accent.opacity(0.25);
        c.muted = p.tint;
        c.muted_foreground = p.muted;
        c.accent = p.tint;
        c.accent_foreground = p.ink;
        c.primary = p.primary;
        c.primary_foreground = p.on_primary;
        c.primary_hover = p.primary;
        c.primary_active = p.primary;
        c.secondary = p.tint;
        c.secondary_foreground = p.ink;
        c.secondary_hover = p.button;
        c.secondary_active = p.button;
        c.popover = p.surface;
        c.popover_foreground = p.ink;
        c.switch = p.rule;
        c.switch_thumb = gpui_kit::white();
        c.list_hover = p.tint;
        c.list_active = p.tint;
        c.overlay = gpui_kit::black().opacity(0.25);
        c.scrollbar = gpui_kit::transparent_black();
        c.link = p.accent;
        c.danger = p.warning;
        c.danger_foreground = p.on_primary;
    });
}
