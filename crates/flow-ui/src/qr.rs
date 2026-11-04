//! Pairing QR codes (research R14), drawn as quads so the token view looks the same on the Mac and
//! Windows. The white quiet zone is what lets a phone scan it on a dark sheet, and modules land on
//! whole device pixels so no edge is blurred (027 T039).
use gpui_kit::{
    App, Bounds, InteractiveElement, IntoElement, ParentElement, Pixels, SharedString, StatefulInteractiveElement, Styled, Window,
    accesskit, canvas,
    div, point, px, size,
};
use qrcodegen::{QrCode, QrCodeEcc};

/// Modules of white on every side, the minimum the QR standard asks for.
pub const QUIET_ZONE: usize = 4;

/// The module grid of one code, quiet zone not included.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QrMatrix {
    size: usize,
    dark: Vec<bool>,
}

/// A dark rectangle in logical pixels from the code's top-left corner, edges on whole device pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

/// What to paint for a square of `side` logical pixels at `scale` device pixels per point.
#[derive(Clone, Debug, PartialEq)]
pub struct Layout {
    /// Device pixels per module, a whole number of at least 1.
    pub module_px: u32,
    /// Logical side of the code with its quiet zone; at most `side` unless one pixel per module doesn't fit.
    pub drawn: f32,
    /// Offset that centres the code in `side`, on a whole device pixel.
    pub inset: f32,
    pub dark: Vec<Rect>,
}

impl QrMatrix {
    /// Medium error correction, as `CIQRCodeGenerator` uses in the Swift app. `None` when the text is too long.
    pub fn encode(text: &str) -> Option<Self> {
        let code = QrCode::encode_text(text, QrCodeEcc::Medium).ok()?;
        let size = usize::try_from(code.size()).ok()?;
        let mut dark = Vec::with_capacity(size * size);
        for y in 0..size {
            for x in 0..size {
                dark.push(code.get_module(x as i32, y as i32));
            }
        }
        Some(Self { size, dark })
    }

    /// Modules per side, without the quiet zone.
    pub fn size(&self) -> usize {
        self.size
    }

    /// Modules per side with the quiet zone.
    pub fn side_modules(&self) -> usize {
        self.size + 2 * QUIET_ZONE
    }

    /// Whether the module is dark, in coordinates that include the quiet zone.
    pub fn is_dark(&self, x: usize, y: usize) -> bool {
        let (Some(x), Some(y)) = (x.checked_sub(QUIET_ZONE), y.checked_sub(QUIET_ZONE)) else { return false };
        x < self.size && y < self.size && self.dark[y * self.size + x]
    }

    /// Horizontal runs of dark modules as `(x, y, length)`, quiet zone included in the coordinates.
    /// One quad per run keeps a version-6 code near 400 quads instead of 1,000.
    pub fn dark_runs(&self) -> Vec<(usize, usize, usize)> {
        let mut runs = Vec::new();
        for y in 0..self.size {
            let mut x = 0;
            while x < self.size {
                if self.dark[y * self.size + x] {
                    let start = x;
                    while x < self.size && self.dark[y * self.size + x] {
                        x += 1;
                    }
                    runs.push((start + QUIET_ZONE, y + QUIET_ZONE, x - start));
                } else {
                    x += 1;
                }
            }
        }
        runs
    }

    pub fn layout(&self, side: f32, scale: f32) -> Layout {
        let scale = if scale > 0. { scale } else { 1. };
        let modules = self.side_modules() as f32;
        let module_px = ((side * scale) / modules).floor().max(1.) as u32;
        let drawn_px = module_px as f32 * modules;
        let inset_px = ((side * scale - drawn_px) / 2.).floor().max(0.);
        let m = module_px as f32 / scale;
        let dark = self
            .dark_runs()
            .into_iter()
            .map(|(x, y, n)| Rect { x: inset_px / scale + x as f32 * m, y: inset_px / scale + y as f32 * m, w: n as f32 * m, h: m })
            .collect();
        Layout { module_px, drawn: drawn_px / scale, inset: inset_px / scale, dark }
    }
}

/// The QR for `link` in a white square of `side` points, or `None` when the link is too long to encode.
/// The square is white edge to edge, so the quiet zone is at least four modules wide.
pub fn qr_code(id: impl Into<SharedString>, link: &str, side: f32, label: impl Into<SharedString>) -> Option<impl IntoElement> {
    let matrix = QrMatrix::encode(link)?;
    Some(
        div()
            .id(id.into())
            .flex_none()
            .size(px(side))
            .bg(gpui_kit::white())
            .role(accesskit::Role::Image)
            .aria_label(label.into())
            .child(canvas(|_, _, _| (), move |bounds, (), window, cx| paint(&matrix, bounds, window, cx)).size_full()),
    )
}

fn paint(matrix: &QrMatrix, bounds: Bounds<Pixels>, window: &mut Window, _: &mut App) {
    let scale = window.scale_factor();
    let side = f32::from(bounds.size.width).min(f32::from(bounds.size.height));
    let layout = matrix.layout(side, scale);
    // Snap the origin too, or every edge shifts by the same fraction of a pixel.
    let snap = |v: Pixels| (f32::from(v) * scale).round() / scale;
    let (ox, oy) = (snap(bounds.origin.x), snap(bounds.origin.y));
    let black = gpui_kit::black();
    for r in &layout.dark {
        window.paint_quad(gpui_kit::fill(Bounds::new(point(px(ox + r.x), px(oy + r.y)), size(px(r.w), px(r.h))), black));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Not a real token: the shape of a pairing link from `token create --json`.
    const LINK: &str = "localflow://pair?address=https%3A%2F%2Fstudio-mac.local%3A8443#token=lfp_TESTONLYabcdefghijklmnopqrstuvwxyz0123456789";

    /// Paints the layout into a greyscale buffer the way the GPU would, one device pixel per cell.
    fn raster(l: &Layout, side: f32, scale: f32) -> (usize, Vec<u8>) {
        let n = (side * scale).round() as usize;
        let mut img = vec![255u8; n * n];
        for r in &l.dark {
            let (x0, y0) = ((r.x * scale).round() as usize, (r.y * scale).round() as usize);
            let (x1, y1) = (((r.x + r.w) * scale).round() as usize, ((r.y + r.h) * scale).round() as usize);
            for y in y0..y1.min(n) {
                for x in x0..x1.min(n) {
                    img[y * n + x] = 0;
                }
            }
        }
        (n, img)
    }

    fn decode(n: usize, img: &[u8]) -> Vec<String> {
        let mut prepared = rqrr::PreparedImage::prepare_from_greyscale(n, n, |x, y| img[y * n + x]);
        prepared.detect_grids().into_iter().filter_map(|g| g.decode().ok().map(|(_, s)| s)).collect()
    }

    #[test]
    fn drawn_code_decodes_to_the_pairing_link() {
        let m = QrMatrix::encode(LINK).unwrap();
        // The token view's 180-point square at 1x, 2x and a fractional Windows scale.
        for scale in [1.0, 2.0, 1.25] {
            let l = m.layout(180., scale);
            let (n, img) = raster(&l, 180., scale);
            assert_eq!(decode(n, &img), vec![LINK.to_string()], "scale {scale}");
        }
    }

    #[test]
    fn quiet_zone_is_four_white_modules() {
        let m = QrMatrix::encode(LINK).unwrap();
        let s = m.side_modules();
        assert_eq!(s, m.size() + 8);
        for i in 0..s {
            for q in 0..QUIET_ZONE {
                assert!(!m.is_dark(i, q) && !m.is_dark(q, i) && !m.is_dark(i, s - 1 - q) && !m.is_dark(s - 1 - q, i));
            }
        }
        // Finder pattern corners sit right inside the quiet zone.
        assert!(m.is_dark(QUIET_ZONE, QUIET_ZONE));
        let l = m.layout(180., 2.);
        let quiet = QUIET_ZONE as f32 * l.module_px as f32 / 2.;
        let (lo, hi) = (l.inset + quiet - 1e-4, l.inset + l.drawn - quiet + 1e-4);
        assert!(l.dark.iter().all(|r| r.x >= lo && r.y >= lo && r.x + r.w <= hi && r.y + r.h <= hi));
    }

    #[test]
    fn modules_are_whole_device_pixels() {
        let m = QrMatrix::encode(LINK).unwrap();
        for (side, scale) in [(180., 1.), (180., 2.), (180., 1.25), (181.3, 1.5), (40., 1.)] {
            let l = m.layout(side, scale);
            assert!(l.module_px >= 1);
            // Too small for one pixel per module: drawn at one pixel and allowed to overflow.
            let tiny = side * scale < m.side_modules() as f32;
            assert_eq!(l.drawn <= side + 1e-4, !tiny, "{side}@{scale}");
            for r in &l.dark {
                for v in [r.x, r.y, r.w, r.h] {
                    let d = v * scale;
                    assert!((d - d.round()).abs() < 1e-3, "{v} at {scale}x isn't a whole pixel");
                }
            }
        }
    }

    #[test]
    fn runs_cover_exactly_the_dark_modules() {
        let m = QrMatrix::encode(LINK).unwrap();
        let s = m.side_modules();
        let mut painted = vec![false; s * s];
        for (x, y, n) in m.dark_runs() {
            for i in x..x + n {
                assert!(!painted[y * s + i]);
                painted[y * s + i] = true;
            }
        }
        for y in 0..s {
            for x in 0..s {
                assert_eq!(painted[y * s + x], m.is_dark(x, y));
            }
        }
    }

    #[test]
    fn too_long_text_has_no_code() {
        assert!(QrMatrix::encode(&"x".repeat(8000)).is_none());
        assert!(qr_code("qr", &"x".repeat(8000), 180., "QR").is_none());
    }
}
