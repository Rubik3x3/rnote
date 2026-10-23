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

/// 3D coordinate system builder.
#[derive(Debug, Clone)]
pub struct CoordSystem3DBuilder {
    /// Tip of the z axis.
    tip_z: Vector2,
    /// Tip of the y axis.
    tip_y: Vector2,
    /// Options for the axes.
    axes_options: AxesOptions,
    /// Style of the arrow heads.
    arrow_head: ArrowHead,
}

impl BuilderCreator for CoordSystem3DBuilder {
    fn start(element: Element, _now: Instant) -> Self {
        Self {
            tip_z: element.pos,
            tip_y: element.pos,
            axes_options: AxesOptions::default(),
            arrow_head: ArrowHead::default(),
        }
    }
}

impl Buildable for CoordSystem3DBuilder {
    type Emit = Shape;

    fn handle_event(
        &mut self,
        event: PenEvent,
        _now: Instant,
        constraints: Constraints,
    ) -> EventResult<BuilderProgress<Self::Emit>> {
        let progress = match event {
            PenEvent::Down { element, .. } => {
                self.tip_y = constraints.constrain(element.pos - self.tip_z) + self.tip_z;
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

        indicators::draw_pos_indicator(cx, PenState::Up, self.tip_z, zoom);
        indicators::draw_pos_indicator(cx, PenState::Down, self.tip_y, zoom);
        cx.restore().unwrap();
    }
}

impl CoordSystem3DBuilder {
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
    ///
    /// The x axis is drawn diagonally, pointing towards the viewer.
    /// The dotted grid lies in the y-z plane, parallel to the screen.
    pub fn state_as_shapes(&self) -> Vec<Shape> {
        let center = Vector2::new(self.tip_z.x, self.tip_y.y);
        let tip_x_offset = ((center - self.tip_z).length() + (center - self.tip_y).length()) / 4.0;
        let down = Vector2::new(center.x, 2.0 * self.tip_y.y - self.tip_z.y);
        let left = Vector2::new(2.0 * self.tip_z.x - self.tip_y.x, center.y);
        let forward = center + Vector2::new(-tip_x_offset, tip_x_offset);
        let backward = center + Vector2::new(tip_x_offset, -tip_x_offset);

        let axes = [
            Axis::new(center, forward, Some(backward)),
            Axis::new(center, self.tip_y, Some(left)),
            Axis::new(center, self.tip_z, Some(down)),
        ];
        self.axes_options
            .coord_system_shapes(&axes, &[(1, 2)], self.arrow_head)
    }
}
