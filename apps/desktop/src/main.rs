use flow_ui::prelude::*;
use localflow::{core::Core, shell::Shell};

fn main() {
    flow_ui::application().run(|cx| {
        let services = flow_platform::native();
        let dark = matches!(cx.window_appearance(), WindowAppearance::Dark | WindowAppearance::VibrantDark);
        let core = Core::load(services);
        let appearance = core.prefs.string("appearance");
        let is_dark = match appearance.as_deref() {
            Some("dark") => true,
            Some("light") => false,
            _ => dark,
        };
        let (contrast, motion) = (core.services.high_contrast(), core.services.reduce_motion());
        flow_ui::init(Mode::new(is_dark, contrast), motion, cx);
        cx.set_global(core);
        // The audit opens a window that takes no focus and stays out of the tiling layout.
        let audit = std::env::var_os("LOCALFLOW_AUDIT_WINDOW").is_some();
        let bounds = Bounds { origin: point(px(30.), px(60.)), size: size(px(1180.), px(780.)) };
        let options = if audit {
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), titlebar: None, focus: false, kind: WindowKind::PopUp, is_movable: false, ..Default::default() }
        } else {
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..Default::default() }
        };
        flow_ui::open_window(options, cx, |w, cx| cx.new(|cx| Shell::new(w, cx))).expect("main window opens");
        if !audit {
            cx.activate(true);
        }
    });
}
