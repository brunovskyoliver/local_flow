//! The only text element page code uses. GPUI has no letter spacing, can't wrap mixed styles
//! across flex children, and plain strings are invisible to accessibility. `Txt` shapes with
//! the text system, adds tracking per glyph, wraps at word boundaries and paints glyphs itself,
//! and always reports a Label node with its value.
use gpui_kit::{
    App, AvailableSpace, Bounds, Element, ElementId, Font, FontStyle, FontWeight, GlobalElementId,
    Hsla, InspectorElementId, IntoElement, LayoutId, MouseUpEvent, Pixels, Point, SharedString, Size, Style,
    TextRun, Window, accesskit, point, px, size,
};
use std::cell::RefCell;
use std::hash::{Hash, Hasher};
use std::rc::Rc;
use std::panic::Location;

pub const FIGTREE: &str = "Figtree";
pub const GARAMOND: &str = "EB Garamond";
#[cfg(target_os = "windows")]
pub const MONO: &str = "Consolas";
#[cfg(not(target_os = "windows"))]
pub const MONO: &str = "Menlo";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Align {
    Left,
    Center,
    Right,
}

/// A span in rich text; unset fields come from the `Txt`.
#[derive(Clone)]
pub struct Span {
    pub text: SharedString,
    pub italic: bool,
    pub serif: Option<bool>,
    pub weight: Option<f32>,
    pub color: Option<Hsla>,
    pub underline: bool,
    pub strike: bool,
    /// The key `Txt::on_link` receives when this span is clicked.
    pub link: Option<SharedString>,
}

pub fn span(text: impl Into<SharedString>) -> Span {
    Span { text: text.into(), italic: false, serif: None, weight: None, color: None, underline: false, strike: false, link: None }
}

impl Span {
    pub fn italic(mut self) -> Self {
        self.italic = true;
        self
    }
    pub fn serif(mut self, on: bool) -> Self {
        self.serif = Some(on);
        self
    }
    pub fn weight(mut self, w: f32) -> Self {
        self.weight = Some(w);
        self
    }
    pub fn color(mut self, c: impl Into<Hsla>) -> Self {
        self.color = Some(c.into());
        self
    }
    pub fn underline(mut self) -> Self {
        self.underline = true;
        self
    }
    pub fn strike(mut self) -> Self {
        self.strike = true;
        self
    }
    /// An inline link. Takes effect when the `Txt` has `on_link`.
    pub fn link(mut self, key: impl Into<SharedString>) -> Self {
        self.link = Some(key.into());
        self
    }
}

type LinkHandler = std::rc::Rc<dyn Fn(&SharedString, &mut Window, &mut App)>;

pub struct Txt {
    id: ElementId,
    location: &'static Location<'static>,
    spans: Vec<Span>,
    size: Option<f32>,
    weight: Option<f32>,
    serif: bool,
    italic: bool,
    tracking: f32,
    line_spacing: f32,
    color: Option<Hsla>,
    align: Align,
    lines: Option<usize>,
    accessible: bool,
    opacity: f32,
    mono_digits: bool,
    mono: bool,
    no_widow: bool,
    swift_lines: bool,
    selectable: bool,
    selection_hitbox: Option<gpui_kit::Hitbox>,
    on_link: Option<LinkHandler>,
}

thread_local! {
    /// How many times each call site and text pair was built this frame, and whether a paint has
    /// passed since, which means the next `t` starts a new frame.
    static BUILT: std::cell::RefCell<(bool, std::collections::HashMap<u64, u64>)> = std::cell::RefCell::default();
}

/// Rows repeat the same text at the same call site ("Unused"), and an equal id drops the node from
/// the accessibility tree. The nth repeat in a frame gets its own id; the same order keeps it stable.
fn occurrence_id(hash: u64) -> u64 {
    BUILT.with_borrow_mut(|(painted, seen)| {
        if std::mem::take(painted) {
            seen.clear();
        }
        let n = seen.entry(hash).or_insert(0);
        *n += 1;
        hash.wrapping_add(*n - 1)
    })
}

/// Text at the inherited size and color. Id comes from the call site and the text.
#[track_caller]
pub fn t(text: impl Into<SharedString>) -> Txt {
    rich(vec![span(text)])
}

/// Mixed-style text that wraps as a single paragraph.
#[track_caller]
pub fn rich(spans: Vec<Span>) -> Txt {
    let location = Location::caller();
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    (location.file(), location.line(), location.column()).hash(&mut hash);
    for s in &spans {
        s.text.hash(&mut hash);
    }
    Txt {
        id: ElementId::Integer(occurrence_id(hash.finish())),
        location,
        spans,
        size: None,
        weight: None,
        serif: false,
        italic: false,
        tracking: 0.0,
        line_spacing: 0.0,
        color: None,
        align: Align::Left,
        lines: None,
        accessible: true,
        opacity: 1.0,
        mono_digits: false,
        mono: false,
        no_widow: false,
        swift_lines: false,
        selectable: false,
        selection_hitbox: None,
        on_link: None,
    }
}

impl Txt {
    /// `.font(.flow(size:weight:))`
    pub fn font(mut self, size: f32, weight: f32) -> Self {
        self.size = Some(size);
        self.weight = Some(weight);
        self
    }
    pub fn size(mut self, size: f32) -> Self {
        self.size = Some(size);
        self
    }
    pub fn weight(mut self, w: f32) -> Self {
        self.weight = Some(w);
        self
    }
    pub fn medium(self) -> Self {
        self.weight(500.0)
    }
    pub fn semibold(self) -> Self {
        self.weight(600.0)
    }
    pub fn bold(self) -> Self {
        self.weight(700.0)
    }
    pub fn serif(mut self) -> Self {
        self.serif = true;
        self
    }
    pub fn italic(mut self) -> Self {
        self.italic = true;
        self
    }
    pub fn tracking(mut self, t: f32) -> Self {
        self.tracking = t;
        self
    }
    /// SwiftUI `.lineSpacing`: extra points between lines.
    pub fn line_spacing(mut self, s: f32) -> Self {
        self.line_spacing = s;
        self
    }
    pub fn color(mut self, c: impl Into<Hsla>) -> Self {
        self.color = Some(c.into());
        self
    }
    pub fn center(mut self) -> Self {
        self.align = Align::Center;
        self
    }
    pub fn right(mut self) -> Self {
        self.align = Align::Right;
        self
    }
    /// `.lineLimit(n)`: truncates the last line with an ellipsis.
    pub fn lines(mut self, n: usize) -> Self {
        self.lines = Some(n);
        self
    }
    /// `.accessibilityHidden(true)`: for text whose meaning a parent's label already carries.
    pub fn a11y_hidden(mut self) -> Self {
        self.accessible = false;
        self
    }
    /// A stable id when text changes but the element is logically the same, such as a counter.
    pub fn id(mut self, id: impl Into<ElementId>) -> Self {
        self.id = id.into();
        self
    }
    pub fn opacity(mut self, o: f32) -> Self {
        self.opacity = o;
        self
    }
    /// `.monospacedDigit()`: Figtree's `tnum` feature.
    pub fn mono_digits(mut self) -> Self {
        self.mono_digits = true;
        self
    }
    /// `.system(design: .monospaced)`.
    pub fn mono(mut self) -> Self {
        self.mono = true;
        self
    }
    /// Called with a `Span::link` key when that span is clicked.
    pub fn on_link(mut self, f: impl Fn(&SharedString, &mut Window, &mut App) + 'static) -> Self {
        self.on_link = Some(std::rc::Rc::new(f));
        self
    }
    /// AppKit's standard line break strategy, which SwiftUI text gets: a single word never sits
    /// alone on the last line; the word before it moves down too.
    /// Whole-point line height, as SwiftUI lays out this font at 11 to 13: 11 is 13, 12 is 14, 13 is 15.
    /// The default rounds the text's height up, which adds about 1pt per line.
    pub fn swift_lines(mut self) -> Self {
        self.swift_lines = true;
        self
    }
    pub fn no_widow(mut self) -> Self {
        self.no_widow = true;
        self
    }
    /// `.textSelection(.enabled)`: drag to select, double click for a word, triple for the text,
    /// Cmd-C to copy. Stays a Label to accessibility.
    pub fn selectable(mut self) -> Self {
        self.selectable = true;
        self
    }
    pub fn text(&self) -> String {
        self.spans.iter().map(|s| s.text.as_ref()).collect()
    }
}

struct Glyph {
    font: gpui_kit::FontId,
    id: gpui_kit::GlyphId,
    x: f32,
    emoji: bool,
    color: Hsla,
    /// Where this glyph starts in the text.
    byte: usize,
}

struct Mark {
    from: f32,
    to: f32,
    color: Hsla,
    strike: bool,
}

#[derive(Default)]
struct Line {
    glyphs: Vec<Glyph>,
    marks: Vec<Mark>,
    links: Vec<(f32, f32, SharedString)>,
    width: f32,
    /// The byte after this line's last glyph.
    end: usize,
}

/// Selected bytes: `anchor` where the drag began, `head` where it is now.
#[derive(Default)]
struct Selection {
    anchor: usize,
    head: usize,
    dragging: bool,
    /// Key events only reach elements on the focus path, so a selected text takes focus to hear Cmd-C.
    focus: Option<gpui_kit::FocusHandle>,
}

impl Selection {
    fn range(&self) -> (usize, usize) {
        (self.anchor.min(self.head), self.anchor.max(self.head))
    }
}

#[derive(Clone)]
pub struct Resolved {
    size: f32,
    tracking: f32,
    spacing: f32,
    align: Align,
    lines: Option<usize>,
    no_widow: bool,
    swift_lines: bool,
    text: String,
    runs: Vec<TextRun>,
    marks: Vec<(usize, usize, bool)>,
    links: Vec<(usize, usize, SharedString)>,
    color: Hsla,
    ellipsis_font: Font,
}

struct Laid {
    lines: Vec<Line>,
    line_height: f32,
    ascent: f32,
    descent: f32,
    gap: f32,
}

impl Laid {
    fn height(&self) -> f32 {
        let n = self.lines.len().max(1) as f32;
        n * self.line_height + (n - 1.0) * self.gap
    }
    fn width(&self) -> f32 {
        self.lines.iter().map(|l| l.width).fold(0.0, f32::max)
    }
}

/// Greedy word wrap of already-shaped glyphs. Pure so the tests can drive it.
pub(crate) fn wrap_points(xs: &[(f32, bool)], end: f32, max: f32) -> Vec<usize> {
    let mut breaks = vec![];
    let mut start_x = 0.0;
    let mut last_space: Option<usize> = None;
    let mut i = 0;
    while i < xs.len() {
        let next = xs.get(i + 1).map(|g| g.0).unwrap_or(end);
        if next - start_x > max && i > *breaks.last().unwrap_or(&0) && !xs[i].1 {
            let at = last_space.map(|s| s + 1).filter(|&s| s > *breaks.last().unwrap_or(&0)).unwrap_or(i);
            breaks.push(at);
            start_x = xs[at].0;
            last_space = None;
            i = at;
            continue;
        }
        if xs[i].1 {
            last_space = Some(i);
        }
        i += 1;
    }
    breaks
}

/// Moves the last line's start back one word when that line is a single word.
fn pull_down_widow(starts: &mut [usize], xs: &[(f32, bool)]) {
    let n = starts.len() - 1;
    let last = starts[n];
    let one_word = !xs[last..].iter().enumerate().any(|(i, g)| g.1 && xs[last + i + 1..].iter().any(|g| !g.1));
    if one_word && let Some(space) = xs[starts[n - 1]..last.saturating_sub(1)].iter().rposition(|g| g.1) {
        starts[n] = starts[n - 1] + space + 1;
    }
}

fn layout(r: &Resolved, max: Option<f32>, window: &mut Window) -> Laid {
    let sys = window.text_system().clone();
    let size_px = px(r.size);
    let mut laid = Laid { lines: vec![], line_height: 0.0, ascent: 0.0, descent: 0.0, gap: r.spacing };
    let mut offset = 0;
    for paragraph in r.text.split('\n') {
        let end = offset + paragraph.len();
        let mut runs = vec![];
        let mut pos = 0;
        for run in &r.runs {
            let (from, to) = (pos, pos + run.len);
            pos = to;
            let (a, b) = (from.max(offset), to.min(end));
            if a < b {
                runs.push(TextRun { len: b - a, ..run.clone() });
            }
        }
        if runs.is_empty() {
            runs.push(TextRun { len: 0, ..r.runs[0].clone() });
        }
        let shaped = sys.layout_line(paragraph, size_px, &runs, None);
        laid.ascent = laid.ascent.max(f32::from(shaped.ascent));
        laid.descent = laid.descent.max(f32::from(shaped.descent));
        let mut flat = vec![];
        for run in &shaped.runs {
            for g in &run.glyphs {
                let n = flat.len() as f32;
                flat.push((run.font_id, g.id, f32::from(g.position.x) + n * r.tracking, g.index, g.is_emoji));
            }
        }
        let total = f32::from(shaped.width) + flat.len() as f32 * r.tracking;
        let xs: Vec<(f32, bool)> =
            flat.iter().map(|g| (g.2, paragraph[g.3..].starts_with([' ', '\t']))).collect();
        let breaks = match max {
            Some(m) => wrap_points(&xs, total, m),
            None => vec![],
        };
        let mut starts = vec![0];
        starts.extend(breaks);
        if r.no_widow && starts.len() > 1 {
            pull_down_widow(&mut starts, &xs);
        }
        for (n, &from) in starts.iter().enumerate() {
            let to = starts.get(n + 1).copied().unwrap_or(flat.len());
            let base = flat.get(from).map(|g| g.2).unwrap_or(0.0);
            let mut line = Line::default();
            for g in &flat[from..to] {
                line.glyphs.push(Glyph { font: g.0, id: g.1, x: g.2 - base, emoji: g.4, color: color_at(r, offset + g.3), byte: offset + g.3 });
            }
            line.end = flat.get(to).map_or(end, |g| offset + g.3);
            let raw_end = flat.get(to).map(|g| g.2).unwrap_or(total);
            // Trailing spaces don't count toward the line's width, as in SwiftUI.
            let mut last = to;
            while last > from && xs[last - 1].1 {
                last -= 1;
            }
            line.width = if last == to { raw_end - base } else { flat[last].2 - base };
            for &(a, b, strike) in &r.marks {
                let inside: Vec<_> = flat[from..to].iter().filter(|g| offset + g.3 >= a && offset + g.3 < b).collect();
                if let (Some(f), Some(_)) = (inside.first(), inside.last()) {
                    let lastix = from + flat[from..to].iter().rposition(|g| offset + g.3 >= a && offset + g.3 < b).unwrap();
                    let e = flat.get(lastix + 1).map(|g| g.2).unwrap_or(total);
                    line.marks.push(Mark { from: f.2 - base, to: e - base, color: color_at(r, a), strike });
                }
            }
            for (a, b, key) in &r.links {
                let hit = |g: &&(gpui_kit::FontId, gpui_kit::GlyphId, f32, usize, bool)| offset + g.3 >= *a && offset + g.3 < *b;
                if let Some(f) = flat[from..to].iter().find(hit) {
                    let last = from + flat[from..to].iter().rposition(|g| hit(&g)).unwrap();
                    let e = flat.get(last + 1).map(|g| g.2).unwrap_or(total);
                    line.links.push((f.2 - base, e - base, key.clone()));
                }
            }
            laid.lines.push(line);
        }
        offset = end + 1;
    }
    laid.line_height = laid.ascent + laid.descent;
    if r.swift_lines {
        laid.line_height = laid.line_height.floor();
    }
    if laid.line_height == 0.0 {
        laid.line_height = r.size * 1.2;
    }
    if let Some(limit) = r.lines
        && (laid.lines.len() > limit || max.is_some_and(|m| laid.lines.get(limit.saturating_sub(1)).is_some_and(|l| l.width > m)))
    {
        let more = laid.lines.len() > limit;
        laid.lines.truncate(limit);
        let m = max.unwrap_or(f32::MAX);
        let dots = sys.layout_line(
            "…",
            size_px,
            &[TextRun { len: "…".len(), font: r.ellipsis_font.clone(), color: r.color, background_color: None, underline: None, strikethrough: None }],
            None,
        );
        let dot_w = f32::from(dots.width);
        if let Some(line) = laid.lines.last_mut() {
            if more || line.width > m {
                while let Some(g) = line.glyphs.last() {
                    if g.x + dot_w <= m && !line.glyphs.is_empty() && g.x > 0.0 {
                        break;
                    }
                    line.glyphs.pop();
                    if line.glyphs.is_empty() {
                        break;
                    }
                }
                let x = line.glyphs.last().map(|g| g.x).unwrap_or(0.0);
                if let Some(run) = dots.runs.first() {
                    if let Some(g) = run.glyphs.first() {
                        line.glyphs.pop();
                        line.glyphs.push(Glyph { font: run.font_id, id: g.id, x, emoji: false, color: r.color, byte: line.end });
                    }
                }
                line.width = x + dot_w;
            }
        }
    }
    laid
}

/// The caret position nearest a point relative to the text's origin, left aligned.
fn byte_at(l: &Laid, x: f32, y: f32) -> usize {
    let pitch = l.line_height + l.gap;
    let n = ((y / pitch).floor().max(0.) as usize).min(l.lines.len().saturating_sub(1));
    let Some(line) = l.lines.get(n) else { return 0 };
    for (i, g) in line.glyphs.iter().enumerate() {
        let next = line.glyphs.get(i + 1).map_or(line.width, |g| g.x);
        if x < (g.x + next) / 2. {
            return g.byte;
        }
    }
    line.end
}

/// The word around `at`, bounded by whitespace and punctuation.
fn word_at(text: &str, at: usize) -> (usize, usize) {
    let is_word = |c: char| c.is_alphanumeric() || c == '\'' || c == '’' || c == '_';
    let start = text[..at].char_indices().rev().take_while(|(_, c)| is_word(*c)).last().map_or(at, |(i, _)| i);
    let end = text[at..].char_indices().find(|(_, c)| !is_word(*c)).map_or(text.len(), |(i, _)| at + i);
    (start, end)
}

fn color_at(r: &Resolved, byte: usize) -> Hsla {
    let mut pos = 0;
    for run in &r.runs {
        pos += run.len;
        if byte < pos {
            return run.color;
        }
    }
    r.color
}

impl Txt {
    fn resolve(&self, window: &Window) -> Resolved {
        let style = window.text_style();
        let size = self.size.unwrap_or_else(|| f32::from(style.font_size.to_pixels(window.rem_size())));
        let mut color = self.color.unwrap_or(style.color);
        color.a *= self.opacity;
        let base_weight = self.weight.map(FontWeight).unwrap_or(FontWeight(style.font_weight.0));
        let inherited_serif = style.font_family.as_ref() == GARAMOND;
        let features = if self.mono_digits {
            gpui_kit::FontFeatures(std::sync::Arc::new(vec![("tnum".into(), 1)]))
        } else {
            style.font_features.clone()
        };
        let mut runs = vec![];
        let mut marks = vec![];
        let mut links = vec![];
        let mut text = String::new();
        let make = |serif: bool, weight: FontWeight, italic: bool| Font {
            family: if self.mono { MONO.into() } else if serif { GARAMOND.into() } else { FIGTREE.into() },
            features: features.clone(),
            fallbacks: style.font_fallbacks.clone(),
            weight,
            style: if italic { FontStyle::Italic } else { FontStyle::Normal },
        };
        for s in &self.spans {
            let serif = s.serif.unwrap_or(self.serif || inherited_serif);
            let weight = s.weight.map(FontWeight).unwrap_or(base_weight);
            let mut c = s.color.unwrap_or(color);
            if s.color.is_some() {
                c.a *= self.opacity;
            }
            if s.text.is_empty() {
                continue;
            }
            if let Some(key) = &s.link {
                links.push((text.len(), text.len() + s.text.len(), key.clone()));
            }
            if s.underline || s.strike {
                marks.push((text.len(), text.len() + s.text.len(), s.strike));
            }
            runs.push(TextRun {
                len: s.text.len(),
                font: make(serif, weight, s.italic || self.italic),
                color: c,
                background_color: None,
                underline: None,
                strikethrough: None,
            });
            text.push_str(&s.text);
        }
        if runs.is_empty() {
            runs.push(TextRun { len: 0, font: make(self.serif, base_weight, false), color, background_color: None, underline: None, strikethrough: None });
        }
        Resolved {
            size,
            tracking: self.tracking,
            spacing: self.line_spacing,
            align: self.align,
            lines: self.lines,
            no_widow: self.no_widow,
            swift_lines: self.swift_lines,
            text,
            ellipsis_font: runs[0].font.clone(),
            runs,
            marks,
            links,
            color,
        }
    }
}

impl IntoElement for Txt {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

impl Element for Txt {
    type RequestLayoutState = Resolved;
    type PrepaintState = Vec<(gpui_kit::Hitbox, SharedString)>;

    fn id(&self) -> Option<ElementId> {
        Some(self.id.clone())
    }
    fn source_location(&self) -> Option<&'static Location<'static>> {
        Some(self.location)
    }
    fn a11y_role(&self) -> Option<accesskit::Role> {
        self.accessible.then_some(accesskit::Role::Label)
    }
    fn write_a11y_info(&self, node: &mut accesskit::Node) {
        node.set_value(self.text());
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        _: &mut App,
    ) -> (LayoutId, Resolved) {
        let r = self.resolve(window);
        crate::probe::record(&r.text);
        let mut style = Style::default();
        if self.lines.is_some() {
            style.min_size.width = px(0.).into();
        }
        let measure = r.clone();
        let id = window.request_measured_layout(style, move |known: Size<Option<Pixels>>, avail: Size<AvailableSpace>, window, _| {
            let max = known.width.map(f32::from).or(match avail.width {
                AvailableSpace::Definite(w) => Some(f32::from(w)),
                AvailableSpace::MinContent => Some(0.0),
                AvailableSpace::MaxContent => None,
            });
            let l = layout(&measure, max.map(|m| m + 0.5), window);
            size(px(known.width.map(f32::from).unwrap_or(l.width().ceil())), px(l.height().ceil()))
        });
        (id, r)
    }

    fn prepaint(
        &mut self,
        id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        r: &mut Resolved,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        self.selection_hitbox = self.selectable.then(|| window.insert_hitbox(bounds, gpui_kit::HitboxBehavior::Normal));
        if let (true, Some(id)) = (self.selectable, id) {
            let focus = window.with_element_state(id, |s: Option<Rc<RefCell<Selection>>>, _| {
                let s = s.unwrap_or_default();
                let focus = s.borrow_mut().focus.get_or_insert_with(|| cx.focus_handle()).clone();
                (focus, s)
            });
            window.set_focus_handle(&focus, cx);
        }
        if self.on_link.is_none() || r.links.is_empty() {
            return vec![];
        }
        let w = f32::from(bounds.size.width);
        let l = layout(r, Some(w + 0.5), window);
        let mut y = f32::from(bounds.origin.y);
        let mut out = vec![];
        for line in &l.lines {
            let dx = match r.align {
                Align::Left => 0.0,
                Align::Center => (w - line.width) / 2.0,
                Align::Right => w - line.width,
            };
            for (a, b, key) in &line.links {
                let rect = Bounds::new(point(px(f32::from(bounds.origin.x) + dx + a), px(y)), size(px(b - a), px(l.line_height)));
                out.push((window.insert_hitbox(rect, gpui_kit::HitboxBehavior::Normal), key.clone()));
            }
            y += l.line_height + l.gap;
        }
        out
    }

    fn paint(
        &mut self,
        id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        r: &mut Resolved,
        links: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        BUILT.with_borrow_mut(|(painted, _)| *painted = true);
        if let Some(handler) = &self.on_link {
            for (hitbox, key) in links.drain(..) {
                window.set_cursor_style(gpui_kit::CursorStyle::PointingHand, &hitbox);
                let (handler, key) = (handler.clone(), key);
                window.on_mouse_event(move |e: &MouseUpEvent, phase, window, cx| {
                    if phase.bubble() && hitbox.bounds.contains(&e.position) {
                        handler(&key, window, cx);
                    }
                });
            }
        }
        let w = f32::from(bounds.size.width);
        let l = Rc::new(layout(r, Some(w + 0.5), window));
        if let (Some(hitbox), Some(id)) = (self.selection_hitbox.as_ref(), id) {
            paint_selection(id, hitbox, bounds, r, &l, window, cx);
        }
        let mut y = f32::from(bounds.origin.y);
        let x0 = f32::from(bounds.origin.x);
        for line in &l.lines {
            let dx = match r.align {
                Align::Left => 0.0,
                Align::Center => (w - line.width) / 2.0,
                Align::Right => w - line.width,
            };
            let baseline = y + l.ascent;
            for g in &line.glyphs {
                let origin: Point<Pixels> = point(px(x0 + dx + g.x), px(baseline));
                if g.emoji {
                    let _ = window.paint_emoji(origin, g.font, g.id, px(r.size));
                } else {
                    let _ = window.paint_glyph(origin, g.font, g.id, px(r.size), g.color);
                }
            }
            for m in &line.marks {
                let my = if m.strike { baseline - r.size * 0.3 } else { baseline + 1.5 };
                window.paint_quad(gpui_kit::fill(
                    Bounds::new(point(px(x0 + dx + m.from), px(my)), size(px(m.to - m.from), px(1.0))),
                    m.color,
                ));
            }
            y += l.line_height + l.gap;
        }
    }
}

/// The highlight, and the mouse and Cmd-C handling behind it. Registered each frame, as GPUI wants.
fn paint_selection(id: &GlobalElementId, hitbox: &gpui_kit::Hitbox, bounds: Bounds<Pixels>, r: &Resolved, l: &Rc<Laid>, window: &mut Window, cx: &mut App) {
    use gpui_kit::{CursorStyle, KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent};
    let state: Rc<RefCell<Selection>> = window.with_element_state(id, |s: Option<Rc<RefCell<Selection>>>, _| {
        let s = s.unwrap_or_default();
        (s.clone(), s)
    });
    window.set_cursor_style(CursorStyle::IBeam, hitbox);
    let (from, to) = state.borrow().range();
    if from < to {
        let color = crate::tokens::pal(cx).accent.opacity(0.3);
        let (x0, mut y) = (f32::from(bounds.origin.x), f32::from(bounds.origin.y));
        for line in &l.lines {
            let start = line.glyphs.iter().find(|g| g.byte >= from).filter(|g| g.byte < to).map(|g| g.x);
            if let Some(a) = start {
                let b = line.glyphs.iter().find(|g| g.byte >= to).map_or(line.width, |g| g.x);
                window.paint_quad(gpui_kit::fill(Bounds::new(point(px(x0 + a), px(y)), size(px(b - a), px(l.line_height))), color));
            }
            y += l.line_height + l.gap;
        }
    }
    let origin = bounds.origin;
    let text: Rc<str> = r.text.as_str().into();
    let at = {
        let lines = l.clone();
        move |p: Point<Pixels>| byte_at(&lines, f32::from(p.x - origin.x), f32::from(p.y - origin.y))
    };
    let hit = hitbox.clone();
    {
        let (state, text, at) = (state.clone(), text.clone(), at.clone());
        window.on_mouse_event(move |e: &MouseDownEvent, phase, window, cx| {
            if !phase.bubble() {
                return;
            }
            let mut s = state.borrow_mut();
            if hit.is_hovered(window) && e.button == MouseButton::Left {
                let b = at(e.position);
                (s.anchor, s.head) = match e.click_count {
                    1 => (b, b),
                    2 => word_at(&text, b),
                    _ => (0, text.len()),
                };
                s.dragging = e.click_count == 1;
                if let Some(f) = &s.focus {
                    f.focus(window, cx);
                    // Or the page's own focus handle takes it back as the event bubbles.
                    window.prevent_default();
                }
                window.refresh();
            } else if s.anchor != s.head {
                // Clicking elsewhere clears it, as an NSTextView losing the selection does.
                s.anchor = s.head;
                window.refresh();
            }
        });
    }
    {
        let state = state.clone();
        window.on_mouse_event(move |e: &MouseMoveEvent, phase, window, _| {
            let mut s = state.borrow_mut();
            if phase.bubble() && s.dragging {
                s.head = at(e.position);
                window.refresh();
            }
        });
    }
    {
        let state = state.clone();
        window.on_mouse_event(move |_: &MouseUpEvent, _, _, _| state.borrow_mut().dragging = false);
    }
    window.on_key_event(move |e: &KeyDownEvent, phase, _, cx| {
        let k = &e.keystroke;
        let (from, to) = state.borrow().range();
        if phase.bubble() && from < to && k.key == "c" && k.modifiers.platform {
            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(text[from..to].to_string()));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::{BUILT, occurrence_id, word_at, wrap_points};

    #[test]
    fn repeats_differ_within_a_frame_and_stay_stable_across_frames() {
        let frame = || (occurrence_id(7), occurrence_id(7), occurrence_id(9));
        let first = frame();
        assert_ne!(first.0, first.1);
        BUILT.with_borrow_mut(|(painted, _)| *painted = true);
        assert_eq!(frame(), first);
    }

    #[test]
    fn a_lone_last_word_takes_the_word_before_it() {
        // "aa bb cc" broken before "cc", then before "bb cc".
        let xs: Vec<(f32, bool)> = "aa bb cc".chars().enumerate().map(|(i, c)| (i as f32, c == ' ')).collect();
        let mut starts = vec![0, 6];
        super::pull_down_widow(&mut starts, &xs);
        assert_eq!(starts, vec![0, 3]);
        // Two words on the last line stay.
        let mut two = vec![0, 3];
        super::pull_down_widow(&mut two, &xs);
        assert_eq!(two, vec![0, 3]);
    }

    #[test]
    fn a_word_stops_at_spaces_and_punctuation() {
        assert_eq!(word_at("the north, wind", 5), (4, 9));
        assert_eq!(word_at("the north, wind", 9), (4, 9));
        assert_eq!(word_at("the north, wind", 3), (0, 3));
    }

    #[test]
    fn wraps_at_the_last_space_and_never_empties_a_line() {
        // "aa bb": each glyph 10 wide; space at index 2.
        let xs: Vec<(f32, bool)> = [false, false, true, false, false].iter().enumerate().map(|(i, s)| (i as f32 * 10.0, *s)).collect();
        assert_eq!(wrap_points(&xs, 50.0, 100.0), Vec::<usize>::new());
        assert_eq!(wrap_points(&xs, 50.0, 35.0), vec![3]);
        // A word wider than the line breaks inside it.
        assert_eq!(wrap_points(&xs[..2], 20.0, 15.0), vec![1]);
    }
}
