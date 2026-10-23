//! Plotting of real functions into a coordinate system, composed of regular shapes.

// Modules
mod expr;

// Re-exports
pub use expr::{Expr, ParseError};

// Imports
use crate::Shape;
use crate::builders::{AxesOptions, Axis};
use crate::shapes::{ArrowHead, Polyline};
use p2d::math::Vector2;

/// A closed interval.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Range {
    /// Lower bound.
    pub min: f64,
    /// Upper bound.
    pub max: f64,
}

impl Range {
    /// A new range. Its bounds must include zero, where the axes cross.
    pub fn new(min: f64, max: f64) -> anyhow::Result<Self> {
        if !(min.is_finite() && max.is_finite()) || min >= max {
            anyhow::bail!("the minimum must be smaller than the maximum");
        }
        if min > 0.0 || max < 0.0 {
            anyhow::bail!("the range must include 0");
        }
        Ok(Self { min, max })
    }

    fn len(&self) -> f64 {
        self.max - self.min
    }
}

/// Graphs of one or more functions in a shared coordinate system.
#[derive(Debug, Clone)]
pub struct FunctionGraph {
    /// The plotted functions.
    pub functions: Vec<Expr>,
    /// The visible x range.
    pub x_range: Range,
    /// The visible y range.
    pub y_range: Range,
    /// Size of one unit on the canvas. Also the tick spacing of the axes.
    pub unit: f64,
}

impl FunctionGraph {
    /// Maximum number of samples per function.
    const SAMPLES_MAX: usize = 4000;
    /// Samples per unit length on the canvas.
    const SAMPLES_PER_CANVAS_UNIT: f64 = 0.5;
    /// The axes extend this many units beyond the range, leaving room for the arrow tips.
    const AXES_OVERSHOOT: f64 = 0.6;

    /// Converts a point of the function to canvas coordinates, with the y axis pointing up.
    fn to_canvas(&self, origin: Vector2, x: f64, y: f64) -> Vector2 {
        origin + Vector2::new(x, -y) * self.unit
    }

    /// The axes of the graph, crossing at `origin` on the canvas.
    pub fn axes(&self, origin: Vector2) -> [Axis; 2] {
        let half_axis = |min: f64, max: f64, dir: Vector2| {
            let pos = origin + dir * ((max + Self::AXES_OVERSHOOT) * self.unit);
            let neg =
                (min < 0.0).then(|| origin + dir * ((min - Self::AXES_OVERSHOOT) * self.unit));
            Axis::new(origin, pos, neg)
        };
        [
            half_axis(self.x_range.min, self.x_range.max, Vector2::X),
            half_axis(self.y_range.min, self.y_range.max, -Vector2::Y),
        ]
    }

    /// Where the origin must be, so that the graph is centered at `center`.
    pub fn origin_for_center(&self, center: Vector2) -> Vector2 {
        let mid = Vector2::new(
            (self.x_range.min + self.x_range.max) * 0.5,
            (self.y_range.min + self.y_range.max) * 0.5,
        );
        center - Vector2::new(mid.x, -mid.y) * self.unit
    }

    /// The shapes of the coordinate system.
    pub fn axes_shapes(
        &self,
        origin: Vector2,
        axes_options: AxesOptions,
        arrow_head: ArrowHead,
    ) -> Vec<Shape> {
        let options = AxesOptions {
            tick_spacing: self.unit,
            ..axes_options
        };
        options.coord_system_shapes(&self.axes(origin), &[(0, 1)], arrow_head)
    }

    /// The curve of every function, each as a list of continuous pieces.
    pub fn curves(&self, origin: Vector2) -> Vec<Vec<Polyline>> {
        self.functions
            .iter()
            .map(|f| self.curve(f, origin))
            .collect()
    }

    fn curve(&self, f: &Expr, origin: Vector2) -> Vec<Polyline> {
        let n = ((self.x_range.len() * self.unit * Self::SAMPLES_PER_CANVAS_UNIT).ceil() as usize)
            .clamp(16, Self::SAMPLES_MAX);
        let dx = self.x_range.len() / n as f64;

        let mut pieces: Vec<Vec<Vector2>> = Vec::new();
        let mut current: Vec<Vector2> = Vec::new();
        let mut prev: Option<(f64, f64)> = None;

        for i in 0..=n {
            let x = self.x_range.min + i as f64 * dx;
            let y = f.eval(x);

            if let Some((x0, y0)) = prev
                && y.is_finite()
                && y0.is_finite()
                && !self.is_discontinuous(f, x0, y0, x, y)
                && let Some((a, b)) = self.clip(x0, y0, x, y)
            {
                let a = self.to_canvas(origin, a.0, a.1);
                let b = self.to_canvas(origin, b.0, b.1);
                if current
                    .last()
                    .is_none_or(|last| (*last - a).length() > 1e-6)
                {
                    // the curve re-entered the visible area
                    finish_piece(&mut pieces, &mut current);
                    current.push(a);
                }
                current.push(b);
            } else {
                finish_piece(&mut pieces, &mut current);
            }

            prev = Some((x, y));
        }
        finish_piece(&mut pieces, &mut current);

        pieces
            .into_iter()
            .map(|points| Polyline {
                start: points[0],
                path: points[1..].to_vec(),
            })
            .collect()
    }

    /// Detects poles and jumps between two samples, e.g. of `1/x` or `tan(x)`.
    ///
    /// Bisects towards the larger change: for a continuous function the change shrinks with the interval, at a
    /// pole or jump it does not.
    fn is_discontinuous(&self, f: &Expr, x0: f64, y0: f64, x1: f64, y1: f64) -> bool {
        const BISECTIONS: usize = 24;
        let threshold = self.y_range.len() * 0.05;

        let (mut a, mut b) = ((x0, y0), (x1, y1));
        if (b.1 - a.1).abs() < threshold {
            return false;
        }
        for _ in 0..BISECTIONS {
            let xm = (a.0 + b.0) * 0.5;
            let mid = (xm, f.eval(xm));
            if !mid.1.is_finite() {
                return true;
            }
            if (mid.1 - a.1).abs() > (b.1 - mid.1).abs() {
                b = mid;
            } else {
                a = mid;
            }
            if (b.1 - a.1).abs() < threshold {
                return false;
            }
        }
        true
    }

    /// Clips the segment to the visible area (Liang-Barsky).
    #[allow(clippy::type_complexity)]
    fn clip(&self, x0: f64, y0: f64, x1: f64, y1: f64) -> Option<((f64, f64), (f64, f64))> {
        let (dx, dy) = (x1 - x0, y1 - y0);
        let (mut t0, mut t1) = (0.0_f64, 1.0_f64);
        for (p, q) in [
            (-dx, x0 - self.x_range.min),
            (dx, self.x_range.max - x0),
            (-dy, y0 - self.y_range.min),
            (dy, self.y_range.max - y0),
        ] {
            if p == 0.0 {
                if q < 0.0 {
                    return None;
                }
            } else {
                let r = q / p;
                if p < 0.0 {
                    t0 = t0.max(r);
                } else {
                    t1 = t1.min(r);
                }
            }
        }
        if t0 > t1 {
            return None;
        }
        Some(((x0 + t0 * dx, y0 + t0 * dy), (x0 + t1 * dx, y0 + t1 * dy)))
    }
}

fn finish_piece(pieces: &mut Vec<Vec<Vector2>>, current: &mut Vec<Vector2>) {
    if current.len() >= 2 {
        pieces.push(std::mem::take(current));
    } else {
        current.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn graph(function: &str, x: (f64, f64), y: (f64, f64)) -> FunctionGraph {
        FunctionGraph {
            functions: vec![Expr::parse(function).unwrap()],
            x_range: Range::new(x.0, x.1).unwrap(),
            y_range: Range::new(y.0, y.1).unwrap(),
            unit: 20.0,
        }
    }

    fn points(piece: &Polyline) -> Vec<Vector2> {
        std::iter::once(piece.start)
            .chain(piece.path.iter().copied())
            .collect()
    }

    #[test]
    fn line_is_one_piece_through_origin() {
        let g = graph("2x", (-5.0, 5.0), (-10.0, 10.0));
        let curves = g.curves(Vector2::ZERO);
        assert_eq!(curves[0].len(), 1);
        // y = 2x at x = 1 lies at canvas (20, -40)
        assert!(
            points(&curves[0][0])
                .iter()
                .any(|p| (*p - Vector2::new(20.0, -40.0)).length() < 1.0)
        );
    }

    #[test]
    fn hyperbola_is_split_at_pole() {
        let g = graph("1/x", (-5.0, 5.0), (-5.0, 5.0));
        let curves = g.curves(Vector2::ZERO);
        assert_eq!(curves[0].len(), 2);
    }

    #[test]
    fn tangent_has_no_vertical_jumps() {
        let g = graph("tan(x)", (-5.0, 5.0), (-5.0, 5.0));
        for piece in &g.curves(Vector2::ZERO)[0] {
            for w in points(piece).windows(2) {
                // no segment spans the whole visible height
                assert!((w[1].y - w[0].y).abs() < 5.0 * 20.0);
            }
        }
    }

    #[test]
    fn logarithm_starts_right_of_zero() {
        let g = graph("ln(x)", (-2.0, 8.0), (-4.0, 4.0));
        let curve = &g.curves(Vector2::ZERO)[0];
        assert_eq!(curve.len(), 1);
        assert!(points(&curve[0]).iter().all(|p| p.x >= 0.0));
    }

    #[test]
    fn curves_stay_inside_the_range() {
        let g = graph("x^2", (-5.0, 5.0), (-1.0, 9.0));
        for piece in &g.curves(Vector2::ZERO)[0] {
            for p in points(piece) {
                assert!(p.x >= -100.0 - 1e-6 && p.x <= 100.0 + 1e-6);
                assert!(p.y >= -180.0 - 1e-6 && p.y <= 20.0 + 1e-6);
            }
        }
    }

    #[test]
    fn range_must_include_zero() {
        assert!(Range::new(1.0, 5.0).is_err());
        assert!(Range::new(3.0, -3.0).is_err());
        assert!(Range::new(0.0, 5.0).is_ok());
    }
}
