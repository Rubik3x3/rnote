// Imports
use super::PenBehaviour;
use super::PenStyle;
use super::pensconfig::brushconfig::BrushStyle;
use crate::engine::{EngineTask, EngineTaskSender, EngineView, EngineViewMut};
use crate::store::StrokeKey;
use crate::strokes::BrushStroke;
use crate::strokes::Stroke;
use crate::tasks::{OneOffTaskError, OneOffTaskHandle};
use crate::{DrawableOnDoc, WidgetFlags};
use p2d::bounding_volume::{Aabb, BoundingVolume};
use p2d::math::Vector2;
use piet::RenderContext;
use rnote_compose::Constraints;
use rnote_compose::PenPath;
use rnote_compose::Style;
use rnote_compose::builders::buildable::{Buildable, BuilderCreator, BuilderProgress};
use rnote_compose::builders::{
    PenPathBuilderType, PenPathCurvedBuilder, PenPathModeledBuilder, PenPathSimpleBuilder,
};
use rnote_compose::eventresult::{EventPropagation, EventResult};
use rnote_compose::penevent::{PenEvent, PenProgress};
use rnote_compose::penpath::{Element, Segment};
use rnote_compose::recognition::{RecognitionOptions, RecognizedShape};
use std::time::{Duration, Instant};
use tracing::error;

#[derive(Debug)]
enum BrushState {
    Idle,
    Drawing {
        path_builder: Box<dyn Buildable<Emit = Segment>>,
        current_stroke_key: StrokeKey,
        preview_style: Style,
        /// Detects when the pen is held still, `None` when shape recognition is disabled.
        hold: Option<Box<HoldDetector>>,
        /// The shape the stroke was turned into.
        snapped: Option<Box<Snapped>>,
    },
}

/// Tracks the input of a stroke and fires [EngineTask::BrushHold] once the pen stays still for the delay.
#[derive(Debug)]
struct HoldDetector {
    points: Vec<Vector2>,
    pressures: Vec<f64>,
    /// The position the pen is held around.
    anchor: Vector2,
    /// Number of points up to the anchor, the jitter while holding is left out of the recognition.
    anchor_len: usize,
    anchor_time: Instant,
    delay: Duration,
    key: StrokeKey,
    tasks_tx: EngineTaskSender,
    task: OneOffTaskHandle,
}

impl HoldDetector {
    fn new(
        element: Element,
        now: Instant,
        delay: Duration,
        key: StrokeKey,
        tasks_tx: EngineTaskSender,
    ) -> Self {
        Self {
            points: vec![element.pos],
            pressures: vec![element.pressure],
            anchor: element.pos,
            anchor_len: 1,
            anchor_time: now,
            delay,
            key,
            task: Self::spawn_task(key, tasks_tx.clone(), delay),
            tasks_tx,
        }
    }

    fn spawn_task(key: StrokeKey, tasks_tx: EngineTaskSender, delay: Duration) -> OneOffTaskHandle {
        OneOffTaskHandle::new(move || tasks_tx.send(EngineTask::BrushHold { key }), delay)
    }

    /// Records a new input, restarting the countdown when the pen moved away from the anchor.
    fn track(&mut self, element: Element, now: Instant, tolerance: f64) {
        self.points.push(element.pos);
        self.pressures.push(element.pressure);
        if (element.pos - self.anchor).length() <= tolerance {
            return;
        }
        self.anchor = element.pos;
        self.anchor_len = self.points.len();
        self.anchor_time = now;
        match self.task.reset_timeout() {
            Ok(()) => {}
            Err(OneOffTaskError::TimeoutReached) => {
                self.task = Self::spawn_task(self.key, self.tasks_tx.clone(), self.delay);
            }
            Err(e) => {
                error!("Could not reset the brush hold timeout, Err: {e:?}");
                self.task = Self::spawn_task(self.key, self.tasks_tx.clone(), self.delay);
            }
        }
    }

    fn held_long_enough(&self) -> bool {
        // the timeout of the task can fire a bit early
        self.anchor_time.elapsed() >= self.delay.mul_f64(0.9)
    }

    /// The median pressure, so the shape keeps the width the stroke was drawn with.
    fn pressure(&self) -> f64 {
        let mut pressures = self.pressures[..self.anchor_len].to_vec();
        pressures.sort_by(f64::total_cmp);
        pressures
            .get(pressures.len() / 2)
            .copied()
            .unwrap_or(Element::PRESSURE_DEFAULT)
    }
}

/// A stroke that was turned into a shape, while the pen is still down.
#[derive(Debug)]
struct Snapped {
    /// Where the pen was when the shape was recognized.
    anchor: Vector2,
    /// The hand-drawn stroke, brought back when the pen moves on.
    freehand: PenPath,
}

#[derive(Debug)]
pub struct Brush {
    state: BrushState,
}

impl Default for Brush {
    fn default() -> Self {
        Self {
            state: BrushState::Idle,
        }
    }
}

impl PenBehaviour for Brush {
    fn init(&mut self, _engine_view: &EngineView) -> WidgetFlags {
        WidgetFlags::default()
    }

    fn deinit(&mut self) -> WidgetFlags {
        WidgetFlags::default()
    }

    fn style(&self) -> PenStyle {
        PenStyle::Brush
    }

    fn update_state(&mut self, _engine_view: &mut EngineViewMut) -> WidgetFlags {
        WidgetFlags::default()
    }

    fn handle_event(
        &mut self,
        event: PenEvent,
        now: Instant,
        engine_view: &mut EngineViewMut,
    ) -> (EventResult<PenProgress>, WidgetFlags) {
        let mut widget_flags = WidgetFlags::default();

        let event_result = match (&mut self.state, event) {
            (BrushState::Idle, PenEvent::Down { element, .. }) => {
                if !element.filter_by_bounds(
                    engine_view
                        .document
                        .bounds()
                        .loosened(Self::INPUT_OVERSHOOT),
                ) {
                    #[cfg(feature = "ui")]
                    {
                        if engine_view.config.pens_config.brush_config.style == BrushStyle::Marker {
                            play_marker_sound(engine_view);
                        } else {
                            trigger_brush_sound(engine_view);
                        }
                    }

                    engine_view
                        .config
                        .pens_config
                        .brush_config
                        .new_style_seeds();

                    let preview_style = Self::get_preview_style(&engine_view.as_im());
                    let brushstroke =
                        Stroke::BrushStroke(BrushStroke::new(element, preview_style.clone()));

                    let current_stroke_key = engine_view.store.insert_stroke(
                        brushstroke,
                        Some(
                            engine_view
                                .config
                                .pens_config
                                .brush_config
                                .layer_for_current_options(),
                        ),
                    );

                    engine_view.store.regenerate_rendering_for_stroke(
                        current_stroke_key,
                        engine_view.camera.viewport(),
                        engine_view.camera.image_scale(),
                    );

                    let brush_config = &engine_view.config.pens_config.brush_config;
                    let hold = brush_config.shape_recognition.then(|| {
                        Box::new(HoldDetector::new(
                            element,
                            now,
                            Duration::from_millis(brush_config.shape_recognition_delay_ms.into()),
                            current_stroke_key,
                            engine_view.tasks_tx.clone(),
                        ))
                    });

                    self.state = BrushState::Drawing {
                        path_builder: new_builder(brush_config.builder_type, element, now),
                        current_stroke_key,
                        preview_style,
                        hold,
                        snapped: None,
                    };

                    EventResult {
                        handled: true,
                        propagate: EventPropagation::Stop,
                        progress: PenProgress::InProgress,
                    }
                } else {
                    EventResult {
                        handled: false,
                        propagate: EventPropagation::Proceed,
                        progress: PenProgress::Idle,
                    }
                }
            }
            (BrushState::Idle, _) => EventResult {
                handled: false,
                propagate: EventPropagation::Proceed,
                progress: PenProgress::Idle,
            },
            (
                BrushState::Drawing {
                    current_stroke_key, ..
                },
                PenEvent::Cancel,
            ) => {
                if let Some(Stroke::BrushStroke(brushstroke)) =
                    engine_view.store.get_stroke_mut(*current_stroke_key)
                {
                    brushstroke.style = engine_view
                        .config
                        .pens_config
                        .brush_config
                        .style_for_current_options();
                }

                // Finish up the last stroke
                engine_view
                    .store
                    .update_geometry_for_stroke(*current_stroke_key);
                engine_view.store.regenerate_rendering_for_stroke_threaded(
                    engine_view.tasks_tx.clone(),
                    *current_stroke_key,
                    engine_view.camera.viewport(),
                    engine_view.camera.image_scale(),
                );
                widget_flags |= engine_view
                    .document
                    .resize_autoexpand(engine_view.store, engine_view.camera);

                self.state = BrushState::Idle;

                widget_flags |= engine_view.store.record(Instant::now());
                widget_flags.store_modified = true;

                EventResult {
                    handled: true,
                    propagate: EventPropagation::Stop,
                    progress: PenProgress::Finished,
                }
            }
            (
                BrushState::Drawing {
                    current_stroke_key,
                    snapped: snapped_slot @ Some(_),
                    ..
                },
                pen_event,
            ) => {
                let current_stroke_key = *current_stroke_key;
                match pen_event {
                    PenEvent::Down { element, .. } => {
                        let moved = snapped_slot
                            .as_ref()
                            .map(|snapped| {
                                (element.pos - snapped.anchor).length()
                                    * engine_view.camera.total_zoom()
                            })
                            .unwrap_or_default();
                        if moved >= Self::RESUME_DISTANCE
                            && let Some(snapped) = snapped_slot.take()
                        {
                            // the pen only paused, keep drawing by hand
                            widget_flags |= Self::set_stroke_path(
                                snapped.freehand,
                                current_stroke_key,
                                engine_view,
                            );
                            let (result, wf) = self.handle_event(pen_event, now, engine_view);
                            return (result, widget_flags | wf);
                        }

                        EventResult {
                            handled: true,
                            propagate: EventPropagation::Stop,
                            progress: PenProgress::InProgress,
                        }
                    }
                    PenEvent::Up { .. } => {
                        // the hand-drawn stroke goes into the history first, so undoing brings it back
                        if let Some(snapped) = snapped_slot.take()
                            && let Some(Stroke::BrushStroke(brushstroke)) =
                                engine_view.store.get_stroke_mut(current_stroke_key)
                        {
                            brushstroke.style = engine_view
                                .config
                                .pens_config
                                .brush_config
                                .style_for_current_options();
                            let shape_path =
                                std::mem::replace(&mut brushstroke.path, snapped.freehand);
                            engine_view
                                .store
                                .update_geometry_for_stroke(current_stroke_key);
                            widget_flags |= engine_view.store.record(Instant::now());
                            if let Some(Stroke::BrushStroke(brushstroke)) =
                                engine_view.store.get_stroke_mut(current_stroke_key)
                            {
                                brushstroke.path = shape_path;
                            }
                            engine_view
                                .store
                                .update_geometry_for_stroke(current_stroke_key);
                        }

                        engine_view.store.regenerate_rendering_for_stroke_threaded(
                            engine_view.tasks_tx.clone(),
                            current_stroke_key,
                            engine_view.camera.viewport(),
                            engine_view.camera.image_scale(),
                        );
                        widget_flags |= engine_view
                            .document
                            .resize_autoexpand(engine_view.store, engine_view.camera);

                        self.state = BrushState::Idle;

                        widget_flags |= engine_view.store.record(Instant::now());
                        widget_flags.store_modified = true;

                        EventResult {
                            handled: true,
                            propagate: EventPropagation::Stop,
                            progress: PenProgress::Finished,
                        }
                    }
                    _ => EventResult {
                        handled: true,
                        propagate: EventPropagation::Stop,
                        progress: PenProgress::InProgress,
                    },
                }
            }
            (
                BrushState::Drawing {
                    path_builder,
                    current_stroke_key,
                    hold,
                    ..
                },
                pen_event,
            ) => {
                if let (Some(hold), PenEvent::Down { element, .. }) = (hold.as_mut(), &pen_event) {
                    hold.track(
                        *element,
                        now,
                        Self::HOLD_TOLERANCE / engine_view.camera.total_zoom(),
                    );
                }

                let builder_result =
                    path_builder.handle_event(pen_event, now, Constraints::default());
                let handled = builder_result.handled;
                let propagate = builder_result.propagate;

                let progress = match builder_result.progress {
                    BuilderProgress::InProgress => {
                        #[cfg(feature = "ui")]
                        {
                            if engine_view.config.pens_config.brush_config.style
                                != BrushStyle::Marker
                            {
                                trigger_brush_sound(engine_view);
                            }
                        }

                        PenProgress::InProgress
                    }
                    BuilderProgress::EmitContinue(segments) => {
                        #[cfg(feature = "ui")]
                        {
                            if engine_view.config.pens_config.brush_config.style
                                != BrushStyle::Marker
                            {
                                trigger_brush_sound(engine_view);
                            }
                        }

                        let n_segments = segments.len();

                        if n_segments != 0 {
                            if let Some(Stroke::BrushStroke(brushstroke)) =
                                engine_view.store.get_stroke_mut(*current_stroke_key)
                            {
                                brushstroke.extend_w_segments(segments);
                                widget_flags.store_modified = true;
                            }

                            engine_view.store.append_rendering_last_segments(
                                engine_view.tasks_tx.clone(),
                                *current_stroke_key,
                                n_segments,
                                engine_view.camera.viewport(),
                                engine_view.camera.image_scale(),
                            );
                        }

                        PenProgress::InProgress
                    }
                    BuilderProgress::Finished(segments) => {
                        let n_segments = segments.len();

                        if n_segments != 0 {
                            if let Some(Stroke::BrushStroke(brushstroke)) =
                                engine_view.store.get_stroke_mut(*current_stroke_key)
                            {
                                brushstroke.extend_w_segments(segments);
                                widget_flags.store_modified = true;
                            }

                            engine_view.store.append_rendering_last_segments(
                                engine_view.tasks_tx.clone(),
                                *current_stroke_key,
                                n_segments,
                                engine_view.camera.viewport(),
                                engine_view.camera.image_scale(),
                            );
                        }

                        if let Some(Stroke::BrushStroke(brushstroke)) =
                            engine_view.store.get_stroke_mut(*current_stroke_key)
                        {
                            brushstroke.style = engine_view
                                .config
                                .pens_config
                                .brush_config
                                .style_for_current_options();
                        }

                        // Finish up the last stroke
                        engine_view
                            .store
                            .update_geometry_for_stroke(*current_stroke_key);
                        engine_view.store.regenerate_rendering_for_stroke_threaded(
                            engine_view.tasks_tx.clone(),
                            *current_stroke_key,
                            engine_view.camera.viewport(),
                            engine_view.camera.image_scale(),
                        );
                        widget_flags |= engine_view
                            .document
                            .resize_autoexpand(engine_view.store, engine_view.camera);

                        self.state = BrushState::Idle;

                        widget_flags |= engine_view.store.record(Instant::now());
                        widget_flags.store_modified = true;

                        PenProgress::Finished
                    }
                };

                EventResult {
                    handled,
                    propagate,
                    progress,
                }
            }
        };

        (event_result, widget_flags)
    }
}

impl DrawableOnDoc for Brush {
    fn bounds_on_doc(&self, engine_view: &EngineView) -> Option<Aabb> {
        let style = engine_view
            .config
            .pens_config
            .brush_config
            .style_for_current_options();

        match &self.state {
            BrushState::Idle => None,
            BrushState::Drawing { path_builder, .. } => {
                path_builder.bounds(&style, engine_view.camera.zoom())
            }
        }
    }

    fn draw_on_doc(
        &self,
        cx: &mut piet_cairo::CairoRenderContext,
        engine_view: &EngineView,
    ) -> anyhow::Result<()> {
        cx.save().map_err(|e| anyhow::anyhow!("{e:?}"))?;

        match &self.state {
            BrushState::Idle => {}
            BrushState::Drawing {
                snapped: Some(_), ..
            } => {
                // The shape is rendered as the stroke itself
            }
            BrushState::Drawing {
                path_builder,
                preview_style,
                ..
            } => {
                match engine_view.config.pens_config.brush_config.style {
                    BrushStyle::Marker => {
                        // Don't draw the marker, as the pen would render on top of other strokes, while the stroke itself would render underneath them.
                    }
                    BrushStyle::Solid | BrushStyle::Textured => {
                        path_builder.draw_styled(
                            cx,
                            preview_style,
                            engine_view.camera.total_zoom(),
                        );
                    }
                }
            }
        }

        cx.restore().map_err(|e| anyhow::anyhow!("{e:?}"))?;
        Ok(())
    }
}

impl Brush {
    const INPUT_OVERSHOOT: f64 = 30.0;
    /// Movement in surface pixels that still counts as holding the pen still.
    const HOLD_TOLERANCE: f64 = 4.0;
    /// Strokes smaller than this in surface pixels are never recognized, so writing is left alone.
    const RECOGNITION_MIN_SIZE: f64 = 18.0;
    /// Movement in surface pixels after recognition that brings back the hand-drawn stroke to keep drawing,
    /// so pausing in the middle of a stroke does not cut it short.
    const RESUME_DISTANCE: f64 = 12.0;
    /// Maximum length of the segments of recognized shapes, keeps partial erasing precise.
    const SHAPE_MAX_SEGMENT_LEN: f64 = 24.0;
    /// How far the segments of recognized shapes may deviate from the ideal curve, in surface pixels.
    const SHAPE_FLATNESS: f64 = 0.1;
    /// The largest deviation in document units, so shapes recognized when zoomed out stay smooth when zooming in.
    const SHAPE_FLATNESS_MAX: f64 = 0.05;

    /// Handles the pen being held still, turning the stroke into the recognized shape.
    ///
    /// Moving on brings back the hand-drawn stroke. When the pen is lifted, the hand-drawn stroke is recorded in
    /// the history before the shape, so undoing brings it back.
    pub(crate) fn handle_hold(
        &mut self,
        key: StrokeKey,
        engine_view: &mut EngineViewMut,
    ) -> WidgetFlags {
        let mut widget_flags = WidgetFlags::default();
        let BrushState::Drawing {
            current_stroke_key,
            hold: Some(hold),
            snapped,
            ..
        } = &mut self.state
        else {
            return widget_flags;
        };
        if *current_stroke_key != key || snapped.is_some() || !hold.held_long_enough() {
            return widget_flags;
        }

        let zoom = engine_view.camera.total_zoom();
        let brush_config = &engine_view.config.pens_config.brush_config;
        let options = RecognitionOptions {
            circle_tolerance: brush_config.shape_circle_tolerance,
        };
        let Some(shape) = RecognizedShape::recognize_with(
            &hold.points[..hold.anchor_len],
            Self::RECOGNITION_MIN_SIZE / zoom,
            options,
        ) else {
            return widget_flags;
        };
        let Some(path) = shape.to_pen_path(
            hold.pressure(),
            Self::SHAPE_MAX_SEGMENT_LEN,
            (Self::SHAPE_FLATNESS / zoom).min(Self::SHAPE_FLATNESS_MAX),
        ) else {
            return widget_flags;
        };
        let Some(Stroke::BrushStroke(brushstroke)) = engine_view.store.get_stroke_ref(key) else {
            return widget_flags;
        };
        *snapped = Some(Box::new(Snapped {
            anchor: hold.anchor,
            freehand: brushstroke.path.clone(),
        }));
        widget_flags |= Self::set_stroke_path(path, key, engine_view);
        widget_flags
    }

    fn set_stroke_path(
        path: PenPath,
        key: StrokeKey,
        engine_view: &mut EngineViewMut,
    ) -> WidgetFlags {
        let mut widget_flags = WidgetFlags::default();
        if let Some(Stroke::BrushStroke(brushstroke)) = engine_view.store.get_stroke_mut(key) {
            brushstroke.path = path;
        } else {
            return widget_flags;
        }
        engine_view.store.update_geometry_for_stroke(key);
        engine_view.store.regenerate_rendering_for_stroke(
            key,
            engine_view.camera.viewport(),
            engine_view.camera.image_scale(),
        );
        widget_flags.redraw = true;
        widget_flags.store_modified = true;
        widget_flags
    }

    fn get_preview_style(engine_view: &EngineView) -> Style {
        let mut style = engine_view
            .config
            .pens_config
            .brush_config
            .style_for_current_options();

        if let Some(mut stroke_color) = style.stroke_color() {
            stroke_color.a = 1.0;
            style.set_stroke_color(stroke_color);
        }

        style
    }
}

#[cfg(feature = "ui")]
fn play_marker_sound(engine_view: &mut EngineViewMut) {
    if let Some(audioplayer) = engine_view.audioplayer {
        audioplayer.play_random_marker_sound();
    }
}

#[cfg(feature = "ui")]
fn trigger_brush_sound(engine_view: &mut EngineViewMut) {
    if let Some(audioplayer) = engine_view.audioplayer.as_mut() {
        audioplayer.trigger_random_brush_sound();
    }
}

fn new_builder(
    builder_type: PenPathBuilderType,
    element: Element,
    now: Instant,
) -> Box<dyn Buildable<Emit = Segment>> {
    match builder_type {
        PenPathBuilderType::Simple => Box::new(PenPathSimpleBuilder::start(element, now)),
        PenPathBuilderType::Curved => Box::new(PenPathCurvedBuilder::start(element, now)),
        PenPathBuilderType::Modeled => Box::new(PenPathModeledBuilder::start(element, now)),
    }
}

#[cfg(test)]
mod tests {
    use crate::Engine;
    use crate::strokes::Stroke;
    use futures::FutureExt;
    use p2d::math::Vector2;
    use rnote_compose::penevent::PenEvent;
    use rnote_compose::penpath::Element;
    use std::f64::consts::TAU;
    use std::time::{Duration, Instant};

    fn down(pos: Vector2) -> PenEvent {
        PenEvent::Down {
            element: Element::new(pos, 0.5),
            modifier_keys: Default::default(),
        }
    }

    fn handle_pending_tasks(engine: &mut Engine, rx: &mut crate::engine::EngineTaskReceiver) {
        while let Some(Some(task)) = rx.recv().now_or_never() {
            let _ = engine.handle_engine_task(task);
        }
    }

    /// Distances of the stroke points to the center.
    fn radii(engine: &Engine, center: Vector2) -> Vec<f64> {
        let keys = engine.store.stroke_keys_as_rendered();
        assert_eq!(keys.len(), 1);
        let Some(Stroke::BrushStroke(brushstroke)) = engine.store.get_stroke_ref(keys[0]) else {
            panic!("not a brushstroke");
        };
        brushstroke
            .path
            .clone()
            .into_elements()
            .iter()
            .map(|e| (e.pos - center).length())
            .collect()
    }

    fn spread(values: &[f64]) -> f64 {
        let max = values.iter().copied().fold(f64::MIN, f64::max);
        let min = values.iter().copied().fold(f64::MAX, f64::min);
        max - min
    }

    #[test]
    fn holding_turns_the_stroke_into_a_shape_and_undo_restores_it() {
        let mut engine = Engine::default();
        engine
            .config
            .write()
            .pens_config
            .brush_config
            .shape_recognition_delay_ms = 200;
        let mut rx = engine.take_engine_tasks_rx().unwrap();
        let center = Vector2::new(300.0, 300.0);

        let wobbly = |i: usize| {
            let a = i as f64 / 120.0 * TAU;
            center + Vector2::from_angle(a) * (100.0 + (i as f64 * 1.3).sin() * 4.0)
        };
        for i in 0..=120 {
            let _ = engine.handle_pen_event(down(wobbly(i)), None, Instant::now());
        }
        // holding still, with a bit of jitter
        for _ in 0..5 {
            std::thread::sleep(Duration::from_millis(80));
            let _ = engine.handle_pen_event(
                down(wobbly(120) + Vector2::new(1.0, 0.5)),
                None,
                Instant::now(),
            );
        }
        handle_pending_tasks(&mut engine, &mut rx);
        let _ = engine.handle_pen_event(
            PenEvent::Up {
                element: Element::new(wobbly(120), 0.5),
                modifier_keys: Default::default(),
            },
            None,
            Instant::now(),
        );

        let snapped = radii(&engine, center);
        assert!(snapped.len() > 16);
        assert!(spread(&snapped) < 2.0, "not a circle: {snapped:?}");

        // undo brings back the hand-drawn stroke, then removes it
        let _ = engine.undo(Instant::now());
        assert!(spread(&radii(&engine, center)) > 4.0);
        let _ = engine.undo(Instant::now());
        assert!(engine.store.stroke_keys_as_rendered().is_empty());
    }

    #[test]
    fn moving_on_keeps_the_hand_drawn_stroke() {
        let mut engine = Engine::default();
        let mut rx = engine.take_engine_tasks_rx().unwrap();
        let center = Vector2::new(300.0, 300.0);
        let point = |i: usize| center + Vector2::from_angle(i as f64 / 120.0 * TAU) * 100.0;

        for i in 0..=120 {
            let _ = engine.handle_pen_event(down(point(i)), None, Instant::now());
            std::thread::sleep(Duration::from_millis(5));
        }
        handle_pending_tasks(&mut engine, &mut rx);
        let _ = engine.handle_pen_event(
            PenEvent::Up {
                element: Element::new(point(120), 0.5),
                modifier_keys: Default::default(),
            },
            None,
            Instant::now(),
        );
        // never held still, so the stroke has the input points
        assert!(radii(&engine, center).len() > 100);
    }

    #[test]
    fn pausing_in_the_middle_keeps_drawing() {
        let mut engine = Engine::default();
        engine
            .config
            .write()
            .pens_config
            .brush_config
            .shape_recognition_delay_ms = 200;
        let mut rx = engine.take_engine_tasks_rx().unwrap();
        let center = Vector2::new(300.0, 300.0);
        let wobbly = |i: usize| {
            let a = i as f64 / 120.0 * TAU;
            center + Vector2::from_angle(a) * (100.0 + (i as f64 * 1.3).sin() * 4.0)
        };
        let hold =
            |engine: &mut Engine, rx: &mut crate::engine::EngineTaskReceiver, pos: Vector2| {
                for _ in 0..5 {
                    std::thread::sleep(Duration::from_millis(80));
                    let _ = engine.handle_pen_event(down(pos), None, Instant::now());
                }
                handle_pending_tasks(engine, rx);
            };

        // half of the circle, then a pause that turns it into an arc
        for i in 0..=60 {
            let _ = engine.handle_pen_event(down(wobbly(i)), None, Instant::now());
        }
        hold(&mut engine, &mut rx, wobbly(60));
        // drawing on brings back the stroke and continues it
        for i in 61..=120 {
            let _ = engine.handle_pen_event(down(wobbly(i)), None, Instant::now());
        }
        hold(&mut engine, &mut rx, wobbly(120));
        let _ = engine.handle_pen_event(
            PenEvent::Up {
                element: Element::new(wobbly(120), 0.5),
                modifier_keys: Default::default(),
            },
            None,
            Instant::now(),
        );

        let keys = engine.store.stroke_keys_as_rendered();
        let Some(Stroke::BrushStroke(brushstroke)) = engine.store.get_stroke_ref(keys[0]) else {
            panic!("not a brushstroke");
        };
        let elements = brushstroke.path.clone().into_elements();
        // a full circle, all around the center
        assert!(spread(&radii(&engine, center)) < 2.0);
        for quadrant in 0..4 {
            let a = quadrant as f64 * TAU / 4.0 + TAU / 8.0;
            let dir = Vector2::from_angle(a);
            assert!(
                elements
                    .iter()
                    .any(|e| (e.pos - center).normalize().dot(dir) > 0.99),
                "quadrant {quadrant} is missing"
            );
        }

        // undo brings back the whole hand-drawn stroke
        let _ = engine.undo(Instant::now());
        let freehand = radii(&engine, center);
        assert!(spread(&freehand) > 4.0);
        assert!(freehand.len() > 100);
    }
}
