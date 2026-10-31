//! SF Symbols can't ship on Windows, so both platforms use bundled SVGs (plan, "Keeping the look"):
//! Lucide where its shape is the same, our own `sf-*` drawings where Lucide's differs visibly. Those
//! are drawn for this project to follow the SF shape and metrics, not derived from Apple's files.
//! Page code asks by SF Symbol name so it reads like the Swift it ports.
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
        "chart.bar" => "sf-chart-bar",
        "chart.bar.xaxis" => "chart-bar-xaxis",
        "checkmark" => "check",
        "checkmark.circle" => "circle-check",
        "checkmark.circle.fill" => "circle-check-big",
        "checkmark.shield" => "shield-check",
        "chevron.down" => "chevron-down",
        "chevron.left" => "chevron-left",
        "chevron.right" => "chevron-right",
        "chevron.up" => "chevron-up",
        "chevron.up.chevron.down" => "chevrons-native",
        "circle.fill" | "circle" => "circle",
        "clock" => "clock",
        "command" => "command",
        "desktopcomputer" => "monitor",
        "doc.on.clipboard" => "sf-doc-on-clipboard",
        "doc.on.doc" => "copy",
        "doc.text" => "file-text",
        "ellipsis" => "ellipsis",
        "exclamationmark.circle" => "sf-exclamation-circle",
        "exclamationmark.triangle" | "exclamationmark.triangle.fill" => "sf-exclamation-triangle",
        "externaldrive.badge.exclamationmark" => "sf-externaldrive-badge",
        "gearshape" => "sf-gear",
        "globe" => "globe",
        "info.circle" => "info",
        "iphone" => "smartphone",
        "keyboard" => "keyboard",
        "lightbulb" => "lightbulb",
        "lock.shield" => "shield",
        "magnifyingglass" => "search",
        "mic" | "mic.fill" => "sf-mic",
        "mic.slash" => "sf-mic-slash",
        "pause.circle" => "circle-pause",
        "pause.circle.fill" => "sf-pause-circle-fill",
        "pause.fill" => "sf-pause-fill",
        "person.2" => "sf-person-2",
        "person.2.wave.2" => "users",
        "person.badge.plus" => "user-plus",
        "play.circle" => "circle-play",
        "play.fill" => "play",
        "plus" => "plus",
        "record.circle" => "sf-record-circle",
        "record.circle.fill" => "sf-record-circle-fill",
        "server.rack" => "server",
        "sidebar.right" => "panel-right",
        "sparkles" => "sparkles",
        "speaker.wave.2" | "speaker.wave.2.fill" => "volume-2",
        "square.on.square" | "square.stack" | "square.stack.3d.up" => "layers",
        "stop.fill" => "square",
        "text.badge.checkmark" => "sf-text-badge-check",
        "text.badge.xmark" => "sf-text-badge-x",
        "text.book.closed" => "sf-book",
        "text.insert" => "text-cursor-input",
        "text.quote" => "sf-text-quote",
        "trash" => "trash",
        "waveform" => "sf-waveform",
        "xmark" => "x",
        other => panic!("no icon mapped for SF Symbol {other}"),
    }
}

/// A symbol drawn at `size` points in `color`, hidden from accessibility as SF Symbols with a
/// neighboring label are.
pub fn icon(symbol: &str, size: f32, color: impl Into<Hsla>) -> Svg {
    let path: SharedString = format!("flow-icons/{}.svg", lucide(symbol)).into();
    // An SF glyph overhangs its point size: its 24 unit box is 1.25 em, centered on the layout box.
    let overhang = if lucide(symbol).starts_with("sf-") { size * 0.125 } else { 0. };
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
    "sf-record-circle", "sf-record-circle-fill", "sf-chart-bar", "sf-mic", "sf-mic-slash", "sf-book", "sf-gear", "sf-waveform",
    "sf-pause-fill", "sf-pause-circle-fill", "sf-exclamation-circle", "sf-exclamation-triangle", "sf-externaldrive-badge",
    "sf-text-badge-check", "sf-text-badge-x", "sf-doc-on-clipboard", "sf-person-2", "sf-text-quote",
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

