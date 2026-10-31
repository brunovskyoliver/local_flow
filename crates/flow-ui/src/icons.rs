//! SF Symbols can't ship on Windows, so both platforms use bundled SVGs (plan, "Keeping the look"):
//! Lucide where its shape was compared with the symbol and is close, though usually drawn a little
//! smaller; our own `sf-*` drawings elsewhere (`sfw-*` for wide glyphs). Ours are hand-drawn from
//! primitives by comparing with the rendered symbol, not derived from Apple's glyph data.
//! Page code asks by SF Symbol name so it reads like the Swift it ports.
use gpui_kit::{AssetSource, Hsla, Result, SharedString, Styled, Svg, px, svg};
use std::borrow::Cow;

/// SF Symbol name to bundled SVG file.
pub fn lucide(symbol: &str) -> &'static str {
    match symbol {
        "arrow.right" => "arrow-right",
        "infinity" => "sf-infinity",
        "bubble.left" => "sf-bubble-left",
        "envelope" => "sf-envelope",
        "text.bubble" => "sf-text-bubble",
        "cpu" => "cpu",
        "key" => "sf-key",
        "laptopcomputer" => "sfw-laptop",
        "largecircle.fill.circle" => "sf-largecircle-fill-circle",
        "link" => "link",
        "arrow.clockwise" => "sf-arrow-clockwise",
        "arrow.up.right.square" => "sf-arrow-up-right-square",
        "bolt.horizontal" => "sfw-bolt-horizontal",
        "chart.bar" => "sf-chart-bar",
        "chart.bar.xaxis" => "chart-bar-xaxis",
        "checkmark" => "sf-check",
        "checkmark.circle" => "sf-checkmark-circle",
        "checkmark.circle.fill" => "sf-checkmark-circle-fill",
        "checkmark.shield" => "sf-checkmark-shield",
        "chevron.down" => "chevron-down",
        "chevron.left" => "chevron-left",
        "chevron.right" => "chevron-right",
        "chevron.up" => "chevron-up",
        "chevron.up.chevron.down" => "chevrons-native",
        "circle.fill" => "sf-circle-fill",
        "circle" => "circle",
        "clock" => "sf-clock",
        "command" => "command",
        "desktopcomputer" => "sf-desktop",
        "doc.on.clipboard" => "sf-doc-on-clipboard",
        "doc.on.doc" => "sf-doc-on-doc",
        "doc.text" => "file-text",
        "ellipsis" => "ellipsis",
        "exclamationmark.circle" => "sf-exclamation-circle",
        "exclamationmark.triangle" => "sf-exclamation-triangle",
        "exclamationmark.triangle.fill" => "sf-exclamation-triangle-fill",
        "externaldrive.badge.exclamationmark" => "sfw-externaldrive-badge",
        "gearshape" => "sf-gear",
        "globe" => "sf-globe",
        "info.circle" => "sf-info-circle",
        "iphone" => "sf-iphone",
        "keyboard" => "sf-keyboard",
        "lightbulb" => "sf-lightbulb",
        "lock.shield" => "sf-lock-shield",
        "magnifyingglass" => "search",
        "mic" => "sf-mic",
        "mic.fill" => "sf-mic-fill",
        "mic.slash" => "sf-mic-slash",
        "pause.circle" => "circle-pause",
        "pause.circle.fill" => "sf-pause-circle-fill",
        "pause.fill" => "sf-pause-fill",
        "person.2" => "sfw-person-2",
        "person.2.wave.2" => "sfw-person-2-wave-2",
        "person.badge.plus" => "sf-person-badge-plus",
        "play.circle" => "sf-play-circle",
        "play.fill" => "sf-play-fill",
        "plus" => "plus",
        "record.circle" => "sf-record-circle",
        "record.circle.fill" => "sf-record-circle-fill",
        "server.rack" => "sf-server-rack",
        "sidebar.right" => "sf-sidebar-right",
        "sparkles" => "sf-sparkles",
        "speaker.wave.2" => "volume-2",
        "speaker.wave.2.fill" => "sf-speaker-wave-2-fill",
        "square.on.square" => "sf-square-on-square",
        "square.stack" => "sf-square-stack",
        "square.stack.3d.up" => "layers",
        "stop.fill" => "sf-stop-fill",
        "text.badge.checkmark" => "sf-text-badge-check",
        "text.badge.xmark" => "sf-text-badge-x",
        "text.book.closed" => "sf-book",
        "text.insert" => "sf-text-insert",
        "text.quote" => "sf-text-quote",
        "trash" => "sf-trash",
        "waveform" => "sf-waveform",
        "xmark" => "x",
        other => panic!("no icon mapped for SF Symbol {other}"),
    }
}

/// A symbol drawn at `size` points in `color`, hidden from accessibility as SF Symbols with a
/// neighboring label are.
pub fn icon(symbol: &str, size: f32, color: impl Into<Hsla>) -> Svg {
    let path: SharedString = format!("flow-icons/{}.svg", lucide(symbol)).into();
    // An SF glyph overhangs its point size: `sf-` boxes are 1.18 em (fitted on the contact sheet in `audit/icons`), `sfw-` 1.888 em at the same unit scale.
    let file = lucide(symbol);
    let overhang = if file.starts_with("sfw-") { size * 0.444 } else if file.starts_with("sf-") { size * 0.09 } else { 0. };
    svg().path(path).size(px(size + 2. * overhang)).m(px(-overhang)).flex_none().text_color(color.into())
}

/// Bundled icons in front of Kit's own assets.
pub struct FlowAssets;

macro_rules! embed { ($($name:literal),* $(,)?) => {
    const ICONS: &[(&str, &[u8])] = &[$(($name, include_bytes!(concat!("../assets/icons/", $name, ".svg")))),*];
}}
embed!(
    "infinity", "mail", "message-circle", "message-square-text",
    "cpu", "key", "laptop", "link",
    "arrow-right", "rotate-cw", "square-arrow-out-up-right", "ellipsis", "chart-no-axes-column", "chart-column", "check",
    "circle-check", "circle-check-big", "shield-check", "chevron-down", "chevron-left", "chevron-right", "chevron-up",
    "circle", "clock", "command", "monitor", "clipboard", "copy", "file-text", "circle-alert", "triangle-alert",
    "hard-drive", "settings", "globe", "info", "smartphone", "keyboard", "lightbulb", "shield", "search", "mic", "mic-off",
    "circle-pause", "pause", "users", "user-plus", "circle-play", "play", "plus", "circle-dot", "server", "panel-right",
    "sparkles", "volume-2", "layers", "square", "list-checks", "file-x", "book-text", "text-cursor-input", "quote", "trash",
    "audio-waveform", "x", "chart-bar-xaxis", "chevrons-native",
    "sf-arrow-clockwise", "sf-arrow-up-right-square", "sf-book", "sf-bubble-left", "sf-chart-bar",
    "sf-check", "sf-checkmark-circle", "sf-checkmark-circle-fill", "sf-checkmark-shield", "sf-circle-fill",
    "sf-clock", "sf-desktop", "sf-doc-on-clipboard", "sf-doc-on-doc", "sf-envelope",
    "sf-exclamation-circle", "sf-exclamation-triangle", "sf-exclamation-triangle-fill", "sf-externaldrive-badge", "sf-gear",
    "sf-globe", "sf-infinity", "sf-info-circle", "sf-iphone", "sf-key",
    "sf-keyboard", "sf-largecircle-fill-circle", "sf-lightbulb", "sf-lock-shield", "sf-mic",
    "sf-mic-fill", "sf-mic-slash", "sf-pause-circle-fill", "sf-pause-fill", "sf-person-2",
    "sf-person-badge-plus", "sf-play-circle", "sf-play-fill", "sf-record-circle", "sf-record-circle-fill",
    "sf-server-rack", "sf-sidebar-right", "sf-sparkles", "sf-speaker-wave-2-fill", "sf-square-on-square",
    "sf-square-stack", "sf-stop-fill", "sf-text-badge-check", "sf-text-badge-x", "sf-text-bubble",
    "sf-text-insert", "sf-text-quote", "sf-trash", "sf-waveform", "sfw-bolt-horizontal",
    "sfw-externaldrive-badge", "sfw-laptop", "sfw-person-2", "sfw-person-2-wave-2",
);

impl AssetSource for FlowAssets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if let Some(name) = path.strip_prefix("flow-icons/").and_then(|p| p.strip_suffix(".svg")) {
            return Ok(ICONS.iter().find(|(n, _)| *n == name).map(|(_, b)| Cow::Borrowed(*b)));
        }
        gpui_kit::assets::Assets::new("").load(path)
    }
    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        gpui_kit::assets::Assets::new("").list(path)
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    fn svg_of(symbol: &str) -> &'static str {
        let name = lucide(symbol);
        std::str::from_utf8(ICONS.iter().find(|(n, _)| *n == name).unwrap_or_else(|| panic!("{name} not embedded")).1).unwrap()
    }

    /// Every symbol Swift names has a bundled file, so `icon` can't panic or draw nothing.
    #[::core::prelude::v1::test]
    fn every_swift_symbol_maps_to_a_bundled_file() {
        let mut seen = 0;
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/macos/LocalFlow");
        let mut dirs = vec![std::path::PathBuf::from(root)];
        while let Some(dir) = dirs.pop() {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    dirs.push(path);
                } else if path.extension().is_some_and(|e| e == "swift") {
                    let source = std::fs::read_to_string(&path).unwrap();
                    for key in ["systemName: \"", "systemImage: \""] {
                        for part in source.split(key).skip(1) {
                            svg_of(part.split('"').next().unwrap());
                            seen += 1;
                        }
                    }
                }
            }
        }
        assert!(seen > 50, "only found {seen} symbol uses");
    }

    /// A `.fill` symbol must draw solid and must not share the outline's file.
    #[::core::prelude::v1::test]
    fn filled_symbols_are_solid() {
        for symbol in ["checkmark.circle.fill", "circle.fill", "exclamationmark.triangle.fill", "mic.fill", "pause.circle.fill", "pause.fill", "play.fill", "record.circle.fill", "speaker.wave.2.fill", "stop.fill"] {
            assert!(svg_of(symbol).contains(r#"fill="currentColor""#), "{symbol} has no solid fill");
            let outline = symbol.strip_suffix(".fill").unwrap();
            if !matches!(outline, "stop" | "play" | "pause") {
                assert_ne!(lucide(symbol), lucide(outline), "{symbol} shares a file with its outline");
            }
        }
    }

    /// The symbols the audit named keep a distinct in-house drawing.
    #[::core::prelude::v1::test]
    fn drawn_symbols_use_their_own_shape() {
        for symbol in ["bolt.horizontal", "server.rack", "laptopcomputer", "envelope", "bubble.left", "text.bubble", "infinity", "desktopcomputer", "person.2", "exclamationmark.triangle"] {
            assert!(lucide(symbol).starts_with("sf"), "{symbol} uses {}", lucide(symbol));
        }
        assert_ne!(lucide("bolt.horizontal"), lucide("ellipsis"));
    }
}
