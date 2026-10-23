// Imports
use super::Axis;
use crate::shapes::Ellipse;
use p2d::glamx::DAffine2;
use p2d::math::Vector2;

/// Upper bound of dots in a grid, the spacing between dots is increased to stay below it.
const DOTS_MAX: usize = 2500;
/// Radius of a dot, the visible size mostly comes from the stroke width.
const DOT_RADIUS: f64 = 0.5;

/// Dots at the intersections of the tick positions in the plane spanned by two axes.
///
/// The axes themselves are left out.
pub(super) fn dots(origin: Vector2, a: &Axis, b: &Axis, spacing: f64) -> Vec<Ellipse> {
    let range_a = a.tick_range(spacing);
    let range_b = b.tick_range(spacing);

    let n_dots = (range_a.end() - range_a.start() + 1) * (range_b.end() - range_b.start() + 1);
    // thin out the grid in both directions until it stays below the limit
    let step = (1_i64..)
        .find(|s| n_dots / (s * s) <= DOTS_MAX as i64)
        .unwrap_or(1);

    let dir_a = a.dir();
    let dir_b = b.dir();

    range_a
        .filter(|i| *i != 0 && i % step == 0)
        .flat_map(|i| {
            range_b
                .clone()
                .filter(|j| *j != 0 && j % step == 0)
                .map(move |j| origin + dir_a * (i as f64 * spacing) + dir_b * (j as f64 * spacing))
        })
        .map(|pos| Ellipse {
            radii: Vector2::splat(DOT_RADIUS),
            affine: DAffine2::from_translation(pos),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dots_skip_axes() {
        let x = Axis::new(Vector2::ZERO, Vector2::new(100.0, 0.0), None);
        let y = Axis::new(Vector2::ZERO, Vector2::new(0.0, -100.0), None);
        // 4 ticks per axis: 20, 40, 60, 80 (the outermost tick keeps half a spacing to the end)
        let dots = dots(Vector2::ZERO, &x, &y, 20.0);
        assert_eq!(dots.len(), 16);
    }

    #[test]
    fn dots_are_capped() {
        let x = Axis::new(
            Vector2::ZERO,
            Vector2::new(10_000.0, 0.0),
            Some(Vector2::new(-10_000.0, 0.0)),
        );
        let y = Axis::new(
            Vector2::ZERO,
            Vector2::new(0.0, -10_000.0),
            Some(Vector2::new(0.0, 10_000.0)),
        );
        assert!(dots(Vector2::ZERO, &x, &y, 4.0).len() <= DOTS_MAX);
    }
}
