//! Recognition of hand-drawn strokes as ideal shapes.
//!
//! A stroke is classified from its geometry alone: straight lines (snapped to horizontal and vertical),
//! polylines, circular arcs, parabolas, cubic functions, triangles, rectangles, squares, regular polygons, stars,
//! circles and ellipses. Strokes that match none of them are smoothed.
//!
//! All tolerances are relative to the size of the stroke, so recognition behaves the same at every zoom level.

// Imports
use crate::PenPath;
use crate::ext::Vector2Ext;
use crate::penpath::{Element, Segment};
use kurbo::{Affine, BezPath, ParamCurve, Shape as _};
use p2d::math::Vector2;
use std::f64::consts::{FRAC_PI_2, PI, TAU};

/// The kind of a recognized shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecognizedKind {
    /// A straight line.
    Line,
    /// Connected straight lines.
    Polyline,
    /// A circular arc.
    Arc,
    /// The graph of a quadratic function.
    Parabola,
    /// The graph of a cubic function.
    Cubic,
    /// A smoothed open curve.
    Curve,
    /// A triangle.
    Triangle,
    /// A rectangle.
    Rectangle,
    /// A square.
    Square,
    /// Any other quadrilateral.
    Quadrilateral,
    /// A regular pentagon.
    Pentagon,
    /// A regular hexagon.
    Hexagon,
    /// A polygon that is not regular.
    Polygon,
    /// A five-pointed star.
    Star,
    /// A circle.
    Circle,
    /// An ellipse.
    Ellipse,
    /// A smoothed closed curve.
    ClosedCurve,
}

/// A shape recognized from a stroke.
#[derive(Debug, Clone)]
pub struct RecognizedShape {
    /// The kind.
    pub kind: RecognizedKind,
    /// The ideal outline.
    pub path: BezPath,
}

/// Number of points a stroke is resampled to before it is analyzed.
const N_SAMPLES: usize = 128;
/// Angle tolerance for snapping lines and edges to horizontal or vertical.
const AXIS_SNAP_TOL: f64 = 10.0 * PI / 180.0;
/// Minimum direction change for a point to count as a corner.
const CORNER_ANGLE_MIN: f64 = 38.0 * PI / 180.0;
/// Ends closer than this, relative to the stroke diagonal, close a stroke that turns at least half around.
const CLOSE_TOL: f64 = 0.2;
/// A stroke turning around at least this much is closed when its ends are closer than [CLOSE_GAP_MAX].
const CLOSE_WINDING: f64 = 1.25 * PI;
/// The largest gap between the ends of a stroke that is still closed, relative to the stroke diagonal.
const CLOSE_GAP_MAX: f64 = 0.6;
/// The largest mean distance between a stroke and a closed shape that still fits, relative to the stroke diagonal.
const CLOSED_FIT_TOL: f64 = 0.05;
/// Circles win over other closed shapes unless those fit clearly better, by this factor of the error.
const CIRCLE_PREFERENCE: f64 = 0.75;
/// Turns sharper than this close to the ends of open strokes are hooks, left by landing or lifting the pen.
const HOOK_ANGLE: f64 = 50.0 * PI / 180.0;

/// Options for the recognition.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecognitionOptions {
    /// How much a circle may be squashed and still become a circle instead of an ellipse, from 0 to 1.
    ///
    /// The ratio of the short to the long radius of a recognized ellipse is below `1 - circle_tolerance`.
    pub circle_tolerance: f64,
}

impl Default for RecognitionOptions {
    fn default() -> Self {
        Self {
            circle_tolerance: Self::CIRCLE_TOLERANCE_DEFAULT,
        }
    }
}

impl RecognitionOptions {
    /// The default circle tolerance.
    pub const CIRCLE_TOLERANCE_DEFAULT: f64 = 0.25;
}

impl RecognizedShape {
    /// Recognizes the shape of a stroke with the default options. `min_size` is the smallest diagonal a stroke
    /// must have.
    pub fn recognize(points: &[Vector2], min_size: f64) -> Option<Self> {
        Self::recognize_with(points, min_size, RecognitionOptions::default())
    }

    /// Recognizes the shape of a stroke. `min_size` is the smallest diagonal a stroke must have.
    pub fn recognize_with(
        points: &[Vector2],
        min_size: f64,
        options: RecognitionOptions,
    ) -> Option<Self> {
        let points = dedup(points);
        if points.len() < 2 {
            return None;
        }
        let (mins, maxs) = bounds(&points);
        let diag = (maxs - mins).length();
        if !diag.is_finite() || diag < min_size.max(1e-6) {
            return None;
        }
        let pts = resample(&points, N_SAMPLES);

        Some(match closed_part(&pts, diag) {
            Some(drawn) => recognize_closed(
                &resample_closed(&drawn, N_SAMPLES),
                &resample(&drawn, N_SAMPLES),
                diag,
                options,
            ),
            None => recognize_open(&pts, diag),
        })
    }

    /// Whether the shape is closed.
    pub fn is_closed(&self) -> bool {
        !matches!(
            self.kind,
            RecognizedKind::Line
                | RecognizedKind::Polyline
                | RecognizedKind::Arc
                | RecognizedKind::Parabola
                | RecognizedKind::Cubic
                | RecognizedKind::Curve
        )
    }

    /// The first point of the outline.
    pub fn start(&self) -> Vector2 {
        self.path
            .segments()
            .next()
            .map(|seg| Vector2::from_kurbo_point(seg.start()))
            .unwrap_or_default()
    }

    /// The last point of the outline.
    pub fn end(&self) -> Vector2 {
        self.path
            .segments()
            .last()
            .map(|seg| Vector2::from_kurbo_point(seg.end()))
            .unwrap_or_default()
    }

    /// The center of the bounding box.
    pub fn center(&self) -> Vector2 {
        Vector2::from_kurbo_point(self.path.bounding_box().center())
    }

    /// The shape adjusted to a pen that moved from `anchor` to `pos` after the shape was recognized.
    ///
    /// Lines end at the pen and keep snapping to horizontal and vertical. Other open shapes are rotated and scaled
    /// around their start so their end follows the pen, closed shapes are scaled around their center.
    pub fn adjusted(&self, anchor: Vector2, pos: Vector2) -> Self {
        let start = self.start();
        let affine = if self.kind == RecognizedKind::Line {
            let end = snap_line_end(start, pos);
            let mut path = BezPath::new();
            path.move_to(start.to_kurbo_point());
            path.line_to(end.to_kurbo_point());
            return Self {
                kind: self.kind,
                path,
            };
        } else if self.is_closed() {
            let center = self.center();
            let from = (anchor - center).length();
            if from < 1e-6 {
                return self.clone();
            }
            let scale = ((pos - center).length() / from).max(0.05);
            Affine::translate(center.to_kurbo_vec())
                * Affine::scale(scale)
                * Affine::translate(-center.to_kurbo_vec())
        } else {
            let from = anchor - start;
            let to = pos - start;
            if from.length() < 1e-6 || to.length() < 1e-6 {
                return self.clone();
            }
            let scale = to.length() / from.length();
            let angle = to.to_angle() - from.to_angle();
            Affine::translate(start.to_kurbo_vec())
                * Affine::rotate(angle)
                * Affine::scale(scale)
                * Affine::translate(-start.to_kurbo_vec())
        };
        Self {
            kind: self.kind,
            path: affine * &self.path,
        }
    }

    /// Converts the outline to a pen path of straight segments with constant pressure.
    ///
    /// Curves are flattened so the segments stay within `tolerance` of them. Brush styles render curved segments
    /// with only a few lines, so the shape would look like a polygon when zoomed in. Segments are also split so
    /// none is longer than `max_seg_len`, which keeps partial erasing precise.
    pub fn to_pen_path(&self, pressure: f64, max_seg_len: f64, tolerance: f64) -> Option<PenPath> {
        let max_seg_len = max_seg_len.max(1.0);
        let mut points: Vec<kurbo::Point> = Vec::new();
        kurbo::flatten(&self.path, tolerance.max(1e-4), |el| {
            let p = match el {
                kurbo::PathEl::MoveTo(p) | kurbo::PathEl::LineTo(p) => p,
                kurbo::PathEl::ClosePath => match points.first() {
                    Some(&first) => first,
                    None => return,
                },
                _ => return,
            };
            if points.last() != Some(&p) {
                points.push(p);
            }
        });

        let el = |p: kurbo::Point| Element::new(Vector2::from_kurbo_point(p), pressure);
        let mut segments = Vec::with_capacity(points.len());
        for pair in points.windows(2) {
            let n = (pair[0].distance(pair[1]) / max_seg_len)
                .ceil()
                .clamp(1.0, 512.0) as usize;
            for i in 1..=n {
                segments.push(Segment::LineTo {
                    end: el(pair[0].lerp(pair[1], i as f64 / n as f64)),
                });
            }
        }

        Some(PenPath::new_w_segments(el(*points.first()?), segments))
    }
}

fn recognize_open(pts: &[Vector2], diag: f64) -> RecognizedShape {
    if let Some(line) = line_shape(pts) {
        return line;
    }

    // Leave out the hooks where the pen landed or lifted
    let (from, to) = without_hooks(pts);
    let trimmed_hooks = (from, to) != (0, pts.len() - 1);
    let pts = &pts[from..=to];
    if trimmed_hooks && let Some(line) = line_shape(pts) {
        return line;
    }

    // Polyline, without the corners right at the ends
    let k = (pts.len() / 40).max(2);
    let mut corners = find_corners(pts, k, false);
    let hook = pts.len() * 8 / 100;
    let (mut from, mut to) = (0, pts.len() - 1);
    if corners.first().is_some_and(|c| *c <= hook) {
        from = corners.remove(0);
    }
    if corners.last().is_some_and(|c| *c + hook >= pts.len() - 1) {
        to = corners.pop().unwrap_or(to);
    }
    let trimmed = &pts[from..=to];
    if corners.is_empty() && (from, to) != (0, pts.len() - 1) {
        if let Some(line) = line_shape(trimmed) {
            return line;
        }
    } else if (1..=4).contains(&corners.len()) {
        let mut bounds = vec![0];
        bounds.extend(corners.iter().map(|c| c - from));
        bounds.push(trimmed.len() - 1);
        if let Some(vertices) = fit_polyline(trimmed, &bounds, k, diag) {
            return polyline_shape(RecognizedKind::Polyline, &vertices, false);
        }
    }

    // Arc and function graphs, the best fit wins
    let mut best: Option<(f64, RecognizedShape)> = None;
    let mut consider = |err: f64, shape: RecognizedShape| {
        if best.as_ref().is_none_or(|(e, _)| err < *e) {
            best = Some((err, shape));
        }
    };
    if let Some((err, shape)) = fit_arc(pts, diag) {
        consider(err, shape);
    }
    for axis in [Axis::X, Axis::Y] {
        if let Some(fits) = fit_function(pts, axis, diag) {
            for (err, shape) in fits {
                consider(err, shape);
            }
        }
    }
    if let Some((_, shape)) = best {
        return shape;
    }

    // Fallback: smooth the stroke
    RecognizedShape {
        kind: RecognizedKind::Curve,
        path: smooth_curve(pts, diag),
    }
}

/// The range of the stroke without the hooks where the pen landed or lifted: sharp turns close to its ends.
fn without_hooks(pts: &[Vector2]) -> (usize, usize) {
    let n = pts.len();
    let k = (n / 40).max(2);
    let zone = n / 10;
    if zone <= k || n < 4 * zone {
        return (0, n - 1);
    }
    let sharpest = |range: std::ops::RangeInclusive<usize>| {
        range
            .map(|i| (i, turning(pts, i, k, false).abs()))
            .max_by(|a, b| a.1.total_cmp(&b.1))
            .filter(|(_, turn)| *turn >= HOOK_ANGLE)
            .map(|(i, _)| i)
    };
    (
        sharpest(k..=zone).unwrap_or(0),
        sharpest(n - 1 - zone..=n - 1 - k).unwrap_or(n - 1),
    )
}

/// Smooths an open stroke between its key points: the ends, and the peaks and valleys where it turns back
/// horizontally or vertically. Key points stay where they were drawn, peaks and valleys get a level tangent.
fn smooth_curve(pts: &[Vector2], diag: f64) -> BezPath {
    let n = pts.len();
    let heavy = smooth(pts, 4, false);
    // positions of key points, smoothed only lightly so peaks are not flattened
    let light = smooth(pts, 1, false);
    let prominence = 0.04 * diag;
    let margin = 3;

    // the ends follow the direction the stroke starts and ends with, without the jitter of the first points
    let m = (n * 6 / 100).clamp(4, n - 1);
    let end_line = |part: &[Vector2], toward: Vector2, end: Vector2| {
        FitLine::fit(part).map(|mut line| {
            if line.dir.dot(toward) < 0.0 {
                line.dir = -line.dir;
            }
            (line.project(end), line.dir)
        })
    };
    let (start, start_dir) = end_line(&heavy[..=m], heavy[m] - heavy[0], light[0])
        .unwrap_or((light[0], end_tangent(&heavy, true)));
    let (end, end_dir) = end_line(
        &heavy[n - 1 - m..],
        heavy[n - 1] - heavy[n - 1 - m],
        light[n - 1],
    )
    .unwrap_or((light[n - 1], -end_tangent(&heavy, false)));

    // (index, tangent in drawing direction)
    let mut keys = vec![(0, start_dir)];
    let mut extrema = extrema_indices(&heavy.iter().map(|p| p.y).collect::<Vec<_>>(), prominence)
        .into_iter()
        .map(|i| (i, true))
        .chain(
            extrema_indices(&heavy.iter().map(|p| p.x).collect::<Vec<_>>(), prominence)
                .into_iter()
                .map(|i| (i, false)),
        )
        .filter(|(i, _)| *i >= margin && *i + margin < n)
        .collect::<Vec<_>>();
    extrema.sort_by_key(|(i, _)| *i);
    for (i, level_y) in extrema {
        let central = (heavy[(i + 2).min(n - 1)] - heavy[i.saturating_sub(2)]).normalize_or_zero();
        let tangent = if level_y {
            Vector2::new(central.x.signum(), 0.0)
        } else {
            Vector2::new(0.0, central.y.signum())
        };
        match keys.last_mut() {
            // a peak in x and y at once is a cusp, keep its own direction
            Some(last) if last.0 != 0 && i - last.0 < margin => last.1 = central,
            _ => keys.push((
                i,
                if central.length() > 0.0 {
                    tangent
                } else {
                    central
                },
            )),
        }
    }
    keys.push((n - 1, end_dir));

    let mut points = heavy;
    for (i, _) in &keys {
        points[*i] = light[*i];
    }
    points[0] = start;
    points[n - 1] = end;
    let mut path = BezPath::new();
    path.move_to(points[0].to_kurbo_point());
    for w in keys.windows(2) {
        let ((a, ta), (b, tb)) = (w[0], w[1]);
        fit_cubic(
            &points[a..=b],
            ta,
            -tb,
            (CURVE_FIT_TOL * diag).powi(2),
            &mut path,
            0,
        );
    }
    path
}

/// Indices of the peaks and valleys of the values that stand out by at least the prominence.
fn extrema_indices(values: &[f64], prominence: f64) -> Vec<usize> {
    let mut out = Vec::new();
    let (mut dir, mut hi, mut lo) = (0, 0, 0);
    for (i, v) in values.iter().enumerate().skip(1) {
        match dir {
            0 if v - values[0] >= prominence => (dir, hi) = (1, i),
            0 if values[0] - v >= prominence => (dir, lo) = (-1, i),
            1 if *v > values[hi] => hi = i,
            1 if values[hi] - v >= prominence => {
                out.push(hi);
                (dir, lo) = (-1, i);
            }
            -1 if *v < values[lo] => lo = i,
            -1 if v - values[lo] >= prominence => {
                out.push(lo);
                (dir, hi) = (1, i);
            }
            _ => {}
        }
    }
    out
}

/// Recognizes a closed stroke.
///
/// `ring` is the drawn stroke closed by a line between its ends, `drawn` only the drawn part. Sharp polygons are
/// recognized from their corners, everything else is compared with the ideal shapes and the closest one wins.
fn recognize_closed(
    ring: &[Vector2],
    drawn: &[Vector2],
    diag: f64,
    options: RecognitionOptions,
) -> RecognizedShape {
    let k = (ring.len() / 40).max(2);
    let corners = find_corners(ring, k, true);
    let turns = corners
        .iter()
        .map(|i| turning(ring, *i, k, true))
        .collect::<Vec<f64>>();
    let orientation = signed_area(ring).signum();

    // Polygons are convex, stars alternate between outer and inner corners
    let convex = turns.iter().all(|t| t.signum() == orientation);
    let alternating = |offset: usize| {
        turns
            .iter()
            .enumerate()
            .all(|(i, t)| (t.signum() == orientation) == (i % 2 == offset))
    };
    let star = corners.len() == 10 && (alternating(0) || alternating(1));

    if (convex && (5..=6).contains(&corners.len()) || star)
        && let Some(vertices) = fit_polygon(ring, &corners, k, diag)
    {
        return regularize_polygon(vertices, star);
    }

    let mut candidates = Vec::new();
    if convex
        && (3..=4).contains(&corners.len())
        && let Some(vertices) = fit_polygon(ring, &corners, k, diag)
    {
        candidates.push(regularize_polygon(vertices, false));
    }
    if let Some(vertices) = fit_triangle(drawn, diag) {
        candidates.push(regularize_polygon(vertices, false));
    }
    if let Some(vertices) = fit_quadrilateral(drawn, diag) {
        candidates.push(regularize_polygon(vertices, false));
    }
    candidates.extend(fit_circle_or_ellipse(drawn, diag, options.circle_tolerance));

    let best = candidates
        .into_iter()
        .map(|shape| (outline_error(drawn, &shape.path, diag) / diag, shape))
        .filter(|(err, _)| *err <= CLOSED_FIT_TOL)
        .min_by(|a, b| {
            let weight = |shape: &RecognizedShape| {
                if shape.kind == RecognizedKind::Circle {
                    CIRCLE_PREFERENCE
                } else {
                    1.0
                }
            };
            (a.0 * weight(&a.1)).total_cmp(&(b.0 * weight(&b.1)))
        });
    if let Some((_, shape)) = best {
        return shape;
    }

    // Fallback: smooth the stroke
    let smoothed = smooth(ring, 3, true);
    let seam = (smoothed[1] - smoothed[smoothed.len() - 1]).normalize_or_zero();
    let mut closed = smoothed.clone();
    closed.push(smoothed[0]);
    RecognizedShape {
        kind: RecognizedKind::ClosedCurve,
        path: fit_beziers(&closed, seam, -seam, CURVE_FIT_TOL * diag),
    }
}

/// The largest triangle in the stroke, with its edges fitted to the stroke.
fn fit_triangle(drawn: &[Vector2], diag: f64) -> Option<Vec<Vector2>> {
    let hull = convex_hull(drawn);
    let h = hull.len();
    if h < 3 {
        return None;
    }
    let area = |a: Vector2, b: Vector2, c: Vector2| (b - a).perp_dot(c - a).abs();
    let mut best = (0.0, [0, 1, 2]);
    for i in 0..h {
        for j in i + 1..h {
            for l in j + 1..h {
                let a = area(hull[i], hull[j], hull[l]);
                if a > best.0 {
                    best = (a, [i, j, l]);
                }
            }
        }
    }
    if best.0 < 1e-9 {
        return None;
    }
    Some(refine_polygon(
        drawn,
        best.1.map(|i| hull[i]).to_vec(),
        diag,
    ))
}

/// The quadrilateral around the stroke, oriented along its dominant directions, with its edges fitted to the stroke.
fn fit_quadrilateral(drawn: &[Vector2], diag: f64) -> Option<Vec<Vector2>> {
    // dominant edge direction modulo a quarter turn, weighted by length
    let (sin, cos) = drawn.windows(2).fold((0.0, 0.0), |(s, c), w| {
        let d = w[1] - w[0];
        let a = d.to_angle() * 4.0;
        (s + a.sin() * d.length(), c + a.cos() * d.length())
    });
    let angle = sin.atan2(cos) / 4.0;
    let (u, v) = (
        Vector2::from_angle(angle),
        Vector2::from_angle(angle).perp(),
    );
    let (mut x0, mut x1, mut y0, mut y1) = (
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
    );
    for p in drawn {
        (x0, x1) = (x0.min(p.dot(u)), x1.max(p.dot(u)));
        (y0, y1) = (y0.min(p.dot(v)), y1.max(p.dot(v)));
    }
    if x1 - x0 < 1e-6 || y1 - y0 < 1e-6 {
        return None;
    }
    let corner = |x: f64, y: f64| u * x + v * y;
    let vertices = vec![
        corner(x0, y0),
        corner(x1, y0),
        corner(x1, y1),
        corner(x0, y1),
    ];
    Some(refine_polygon(drawn, vertices, diag))
}

/// Fits each edge of the polygon to the stroke points closest to it, leaving out the rounded corners.
///
/// Edges without enough points keep their position.
fn refine_polygon(drawn: &[Vector2], vertices: Vec<Vector2>, diag: f64) -> Vec<Vector2> {
    let n = vertices.len();
    let mut groups = vec![Vec::new(); n];
    for p in drawn {
        let (edge, t) = (0..n)
            .map(|i| {
                let (a, b) = (vertices[i], vertices[(i + 1) % n]);
                let d = b - a;
                let t = ((*p - a).dot(d) / d.length_squared().max(1e-12)).clamp(0.0, 1.0);
                (i, t, (*p - (a + d * t)).length())
            })
            .min_by(|a, b| a.2.total_cmp(&b.2))
            .map(|(i, t, _)| (i, t))
            .unwrap_or((0, 0.0));
        if (0.15..=0.85).contains(&t) {
            groups[edge].push(*p);
        }
    }
    let lines = (0..n)
        .map(|i| {
            let (a, b) = (vertices[i], vertices[(i + 1) % n]);
            let mut line = if groups[i].len() >= 4 {
                FitLine::fit(&groups[i])
            } else {
                None
            }
            .unwrap_or(FitLine {
                point: a,
                dir: (b - a).normalize_or_zero(),
            });
            if line.dir.dot(b - a) < 0.0 {
                line.dir = -line.dir;
            }
            line.dir = snap_dir(line.dir);
            line
        })
        .collect::<Vec<_>>();
    let refined = (0..n)
        .map(|i| lines[(i + n - 1) % n].intersect(&lines[i]))
        .collect::<Option<Vec<_>>>();
    match refined {
        Some(refined)
            if refined
                .iter()
                .zip(&vertices)
                .all(|(r, v)| (*r - *v).length() < 0.3 * diag) =>
        {
            refined
        }
        _ => vertices,
    }
}

/// Mean distance from the stroke points to the outline of the shape.
fn outline_error(drawn: &[Vector2], path: &BezPath, diag: f64) -> f64 {
    let outline = flatten_outline(path, 0.002 * diag);
    drawn
        .iter()
        .map(|p| dist_to_outline(*p, &outline))
        .sum::<f64>()
        / drawn.len().max(1) as f64
}

fn flatten_outline(path: &BezPath, tolerance: f64) -> Vec<Vector2> {
    let mut outline = Vec::new();
    kurbo::flatten(path, tolerance.max(1e-3), |el| match el {
        kurbo::PathEl::MoveTo(p) | kurbo::PathEl::LineTo(p) => {
            outline.push(Vector2::from_kurbo_point(p))
        }
        _ => {}
    });
    outline
}

fn dist_to_outline(p: Vector2, outline: &[Vector2]) -> f64 {
    if outline.len() == 1 {
        return (p - outline[0]).length();
    }
    outline
        .windows(2)
        .map(|w| {
            let d = w[1] - w[0];
            let t = ((p - w[0]).dot(d) / d.length_squared().max(1e-12)).clamp(0.0, 1.0);
            (p - (w[0] + d * t)).length()
        })
        .fold(f64::INFINITY, f64::min)
}

/// Convex hull with Andrew's monotone chain, counterclockwise.
fn convex_hull(points: &[Vector2]) -> Vec<Vector2> {
    let mut pts = points.to_vec();
    pts.sort_by(|a, b| a.x.total_cmp(&b.x).then(a.y.total_cmp(&b.y)));
    pts.dedup_by(|a, b| (*a - *b).length() < 1e-9);
    if pts.len() < 3 {
        return pts;
    }
    let cross = |o: Vector2, a: Vector2, b: Vector2| (a - o).perp_dot(b - o);
    let mut hull: Vec<Vector2> = Vec::with_capacity(pts.len() * 2);
    for pass in 0..2 {
        let start = hull.len();
        let iter: Box<dyn Iterator<Item = &Vector2>> = if pass == 0 {
            Box::new(pts.iter())
        } else {
            Box::new(pts.iter().rev())
        };
        for p in iter {
            while hull.len() >= start + 2
                && cross(hull[hull.len() - 2], hull[hull.len() - 1], *p) <= 0.0
            {
                hull.pop();
            }
            hull.push(*p);
        }
        hull.pop();
    }
    hull
}

/// Total signed direction change along the polyline.
fn winding(points: &[Vector2]) -> f64 {
    points
        .windows(3)
        .map(|w| {
            let (a, b) = (w[1] - w[0], w[2] - w[1]);
            a.perp_dot(b).atan2(a.dot(b))
        })
        .sum()
}

/// A straight line, snapped to horizontal or vertical, when the points are straight.
fn line_shape(pts: &[Vector2]) -> Option<RecognizedShape> {
    let (first, last) = (pts[0], pts[pts.len() - 1]);
    let chord = (last - first).length();
    if chord <= 0.0 || path_length(pts) > 1.2 * chord {
        return None;
    }
    let max_dev = pts
        .iter()
        .map(|p| dist_to_line(*p, first, last))
        .fold(0.0, f64::max);
    (max_dev <= 0.07 * chord).then(|| {
        polyline_shape(
            RecognizedKind::Line,
            &[first, snap_line_end(first, last)],
            false,
        )
    })
}

/// Snaps the end of a line so the line becomes horizontal or vertical when it nearly is.
fn snap_line_end(start: Vector2, end: Vector2) -> Vector2 {
    let d = end - start;
    if d.length() < 1e-9 {
        return end;
    }
    let snapped = snap_dir(d.normalize());
    start + snapped * d.dot(snapped)
}

/// Snaps a unit direction to horizontal or vertical when it is within the tolerance.
fn snap_dir(dir: Vector2) -> Vector2 {
    let angle = dir.to_angle();
    let quarter = (angle / FRAC_PI_2).round() * FRAC_PI_2;
    if (angle - quarter).abs() <= AXIS_SNAP_TOL {
        Vector2::from_angle(quarter)
    } else {
        dir
    }
}

fn polyline_shape(kind: RecognizedKind, vertices: &[Vector2], closed: bool) -> RecognizedShape {
    let mut path = BezPath::new();
    for (i, v) in vertices.iter().enumerate() {
        if i == 0 {
            path.move_to(v.to_kurbo_point());
        } else {
            path.line_to(v.to_kurbo_point());
        }
    }
    if closed && let Some(first) = vertices.first() {
        path.line_to(first.to_kurbo_point());
    }
    RecognizedShape { kind, path }
}

/// Fits straight lines between the boundary indices, returns the vertices where the lines meet.
///
/// Fails when a part is not straight.
fn fit_polyline(pts: &[Vector2], bounds: &[usize], k: usize, diag: f64) -> Option<Vec<Vector2>> {
    let lines = bounds
        .windows(2)
        .map(|w| fit_edge(pts, w[0], w[1], k, diag, false))
        .collect::<Option<Vec<FitLine>>>()?;
    let total = path_length(pts);
    if bounds
        .windows(2)
        .any(|w| (pts[w[1]] - pts[w[0]]).length() < 0.1 * total)
    {
        return None;
    }

    let mut vertices = vec![lines[0].project(pts[0])];
    for w in lines.windows(2) {
        vertices.push(w[0].intersect(&w[1])?);
    }
    vertices.push(lines[lines.len() - 1].project(pts[pts.len() - 1]));
    Some(vertices)
}

/// Fits straight edges between consecutive corners of a closed ring, returns the vertices where they meet.
fn fit_polygon(ring: &[Vector2], corners: &[usize], k: usize, diag: f64) -> Option<Vec<Vector2>> {
    let n = corners.len();
    let edges = (0..n)
        .map(|i| fit_edge(ring, corners[i], corners[(i + 1) % n], k, diag, true))
        .collect::<Option<Vec<FitLine>>>()?;
    let vertices = (0..n)
        .map(|i| edges[(i + n - 1) % n].intersect(&edges[i]))
        .collect::<Option<Vec<Vector2>>>()?;

    // intersections of nearly parallel edges can end up far away
    let (mins, maxs) = bounds(ring);
    let center = (mins + maxs) * 0.5;
    if vertices.iter().any(|v| (*v - center).length() > diag) {
        return None;
    }
    Some(vertices)
}

/// Fits a line to the points between two indices, checking that they are straight.
fn fit_edge(
    pts: &[Vector2],
    from: usize,
    to: usize,
    k: usize,
    diag: f64,
    cyclic: bool,
) -> Option<FitLine> {
    let n = pts.len();
    let count = if cyclic {
        (to + n - from) % n
    } else {
        to - from
    };
    if count < 2 {
        return None;
    }
    let edge = (0..=count).map(|i| pts[(from + i) % n]).collect::<Vec<_>>();
    let (a, b) = (edge[0], edge[edge.len() - 1]);
    let len = (b - a).length();
    let max_dev = edge
        .iter()
        .map(|p| dist_to_line(*p, a, b))
        .fold(0.0, f64::max);
    if len < 1e-6 || max_dev > (0.07 * len).max(0.02 * diag) {
        return None;
    }
    // leave out the points around the corners, they are rounded when drawn by hand
    let trim = (k / 2).min(edge.len() / 4);
    let inner = &edge[trim..edge.len() - trim];
    let mut line = FitLine::fit(if inner.len() >= 2 { inner } else { &edge })?;
    if line.dir.dot(b - a) < 0.0 {
        line.dir = -line.dir;
    }
    line.dir = snap_dir(line.dir);
    Some(line)
}

fn regularize_polygon(vertices: Vec<Vector2>, star: bool) -> RecognizedShape {
    let n = vertices.len();
    let centroid = vertices.iter().copied().sum::<Vector2>() / n as f64;
    let radii = vertices
        .iter()
        .map(|v| (*v - centroid).length())
        .collect::<Vec<f64>>();
    let sides = (0..n)
        .map(|i| (vertices[(i + 1) % n] - vertices[i]).length())
        .collect::<Vec<f64>>();
    let uniform = |values: &[f64], tol: f64| {
        let mean = values.iter().sum::<f64>() / values.len() as f64;
        values.iter().all(|v| (v - mean).abs() <= tol * mean)
    };

    if star {
        // the outer corners are the ones farther from the center
        let offset = if radii[0] > radii[1] { 0 } else { 1 };
        let outer = (0..5).map(|i| radii[2 * i + offset]).sum::<f64>() / 5.0;
        let inner = (0..5).map(|i| radii[2 * i + 1 - offset]).sum::<f64>() / 5.0;
        let rotation = snap_rotation((vertices[offset] - centroid).to_angle(), 5);
        let inner = inner.clamp(0.25 * outer, 0.7 * outer);
        let points = (0..10)
            .map(|i| {
                let r = if i % 2 == 0 { outer } else { inner };
                centroid + Vector2::from_angle(rotation + i as f64 * PI / 5.0) * r
            })
            .collect::<Vec<_>>();
        return polyline_shape(RecognizedKind::Star, &points, true);
    }

    match n {
        3 if uniform(&sides, 0.12) => {
            regular_polygon(RecognizedKind::Triangle, &vertices, centroid)
        }
        3 => polyline_shape(RecognizedKind::Triangle, &vertices, true),
        4 => {
            let right_angles = (0..n).all(|i| {
                let a = vertices[(i + n - 1) % n] - vertices[i];
                let b = vertices[(i + 1) % n] - vertices[i];
                (a.normalize().dot(b.normalize())).abs() < (15.0_f64.to_radians()).sin()
            });
            if right_angles {
                rectangle(&vertices, centroid)
            } else {
                polyline_shape(RecognizedKind::Quadrilateral, &vertices, true)
            }
        }
        5 | 6 if uniform(&sides, 0.3) && uniform(&radii, 0.2) => {
            let kind = if n == 5 {
                RecognizedKind::Pentagon
            } else {
                RecognizedKind::Hexagon
            };
            regular_polygon(kind, &vertices, centroid)
        }
        _ => polyline_shape(RecognizedKind::Polygon, &vertices, true),
    }
}

/// Snaps the angle of a vertex of a regular polygon so the polygon stands upright, if it nearly does.
fn snap_rotation(angle: f64, n: usize) -> f64 {
    let step = TAU / n as f64;
    // a vertex pointing straight up, or an edge lying flat at the top
    [-FRAC_PI_2, -FRAC_PI_2 + step * 0.5]
        .into_iter()
        .find_map(|upright| {
            let delta = (angle - upright).rem_euclid(step);
            let delta = if delta > step * 0.5 {
                delta - step
            } else {
                delta
            };
            (delta.abs() <= AXIS_SNAP_TOL).then_some(angle - delta)
        })
        .unwrap_or(angle)
}

fn regular_polygon(
    kind: RecognizedKind,
    vertices: &[Vector2],
    centroid: Vector2,
) -> RecognizedShape {
    let n = vertices.len();
    let radius = vertices
        .iter()
        .map(|v| (*v - centroid).length())
        .sum::<f64>()
        / n as f64;
    let rotation = snap_rotation((vertices[0] - centroid).to_angle(), n);
    let orientation = signed_area(vertices).signum();
    let points = (0..n)
        .map(|i| {
            centroid
                + Vector2::from_angle(rotation + orientation * i as f64 * TAU / n as f64) * radius
        })
        .collect::<Vec<_>>();
    polyline_shape(kind, &points, true)
}

fn rectangle(vertices: &[Vector2], centroid: Vector2) -> RecognizedShape {
    // mean edge direction, modulo a quarter turn
    let (sin, cos) = (0..4).fold((0.0, 0.0), |(s, c), i| {
        let a = (vertices[(i + 1) % 4] - vertices[i]).to_angle() * 4.0;
        (s + a.sin(), c + a.cos())
    });
    let mut angle = sin.atan2(cos) / 4.0;
    let quarter = (angle / FRAC_PI_2).round() * FRAC_PI_2;
    if (angle - quarter).abs() <= AXIS_SNAP_TOL {
        angle = quarter;
    }
    let (u, v) = (
        Vector2::from_angle(angle),
        Vector2::from_angle(angle).perp(),
    );
    let mut xs = vertices
        .iter()
        .map(|p| (*p - centroid).dot(u))
        .collect::<Vec<_>>();
    let mut ys = vertices
        .iter()
        .map(|p| (*p - centroid).dot(v))
        .collect::<Vec<_>>();
    xs.sort_by(f64::total_cmp);
    ys.sort_by(f64::total_cmp);
    let (x0, x1) = ((xs[0] + xs[1]) * 0.5, (xs[2] + xs[3]) * 0.5);
    let (y0, y1) = ((ys[0] + ys[1]) * 0.5, (ys[2] + ys[3]) * 0.5);
    let mid = centroid + u * ((x0 + x1) * 0.5) + v * ((y0 + y1) * 0.5);
    let (mut w, mut h) = (x1 - x0, y1 - y0);
    let kind = if (w - h).abs() <= 0.12 * w.max(h) {
        w = (w + h) * 0.5;
        h = w;
        RecognizedKind::Square
    } else {
        RecognizedKind::Rectangle
    };
    let corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
        .map(|(sx, sy)| mid + u * (sx * w * 0.5) + v * (sy * h * 0.5));
    polyline_shape(kind, &corners, true)
}

/// The circle and, when it is not round, the ellipse that fit the stroke. The stroke may leave a gap.
fn fit_circle_or_ellipse(
    drawn: &[Vector2],
    diag: f64,
    circle_tolerance: f64,
) -> Vec<RecognizedShape> {
    let mut shapes = Vec::new();
    if let Some((center, radius)) = fit_circle(drawn, diag)
        && radius <= 2.0 * diag
    {
        shapes.push(RecognizedShape {
            kind: RecognizedKind::Circle,
            path: kurbo::Circle::new(center.to_kurbo_point(), radius).to_path(1e-3),
        });
    }
    if let Some((center, (rx, ry), mut rotation)) = fit_conic_ellipse(drawn, diag)
        && rx.min(ry) / rx.max(ry) < 1.0 - circle_tolerance.clamp(0.0, 1.0)
        && rx.max(ry) <= 2.0 * diag
    {
        let quarter = (rotation / FRAC_PI_2).round() * FRAC_PI_2;
        if (rotation - quarter).abs() <= AXIS_SNAP_TOL {
            rotation = quarter;
        }
        shapes.push(RecognizedShape {
            kind: RecognizedKind::Ellipse,
            path: kurbo::Ellipse::new(center.to_kurbo_point(), (rx, ry), rotation).to_path(1e-3),
        });
    }
    shapes
}

/// Least squares conic a·x² + b·xy + c·y² + d·x + e·y = 1 around the mean, when it is an ellipse.
///
/// Returns the center, the radii and the rotation.
fn fit_conic_ellipse(pts: &[Vector2], diag: f64) -> Option<(Vector2, (f64, f64), f64)> {
    let n = pts.len() as f64;
    let mean = pts.iter().copied().sum::<Vector2>() / n;
    let mut m = [[0.0; 5]; 5];
    let mut r = [0.0; 5];
    for p in pts {
        let q = (*p - mean) / diag;
        let row = [q.x * q.x, q.x * q.y, q.y * q.y, q.x, q.y];
        for i in 0..5 {
            for j in 0..5 {
                m[i][j] += row[i] * row[j];
            }
            r[i] += row[i];
        }
    }
    let [a, b, c, d, e] = solve(m, r)?;
    if b * b - 4.0 * a * c >= 0.0 {
        return None;
    }
    let [cx, cy] = solve([[2.0 * a, b], [b, 2.0 * c]], [-d, -e])?;
    let f0 = a * cx * cx + b * cx * cy + c * cy * cy + d * cx + e * cy - 1.0;
    let rotation = 0.5 * b.atan2(a - c);
    let (sin, cos) = rotation.sin_cos();
    let l1 = a * cos * cos + b * sin * cos + c * sin * sin;
    let l2 = a * sin * sin - b * sin * cos + c * cos * cos;
    let (r1, r2) = (-f0 / l1, -f0 / l2);
    if r1 <= 0.0 || r2 <= 0.0 {
        return None;
    }
    Some((
        mean + Vector2::new(cx, cy) * diag,
        (r1.sqrt() * diag, r2.sqrt() * diag),
        rotation,
    ))
}

/// Algebraic circle fit of x² + y² + d·x + e·y + f = 0, works for arcs too. Returns the center and radius.
fn fit_circle(pts: &[Vector2], diag: f64) -> Option<(Vector2, f64)> {
    // around the mean for numerical stability
    let n = pts.len() as f64;
    let mean = pts.iter().copied().sum::<Vector2>() / n;
    let mut m = [[0.0; 3]; 3];
    let mut r = [0.0; 3];
    for p in pts {
        let q = (*p - mean) / diag;
        let row = [q.x, q.y, 1.0];
        let rhs = -(q.x * q.x + q.y * q.y);
        for i in 0..3 {
            for j in 0..3 {
                m[i][j] += row[i] * row[j];
            }
            r[i] += row[i] * rhs;
        }
    }
    let [d, e, f] = solve(m, r)?;
    let c = Vector2::new(-d * 0.5, -e * 0.5);
    let radius_sq = c.length_squared() - f;
    (radius_sq > 0.0).then(|| (mean + c * diag, radius_sq.sqrt() * diag))
}

/// Fits a circular arc, returns the normalized error with the arc.
fn fit_arc(pts: &[Vector2], diag: f64) -> Option<(f64, RecognizedShape)> {
    let n = pts.len() as f64;
    let (center, radius) = fit_circle(pts, diag)?;
    if radius > 4.0 * diag {
        return None;
    }

    let rms = (pts
        .iter()
        .map(|p| ((*p - center).length() - radius).powi(2))
        .sum::<f64>()
        / n)
        .sqrt();
    let sweep = pts
        .windows(2)
        .map(|w| {
            let (a, b) = (w[0] - center, w[1] - center);
            a.perp_dot(b).atan2(a.dot(b))
        })
        .sum::<f64>();
    if rms > 0.025 * radius || sweep.abs() < 30.0_f64.to_radians() || sweep.abs() > TAU * 0.95 {
        return None;
    }

    let start_angle = (pts[0] - center).to_angle();
    let arc = kurbo::Arc::new(
        center.to_kurbo_point(),
        (radius, radius),
        start_angle,
        sweep,
        0.0,
    );
    let path = arc.to_path(1e-3);
    Some((
        rms / diag,
        RecognizedShape {
            kind: RecognizedKind::Arc,
            path,
        },
    ))
}

#[derive(Debug, Clone, Copy)]
enum Axis {
    X,
    Y,
}

impl Axis {
    /// Splits a point into the coordinate along and across the axis.
    fn split(self, p: Vector2) -> (f64, f64) {
        match self {
            Self::X => (p.x, p.y),
            Self::Y => (p.y, p.x),
        }
    }

    fn join(self, along: f64, across: f64) -> Vector2 {
        match self {
            Self::X => Vector2::new(along, across),
            Self::Y => Vector2::new(across, along),
        }
    }
}

/// Fits quadratic and cubic functions over the axis, when the stroke is the graph of a function over it.
///
/// Returns the acceptable fits with their normalized errors.
fn fit_function(pts: &[Vector2], axis: Axis, diag: f64) -> Option<Vec<(f64, RecognizedShape)>> {
    let (u_first, _) = axis.split(pts[0]);
    let (u_last, _) = axis.split(pts[pts.len() - 1]);
    let total = u_last - u_first;
    if total.abs() < 0.3 * diag {
        return None;
    }
    let backtrack = pts
        .windows(2)
        .map(|w| ((axis.split(w[1]).0 - axis.split(w[0]).0) * -total.signum()).max(0.0))
        .sum::<f64>();
    if backtrack > 0.03 * total.abs() {
        return None;
    }

    // fit in normalized coordinates s ∈ [-1, 1]
    let mid = (u_first + u_last) * 0.5;
    let half = total * 0.5;
    let samples = pts
        .iter()
        .map(|p| {
            let (u, v) = axis.split(*p);
            ((u - mid) / half, v)
        })
        .collect::<Vec<_>>();

    let mut fits = Vec::new();
    let quad = fit_poly::<3>(&samples)?;
    let cubic = fit_poly::<4>(&samples)?;
    let err2 = poly_rms(&samples, &quad) / diag;
    let err3 = poly_rms(&samples, &cubic) / diag;
    // the graph must also stay close everywhere, not only on average
    let close = |c: &[f64]| {
        samples.iter().all(|(s, v)| {
            let y = c.iter().rev().fold(0.0, |acc, ci| acc * s + ci);
            (y - v).abs() <= 0.045 * diag
        })
    };

    const TOL: f64 = 0.015;
    if err2 <= TOL && close(&quad) {
        let coeffs = [quad[0], quad[1], quad[2], 0.0];
        fits.push((
            err2,
            poly_shape(RecognizedKind::Parabola, axis, mid, half, coeffs),
        ));
    }
    if err3 <= TOL && err3 < 0.6 * err2 && close(&cubic) {
        // a cubic has more freedom, so it has to be clearly better to win
        fits.push((
            err3 * 1.5,
            poly_shape(RecognizedKind::Cubic, axis, mid, half, cubic),
        ));
    }
    Some(fits)
}

/// The cubic Bézier that is exactly the graph of the polynomial with the coefficients over s ∈ [-1, 1].
fn poly_shape(
    kind: RecognizedKind,
    axis: Axis,
    mid: f64,
    half: f64,
    c: [f64; 4],
) -> RecognizedShape {
    // v(t) with s = 2t - 1, in the power basis of t
    let (s0, d): (f64, f64) = (-1.0, 2.0);
    let mut a = [0.0; 4];
    let binomial = [
        [1.0, 0.0, 0.0, 0.0],
        [1.0, 1.0, 0.0, 0.0],
        [1.0, 2.0, 1.0, 0.0],
        [1.0, 3.0, 3.0, 1.0],
    ];
    for (k, ck) in c.iter().enumerate() {
        for j in 0..=k {
            a[j] += ck * binomial[k][j] * s0.powi((k - j) as i32) * d.powi(j as i32);
        }
    }
    // power basis to Bernstein basis
    let b = [
        a[0],
        a[0] + a[1] / 3.0,
        a[0] + 2.0 * a[1] / 3.0 + a[2] / 3.0,
        a[0] + a[1] + a[2] + a[3],
    ];
    let p = |i: usize| {
        let u = mid + half * (2.0 * i as f64 / 3.0 - 1.0);
        axis.join(u, b[i]).to_kurbo_point()
    };
    let mut path = BezPath::new();
    path.move_to(p(0));
    path.curve_to(p(1), p(2), p(3));
    RecognizedShape { kind, path }
}

/// Least squares polynomial fit with N coefficients, in increasing order.
fn fit_poly<const N: usize>(samples: &[(f64, f64)]) -> Option<[f64; N]> {
    let mut m = [[0.0; N]; N];
    let mut r = [0.0; N];
    for (s, v) in samples {
        let mut powers = [1.0; N];
        for i in 1..N {
            powers[i] = powers[i - 1] * s;
        }
        for i in 0..N {
            for j in 0..N {
                m[i][j] += powers[i] * powers[j];
            }
            r[i] += powers[i] * v;
        }
    }
    solve(m, r)
}

fn poly_rms<const N: usize>(samples: &[(f64, f64)], c: &[f64; N]) -> f64 {
    let sum = samples
        .iter()
        .map(|(s, v)| {
            let y = c.iter().rev().fold(0.0, |acc, ci| acc * s + ci);
            (y - v).powi(2)
        })
        .sum::<f64>();
    (sum / samples.len() as f64).sqrt()
}

/// Solves the linear system with gaussian elimination.
fn solve<const N: usize>(mut m: [[f64; N]; N], mut r: [f64; N]) -> Option<[f64; N]> {
    for col in 0..N {
        let pivot = (col..N).max_by(|a, b| m[*a][col].abs().total_cmp(&m[*b][col].abs()))?;
        if m[pivot][col].abs() < 1e-12 {
            return None;
        }
        m.swap(col, pivot);
        r.swap(col, pivot);
        let pivot_row = m[col];
        for row in col + 1..N {
            let factor = m[row][col] / pivot_row[col];
            for (value, pivot_value) in m[row].iter_mut().zip(pivot_row).skip(col) {
                *value -= factor * pivot_value;
            }
            r[row] -= factor * r[col];
        }
    }
    let mut x = [0.0; N];
    for row in (0..N).rev() {
        let sum = (row + 1..N).map(|k| m[row][k] * x[k]).sum::<f64>();
        x[row] = (r[row] - sum) / m[row][row];
    }
    x.iter().all(|v| v.is_finite()).then_some(x)
}

/// A line through a point.
#[derive(Debug, Clone, Copy)]
struct FitLine {
    point: Vector2,
    dir: Vector2,
}

impl FitLine {
    /// Total least squares fit.
    fn fit(pts: &[Vector2]) -> Option<Self> {
        let n = pts.len() as f64;
        let point = pts.iter().copied().sum::<Vector2>() / n;
        let (mut sxx, mut sxy, mut syy) = (0.0, 0.0, 0.0);
        for p in pts {
            let d = *p - point;
            sxx += d.x * d.x;
            sxy += d.x * d.y;
            syy += d.y * d.y;
        }
        if sxx + syy < 1e-12 {
            return None;
        }
        let angle = 0.5 * (2.0 * sxy).atan2(sxx - syy);
        Some(Self {
            point,
            dir: Vector2::from_angle(angle),
        })
    }

    fn project(&self, p: Vector2) -> Vector2 {
        self.point + self.dir * (p - self.point).dot(self.dir)
    }

    fn intersect(&self, other: &Self) -> Option<Vector2> {
        let denom = self.dir.perp_dot(other.dir);
        if denom.abs() < 0.1 {
            return None;
        }
        let t = (other.point - self.point).perp_dot(other.dir) / denom;
        Some(self.point + self.dir * t)
    }
}

/// Signed direction change at index `i`, measured over `k` points to each side.
fn turning(pts: &[Vector2], i: usize, k: usize, cyclic: bool) -> f64 {
    let n = pts.len();
    let (prev, next) = if cyclic {
        (pts[(i + n - k) % n], pts[(i + k) % n])
    } else {
        (pts[i.saturating_sub(k)], pts[(i + k).min(n - 1)])
    };
    let (a, b) = (pts[i] - prev, next - pts[i]);
    a.perp_dot(b).atan2(a.dot(b))
}

/// Indices of the corners, where the direction changes sharply.
fn find_corners(pts: &[Vector2], k: usize, cyclic: bool) -> Vec<usize> {
    let n = pts.len();
    if n < 2 * k + 1 {
        return vec![];
    }
    let range = if cyclic { 0..n } else { k..n - k };
    let turns = (0..n)
        .map(|i| turning(pts, i, k, cyclic).abs())
        .collect::<Vec<f64>>();
    range
        .filter(|&i| {
            turns[i] >= CORNER_ANGLE_MIN
                && (1..=k).all(|d| {
                    let before = if cyclic {
                        (i + n - d) % n
                    } else {
                        i.saturating_sub(d)
                    };
                    let after = if cyclic {
                        (i + d) % n
                    } else {
                        (i + d).min(n - 1)
                    };
                    turns[i] > turns[before] && turns[i] >= turns[after]
                })
        })
        .collect()
}

/// The part of the stroke that forms a closed ring, without the overshoot past the start.
fn closed_part(pts: &[Vector2], diag: f64) -> Option<Vec<Vector2>> {
    let n = pts.len();
    let (end, dist) = (n * 3 / 5..n)
        .map(|i| (i, (pts[i] - pts[0]).length()))
        .min_by(|a, b| a.1.total_cmp(&b.1))?;
    // the stroke must go around, not just come back
    let part = &pts[..=end];
    let len = path_length(part);
    let turned = winding(&smooth(part, 2, false)).abs();
    let closed = len >= 1.5 * diag
        && (dist <= CLOSE_TOL * diag && turned >= PI
            || dist <= CLOSE_GAP_MAX * diag && turned >= CLOSE_WINDING);
    closed.then(|| part.to_vec())
}

fn dedup(points: &[Vector2]) -> Vec<Vector2> {
    let mut out: Vec<Vector2> = Vec::with_capacity(points.len());
    for p in points {
        if p.is_finite() && out.last().is_none_or(|last| (*p - *last).length() > 1e-9) {
            out.push(*p);
        }
    }
    out
}

fn bounds(points: &[Vector2]) -> (Vector2, Vector2) {
    points.iter().fold(
        (
            Vector2::splat(f64::INFINITY),
            Vector2::splat(f64::NEG_INFINITY),
        ),
        |(mins, maxs), p| (mins.min(*p), maxs.max(*p)),
    )
}

fn path_length(points: &[Vector2]) -> f64 {
    points.windows(2).map(|w| (w[1] - w[0]).length()).sum()
}

fn signed_area(points: &[Vector2]) -> f64 {
    let n = points.len();
    (0..n)
        .map(|i| points[i].perp_dot(points[(i + 1) % n]))
        .sum::<f64>()
        * 0.5
}

fn dist_to_line(p: Vector2, a: Vector2, b: Vector2) -> f64 {
    let d = b - a;
    let len = d.length();
    if len < 1e-12 {
        (p - a).length()
    } else {
        d.perp_dot(p - a).abs() / len
    }
}

/// Resamples the polyline to `n` points at equal distances along it.
fn resample(points: &[Vector2], n: usize) -> Vec<Vector2> {
    let total = path_length(points);
    if total <= 0.0 || n < 2 {
        return vec![points[0]; n.max(1)];
    }
    let step = total / (n - 1) as f64;
    let mut out = Vec::with_capacity(n);
    out.push(points[0]);
    let mut acc = 0.0;
    let mut target = step;
    for w in points.windows(2) {
        let seg = (w[1] - w[0]).length();
        while acc + seg >= target && out.len() < n - 1 {
            let t = (target - acc) / seg;
            out.push(w[0] + (w[1] - w[0]) * t);
            target += step;
        }
        acc += seg;
    }
    out.push(points[points.len() - 1]);
    out
}

/// Resamples a closed ring to `n` points, the closing point is not repeated.
fn resample_closed(ring: &[Vector2], n: usize) -> Vec<Vector2> {
    let mut closed = ring.to_vec();
    closed.push(ring[0]);
    let mut out = resample(&closed, n + 1);
    out.pop();
    out
}

/// Moving average smoothing.
fn smooth(points: &[Vector2], passes: usize, cyclic: bool) -> Vec<Vector2> {
    const RADIUS: usize = 2;
    let n = points.len();
    let mut cur = points.to_vec();
    for _ in 0..passes {
        cur = (0..n)
            .map(|i| {
                // the window shrinks towards the ends of open strokes, the ends themselves stay
                let r = if cyclic {
                    RADIUS
                } else {
                    RADIUS.min(i).min(n - 1 - i)
                };
                let sum = (0..=2 * r)
                    .map(|d| cur[(i + n + d - r) % n])
                    .sum::<Vector2>();
                sum / (2 * r + 1) as f64
            })
            .collect();
    }
    cur
}

/// The largest distance between a smoothed curve and the stroke, relative to the stroke diagonal.
const CURVE_FIT_TOL: f64 = 0.012;

/// The direction from an end of the points into them.
fn end_tangent(points: &[Vector2], start: bool) -> Vector2 {
    let n = points.len();
    let k = 3.min(n - 1);
    if start {
        (points[k] - points[0]).normalize_or_zero()
    } else {
        (points[n - 1 - k] - points[n - 1]).normalize_or_zero()
    }
}

/// Fits smoothly joined cubic Béziers through the points, staying within the tolerance (Schneider's algorithm).
///
/// `t1` is the direction at the start into the curve, `t2` the direction at the end back into the curve.
fn fit_beziers(points: &[Vector2], t1: Vector2, t2: Vector2, tolerance: f64) -> BezPath {
    let mut path = BezPath::new();
    path.move_to(points[0].to_kurbo_point());
    if points.len() >= 2 {
        fit_cubic(points, t1, t2, tolerance * tolerance, &mut path, 0);
    }
    path
}

fn fit_cubic(
    d: &[Vector2],
    t1: Vector2,
    t2: Vector2,
    err_sq: f64,
    path: &mut BezPath,
    depth: usize,
) {
    let n = d.len();
    let push = |path: &mut BezPath, b: [Vector2; 4]| {
        path.curve_to(
            b[1].to_kurbo_point(),
            b[2].to_kurbo_point(),
            b[3].to_kurbo_point(),
        );
    };
    if n <= 3 || depth > 10 {
        let dist = (d[n - 1] - d[0]).length() / 3.0;
        push(
            path,
            [d[0], d[0] + t1 * dist, d[n - 1] + t2 * dist, d[n - 1]],
        );
        return;
    }

    // chord length parameterization
    let mut u = vec![0.0; n];
    for i in 1..n {
        u[i] = u[i - 1] + (d[i] - d[i - 1]).length();
    }
    let total = u[n - 1].max(1e-12);
    u.iter_mut().for_each(|x| *x /= total);

    let mut bez = generate_bezier(d, &u, t1, t2);
    let (mut max, mut split) = max_error(d, &bez, &u);
    if max < err_sq {
        push(path, bez);
        return;
    }
    if max < err_sq * 4.0 {
        for _ in 0..20 {
            for (ui, p) in u.iter_mut().zip(d) {
                *ui = newton_step(&bez, *p, *ui);
            }
            bez = generate_bezier(d, &u, t1, t2);
            (max, split) = max_error(d, &bez, &u);
            if max < err_sq {
                push(path, bez);
                return;
            }
        }
    }

    let split = split.clamp(1, n - 2);
    let tc = (d[split - 1] - d[split + 1]).normalize_or_zero();
    fit_cubic(&d[..=split], t1, tc, err_sq, path, depth + 1);
    fit_cubic(&d[split..], -tc, t2, err_sq, path, depth + 1);
}

/// Least squares control points along the end tangents.
fn generate_bezier(d: &[Vector2], u: &[f64], t1: Vector2, t2: Vector2) -> [Vector2; 4] {
    let (first, last) = (d[0], d[d.len() - 1]);
    let (mut c, mut x) = ([[0.0; 2]; 2], [0.0; 2]);
    for (p, &t) in d.iter().zip(u) {
        let mt = 1.0 - t;
        let (b0, b1, b2, b3) = (mt * mt * mt, 3.0 * t * mt * mt, 3.0 * t * t * mt, t * t * t);
        let (a1, a2) = (t1 * b1, t2 * b2);
        c[0][0] += a1.dot(a1);
        c[0][1] += a1.dot(a2);
        c[1][1] += a2.dot(a2);
        let tmp = *p - (first * (b0 + b1) + last * (b2 + b3));
        x[0] += a1.dot(tmp);
        x[1] += a2.dot(tmp);
    }
    c[1][0] = c[0][1];
    let det = c[0][0] * c[1][1] - c[1][0] * c[0][1];
    let seg_len = (last - first).length();
    let (mut alpha1, mut alpha2) = if det.abs() > 1e-12 {
        (
            (x[0] * c[1][1] - x[1] * c[0][1]) / det,
            (c[0][0] * x[1] - c[1][0] * x[0]) / det,
        )
    } else {
        (0.0, 0.0)
    };
    // degenerate fits fall back to the heuristic of Wu and Barsky
    if alpha1 < 1e-6 * seg_len || alpha2 < 1e-6 * seg_len || !alpha1.is_finite() {
        alpha1 = seg_len / 3.0;
        alpha2 = alpha1;
    }
    [first, first + t1 * alpha1, last + t2 * alpha2, last]
}

fn bez_eval(b: &[Vector2; 4], t: f64) -> Vector2 {
    let mt = 1.0 - t;
    b[0] * (mt * mt * mt)
        + b[1] * (3.0 * t * mt * mt)
        + b[2] * (3.0 * t * t * mt)
        + b[3] * (t * t * t)
}

/// The largest squared distance of a point to the curve at its parameter, and the index of that point.
fn max_error(d: &[Vector2], b: &[Vector2; 4], u: &[f64]) -> (f64, usize) {
    let n = d.len();
    (1..n - 1)
        .map(|i| (i, (bez_eval(b, u[i]) - d[i]).length_squared()))
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(i, e)| (e, i))
        .unwrap_or((0.0, n / 2))
}

/// Improves the parameter of the point on the curve with a Newton-Raphson step.
fn newton_step(b: &[Vector2; 4], p: Vector2, t: f64) -> f64 {
    let q = bez_eval(b, t);
    let d1 = [
        (b[1] - b[0]) * 3.0,
        (b[2] - b[1]) * 3.0,
        (b[3] - b[2]) * 3.0,
    ];
    let d2 = [(d1[1] - d1[0]) * 2.0, (d1[2] - d1[1]) * 2.0];
    let mt = 1.0 - t;
    let q1 = d1[0] * (mt * mt) + d1[1] * (2.0 * t * mt) + d1[2] * (t * t);
    let q2 = d2[0] * mt + d2[1] * t;
    let num = (q - p).dot(q1);
    let den = q1.dot(q1) + (q - p).dot(q2);
    if den.abs() < 1e-12 {
        t
    } else {
        (t - num / den).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic jitter, like a slightly shaky hand.
    fn jitter(points: Vec<Vector2>, amount: f64) -> Vec<Vector2> {
        points
            .into_iter()
            .enumerate()
            .map(|(i, p)| {
                let i = i as f64;
                p + Vector2::new((i * 1.7).sin(), (i * 2.3).cos()) * amount
            })
            .collect()
    }

    fn polygon(vertices: &[Vector2], closed: bool, per_edge: usize) -> Vec<Vector2> {
        let mut pts = Vec::new();
        let count = if closed {
            vertices.len()
        } else {
            vertices.len() - 1
        };
        for i in 0..count {
            let (a, b) = (vertices[i], vertices[(i + 1) % vertices.len()]);
            for j in 0..per_edge {
                pts.push(a + (b - a) * (j as f64 / per_edge as f64));
            }
        }
        pts.push(if closed {
            vertices[0]
        } else {
            vertices[vertices.len() - 1]
        });
        pts
    }

    fn kind(points: &[Vector2]) -> RecognizedKind {
        RecognizedShape::recognize(points, 5.0).unwrap().kind
    }

    fn regular(n: usize, r: f64, rotation: f64) -> Vec<Vector2> {
        (0..n)
            .map(|i| Vector2::from_angle(rotation + i as f64 * TAU / n as f64) * r)
            .collect()
    }

    #[test]
    fn line_snaps_to_horizontal() {
        let pts = jitter(
            polygon(
                &[Vector2::new(0.0, 0.0), Vector2::new(300.0, 20.0)],
                false,
                60,
            ),
            1.5,
        );
        let shape = RecognizedShape::recognize(&pts, 5.0).unwrap();
        assert_eq!(shape.kind, RecognizedKind::Line);
        assert!((shape.start().y - shape.end().y).abs() < 1e-9);
    }

    #[test]
    fn line_snaps_to_vertical() {
        let pts = polygon(
            &[Vector2::new(0.0, 0.0), Vector2::new(-15.0, 200.0)],
            false,
            60,
        );
        let shape = RecognizedShape::recognize(&pts, 5.0).unwrap();
        assert_eq!(shape.kind, RecognizedKind::Line);
        assert!((shape.start().x - shape.end().x).abs() < 1e-9);
    }

    #[test]
    fn diagonal_line_is_kept() {
        let pts = polygon(
            &[Vector2::new(0.0, 0.0), Vector2::new(200.0, 150.0)],
            false,
            60,
        );
        let shape = RecognizedShape::recognize(&pts, 5.0).unwrap();
        assert_eq!(shape.kind, RecognizedKind::Line);
        assert!((shape.end() - Vector2::new(200.0, 150.0)).length() < 1e-6);
    }

    #[test]
    fn polyline() {
        let pts = jitter(
            polygon(
                &[
                    Vector2::new(0.0, 0.0),
                    Vector2::new(0.0, 200.0),
                    Vector2::new(250.0, 200.0),
                ],
                false,
                60,
            ),
            1.0,
        );
        assert_eq!(kind(&pts), RecognizedKind::Polyline);
    }

    #[test]
    fn circle() {
        let pts = jitter(
            (0..=200)
                .map(|i| Vector2::from_angle(i as f64 / 200.0 * TAU) * 100.0)
                .collect(),
            2.0,
        );
        assert_eq!(kind(&pts), RecognizedKind::Circle);
    }

    #[test]
    fn circle_with_overshoot_and_gap() {
        let overshoot = (0..=220)
            .map(|i| Vector2::from_angle(i as f64 / 200.0 * TAU) * 100.0)
            .collect::<Vec<_>>();
        assert_eq!(kind(&overshoot), RecognizedKind::Circle);
        let gap = (0..=185)
            .map(|i| Vector2::from_angle(i as f64 / 200.0 * TAU) * 100.0)
            .collect::<Vec<_>>();
        assert_eq!(kind(&gap), RecognizedKind::Circle);
    }

    #[test]
    fn ellipse() {
        let pts = (0..=200)
            .map(|i| {
                let a = i as f64 / 200.0 * TAU;
                Vector2::new(a.cos() * 200.0, a.sin() * 80.0)
            })
            .collect::<Vec<_>>();
        assert_eq!(kind(&pts), RecognizedKind::Ellipse);
    }

    #[test]
    fn rectangle_and_square() {
        let rect = [
            Vector2::new(0.0, 0.0),
            Vector2::new(300.0, 8.0),
            Vector2::new(305.0, 150.0),
            Vector2::new(-4.0, 145.0),
        ];
        let shape =
            RecognizedShape::recognize(&jitter(polygon(&rect, true, 40), 1.5), 5.0).unwrap();
        assert_eq!(shape.kind, RecognizedKind::Rectangle);
        // snapped upright
        let bb = shape.path.bounding_box();
        assert!((bb.height() - 145.0).abs() < 15.0, "{bb:?}");

        let square = [
            Vector2::new(0.0, 0.0),
            Vector2::new(200.0, 0.0),
            Vector2::new(205.0, 190.0),
            Vector2::new(0.0, 200.0),
        ];
        assert_eq!(kind(&polygon(&square, true, 40)), RecognizedKind::Square);
    }

    #[test]
    fn triangles() {
        let equilateral = regular(3, 100.0, -FRAC_PI_2 + 0.05);
        assert_eq!(
            kind(&jitter(polygon(&equilateral, true, 50), 1.0)),
            RecognizedKind::Triangle
        );
        let right = [
            Vector2::new(0.0, 0.0),
            Vector2::new(0.0, 200.0),
            Vector2::new(150.0, 200.0),
        ];
        assert_eq!(kind(&polygon(&right, true, 50)), RecognizedKind::Triangle);
    }

    #[test]
    fn regular_polygons() {
        assert_eq!(
            kind(&jitter(polygon(&regular(5, 120.0, 0.3), true, 40), 1.0)),
            RecognizedKind::Pentagon
        );
        assert_eq!(
            kind(&jitter(polygon(&regular(6, 120.0, 0.1), true, 40), 1.0)),
            RecognizedKind::Hexagon
        );
    }

    #[test]
    fn star() {
        let vertices = (0..10)
            .map(|i| {
                let r = if i % 2 == 0 { 150.0 } else { 60.0 };
                Vector2::from_angle(-FRAC_PI_2 + i as f64 * PI / 5.0) * r
            })
            .collect::<Vec<_>>();
        assert_eq!(kind(&polygon(&vertices, true, 30)), RecognizedKind::Star);
    }

    #[test]
    fn parabola() {
        let pts = jitter(
            (0..=100)
                .map(|i| {
                    let x = -100.0 + 2.0 * i as f64;
                    Vector2::new(x, 0.02 * x * x)
                })
                .collect(),
            0.8,
        );
        let shape = RecognizedShape::recognize(&pts, 5.0).unwrap();
        assert_eq!(shape.kind, RecognizedKind::Parabola);
        // the bezier is the exact graph
        let mid = shape.path.segments().next().unwrap().eval(0.5);
        assert!(mid.x.abs() < 2.0 && mid.y.abs() < 2.0, "{mid:?}");
    }

    #[test]
    fn cubic() {
        let pts = (0..=100)
            .map(|i| {
                let x = -100.0 + 2.0 * i as f64;
                Vector2::new(x, 0.0001 * x * x * x - 0.5 * x)
            })
            .collect::<Vec<_>>();
        assert_eq!(kind(&pts), RecognizedKind::Cubic);
    }

    #[test]
    fn arc() {
        let pts = (0..=100)
            .map(|i| Vector2::from_angle(PI + i as f64 / 100.0 * PI * 1.2) * 100.0)
            .collect::<Vec<_>>();
        assert_eq!(kind(&pts), RecognizedKind::Arc);
    }

    #[test]
    fn squiggle_is_smoothed() {
        let pts = (0..=200)
            .map(|i| {
                let t = i as f64 / 200.0;
                Vector2::new(t * 300.0, (t * 20.0).sin() * 40.0 + t * t * 80.0)
            })
            .collect::<Vec<_>>();
        assert_eq!(kind(&pts), RecognizedKind::Curve);
    }

    #[test]
    fn too_small_is_ignored() {
        let pts = polygon(&[Vector2::new(0.0, 0.0), Vector2::new(3.0, 0.0)], false, 5);
        assert!(RecognizedShape::recognize(&pts, 5.0).is_none());
    }

    #[test]
    fn pen_path_segments_are_short() {
        let pts = (0..=200)
            .map(|i| Vector2::from_angle(i as f64 / 200.0 * TAU) * 100.0)
            .collect::<Vec<_>>();
        let shape = RecognizedShape::recognize(&pts, 5.0).unwrap();
        let path = shape.to_pen_path(0.5, 20.0, 0.05).unwrap();
        assert!(path.segments.len() >= 32);
        // the segments are straight and stay close to the circle
        for seg in &path.segments {
            assert!(matches!(seg, Segment::LineTo { .. }));
        }
        let elements = path.clone().into_elements();
        for pair in elements.windows(2) {
            let mid = (pair[0].pos + pair[1].pos) * 0.5;
            assert!((100.0 - mid.length()).abs() < 0.2, "{}", mid.length());
        }
        let end = path.segments.last().unwrap().end();
        assert!((end.pos - path.start.pos).length() < 1e-6);
    }

    #[test]
    fn adjusting_a_line_follows_the_pen() {
        let pts = polygon(
            &[Vector2::new(0.0, 0.0), Vector2::new(100.0, 0.0)],
            false,
            30,
        );
        let shape = RecognizedShape::recognize(&pts, 5.0).unwrap();
        let adjusted = shape.adjusted(Vector2::new(100.0, 0.0), Vector2::new(180.0, 5.0));
        assert!((adjusted.end() - Vector2::new(180.0, 0.0)).length() < 1e-6);
    }

    /// A polygon drawn by hand, with corners rounded over `radius`.
    fn rounded(vertices: &[Vector2], radius: f64, per_edge: usize) -> Vec<Vector2> {
        let n = vertices.len();
        let mut pts = Vec::new();
        for i in 0..=n {
            let (prev, v, next) = (
                vertices[(i + n - 1) % n],
                vertices[i % n],
                vertices[(i + 1) % n],
            );
            let a = v + (prev - v).normalize() * radius;
            let b = v + (next - v).normalize() * radius;
            for j in 0..=6 {
                let t = j as f64 / 6.0;
                // quadratic bezier around the corner
                pts.push(a * (1.0 - t) * (1.0 - t) + v * 2.0 * t * (1.0 - t) + b * t * t);
            }
            if i < n {
                let c = vertices[(i + 1) % n] + (v - vertices[(i + 1) % n]).normalize() * radius;
                for j in 1..per_edge {
                    pts.push(b + (c - b) * (j as f64 / per_edge as f64));
                }
            }
        }
        pts
    }

    #[test]
    fn hand_drawn_rounded_rectangle() {
        let rect = [
            Vector2::new(0.0, 0.0),
            Vector2::new(260.0, -6.0),
            Vector2::new(265.0, 160.0),
            Vector2::new(5.0, 165.0),
        ];
        let pts = jitter(rounded(&rect, 12.0, 40), 2.0);
        assert_eq!(kind(&pts), RecognizedKind::Rectangle);
    }

    #[test]
    fn hand_drawn_triangle() {
        let tri = [
            Vector2::new(0.0, 0.0),
            Vector2::new(120.0, 200.0),
            Vector2::new(-130.0, 190.0),
        ];
        let pts = jitter(rounded(&tri, 8.0, 50), 2.0);
        assert_eq!(kind(&pts), RecognizedKind::Triangle);
    }

    #[test]
    fn shaky_circle() {
        let pts = jitter(
            (0..=150)
                .map(|i| {
                    let a = i as f64 / 150.0 * TAU;
                    Vector2::from_angle(a) * (100.0 + (a * 3.0).sin() * 5.0)
                })
                .collect(),
            3.0,
        );
        assert_eq!(kind(&pts), RecognizedKind::Circle);
    }

    #[test]
    fn rotated_ellipse() {
        let rot = 0.6_f64;
        let pts = (0..=200)
            .map(|i| {
                let a = i as f64 / 200.0 * TAU;
                let p = Vector2::new(a.cos() * 180.0, a.sin() * 70.0);
                Vector2::new(
                    p.x * rot.cos() - p.y * rot.sin(),
                    p.x * rot.sin() + p.y * rot.cos(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(kind(&jitter(pts, 1.5)), RecognizedKind::Ellipse);
    }

    #[test]
    fn hexagon_stays_upright() {
        let shape = RecognizedShape::recognize(
            &polygon(&regular(6, 100.0, -FRAC_PI_2 + 0.08), true, 40),
            5.0,
        )
        .unwrap();
        assert_eq!(shape.kind, RecognizedKind::Hexagon);
        // a vertex points straight up
        let top = shape
            .path
            .segments()
            .map(|s| s.start())
            .min_by(|a, b| a.y.total_cmp(&b.y))
            .unwrap();
        let c = shape.center();
        assert!((top.x - c.x).abs() < 1e-6, "{top:?} {c:?}");
    }

    /// A shape drawn by hand: wobbly, at an uneven speed, starting `start` of the way along it and drawing
    /// `amount` of it (less than 1 leaves a gap, more overshoots).
    fn hand_drawn(outline: &[Vector2], start: f64, amount: f64) -> Vec<Vector2> {
        let ring = resample_closed(outline, 400);
        let n = ring.len() as f64;
        let count = (amount * n) as usize;
        (0..=count)
            .map(|i| {
                let t = i as f64;
                // uneven speed: skip ahead a little now and then
                let idx = ((start * n + t + (t * 0.05).sin() * 3.0) as usize) % ring.len();
                ring[idx]
                    + Vector2::new((t * 0.07).sin() * 3.0, (t * 0.05).cos() * 3.0)
                    + Vector2::new((t * 1.7).sin(), (t * 2.3).cos()) * 1.2
            })
            .collect()
    }

    fn circle_outline(r: f64) -> Vec<Vector2> {
        (0..200)
            .map(|i| Vector2::from_angle(i as f64 / 200.0 * TAU) * r)
            .collect()
    }

    fn square_outline(side: f64, corner_radius: f64) -> Vec<Vector2> {
        let v = [
            Vector2::new(0.0, 0.0),
            Vector2::new(side, 0.0),
            Vector2::new(side, side),
            Vector2::new(0.0, side),
        ];
        closed_outline(rounded(&v, corner_radius, 40))
    }

    /// The outline of a rounded polygon, without repeating the first corner.
    fn closed_outline(mut pts: Vec<Vector2>) -> Vec<Vector2> {
        pts.truncate(pts.len() - 7);
        pts
    }

    fn assert_full_circle(shape: &RecognizedShape, r: f64) {
        assert_eq!(shape.kind, RecognizedKind::Circle);
        let bb = shape.path.bounding_box();
        assert!(
            (bb.width() - 2.0 * r).abs() < 0.12 * r && (bb.height() - 2.0 * r).abs() < 0.12 * r,
            "{bb:?}"
        );
        // the outline is closed
        assert!((shape.start() - shape.end()).length() < 1e-6);
    }

    #[test]
    fn incomplete_circles_are_completed() {
        for amount in [0.72, 0.8, 0.9, 0.97, 1.0, 1.1, 1.25] {
            for start in [0.0, 0.3, 0.65] {
                let pts = hand_drawn(&circle_outline(100.0), start, amount);
                let shape = RecognizedShape::recognize(&pts, 5.0).unwrap();
                assert_full_circle(&shape, 100.0);
            }
        }
    }

    #[test]
    fn incomplete_squares_are_completed() {
        for corner_radius in [2.0, 15.0, 30.0] {
            for amount in [0.85, 0.92, 1.0, 1.08] {
                for start in [0.0, 0.1, 0.4] {
                    let pts = hand_drawn(&square_outline(200.0, corner_radius), start, amount);
                    let shape = RecognizedShape::recognize(&pts, 5.0).unwrap();
                    assert_eq!(
                        shape.kind,
                        RecognizedKind::Square,
                        "corner radius {corner_radius}, amount {amount}, start {start}"
                    );
                    let bb = shape.path.bounding_box();
                    assert!(
                        (bb.width() - 200.0).abs() < 16.0 && (bb.height() - 200.0).abs() < 16.0,
                        "{bb:?}"
                    );
                    assert!((shape.start() - shape.end()).length() < 1e-6);
                }
            }
        }
    }

    #[test]
    fn incomplete_triangles_are_completed() {
        let tri = regular(3, 120.0, -FRAC_PI_2);
        for amount in [0.9, 1.0, 1.06] {
            for start in [0.0, 0.2, 0.5] {
                let pts = hand_drawn(&closed_outline(rounded(&tri, 10.0, 50)), start, amount);
                assert_eq!(
                    kind(&pts),
                    RecognizedKind::Triangle,
                    "amount {amount}, start {start}"
                );
            }
        }
    }

    #[test]
    fn open_square_sides_stay_a_polyline() {
        let pts = hand_drawn(&square_outline(200.0, 10.0), 0.1, 0.68);
        assert_eq!(kind(&pts), RecognizedKind::Polyline);
    }

    #[test]
    fn smoothed_curves_follow_the_stroke() {
        let pts = (0..=300)
            .map(|i| {
                let t = i as f64 / 300.0;
                Vector2::new(t * 400.0, (t * 9.0).sin() * 60.0 + (t * 3.0).cos() * 30.0)
            })
            .collect::<Vec<_>>();
        let shape = RecognizedShape::recognize(&jitter(pts.clone(), 1.0), 5.0).unwrap();
        assert_eq!(shape.kind, RecognizedKind::Curve);
        let outline = flatten_outline(&shape.path, 0.5);
        let max_dev = pts
            .iter()
            .map(|p| dist_to_outline(*p, &outline))
            .fold(0.0, f64::max);
        assert!(max_dev < 6.0, "{max_dev}");
        // smooth, without many pieces
        assert!(shape.path.segments().count() < 20);
        assert!((shape.start() - pts[0]).length() < 3.0);
        assert!((shape.end() - pts[pts.len() - 1]).length() < 3.0);
    }

    #[test]
    fn smoothed_curves_keep_their_peaks_and_valleys() {
        // a wave with peaks and valleys of different heights
        let wave = |t: f64| Vector2::new(t * 500.0, (t * 12.0).sin() * (40.0 + t * 60.0));
        let pts = (0..=400)
            .map(|i| wave(i as f64 / 400.0))
            .collect::<Vec<_>>();
        let shape = RecognizedShape::recognize(&jitter(pts.clone(), 1.5), 5.0).unwrap();
        assert_eq!(shape.kind, RecognizedKind::Curve);
        let outline = flatten_outline(&shape.path, 0.2);
        // every peak and valley of the wave is on the curve, at its height
        for k in 0..4 {
            let t = (PI / 2.0 + k as f64 * PI) / 12.0;
            let peak = wave(t);
            let nearest = outline
                .iter()
                .copied()
                .min_by(|a, b| (a.x - peak.x).abs().total_cmp(&(b.x - peak.x).abs()))
                .unwrap();
            assert!(
                (nearest.y - peak.y).abs() < 4.0,
                "peak {k}: {nearest:?} {peak:?}"
            );
            let top = if peak.y > 0.0 {
                outline
                    .iter()
                    .map(|p| p.y)
                    .fold(f64::NEG_INFINITY, f64::max)
            } else {
                0.0
            };
            assert!(top <= 110.0, "no overshoot: {top}");
        }
        assert!((shape.start() - pts[0]).length() < 3.0);
        assert!((shape.end() - pts[pts.len() - 1]).length() < 3.0);
    }

    #[test]
    fn more_incomplete_shapes() {
        let rect = closed_outline(rounded(
            &[
                Vector2::new(0.0, 0.0),
                Vector2::new(320.0, 0.0),
                Vector2::new(320.0, 150.0),
                Vector2::new(0.0, 150.0),
            ],
            14.0,
            40,
        ));
        let ellipse = (0..200)
            .map(|i| {
                let a = i as f64 / 200.0 * TAU;
                Vector2::new(a.cos() * 180.0, a.sin() * 80.0)
            })
            .collect::<Vec<_>>();
        let diamond = closed_outline(rounded(&regular(4, 130.0, -FRAC_PI_2), 10.0, 40));
        let hexagon = closed_outline(rounded(&regular(6, 130.0, -FRAC_PI_2), 6.0, 40));
        let oval_circle = (0..200)
            .map(|i| {
                let a = i as f64 / 200.0 * TAU;
                Vector2::new(a.cos() * 100.0, a.sin() * 90.0)
            })
            .collect::<Vec<_>>();
        for amount in [0.88, 1.0, 1.08] {
            for start in [0.05, 0.45] {
                let case = format!("amount {amount}, start {start}");
                assert_eq!(
                    kind(&hand_drawn(&rect, start, amount)),
                    RecognizedKind::Rectangle,
                    "{case}"
                );
                assert_eq!(
                    kind(&hand_drawn(&ellipse, start, amount)),
                    RecognizedKind::Ellipse,
                    "{case}"
                );
                assert_eq!(
                    kind(&hand_drawn(&diamond, start, amount)),
                    RecognizedKind::Square,
                    "{case}"
                );
                assert_eq!(
                    kind(&hand_drawn(&oval_circle, start, amount)),
                    RecognizedKind::Circle,
                    "{case}"
                );
                if amount >= 1.0 {
                    assert_eq!(
                        kind(&hand_drawn(&hexagon, start, amount)),
                        RecognizedKind::Hexagon,
                        "{case}"
                    );
                }
            }
        }
    }

    #[test]
    fn hooks_at_the_ends_of_curves_are_left_out() {
        let wave = |t: f64| Vector2::new(t * 500.0, (t * 9.0).sin() * 70.0);
        let mut pts = vec![wave(0.0) + Vector2::new(6.0, 22.0)];
        pts.extend((0..=300).map(|i| wave(i as f64 / 300.0)));
        pts.push(wave(1.0) + Vector2::new(-8.0, -20.0));
        let shape = RecognizedShape::recognize(&jitter(pts, 1.0), 5.0).unwrap();
        assert_eq!(shape.kind, RecognizedKind::Curve);
        assert!(
            (shape.start() - wave(0.0)).length() < 6.0,
            "{:?}",
            shape.start()
        );
        assert!(
            (shape.end() - wave(1.0)).length() < 6.0,
            "{:?}",
            shape.end()
        );
    }

    #[test]
    fn circle_tolerance() {
        let oval = (0..=220)
            .map(|i| {
                let a = i as f64 / 200.0 * TAU;
                Vector2::new(a.cos() * 100.0, a.sin() * 80.0)
            })
            .collect::<Vec<_>>();
        assert_eq!(kind(&oval), RecognizedKind::Circle);
        let strict = RecognitionOptions {
            circle_tolerance: 0.1,
        };
        assert_eq!(
            RecognizedShape::recognize_with(&oval, 5.0, strict)
                .unwrap()
                .kind,
            RecognizedKind::Ellipse
        );
    }
}
