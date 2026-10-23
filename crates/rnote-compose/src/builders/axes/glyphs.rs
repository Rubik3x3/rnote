// Imports
use crate::shapes::Polyline;
use p2d::math::Vector2;

/// Width of a glyph cell, in glyph units.
const GLYPH_WIDTH: f64 = 1.0;
/// Height of a glyph cell, in glyph units.
const GLYPH_HEIGHT: f64 = 2.0;
/// Horizontal gap between two glyphs, in glyph units.
const GLYPH_GAP: f64 = 0.5;

/// Seven segment style strokes of a character, in glyph units with the y axis pointing down.
///
/// Composed out of plain polylines so that labels stay regular shapes, readable by every Rnote version.
fn glyph_strokes(c: char) -> &'static [&'static [(f64, f64)]] {
    match c {
        '0' => &[&[(0.0, 0.0), (1.0, 0.0), (1.0, 2.0), (0.0, 2.0), (0.0, 0.0)]],
        '1' => &[&[(0.3, 0.4), (0.7, 0.0), (0.7, 2.0)]],
        '2' => &[&[
            (0.0, 0.0),
            (1.0, 0.0),
            (1.0, 1.0),
            (0.0, 1.0),
            (0.0, 2.0),
            (1.0, 2.0),
        ]],
        '3' => &[
            &[(0.0, 0.0), (1.0, 0.0), (1.0, 2.0), (0.0, 2.0)],
            &[(0.0, 1.0), (1.0, 1.0)],
        ],
        '4' => &[
            &[(0.0, 0.0), (0.0, 1.0), (1.0, 1.0)],
            &[(1.0, 0.0), (1.0, 2.0)],
        ],
        '5' => &[&[
            (1.0, 0.0),
            (0.0, 0.0),
            (0.0, 1.0),
            (1.0, 1.0),
            (1.0, 2.0),
            (0.0, 2.0),
        ]],
        '6' => &[&[
            (1.0, 0.0),
            (0.0, 0.0),
            (0.0, 2.0),
            (1.0, 2.0),
            (1.0, 1.0),
            (0.0, 1.0),
        ]],
        '7' => &[&[(0.0, 0.0), (1.0, 0.0), (1.0, 2.0)]],
        '8' => &[
            &[(0.0, 0.0), (1.0, 0.0), (1.0, 2.0), (0.0, 2.0), (0.0, 0.0)],
            &[(0.0, 1.0), (1.0, 1.0)],
        ],
        '9' => &[&[
            (1.0, 1.0),
            (0.0, 1.0),
            (0.0, 0.0),
            (1.0, 0.0),
            (1.0, 2.0),
            (0.0, 2.0),
        ]],
        '-' => &[&[(0.1, 1.0), (0.9, 1.0)]],
        _ => &[],
    }
}

/// A text label drawn with strokes.
#[derive(Debug, Clone)]
pub(super) struct StrokeLabel {
    text: String,
    /// Height of the glyphs.
    height: f64,
}

impl StrokeLabel {
    pub(super) fn new(text: impl Into<String>, height: f64) -> Self {
        Self {
            text: text.into(),
            height,
        }
    }

    fn scale(&self) -> f64 {
        self.height / GLYPH_HEIGHT
    }

    /// The size of the label.
    pub(super) fn size(&self) -> Vector2 {
        let n = self.text.chars().count() as f64;
        let width = if n > 0.0 {
            n * GLYPH_WIDTH + (n - 1.0) * GLYPH_GAP
        } else {
            0.0
        };
        Vector2::new(width, GLYPH_HEIGHT) * self.scale()
    }

    /// The label as polylines, centered at the given position.
    pub(super) fn polylines(&self, center: Vector2) -> Vec<Polyline> {
        let scale = self.scale();
        let top_left = center - self.size() * 0.5;

        self.text
            .chars()
            .enumerate()
            .flat_map(|(i, c)| {
                let offset =
                    top_left + Vector2::new(i as f64 * (GLYPH_WIDTH + GLYPH_GAP) * scale, 0.0);
                glyph_strokes(c).iter().filter_map(move |stroke| {
                    let mut points = stroke
                        .iter()
                        .map(|&(x, y)| offset + Vector2::new(x, y) * scale);
                    let start = points.next()?;
                    Some(Polyline {
                        start,
                        path: points.collect(),
                    })
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_digit_has_strokes() {
        for c in "0123456789-".chars() {
            assert!(!glyph_strokes(c).is_empty(), "missing glyph for '{c}'");
        }
    }

    #[test]
    fn label_is_centered() {
        let label = StrokeLabel::new("-12", 10.0);
        let size = label.size();
        assert_eq!(size, Vector2::new(20.0, 10.0));

        let points = label
            .polylines(Vector2::ZERO)
            .into_iter()
            .flat_map(|p| std::iter::once(p.start).chain(p.path))
            .collect::<Vec<_>>();
        let min = points
            .iter()
            .fold(Vector2::splat(f64::MAX), |a, p| a.min(*p));
        let max = points
            .iter()
            .fold(Vector2::splat(f64::MIN), |a, p| a.max(*p));
        assert!(min.x >= -10.0 && max.x <= 10.0);
        assert!(min.y >= -5.0 && max.y <= 5.0);
    }
}
