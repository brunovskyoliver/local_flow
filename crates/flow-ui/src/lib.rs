//! All visual decisions and the only crate allowed to name GPUI Kit's component layer
//! (`scripts/check-rust-boundaries.sh`).
pub mod components;
pub mod controls;
pub mod fonts;
pub mod icons;
pub mod kit_theme;
pub mod probe;
pub mod tokens;
pub mod txt;

/// GPUI itself, for layout and windows.
pub mod gpui {
    pub use gpui_kit::*;
}

pub mod prelude {
    // gpui_kit's glob exports a `test` macro that would shadow the built-in one `#[gpui::test]` expands to.
    pub use std::prelude::v1::test;
    pub use crate::components::*;
    pub use crate::controls::*;
    pub use crate::icons::{disclosure_chevron, icon};
    pub use crate::tokens::{Flow, Mode, Palette, pal};
    pub use crate::txt::{Align, FIGTREE, GARAMOND, Span, Txt, rich, span, t};
    pub use gpui_kit::prelude::*;
    pub use gpui_kit::*;
}

#[cfg(feature = "test-support")]
pub mod test {
    pub use gpui_kit::TestAppContext;
    pub use gpui_kit::test::*;
}

/// Swift's `FlowFonts.register()`, first in the app's `init`.
pub fn register_fonts(cx: &mut gpui_kit::App) {
    fonts::register(cx);
}

/// Boots GPUI Kit and the theme after `register_fonts`. Call once inside `Application::run`.
pub fn init(mode: tokens::Mode, reduce_motion: bool, cx: &mut gpui_kit::App) {
    gpui_kit::init(cx);
    cx.set_global(tokens::Flow { palette: tokens::Palette::new(mode), reduce_motion, compact: false });
    kit_theme::apply(cx);
    cx.set_reduce_motion(reduce_motion);
}

/// The same setup for a headless test.
#[cfg(feature = "test-support")]
pub fn init_test(mode: tokens::Mode, cx: &mut gpui_kit::App) {
    init(mode, false, cx);
}

pub fn application() -> gpui_kit::Application {
    gpui_kit::application().with_assets(icons::FlowAssets)
}

/// A window without Kit's `Root`, whose theme fill would hide a transparent background.
pub fn open_bare_window<V: gpui_kit::Render>(
    options: gpui_kit::WindowOptions,
    cx: &mut gpui_kit::App,
    build: impl FnOnce(&mut gpui_kit::Window, &mut gpui_kit::App) -> gpui_kit::Entity<V>,
) -> gpui_kit::Result<(gpui_kit::AnyWindowHandle, gpui_kit::Entity<V>)> {
    let window = cx.open_window(options, |window, cx| build(window, cx))?;
    let view = window.update(cx, |_, _, cx| cx.entity())?;
    Ok((window.into(), view))
}

pub fn open_window<V: gpui_kit::Render>(
    options: gpui_kit::WindowOptions,
    cx: &mut gpui_kit::App,
    build: impl FnOnce(&mut gpui_kit::Window, &mut gpui_kit::App) -> gpui_kit::Entity<V>,
) -> gpui_kit::Result<(gpui_kit::AnyWindowHandle, gpui_kit::Entity<V>)> {
    gpui_kit::open_window(options, cx, build)
}
