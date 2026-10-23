// Imports
use crate::strokes::{ShapeStroke, Stroke};
use crate::{Engine, WidgetFlags};
use rnote_compose::Shape;
use rnote_compose::color::soft;
use rnote_compose::plot::FunctionGraph;

/// Curves are drawn thicker than the axes.
const CURVE_WIDTH_FACTOR: f64 = 1.5;

impl Engine {
    /// Inserts the graph, centered in the viewport, styled with the current shaper options.
    ///
    /// The graph is made of regular shape strokes, so documents stay readable by any Rnote version.
    /// The inserted strokes are selected, ready to be moved.
    pub fn insert_function_graph(&mut self, graph: &FunctionGraph) -> WidgetFlags {
        let (mut axes_style, axes_options, arrow_head) = {
            let config = self.config.read();
            let shaper_config = &config.pens_config.shaper_config;
            (
                shaper_config.gen_style_for_current_options(),
                shaper_config.axes_options,
                shaper_config.arrow_head,
            )
        };
        let origin = graph.origin_for_center(self.camera.viewport_center());

        let mut strokes = Vec::new();
        for shape in graph.axes_shapes(origin, axes_options, arrow_head) {
            strokes.push(Stroke::ShapeStroke(ShapeStroke::new(
                shape,
                axes_style.clone(),
            )));
            axes_style.advance_seed();
        }

        for (i, pieces) in graph.curves(origin).into_iter().enumerate() {
            let mut curve_style = axes_style.clone();
            curve_style.set_stroke_color(soft::HUES[i % soft::HUES.len()]);
            curve_style.set_stroke_width(axes_style.stroke_width() * CURVE_WIDTH_FACTOR);

            for piece in pieces {
                strokes.push(Stroke::ShapeStroke(ShapeStroke::new(
                    Shape::Polyline(piece),
                    curve_style.clone(),
                )));
                curve_style.advance_seed();
            }
        }

        self.import_generated_content(strokes.into_iter().map(|s| (s, None)).collect(), false)
    }
}
