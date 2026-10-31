use gpui_kit::App;
use std::borrow::Cow;

/// Static instances: GPUI ignores the variable fonts' weight axis (Phase 0).
pub fn register(cx: &mut App) {
    let all: [&'static [u8]; 7] = [
        include_bytes!("../assets/fonts/Figtree-Light.ttf"),
        include_bytes!("../assets/fonts/Figtree-Regular.ttf"),
        include_bytes!("../assets/fonts/Figtree-Medium.ttf"),
        include_bytes!("../assets/fonts/Figtree-SemiBold.ttf"),
        include_bytes!("../assets/fonts/Figtree-Bold.ttf"),
        include_bytes!("../assets/fonts/EBGaramond-Regular.ttf"),
        include_bytes!("../assets/fonts/EBGaramond-It.ttf"),
    ];
    cx.text_system().add_fonts(all.iter().map(|b| Cow::Borrowed(*b)).collect()).expect("bundled fonts load");
}
