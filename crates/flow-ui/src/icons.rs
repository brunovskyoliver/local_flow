//! SF Symbols can't ship on Windows, so both platforms use bundled Lucide SVGs (plan, "Keeping
//! the look"). Page code asks by SF Symbol name so it reads like the Swift it ports.
use gpui_kit::{AssetSource, Hsla, Result, SharedString, Styled, Svg, px, svg};
use std::borrow::Cow;

/// SF Symbol name to Lucide file. `filled` marks a symbol Swift draws solid.
pub fn lucide(symbol: &str) -> &'static str {
    match symbol {
        "arrow.right" => "arrow-right",
        "infinity" => "infinity",
        "bubble.left" => "message-circle",
        "envelope" => "mail",
        "text.bubble" => "message-square-text",
        "cpu" => "cpu",
        "key" => "key",
        "laptopcomputer" => "laptop",
        "largecircle.fill.circle" => "circle-dot",
        "link" => "link",
        "arrow.clockwise" => "rotate-cw",
        "arrow.up.right.square" => "square-arrow-out-up-right",
        "bolt.horizontal" => "ellipsis",
        "chart.bar" => "chart-no-axes-column",
        "chart.bar.xaxis" => "chart-bar-xaxis",
        "checkmark" => "check",
        "checkmark.circle" => "circle-check",
        "checkmark.circle.fill" => "circle-check-big",
        "checkmark.shield" => "shield-check",
        "chevron.down" => "chevron-down",
        "chevron.left" => "chevron-left",
        "chevron.right" => "chevron-right",
        "chevron.up" => "chevron-up",
        "circle.fill" | "circle" => "circle",
        "clock" => "clock",
        "command" => "command",
        "desktopcomputer" => "monitor",
        "doc.on.clipboard" => "clipboard",
        "doc.on.doc" => "copy",
        "doc.text" => "file-text",
        "ellipsis" => "ellipsis",
        "exclamationmark.circle" => "circle-alert",
        "exclamationmark.triangle" | "exclamationmark.triangle.fill" => "triangle-alert",
        "externaldrive.badge.exclamationmark" => "hard-drive",
        "gearshape" => "settings",
        "globe" => "globe",
        "info.circle" => "info",
        "iphone" => "smartphone",
        "keyboard" => "keyboard",
        "lightbulb" => "lightbulb",
        "lock.shield" => "shield",
        "magnifyingglass" => "search",
        "mic" | "mic.fill" => "mic",
        "mic.slash" => "mic-off",
        "pause.circle" | "pause.circle.fill" => "circle-pause",
        "pause.fill" => "pause",
        "person.2" | "person.2.wave.2" => "users",
        "person.badge.plus" => "user-plus",
        "play.circle" => "circle-play",
        "play.fill" => "play",
        "plus" => "plus",
        "record.circle" | "record.circle.fill" => "circle-dot",
        "server.rack" => "server",
        "sidebar.right" => "panel-right",
        "sparkles" => "sparkles",
        "speaker.wave.2" | "speaker.wave.2.fill" => "volume-2",
        "square.on.square" | "square.stack" | "square.stack.3d.up" => "layers",
        "stop.fill" => "square",
        "text.badge.checkmark" => "list-checks",
        "text.badge.xmark" => "file-x",
        "text.book.closed" => "book-text",
        "text.insert" => "text-cursor-input",
        "text.quote" => "quote",
        "trash" => "trash",
        "waveform" => "audio-waveform",
        "xmark" => "x",
        other => panic!("no icon mapped for SF Symbol {other}"),
    }
}

/// A symbol drawn at `size` points in `color`, hidden from accessibility as SF Symbols with a
/// neighboring label are.
pub fn icon(symbol: &str, size: f32, color: impl Into<Hsla>) -> Svg {
    let path: SharedString = format!("flow-icons/{}.svg", lucide(symbol)).into();
    svg().path(path).size(px(size)).flex_none().text_color(color.into())
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
    "audio-waveform", "x", "chart-bar-xaxis",
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

