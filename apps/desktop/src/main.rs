use flow_ui::prelude::*;
use localflow::{core::Core, menu, pill, shell, tray};

fn main() {
    let app = flow_ui::application().with_quit_mode(QuitMode::Explicit);
    // Dock reopen with no window opens one; with a window, restores it.
    app.on_reopen(|cx| shell::open(None, cx));
    app.run(|cx| {
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
        menu::init(cx);
        cx.on_window_closed(|cx, id| shell::window_closed(id, cx)).detach();
        cx.observe_global::<shell::Session>(|cx| pill::sync_window(cx)).detach();
        pill::apply_scenario(cx);
        pill::sync_window(cx);
        let audit = std::env::var_os("LOCALFLOW_AUDIT_WINDOW").is_some();
        if audit {
            shell::open_main_window(cx);
            // The audit's status item would flicker in the owner's menu bar on every capture.
            if std::env::var_os("LOCALFLOW_TRAY").is_some() {
                tray::install(cx);
            }
        } else {
            // `LSUIElement`: no Dock icon at launch. Swift's window stays closed until asked for (SHELL-006).
            cx.set_activation_policy(ActivationPolicy::Accessory);
            tray::install(cx);
        }
    });
}
