// Modules
mod glyphs;
mod grid;

// Imports
use crate::Shape;
use crate::shapes::{Arrow, ArrowHead, Line};
use anyhow::Context;
use glyphs::StrokeLabel;
use num_derive::{FromPrimitive, ToPrimitive};
use p2d::math::Vector2;
use serde::{Deserialize, Serialize};

/// The style of the axes of the coordinate system builders.
///
/// Every style builds on the features of the previous one.
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, FromPrimitive, ToPrimitive,
)]
#[serde(rename = "axes_style")]
pub enum AxesStyle {
    /// Plain lines.
    #[serde(rename = "plain")]
    Plain = 0,
    /// Arrow tips at both ends of every axis and scale ticks.
    #[default]
    #[serde(rename = "arrows")]
    Arrows,
    /// Like [AxesStyle::Arrows], with numbered ticks.
    #[serde(rename = "numbered")]
    Numbered,
    /// Like [AxesStyle::Numbered], with a dotted grid in the plane.
    #[serde(rename = "dotted_grid")]
    DottedGrid,
}

impl TryFrom<u32> for AxesStyle {
    type Error = anyhow::Error;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        num_traits::FromPrimitive::from_u32(value)
            .with_context(|| format!("AxesStyle try_from::<u32>() for value {value} failed"))
    }
}

impl AxesStyle {
    fn has_arrows(self) -> bool {
        self != Self::Plain
    }

    fn has_ticks(self) -> bool {
        self != Self::Plain
    }

    fn has_numbers(self) -> bool {
        matches!(self, Self::Numbered | Self::DottedGrid)
    }

    fn has_grid(self) -> bool {
        self == Self::DottedGrid
    }
}

/// Options for the axes of the coordinate system builders.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(default, rename = "axes_options")]
pub struct AxesOptions {
    /// The style of the axes.
    #[serde(rename = "style")]
    pub style: AxesStyle,
    /// Distance between two ticks.
    #[serde(rename = "tick_spacing", with = "crate::serialize::f64_dp3")]
    pub tick_spacing: f64,
    /// Length of a tick, measured across the axis.
    #[serde(rename = "tick_length", with = "crate::serialize::f64_dp3")]
    pub tick_length: f64,
}

impl Default for AxesOptions {
    fn default() -> Self {
        Self {
            style: AxesStyle::default(),
            tick_spacing: 24.0,
            tick_length: 8.0,
        }
    }
}

/// An axis through the origin, with a positive and an optional negative half.
#[derive(Debug, Clone, Copy)]
pub struct Axis {
    origin: Vector2,
    positive_end: Vector2,
    negative_end: Option<Vector2>,
}

impl Axis {
    /// A new axis. Without a negative end, only the positive half is drawn.
    pub fn new(origin: Vector2, positive_end: Vector2, negative_end: Option<Vector2>) -> Self {
        Self {
            origin,
            positive_end,
            negative_end,
        }
    }

    /// Normalized direction of the positive half.
    fn dir(&self) -> Vector2 {
        (self.positive_end - self.origin).normalize_or(Vector2::X)
    }

    /// Side the labels are placed on: below horizontal axes, left of all others.
    fn label_side(&self) -> Vector2 {
        let normal = self.dir().perp();
        if normal.x > 1e-6 || (normal.x.abs() <= 1e-6 && normal.y < 0.0) {
            -normal
        } else {
            normal
        }
    }

    /// The halves of the axis, as ends paired with the sign of their tick values.
    fn halves(&self) -> impl Iterator<Item = (Vector2, i64)> {
        std::iter::once((self.positive_end, 1)).chain(self.negative_end.map(|end| (end, -1)))
    }

    /// The range of tick indices, negative indices lie on the negative half.
    fn tick_range(&self, spacing: f64) -> std::ops::RangeInclusive<i64> {
        let n_neg = self
            .negative_end
            .map(|end| n_ticks((end - self.origin).length(), spacing))
            .unwrap_or(0);
        let n_pos = n_ticks((self.positive_end - self.origin).length(), spacing);
        -n_neg..=n_pos
    }
}

/// An axis aligned rectangle.
#[derive(Debug, Clone, Copy)]
struct Rect {
    center: Vector2,
    half: Vector2,
}

impl Rect {
    fn overlaps(&self, other: &Rect) -> bool {
        let dist = (self.center - other.center).abs();
        let reach = self.half + other.half;
        dist.x < reach.x && dist.y < reach.y
    }

    fn contains(&self, pos: Vector2) -> bool {
        let dist = (pos - self.center).abs();
        dist.x <= self.half.x && dist.y <= self.half.y
    }

    /// Whether the segment from `a` to `b` crosses the rectangle (slab method).
    fn hit_by_segment(&self, a: Vector2, b: Vector2) -> bool {
        let d = b - a;
        let (mut t_min, mut t_max) = (0.0_f64, 1.0_f64);
        for k in 0..2 {
            let (lo, hi) = (self.center[k] - self.half[k], self.center[k] + self.half[k]);
            if d[k].abs() < 1e-9 {
                if a[k] < lo || a[k] > hi {
                    return false;
                }
                continue;
            }
            let (t1, t2) = ((lo - a[k]) / d[k], (hi - a[k]) / d[k]);
            t_min = t_min.max(t1.min(t2));
            t_max = t_max.min(t1.max(t2));
            if t_min > t_max {
                return false;
            }
        }
        true
    }
}

/// Number of ticks on a half axis of the given length.
///
/// The outermost tick keeps half a spacing distance to the end, away from a possible arrow tip.
fn n_ticks(len: f64, spacing: f64) -> i64 {
    if len <= spacing {
        return 0;
    }
    ((len - spacing * 0.5) / spacing).floor() as i64
}

impl AxesOptions {
    /// The minimum tick spacing.
    pub const TICK_SPACING_MIN: f64 = 4.0;
    /// The maximum tick spacing.
    pub const TICK_SPACING_MAX: f64 = 500.0;
    /// Gap between a tick and its label, relative to the label height.
    const LABEL_GAP_FACTOR: f64 = 0.6;
    /// Label steps, labels are thinned out with these when they would overlap.
    const LABEL_STEPS: [i64; 7] = [1, 2, 5, 10, 20, 50, 100];

    fn spacing(&self) -> f64 {
        self.tick_spacing
            .clamp(Self::TICK_SPACING_MIN, Self::TICK_SPACING_MAX)
    }

    fn label_height(&self) -> f64 {
        (self.spacing() * 0.4).clamp(6.0, 16.0)
    }

    /// Generates the shapes of a coordinate system.
    ///
    /// `grid_planes` holds index pairs into `axes`, spanning the planes that receive a dotted grid.
    pub fn coord_system_shapes(
        &self,
        axes: &[Axis],
        grid_planes: &[(usize, usize)],
        arrow_head: ArrowHead,
    ) -> Vec<Shape> {
        let mut shapes = axes
            .iter()
            .flat_map(|axis| self.axis_shapes(axis, arrow_head))
            .collect::<Vec<Shape>>();

        let label_rects = if self.style.has_numbers() {
            let placed = self.place_labels(axes);
            let rects = placed.iter().map(|(_, rect)| *rect).collect::<Vec<Rect>>();
            shapes.extend(
                placed
                    .into_iter()
                    .flat_map(|(label, rect)| label.polylines(rect.center))
                    .map(Shape::Polyline),
            );
            rects
        } else {
            vec![]
        };

        if self.style.has_grid() {
            for &(a, b) in grid_planes {
                if let (Some(a), Some(b)) = (axes.get(a), axes.get(b)) {
                    shapes.extend(
                        grid::dots(a.origin, a, b, self.spacing())
                            .into_iter()
                            .filter(|dot| {
                                let pos = dot.affine.translation;
                                !label_rects.iter().any(|rect| rect.contains(pos))
                            })
                            .map(Shape::Ellipse),
                    );
                }
            }
        }

        shapes
    }

    /// Places the labels of all axes, dropping labels that would overlap other labels or cross other axes.
    ///
    /// Labels far from the origin are placed first, so crowded labels around the origin are dropped.
    fn place_labels(&self, axes: &[Axis]) -> Vec<(StrokeLabel, Rect)> {
        let margin = Vector2::splat(self.label_height() * 0.25);
        let mut candidates = axes
            .iter()
            .enumerate()
            .flat_map(|(axis_idx, axis)| {
                self.labels(axis)
                    .into_iter()
                    .map(move |(label, center)| (axis_idx, label, center))
            })
            .collect::<Vec<_>>();
        candidates.sort_by(|(_, _, a), (_, _, b)| {
            let origin = axes[0].origin;
            (*b - origin).length().total_cmp(&(*a - origin).length())
        });

        let mut placed: Vec<(StrokeLabel, Rect)> = Vec::new();
        for (axis_idx, label, center) in candidates {
            let rect = Rect {
                center,
                half: label.size() * 0.5 + margin,
            };
            let overlaps_label = placed.iter().any(|(_, other)| rect.overlaps(other));
            let crosses_axis = axes.iter().enumerate().any(|(idx, axis)| {
                idx != axis_idx
                    && axis
                        .halves()
                        .any(|(end, _)| rect.hit_by_segment(axis.origin, end))
            });
            if !overlaps_label && !crosses_axis {
                placed.push((label, rect));
            }
        }
        placed
    }

    fn axis_shapes(&self, axis: &Axis, arrow_head: ArrowHead) -> Vec<Shape> {
        let mut shapes = Vec::new();

        for (end, _) in axis.halves() {
            if self.style.has_arrows() {
                shapes.push(Shape::Arrow(
                    Arrow::new(axis.origin, end).with_head(arrow_head),
                ));
            } else {
                shapes.push(Shape::Line(Line {
                    start: axis.origin,
                    end,
                }));
            }
        }

        if self.style.has_ticks() {
            shapes.extend(self.tick_lines(axis).into_iter().map(Shape::Line));
        }

        shapes
    }

    fn tick_lines(&self, axis: &Axis) -> Vec<Line> {
        let spacing = self.spacing();
        let dir = axis.dir();
        let half_tick = dir.perp() * (self.tick_length * 0.5);

        axis.tick_range(spacing)
            .filter(|i| *i != 0)
            .map(|i| {
                let pos = axis.origin + dir * (i as f64 * spacing);
                Line {
                    start: pos - half_tick,
                    end: pos + half_tick,
                }
            })
            .collect()
    }

    /// Label candidates of an axis, with their centers.
    fn labels(&self, axis: &Axis) -> Vec<(StrokeLabel, Vector2)> {
        let spacing = self.spacing();
        let height = self.label_height();
        let dir = axis.dir();
        let side = axis.label_side();
        let range = axis.tick_range(spacing);

        // the widest label decides how far labels must be apart
        let widest = StrokeLabel::new(range.start().to_string(), height)
            .size()
            .max(StrokeLabel::new(range.end().to_string(), height).size());
        let extent_along_axis = (dir.x * widest.x).abs() + (dir.y * widest.y).abs();
        let step = Self::LABEL_STEPS
            .into_iter()
            .find(|s| *s as f64 * spacing >= extent_along_axis * 1.3)
            .unwrap_or(*Self::LABEL_STEPS.last().unwrap());

        range
            .filter(|i| *i != 0 && i % step == 0)
            .map(|i| {
                let label = StrokeLabel::new(i.to_string(), height);
                let size = label.size();
                // distance from the axis to the label center, so the label never touches the tick
                let extent_across = (side.x * size.x).abs() * 0.5 + (side.y * size.y).abs() * 0.5;
                let offset =
                    self.tick_length * 0.5 + height * Self::LABEL_GAP_FACTOR + extent_across;
                let center = axis.origin + dir * (i as f64 * spacing) + side * offset;
                (label, center)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn x_axis(negative: bool) -> Axis {
        Axis::new(
            Vector2::ZERO,
            Vector2::new(100.0, 0.0),
            negative.then_some(Vector2::new(-100.0, 0.0)),
        )
    }

    fn options(style: AxesStyle) -> AxesOptions {
        AxesOptions {
            style,
            tick_spacing: 20.0,
            ..Default::default()
        }
    }

    fn count(shapes: &[Shape], f: impl Fn(&Shape) -> bool) -> usize {
        shapes.iter().filter(|s| f(s)).count()
    }

    #[test]
    fn plain_is_lines_only() {
        let shapes =
            options(AxesStyle::Plain).coord_system_shapes(&[x_axis(true)], &[], ArrowHead::Filled);
        assert_eq!(shapes.len(), 2);
        assert_eq!(count(&shapes, |s| matches!(s, Shape::Line(_))), 2);
    }

    #[test]
    fn arrows_on_both_halves() {
        let shapes =
            options(AxesStyle::Arrows).coord_system_shapes(&[x_axis(true)], &[], ArrowHead::Filled);
        assert_eq!(count(&shapes, |s| matches!(s, Shape::Arrow(_))), 2);
        // ticks at +-20, +-40, +-60, +-80
        assert_eq!(count(&shapes, |s| matches!(s, Shape::Line(_))), 8);
    }

    #[test]
    fn numbered_adds_labels() {
        let shapes = options(AxesStyle::Numbered).coord_system_shapes(
            &[x_axis(false)],
            &[],
            ArrowHead::Filled,
        );
        assert!(count(&shapes, |s| matches!(s, Shape::Polyline(_))) > 0);
    }

    #[test]
    fn labels_below_horizontal_axis() {
        let shapes = options(AxesStyle::Numbered).coord_system_shapes(
            &[x_axis(false)],
            &[],
            ArrowHead::Filled,
        );
        for shape in shapes {
            if let Shape::Polyline(p) = shape {
                assert!(p.start.y > 0.0);
            }
        }
    }

    #[test]
    fn grid_only_for_dotted_grid() {
        let y = Axis::new(Vector2::ZERO, Vector2::new(0.0, -100.0), None);
        let axes = [x_axis(false), y];
        let numbered =
            options(AxesStyle::Numbered).coord_system_shapes(&axes, &[(0, 1)], ArrowHead::Filled);
        let grid =
            options(AxesStyle::DottedGrid).coord_system_shapes(&axes, &[(0, 1)], ArrowHead::Filled);
        assert_eq!(count(&numbered, |s| matches!(s, Shape::Ellipse(_))), 0);
        assert_eq!(count(&grid, |s| matches!(s, Shape::Ellipse(_))), 16);
    }

    #[test]
    fn labels_never_overlap_nor_cross_axes() {
        let center = Vector2::ZERO;
        // the 3D layout is the most crowded one, with the diagonal axis
        let axes = [
            Axis::new(
                center,
                Vector2::new(-150.0, 150.0),
                Some(Vector2::new(150.0, -150.0)),
            ),
            Axis::new(
                center,
                Vector2::new(300.0, 0.0),
                Some(Vector2::new(-300.0, 0.0)),
            ),
            Axis::new(
                center,
                Vector2::new(0.0, -300.0),
                Some(Vector2::new(0.0, 300.0)),
            ),
        ];
        for spacing in [4.0, 8.0, 12.0, 20.0, 24.0, 40.0] {
            let options = AxesOptions {
                style: AxesStyle::Numbered,
                tick_spacing: spacing,
                ..Default::default()
            };
            let placed = options.place_labels(&axes);
            assert!(!placed.is_empty(), "no labels at spacing {spacing}");

            for (i, (_, rect)) in placed.iter().enumerate() {
                for (_, other) in &placed[i + 1..] {
                    assert!(!rect.overlaps(other), "labels overlap at spacing {spacing}");
                }
                for axis in &axes {
                    for (end, _) in axis.halves() {
                        assert!(
                            !rect.hit_by_segment(axis.origin, end),
                            "label crosses an axis at spacing {spacing}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn rect_segment_hit() {
        let rect = Rect {
            center: Vector2::ZERO,
            half: Vector2::splat(1.0),
        };
        assert!(rect.hit_by_segment(Vector2::new(-5.0, 0.0), Vector2::new(5.0, 0.0)));
        assert!(!rect.hit_by_segment(Vector2::new(-5.0, 2.0), Vector2::new(5.0, 2.0)));
        assert!(!rect.hit_by_segment(Vector2::new(2.0, 2.0), Vector2::new(5.0, 5.0)));
    }

    #[test]
    fn short_axis_has_no_ticks() {
        let axis = Axis::new(Vector2::ZERO, Vector2::new(5.0, 0.0), None);
        let shapes = AxesOptions::default().coord_system_shapes(&[axis], &[], ArrowHead::Filled);
        assert_eq!(shapes.len(), 1);
    }
}
