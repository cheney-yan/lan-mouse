//! Pure geometry helpers shared by capture backends: where along an edge a
//! point lies, and where on an edge a fraction maps back to.
//!
//! Fractions run from 0.0 at the top / left end of an edge to 1.0 at the
//! bottom / right end, measured along the *remote device's* edge, i.e.
//! relative to the rectangle the remote occupies in local coordinates.

use crate::Position;

/// an axis-aligned rectangle in local (logical) coordinates
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }

    /// squared distance from a point to this rectangle (0 when inside)
    pub fn distance2(&self, x: f64, y: f64) -> f64 {
        let dx = (self.x - x).max(0.0).max(x - (self.x + self.w - 1.0));
        let dy = (self.y - y).max(0.0).max(y - (self.y + self.h - 1.0));
        dx * dx + dy * dy
    }

    /// nearest point inside this rectangle
    pub fn clamp(&self, x: f64, y: f64) -> (f64, f64) {
        (
            x.clamp(self.x, self.x + self.w - 1.0),
            y.clamp(self.y, self.y + self.h - 1.0),
        )
    }
}

/// how far apart two edges may be and still count as touching (points)
pub const SNAP_GAP: f64 = 64.0;

/// Whether `display` borders `remote` on the display's `pos` side: the two
/// facing edges are within `gap` of each other and overlap along the edge.
/// This is the "snapped together in the layout" relation: crossing is
/// allowed along the *whole* edge of such a display, regardless of whether
/// the exact crossing point faces the remote.
pub fn borders(pos: Position, display: &Rect, remote: &Rect, gap: f64) -> bool {
    let (facing, overlap) = match pos {
        Position::Right => ((display.x + display.w - remote.x).abs(), overlap1(display.y, display.h, remote.y, remote.h)),
        Position::Left => ((remote.x + remote.w - display.x).abs(), overlap1(display.y, display.h, remote.y, remote.h)),
        Position::Bottom => ((display.y + display.h - remote.y).abs(), overlap1(display.x, display.w, remote.x, remote.w)),
        Position::Top => ((remote.y + remote.h - display.y).abs(), overlap1(display.x, display.w, remote.x, remote.w)),
    };
    facing <= gap && overlap > 0.0
}

fn overlap1(a0: f64, aw: f64, b0: f64, bw: f64) -> f64 {
    (a0 + aw).min(b0 + bw) - a0.max(b0)
}

/// Where along the remote's edge the point `(x, y)` lies, for a remote that
/// occupies `remote` and sits at `pos` relative to the local displays.
pub fn edge_fraction(pos: Position, remote: &Rect, x: f64, y: f64) -> f64 {
    let f = match pos {
        Position::Left | Position::Right => {
            if remote.h > 0.0 {
                (y - remote.y) / remote.h
            } else {
                0.5
            }
        }
        Position::Top | Position::Bottom => {
            if remote.w > 0.0 {
                (x - remote.x) / remote.w
            } else {
                0.5
            }
        }
    };
    if f.is_finite() { f.clamp(0.0, 1.0) } else { 0.5 }
}

/// The local point where the cursor should reappear when it comes back from
/// a remote at `pos` through `fraction` of the remote's edge: on the local
/// side of the shared edge, `inset` pixels inside, and on an actual display
/// (`displays`): if the shared edge has no display at that spot, the nearest
/// display point is used.
pub fn return_point(
    pos: Position,
    remote: &Rect,
    fraction: f64,
    inset: f64,
    displays: &[Rect],
) -> (f64, f64) {
    let f = fraction.clamp(0.0, 1.0);
    let (x, y) = match pos {
        // remote is to the right: come back onto the local side of its left edge
        Position::Right => (remote.x - inset, remote.y + f * remote.h),
        Position::Left => (remote.x + remote.w - 1.0 + inset, remote.y + f * remote.h),
        Position::Bottom => (remote.x + f * remote.w, remote.y - inset),
        Position::Top => (remote.x + f * remote.w, remote.y + remote.h - 1.0 + inset),
    };
    if displays.is_empty() || displays.iter().any(|d| d.contains(x, y)) {
        return (x, y);
    }
    let nearest = displays
        .iter()
        .min_by(|a, b| a.distance2(x, y).total_cmp(&b.distance2(x, y)))
        .expect("non-empty");
    nearest.clamp(x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    // the real layout: Lenovo (main) 3008x1692 at 0,0; Samsung 3440x1440 at 2550,-1440;
    // imac occupies 3008,0 size 3008x1692 (right of the Lenovo, below the Samsung)
    fn lenovo() -> Rect { Rect { x: 0.0, y: 0.0, w: 3008.0, h: 1692.0 } }
    fn samsung() -> Rect { Rect { x: 2550.0, y: -1440.0, w: 3440.0, h: 1440.0 } }
    fn imac() -> Rect { Rect { x: 3008.0, y: 0.0, w: 3008.0, h: 1692.0 } }

    #[test]
    fn fraction_along_right_edge() {
        assert_eq!(edge_fraction(Position::Right, &imac(), 3007.0, 0.0), 0.0);
        assert_eq!(edge_fraction(Position::Right, &imac(), 3007.0, 846.0), 0.5);
        assert_eq!(edge_fraction(Position::Right, &imac(), 3007.0, 1692.0), 1.0);
        // outside the remote's extent is clamped
        assert_eq!(edge_fraction(Position::Right, &imac(), 3007.0, 5000.0), 1.0);
    }

    #[test]
    fn fraction_along_bottom_edge() {
        // Samsung bottom edge at x=4512 is the middle of imac's top edge
        assert_eq!(edge_fraction(Position::Bottom, &imac(), 4512.0, -1.0), 0.5);
        assert_eq!(edge_fraction(Position::Bottom, &imac(), 3008.0, -1.0), 0.0);
    }

    #[test]
    fn return_from_right_lands_on_lenovo() {
        let d = [lenovo(), samsung()];
        let (x, y) = return_point(Position::Right, &imac(), 0.5, 1.0, &d);
        assert_eq!((x, y), (3007.0, 846.0));
    }

    #[test]
    fn return_from_bottom_lands_on_samsung() {
        let d = [lenovo(), samsung()];
        let (x, y) = return_point(Position::Bottom, &imac(), 0.5, 1.0, &d);
        assert_eq!((x, y), (4512.0, -1.0));
        // beyond the Samsung's right end (fraction 1.0 -> x=6016) snaps to the nearest display point
        let (x, y) = return_point(Position::Bottom, &imac(), 1.0, 1.0, &d);
        assert_eq!((x, y), (5989.0, -1.0));
    }

    #[test]
    fn snapped_edges() {
        // the Lenovo touches imac on its right, along its whole height
        assert!(borders(Position::Right, &lenovo(), &imac(), SNAP_GAP));
        // the Samsung sits above imac (x 3008..5990 overlap), but not to its left
        assert!(borders(Position::Bottom, &samsung(), &imac(), SNAP_GAP));
        assert!(!borders(Position::Right, &samsung(), &imac(), SNAP_GAP));
        // a shorter remote (logical 2560x1440) still borders the whole Lenovo edge
        let short = Rect { x: 3008.0, y: 0.0, w: 2560.0, h: 1440.0 };
        assert!(borders(Position::Right, &lenovo(), &short, SNAP_GAP));
        // a small gap ("black hole") is tolerated, a large one is not
        let gapped = Rect { x: 3040.0, y: 0.0, w: 2560.0, h: 1440.0 };
        assert!(borders(Position::Right, &lenovo(), &gapped, SNAP_GAP));
        let far = Rect { x: 3500.0, y: 0.0, w: 2560.0, h: 1440.0 };
        assert!(!borders(Position::Right, &lenovo(), &far, SNAP_GAP));
    }

    #[test]
    fn no_displays_means_raw_point() {
        let (x, y) = return_point(Position::Left, &imac(), 0.0, 2.0, &[]);
        assert_eq!((x, y), (3008.0 + 3008.0 - 1.0 + 2.0, 0.0));
    }
}
