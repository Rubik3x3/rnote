// Imports
use super::Line;
use crate::Transformable;
use crate::ext::{DPose2Ext, Vector2Ext};
use crate::shapes::Shapeable;
use kurbo::{PathEl, Shape};
use p2d::bounding_volume::Aabb;
use p2d::glamx::prelude::{DPose2, DRot2};
use p2d::math::Vector2;
use serde::{Deserialize, Serialize};

/// All doc-comments of this file and [ArrowBuilder][crate::builders] rely on the following
/// graphic:
///
/// ```text
///         tip
///         /|\
///        / | \
///       /  |  \
///    lline |  rline
///          |
///          |
///          |
///         start
/// ```
///
/// Where `lline`, `tip`, `start` and `rline` represent a vector of the arrow.

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename = "arrow")]
pub struct Arrow {
    /// Start of the arrow.
    pub start: Vector2,

    /// Tip of the arow.
    pub tip: Vector2,

    /// Style of the arrow head.
    ///
    /// Defaults to [ArrowHead::Open] when missing, so older documents stay unchanged.
    #[serde(rename = "head")]
    pub head: ArrowHead,
}

/// The style of an arrow head.
#[derive(
    Debug,
    Clone,
    Copy,
    Default,
    PartialEq,
    Eq,
    Serialize,
    Deserialize,
    num_derive::FromPrimitive,
    num_derive::ToPrimitive,
)]
#[serde(rename = "arrow_head")]
pub enum ArrowHead {
    /// Two open lines.
    #[default]
    #[serde(rename = "open")]
    Open = 0,
    /// A filled triangle.
    #[serde(rename = "filled")]
    Filled,
}

impl TryFrom<u32> for ArrowHead {
    type Error = anyhow::Error;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        num_traits::FromPrimitive::from_u32(value)
            .ok_or_else(|| anyhow::anyhow!("ArrowHead try_from::<u32>() for value {value} failed"))
    }
}

impl Transformable for Arrow {
    fn translate(&mut self, offset: Vector2) {
        self.start += offset;
        self.tip += offset;
    }

    fn rotate(&mut self, angle: f64, center: Vector2) {
        let pose = DPose2::from_rotation_wrt_center(angle, center);
        self.start = pose.transform_point(self.start);
        self.tip = pose.transform_point(self.tip);
    }

    fn scale(&mut self, scale: Vector2) {
        self.start *= scale;
        self.tip *= scale;
    }
}

impl Shapeable for Arrow {
    fn bounds(&self) -> Aabb {
        self.internal_compute_bounds(None)
    }

    fn hitboxes(&self) -> Vec<Aabb> {
        let n_splits = super::hitbox_elems_for_shape_len((self.tip - self.start).length());
        self.split(n_splits)
            .into_iter()
            .map(|line| line.bounds())
            .collect()
    }

    fn outline_path(&self) -> kurbo::BezPath {
        self.to_kurbo(None)
    }
}

impl Arrow {
    /// The tip lines (rline & lline) default length, is the actual length when
    /// no stroke width is associated with the arrow, if there is, it is used as
    /// the base length for the actual width calculation.
    const TIP_LINES_DEFAULT_LENGTH: f64 = 10.0;

    /// The angle for `rline` and `lline` to the stem of the arrow.
    const TIP_LINES_STEM_OBTUSE_ANGLE: f64 = (13.0 / 16.0) * std::f64::consts::PI;

    /// Creating a new arrow with the given start and tip vectors.
    pub fn new(start: Vector2, tip: Vector2) -> Self {
        Self {
            start,
            tip,
            head: ArrowHead::default(),
        }
    }

    /// Sets the style of the arrow head.
    pub fn with_head(mut self, head: ArrowHead) -> Self {
        self.head = head;
        self
    }

    /// Split the stem of the arrow into the given number of lines.
    pub fn split(&self, n_splits: i32) -> Vec<Line> {
        (0..n_splits)
            .map(|i| {
                let sub_start = self
                    .start
                    .lerp(self.tip, f64::from(i) / f64::from(n_splits));
                let sub_end = self
                    .start
                    .lerp(self.tip, f64::from(i + 1) / f64::from(n_splits));

                Line {
                    start: sub_start,
                    end: sub_end,
                }
            })
            .collect::<Vec<Line>>()
    }

    /// Convert to kurbo shape.
    pub fn to_kurbo(&self, stroke_width: Option<f64>) -> kurbo::BezPath {
        let mut bez_path = self.stem_to_kurbo(stroke_width);
        bez_path.extend(self.head_to_kurbo(stroke_width));
        bez_path
    }

    /// The stem as kurbo path.
    ///
    /// For a filled head the stem ends at the head base, so it does not poke through the tip.
    pub fn stem_to_kurbo(&self, stroke_width: Option<f64>) -> kurbo::BezPath {
        let stem_end = match self.head {
            ArrowHead::Open => self.tip,
            ArrowHead::Filled => self.compute_head_base(stroke_width),
        };
        kurbo::Line::new(self.start.to_kurbo_point(), stem_end.to_kurbo_point()).to_path(0.25)
    }

    /// The head as kurbo path, closed for a filled head.
    pub fn head_to_kurbo(&self, stroke_width: Option<f64>) -> kurbo::BezPath {
        let tip = self.tip.to_kurbo_point();
        let lline = self.compute_lline(stroke_width).to_kurbo_point();
        let rline = self.compute_rline(stroke_width).to_kurbo_point();

        let mut els = vec![
            PathEl::MoveTo(lline),
            PathEl::LineTo(tip),
            PathEl::LineTo(rline),
        ];
        if self.head == ArrowHead::Filled {
            els.push(PathEl::ClosePath);
        }
        kurbo::BezPath::from_vec(els)
    }

    /// The center of the head base, between the ends of `lline` and `rline`.
    pub fn compute_head_base(&self, stroke_width: Option<f64>) -> Vector2 {
        (self.compute_lline(stroke_width) + self.compute_rline(stroke_width)) * 0.5
    }

    /// Compute the `lline` of the arrow tip.
    ///
    /// Optionally add the stroke width to adjust the length of the line.
    pub fn compute_lline(&self, stroke_width: Option<f64>) -> Vector2 {
        let vec_a =
            self.compute_stem_direction_vector() * Self::compute_tip_lines_length(stroke_width);
        DRot2::new(Self::TIP_LINES_STEM_OBTUSE_ANGLE) * vec_a + self.tip
    }

    /// Compute the `rline` of the arrow tip.
    ///
    /// Optionally add the stroke width to adjust the length of the line.
    pub fn compute_rline(&self, stroke_width: Option<f64>) -> Vector2 {
        let vec_b =
            self.compute_stem_direction_vector() * Self::compute_tip_lines_length(stroke_width);
        DRot2::new(-Self::TIP_LINES_STEM_OBTUSE_ANGLE) * vec_b + self.tip
    }

    /// Compute the bounds of the arrow in respect to the given stroke width.
    pub fn internal_compute_bounds(&self, stroke_width: Option<f64>) -> Aabb {
        let lline = self.compute_lline(stroke_width);
        let rline = self.compute_rline(stroke_width);
        Aabb::from_points([lline, rline, self.start, self.tip])
    }

    /// Compute the normalized direction vector from `start` to `tip`.
    fn compute_stem_direction_vector(&self) -> Vector2 {
        let direction_vector = self.tip - self.start;
        if direction_vector.length() == 0.0 {
            Vector2::X
        } else {
            direction_vector / direction_vector.length()
        }
    }

    /// Compute the length of the tip lines.
    ///
    /// Optionally add the stroke width to adjust the length of the line.
    fn compute_tip_lines_length(stroke_width: Option<f64>) -> f64 {
        let factor = stroke_width.unwrap_or(0.0);
        Self::TIP_LINES_DEFAULT_LENGTH * (1.0 + 0.18 * factor)
    }
}
