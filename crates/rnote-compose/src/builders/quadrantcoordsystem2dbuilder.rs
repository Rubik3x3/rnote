// Imports
use super::axes::{AxesOptions, Axis};
use super::buildable::{Buildable, BuilderCreator, BuilderProgress};
use crate::eventresult::EventPropagation;
use crate::penevent::{PenEvent, PenState};
use crate::penpath::Element;
use crate::shapes::ArrowHead;
use crate::style::{Composer, indicators};
use crate::{Constraints, EventResult};
use crate::{Shape, Style};
use p2d::bounding_volume::{Aabb, BoundingVolume};
use p2d::math::Vector2;
use piet::RenderContext;
use std::time::Instant;

/// 2D single quadrant coordinate system builder.
#[derive(Debug, Clone)]
pub struct QuadrantCoordSystem2DBuilder {
    /// Tip of the y axis.
    tip_y: Vector2,
    /// Tip of the x axis.
    tip_x: Vector2,
    /// Options for the axes.
    axes_options: AxesOptions,
    /// Style of the arrow heads.
    arrow_head: ArrowHead,
}

impl BuilderCreator for QuadrantCoordSystem2DBuilder {
    fn start(element: Element, _now: Instant) -> Self {
        Self {
            tip_y: element.pos,
            tip_x: element.pos,
            axes_options: AxesOptions::default(),
            arrow_head: ArrowHead::default(),
        }
    }
}

impl Buildable for QuadrantCoordSystem2DBuilder {
    type Emit = Shape;

    fn handle_event(
        &mut self,
        event: PenEvent,
        _now: Instant,
        constraints: Constraints,
    ) -> EventResult<BuilderProgress<Self::Emit>> {
        let progress = match event {
            PenEvent::Down { element, .. } => {
                self.tip_x = constraints.constrain(element.pos - self.tip_y) + self.tip_y;
                BuilderProgress::InProgress
            }
            PenEvent::Up { .. } => BuilderProgress::Finished(self.state_as_shapes()),
            _ => BuilderProgress::InProgress,
        };

        EventResult {
            handled: true,
            propagate: EventPropagation::Stop,
            progress,
        }
    }

    fn bounds(&self, style: &Style, zoom: f64) -> Option<Aabb> {
        Some(
            self.state_as_shapes()
                .iter()
                .map(|shape| shape.composed_bounds(style))
                .fold(Aabb::new_invalid(), |acc, x| acc.merged(&x))
                .loosened(indicators::POS_INDICATOR_RADIUS / zoom),
        )
    }

    fn draw_styled(&self, cx: &mut piet_cairo::CairoRenderContext, style: &Style, zoom: f64) {
        cx.save().unwrap();

        for shape in self.state_as_shapes() {
            shape.draw_composed(cx, style);
        }

        indicators::draw_pos_indicator(cx, PenState::Up, self.tip_y, zoom);
        indicators::draw_pos_indicator(cx, PenState::Down, self.tip_x, zoom);
        cx.restore().unwrap();
    }
}

impl QuadrantCoordSystem2DBuilder {
    /// Sets the options for the axes.
    pub fn with_axes_options(mut self, axes_options: AxesOptions) -> Self {
        self.axes_options = axes_options;
        self
    }

    /// Sets the style of the arrow heads.
    pub fn with_arrow_head(mut self, arrow_head: ArrowHead) -> Self {
        self.arrow_head = arrow_head;
        self
    }

    /// The current state as shapes.
    pub fn state_as_shapes(&self) -> Vec<Shape> {
        let center = Vector2::new(self.tip_y.x, self.tip_x.y);

        let axes = [
            Axis::new(center, self.tip_x, None),
            Axis::new(center, self.tip_y, None),
        ];
        self.axes_options
            .coord_system_shapes(&axes, &[(0, 1)], self.arrow_head)
    }
}
