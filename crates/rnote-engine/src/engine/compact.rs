//! "Compact empty space": closes the big vertical gaps left between blocks of writing,
//! e.g. after zooming in and writing in scattered spots of a page. Used by the
//! `compact-vertical-space` window action.

// Imports
use super::Engine;
use crate::WidgetFlags;
use crate::store::StrokeKey;
use p2d::math::Vector2;
use std::time::Instant;

/// Gaps taller than this (in document px) get closed.
pub const MAX_GAP: f64 = 96.0;
/// The space left between two blocks after closing a gap.
pub const KEPT_GAP: f64 = 48.0;

/// Given the (top, bottom) of each stroke, returns how much each stroke must move up so that
/// no vertical gap between rows of content is taller than `MAX_GAP`.
///
/// Strokes whose vertical ranges overlap form one row ("block") and move together,
/// so nothing inside a block changes its relative position. The first block stays in place.
pub fn upward_offsets(ranges: &[(f64, f64)]) -> Vec<f64> {
    let mut order: Vec<usize> = (0..ranges.len()).collect();
    order.sort_by(|&a, &b| ranges[a].0.total_cmp(&ranges[b].0));

    let mut offsets = vec![0.0; ranges.len()];
    let mut shift = 0.0;
    let mut block_bottom = f64::NEG_INFINITY;
    for i in order {
        let (top, bottom) = ranges[i];
        let gap = top - block_bottom;
        if block_bottom.is_finite() && gap > MAX_GAP {
            shift += gap - KEPT_GAP;
        }
        offsets[i] = shift;
        block_bottom = block_bottom.max(bottom);
    }
    offsets
}

impl Engine {
    /// Closes big vertical gaps in the selection, or in the whole document when nothing is
    /// selected. One undo step. Returns the widget flags to apply.
    pub fn compact_vertical_space(&mut self) -> WidgetFlags {
        let mut keys = self.store.selection_keys_as_rendered();
        if keys.is_empty() {
            keys = self.store.stroke_keys_as_rendered();
        }
        // paired per key, `strokes_bounds` would skip missing strokes and shift the indices
        let (keys, ranges): (Vec<StrokeKey>, Vec<(f64, f64)>) = keys
            .into_iter()
            .filter_map(|key| {
                let b = self.store.strokes_bounds(&[key]).pop()?;
                Some((key, (b.mins[1], b.maxs[1])))
            })
            .unzip();
        let offsets = upward_offsets(&ranges);

        let mut moved: Vec<StrokeKey> = vec![];
        for (&key, &dy) in keys.iter().zip(&offsets) {
            if dy > 0.0 {
                self.store.translate_strokes(&[key], Vector2::new(0.0, -dy));
                self.store
                    .translate_strokes_images(&[key], Vector2::new(0.0, -dy));
                moved.push(key);
            }
        }
        if moved.is_empty() {
            return WidgetFlags::default();
        }
        self.store.update_geometry_for_strokes(&moved);
        self.current_pen_update_state()
            | self.doc_resize_autoexpand()
            | self.record(Instant::now())
            | self.update_rendering_current_viewport()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn big_gaps_shrink_and_blocks_move_together() {
        // two overlapping strokes form one block, then a 400 px gap, then another block
        let ranges = [(0.0, 50.0), (30.0, 80.0), (480.0, 520.0), (500.0, 560.0)];
        let offsets = upward_offsets(&ranges);
        assert_eq!(offsets[0], 0.0);
        assert_eq!(offsets[1], 0.0);
        assert_eq!(offsets[2], 400.0 - KEPT_GAP);
        assert_eq!(offsets[3], 400.0 - KEPT_GAP);
    }

    #[test]
    fn small_gaps_are_kept() {
        let ranges = [(0.0, 50.0), (100.0, 150.0)];
        assert_eq!(upward_offsets(&ranges), vec![0.0, 0.0]);
    }
}
