//! A direct port of `SottoPalette` in `UI/Appearance.swift`. `scripts/check-sotto-tokens.py`
//! keeps the hex values identical.
use gpui_kit::{App, Global, Hsla, Rgba, rgb};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Light,
    Dark,
    ContrastLight,
    ContrastDark,
}

impl Mode {
    pub fn new(dark: bool, high_contrast: bool) -> Self {
        match (dark, high_contrast) {
            (false, false) => Mode::Light,
            (true, false) => Mode::Dark,
            (false, true) => Mode::ContrastLight,
            (true, true) => Mode::ContrastDark,
        }
    }
    pub fn is_dark(self) -> bool {
        matches!(self, Mode::Dark | Mode::ContrastDark)
    }
}

const fn pick(mode: Mode, light: u32, dark: u32) -> u32 {
    match mode {
        Mode::Light | Mode::ContrastLight => light,
        Mode::Dark | Mode::ContrastDark => dark,
    }
}

const fn pick4(mode: Mode, light: u32, dark: u32, contrast_light: u32, contrast_dark: u32) -> u32 {
    match mode {
        Mode::Light => light,
        Mode::Dark => dark,
        Mode::ContrastLight => contrast_light,
        Mode::ContrastDark => contrast_dark,
    }
}

/// Raw hex values, so contrast tests can compute ratios.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hex {
    pub ink: u32,
    pub muted: u32,
    pub canvas: u32,
    pub surface: u32,
    pub tint: u32,
    pub button: u32,
    pub line: u32,
    pub accent: u32,
    pub card: u32,
    pub card_line: u32,
    pub rule: u32,
    pub heat_empty: u32,
    pub data_strong: u32,
    pub streak_outline: u32,
    pub data_scale: [u32; 4],
    pub data_quiet: u32,
    pub on_data_strong: u32,
    pub on_data: u32,
    pub on_data_quiet: u32,
    pub warning: u32,
    pub success: u32,
}

impl Hex {
    pub const fn new(m: Mode) -> Self {
        Hex {
            ink: pick4(m, 0x1A1A1A, 0xDEDDD7, 0x000000, 0xFFFFFF),
            muted: pick4(m, 0x686865, 0x9D9C98, 0x464544, 0xC8C8C2),
            canvas: pick(m, 0xF7F6F3, 0x1F1F1E),
            surface: pick(m, 0xFCFCFB, 0x141414),
            tint: pick(m, 0xF1EEE9, 0x2A2A29),
            button: pick(m, 0xEEEBE3, 0x2E2E2C),
            line: pick4(m, 0xEEEBE3, 0x292928, 0x9D9C98, 0x71716E),
            accent: pick(m, 0x247872, 0x68BDB0),
            card: pick(m, 0xF5F4F1, 0x1F1F1E),
            card_line: pick(m, 0xEDEBE4, 0x292928),
            rule: pick(m, 0xC4C0B4, 0x3A3A38),
            heat_empty: pick(m, 0xEDEBE4, 0x2A2A29),
            data_strong: pick(m, 0x345A5C, 0x4F8580),
            streak_outline: pick(m, 0x2F5452, 0xB9DDD8),
            data_scale: [
                pick(m, 0x457672, 0x84BDB5),
                pick(m, 0x59918A, 0x5A948D),
                pick(m, 0x9ACAC2, 0x3F6A65),
                pick(m, 0xD6ECEA, 0x2E4744),
            ],
            data_quiet: pick(m, 0x84BAB1, 0x3F6A65),
            on_data_strong: pick(m, 0xFFFFFF, 0x000000),
            on_data: pick(m, 0x1A1A1A, 0x141414),
            on_data_quiet: pick(m, 0x1A1A1A, 0xFFFFFF),
            warning: pick(m, 0xB43C0B, 0xFB923C),
            // Swift uses `.systemGreen`; these are its Aqua and Dark Aqua values.
            success: pick(m, 0x28CD41, 0x32D74B),
        }
    }
}

fn h(v: u32) -> Hsla {
    let c: Rgba = rgb(v);
    c.into()
}

#[derive(Clone, Copy)]
pub struct Palette {
    pub mode: Mode,
    pub ink: Hsla,
    pub muted: Hsla,
    pub canvas: Hsla,
    pub surface: Hsla,
    pub sidebar: Hsla,
    pub tint: Hsla,
    pub button: Hsla,
    pub line: Hsla,
    pub accent: Hsla,
    pub primary: Hsla,
    pub on_primary: Hsla,
    pub on_accent: Hsla,
    pub card: Hsla,
    pub card_line: Hsla,
    pub rule: Hsla,
    pub heat_empty: Hsla,
    pub data_strong: Hsla,
    pub streak_outline: Hsla,
    pub data_scale: [Hsla; 4],
    pub data_quiet: Hsla,
    pub on_data_strong: Hsla,
    pub on_data: Hsla,
    pub on_data_quiet: Hsla,
    pub success: Hsla,
    pub warning: Hsla,
}

impl Palette {
    pub fn new(mode: Mode) -> Self {
        let x = Hex::new(mode);
        Palette {
            mode,
            ink: h(x.ink),
            muted: h(x.muted),
            canvas: h(x.canvas),
            surface: h(x.surface),
            sidebar: h(x.canvas),
            tint: h(x.tint),
            button: h(x.button),
            line: h(x.line),
            accent: h(x.accent),
            primary: h(x.ink),
            on_primary: h(x.surface),
            on_accent: h(x.surface),
            card: h(x.card),
            card_line: h(x.card_line),
            rule: h(x.rule),
            heat_empty: h(x.heat_empty),
            data_strong: h(x.data_strong),
            streak_outline: h(x.streak_outline),
            data_scale: x.data_scale.map(h),
            data_quiet: h(x.data_quiet),
            on_data_strong: h(x.on_data_strong),
            on_data: h(x.on_data),
            on_data_quiet: h(x.on_data_quiet),
            success: h(x.success),
            warning: h(x.warning),
        }
    }
}

/// App-wide look state: the palette, Reduce Motion and whether the window is compact.
pub struct Flow {
    pub palette: Palette,
    pub reduce_motion: bool,
    pub compact: bool,
}
impl Global for Flow {}

pub fn pal(cx: &App) -> Palette {
    cx.global::<Flow>().palette
}

pub fn set_mode(mode: Mode, cx: &mut App) {
    cx.global_mut::<Flow>().palette = Palette::new(mode);
    crate::kit_theme::apply(cx);
}

/// WCAG contrast of two sRGB hex colors.
pub fn contrast(a: u32, b: u32) -> f32 {
    fn lum(v: u32) -> f32 {
        let f = |c: u32| {
            let c = c as f32 / 255.0;
            if c <= 0.03928 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        };
        0.2126 * f((v >> 16) & 255) + 0.7152 * f((v >> 8) & 255) + 0.0722 * f(v & 255)
    }
    let (x, y) = (lum(a), lum(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

#[cfg(test)]
mod tests {
    use super::*;

    // parity: SHELL-TOKENS Port of AppearanceContrastTests: text keeps 4.5:1 on every page fill.
    #[test]
    fn text_keeps_contrast_on_every_page_fill() {
        for m in [Mode::Light, Mode::Dark] {
            let x = Hex::new(m);
            for fill in [x.canvas, x.surface, x.card, x.tint, x.button] {
                for text in [x.warning, x.muted, x.ink] {
                    assert!(contrast(text, fill) >= 4.5, "{m:?} {text:x} on {fill:x}");
                }
            }
            assert!(contrast(x.on_data_strong, x.data_strong) >= 4.5);
            assert!(contrast(x.on_data, x.data_scale[1]) >= 4.5);
            assert!(contrast(x.on_data_quiet, x.data_quiet) >= 4.5);
        }
    }
}
