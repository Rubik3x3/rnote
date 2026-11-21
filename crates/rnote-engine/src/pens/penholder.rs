// Imports
use super::penmode::PenModeState;
use super::shortcuts::ShortcutMode;
use super::{
    Brush, Eraser, Pen, PenBehaviour, PenMode, PenStyle, Selector, Shaper, Tools, Typewriter,
};
use crate::DrawableOnDoc;
use crate::camera::NudgeDirection;
use crate::engine::{EngineView, EngineViewMut};
use crate::pens::shortcuts::ShortcutAction;
use crate::widgetflags::WidgetFlags;
use futures::channel::oneshot;
use p2d::bounding_volume::Aabb;
use p2d::math::Vector2;
use piet::RenderContext;
use rnote_compose::eventresult::EventPropagation;
use rnote_compose::penevent::{KeyboardKey, ModifierKey, PenEvent, PenProgress, ShortcutKey};
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename = "backlog_policy")]
pub enum BacklogPolicy {
    #[serde(rename = "no_limit")]
    NoLimit,
    #[serde(rename = "limit")]
    Limit(Duration),
    #[serde(rename = "disable")]
    Disable,
}

/// The Penholder holds the pens and related state and handles pen events.
#[derive(Debug, Serialize, Deserialize)]
#[serde(default, rename = "penholder")]
pub struct PenHolder {
    #[serde(rename = "pen_mode_state")]
    pen_mode_state: PenModeState,
    /// The policy for the retrieval of input event backlogs.
    #[serde(rename = "backlog_policy")]
    backlog_policy: BacklogPolicy,
    #[serde(skip)]
    current_pen: Pen,
    #[serde(skip)]
    progress: PenProgress,
    #[serde(skip)]
    toggle_pen_style: Option<PenStyle>,
    #[serde(skip)]
    prev_shortcut_key: Option<ShortcutKey>,
    #[serde(skip)]
    quick_text: QuickText,
}

/// State for opening a text box with a double tap while using the brush (like Excalidraw).
#[derive(Debug, Default)]
struct QuickText {
    /// Time and position of the brush down that may become a tap.
    tap_start: Option<(Instant, Vector2)>,
    /// Time and position of the last finished tap.
    last_tap: Option<(Instant, Vector2)>,
    /// The typewriter was opened by a double tap, so it goes back to the brush when done.
    from_brush: bool,
}

impl QuickText {
    /// Longest press that still counts as a tap.
    const TAP_MAX_DURATION: Duration = Duration::from_millis(250);
    /// Longest pause between the two taps.
    const DOUBLE_TAP_MAX_INTERVAL: Duration = Duration::from_millis(350);
    /// Max distance in screen pixels: the two taps must hit the same spot, not two dots of a ":".
    const MAX_DISTANCE: f64 = 6.0;
}

impl Default for PenHolder {
    fn default() -> Self {
        Self {
            pen_mode_state: PenModeState::default(),
            backlog_policy: BacklogPolicy::NoLimit,

            current_pen: Pen::default(),
            progress: PenProgress::Idle,
            toggle_pen_style: None,
            prev_shortcut_key: None,
            quick_text: QuickText::default(),
        }
    }
}

impl PenHolder {
    /// Get the current pen mode state.
    pub fn pen_mode_state(&self) -> PenModeState {
        self.pen_mode_state.clone()
    }

    /// Replace the pen mode state.
    pub fn set_pen_mode_state(&mut self, pen_mode_state: PenModeState) {
        self.pen_mode_state = pen_mode_state;
    }

    pub fn backlog_policy(&self) -> BacklogPolicy {
        self.backlog_policy
    }

    /// Get the style without the temporary override.
    pub fn current_pen_style(&self, engine_view: &EngineView) -> PenStyle {
        self.pen_mode_state.style(&engine_view.config.pens_config)
    }

    /// Get the current style, or the override if it is set.
    pub fn current_pen_style_w_override(&self, engine_view: &EngineView) -> PenStyle {
        self.pen_mode_state
            .current_style_w_override(&engine_view.config.pens_config)
    }

    /// The current pen progress.
    pub fn current_pen_progress(&self) -> PenProgress {
        self.progress
    }

    pub fn current_pen_ref(&mut self) -> &Pen {
        &self.current_pen
    }

    pub fn current_pen_mut(&mut self) -> &mut Pen {
        &mut self.current_pen
    }

    /// Change the pen style.
    pub fn change_style(
        &mut self,
        new_style: PenStyle,
        engine_view: &mut EngineViewMut,
    ) -> WidgetFlags {
        let widget_flags = self.change_style_int(new_style, engine_view);
        // When the style is changed externally, the toggle mode / internal states are reset
        self.toggle_pen_style = None;
        self.prev_shortcut_key = None;
        self.quick_text = QuickText::default();

        widget_flags
    }

    /// Change the style override.
    pub fn change_style_override(
        &mut self,
        new_style_override: Option<PenStyle>,
        engine_view: &mut EngineViewMut,
    ) -> WidgetFlags {
        let mut widget_flags = WidgetFlags::default();

        if self.pen_mode_state.style_override() != new_style_override {
            // Deselecting when changing the style override
            let all_strokes = engine_view.store.selection_keys_as_rendered();
            engine_view.store.set_selected_keys(&all_strokes, false);

            self.pen_mode_state.set_style_override(new_style_override);
            widget_flags |= self.reinstall_pen_current_style(engine_view);
            widget_flags.refresh_ui = true;
        }

        widget_flags
    }

    /// Change the pen mode (pen, eraser, etc.).
    ///
    /// Relevant for stylus input.
    pub fn change_pen_mode(
        &mut self,
        new_pen_mode: PenMode,
        engine_view: &mut EngineViewMut,
    ) -> WidgetFlags {
        let mut widget_flags = WidgetFlags::default();

        if self.pen_mode_state.pen_mode() != new_pen_mode {
            self.pen_mode_state.set_pen_mode(new_pen_mode);
            widget_flags |= self.reinstall_pen_current_style(engine_view);
            widget_flags.refresh_ui = true;
        }

        widget_flags
    }

    pub fn current_pen_update_state(&mut self, engine_view: &mut EngineViewMut) -> WidgetFlags {
        self.current_pen.update_state(engine_view)
    }

    /// Reinstall the pen for the current style.
    pub fn reinstall_pen_current_style(&mut self, engine_view: &mut EngineViewMut) -> WidgetFlags {
        // first cancel the current pen
        let (_, mut widget_flags) =
            self.current_pen
                .handle_event(PenEvent::Cancel, Instant::now(), engine_view);

        // then reinstall a new pen instance
        let mut new_pen = new_pen(self.current_pen_style_w_override(&engine_view.as_im()));
        widget_flags |= new_pen.init(&engine_view.as_im()) | new_pen.update_state(engine_view);
        self.current_pen = new_pen;
        widget_flags |= self.handle_changed_pen_style(engine_view);
        self.progress = PenProgress::Idle;

        widget_flags
    }

    pub fn deinit_current_pen(&mut self) -> WidgetFlags {
        self.current_pen_mut().deinit()
    }

    /// Handle a pen event.
    pub fn handle_pen_event(
        &mut self,
        event: PenEvent,
        pen_mode: Option<PenMode>,
        now: Instant,
        engine_view: &mut EngineViewMut,
    ) -> (EventPropagation, WidgetFlags) {
        let mut widget_flags = WidgetFlags::default();

        if let Some(pen_mode) = pen_mode {
            widget_flags |= self.change_pen_mode(pen_mode, engine_view);
        }

        let (consumed, wf) = self.handle_quick_text(&event, now, engine_view);
        widget_flags |= wf;
        if consumed {
            widget_flags.redraw = true;
            return (EventPropagation::Stop, widget_flags);
        }

        // Handle the event with the current pen
        let (mut event_result, wf) = self
            .current_pen
            .handle_event(event.clone(), now, engine_view);
        widget_flags |= wf | self.handle_pen_progress(event_result.progress, engine_view);

        if !event_result.handled {
            let (propagate, wf) = self.handle_pen_event_global(event, now, engine_view);
            event_result.propagate |= propagate;
            widget_flags |= wf;
        }

        // Always redraw after handling a pen event.
        //
        // This is also needed because pens might have claimed/requested an animation frame.
        widget_flags.redraw = true;

        (event_result.propagate, widget_flags)
    }

    /// Handle a requested animation frame.
    ///
    /// Can request another frame using `EngineViewMut#animation.claim_frame()`.
    pub fn handle_animation_frame(&mut self, engine_view: &mut EngineViewMut) {
        self.current_pen.handle_animation_frame(engine_view);
    }

    /// Handle a pressed shortcut key.
    pub fn handle_pressed_shortcut_key(
        &mut self,
        shortcut_key: ShortcutKey,
        _now: Instant,
        engine_view: &mut EngineViewMut,
    ) -> (EventPropagation, WidgetFlags) {
        let mut widget_flags = WidgetFlags::default();
        let mut propagate = EventPropagation::Proceed;

        if let Some(action) = engine_view
            .config
            .pens_config
            .get_shortcut_action(shortcut_key)
        {
            match action {
                ShortcutAction::ChangePenStyle { style, mode } => match mode {
                    ShortcutMode::Temporary => {
                        widget_flags |= self.change_style_override(Some(style), engine_view);
                    }
                    ShortcutMode::Permanent => {
                        self.toggle_pen_style = None;
                        widget_flags |= self.change_style_int(style, engine_view);
                    }
                    ShortcutMode::Toggle => {
                        if let Some(toggle_pen_style) = self.toggle_pen_style {
                            // if the previous key was different, but also in toggle mode,
                            // we switch to the new style instead of toggling back
                            if self
                                .prev_shortcut_key
                                .map(|k| k != shortcut_key)
                                .unwrap_or(true)
                            {
                                widget_flags |= self.change_style_int(style, engine_view);
                            } else {
                                self.toggle_pen_style = None;
                                widget_flags |=
                                    self.change_style_int(toggle_pen_style, engine_view);
                            }
                        } else {
                            self.toggle_pen_style =
                                Some(self.current_pen_style(&engine_view.as_im()));
                            widget_flags |= self.change_style_int(style, engine_view);
                        }
                    }
                    ShortcutMode::Disabled => {}
                },
            }

            propagate = EventPropagation::Stop;
        }

        self.prev_shortcut_key = Some(shortcut_key);
        widget_flags.redraw = true;

        (propagate, widget_flags)
    }

    /// Fetch clipboard content from the current pen.
    #[allow(clippy::type_complexity)]
    pub fn fetch_clipboard_content(
        &self,
        engine_view: &EngineView,
    ) -> oneshot::Receiver<anyhow::Result<(Vec<(Vec<u8>, String)>, WidgetFlags)>> {
        self.current_pen.fetch_clipboard_content(engine_view)
    }

    /// Cut clipboard content from the current pen.
    #[allow(clippy::type_complexity)]
    pub fn cut_clipboard_content(
        &mut self,
        engine_view: &mut EngineViewMut,
    ) -> oneshot::Receiver<anyhow::Result<(Vec<(Vec<u8>, String)>, WidgetFlags)>> {
        self.current_pen.cut_clipboard_content(engine_view)
    }

    /// Internal method for changing the pen style, without some of the side effects that are happening in the public
    /// method.
    fn change_style_int(
        &mut self,
        new_style: PenStyle,
        engine_view: &mut EngineViewMut,
    ) -> WidgetFlags {
        let mut widget_flags = WidgetFlags::default();

        if self.pen_mode_state.style(&engine_view.config.pens_config) != new_style {
            // Deselecting when changing the style
            let all_strokes = engine_view.store.selection_keys_as_rendered();
            engine_view.store.set_selected_keys(&all_strokes, false);

            self.pen_mode_state
                .set_style(&mut engine_view.config.pens_config, new_style);
            widget_flags |= self.reinstall_pen_current_style(engine_view);
            widget_flags.refresh_ui = true;
        }

        widget_flags
    }

    /// Double tap with the brush opens a text box on that spot (or edits the text under it).
    /// Escape or a tap outside the text goes back to the brush.
    ///
    /// Returns true when the event was used up here and must not reach the current pen.
    fn handle_quick_text(
        &mut self,
        event: &PenEvent,
        now: Instant,
        engine_view: &mut EngineViewMut,
    ) -> (bool, WidgetFlags) {
        let mut widget_flags = WidgetFlags::default();
        let style = self.current_pen_style_w_override(&engine_view.as_im());
        let zoom = engine_view.camera.total_zoom();
        let near = |a: Vector2, b: Vector2| (a - b).length() * zoom <= QuickText::MAX_DISTANCE;
        // Down is repeated while the pen moves, only the first one starts a stroke
        let starts_stroke = self.progress != PenProgress::InProgress;

        match (style, event) {
            (PenStyle::Brush, PenEvent::Down { element, .. }) if starts_stroke => {
                let double_tap = self.quick_text.last_tap.take().is_some_and(|(t, pos)| {
                    now.duration_since(t) <= QuickText::DOUBLE_TAP_MAX_INTERVAL
                        && near(pos, element.pos)
                });
                if !double_tap {
                    self.quick_text.tap_start = Some((now, element.pos));
                    return (false, widget_flags);
                }
                // the first tap left a dot, which is the latest history entry
                widget_flags |= engine_view.store.undo(now);
                engine_view.store.regenerate_rendering_in_viewport_threaded(
                    engine_view.tasks_tx.clone(),
                    false,
                    engine_view.camera.viewport(),
                    engine_view.camera.image_scale(),
                );
                widget_flags |= self.change_style_int(PenStyle::Typewriter, engine_view);
                self.quick_text.from_brush = true;
                for event in [
                    PenEvent::Down {
                        element: *element,
                        modifier_keys: Default::default(),
                    },
                    PenEvent::Up {
                        element: *element,
                        modifier_keys: Default::default(),
                    },
                ] {
                    let (result, wf) = self.current_pen.handle_event(event, now, engine_view);
                    widget_flags |= wf | self.handle_pen_progress(result.progress, engine_view);
                }
                (true, widget_flags)
            }
            (PenStyle::Brush, PenEvent::Up { element, .. }) => {
                if let Some((t, pos)) = self.quick_text.tap_start.take()
                    && now.duration_since(t) <= QuickText::TAP_MAX_DURATION
                    && near(pos, element.pos)
                {
                    self.quick_text.last_tap = Some((now, pos));
                }
                (false, widget_flags)
            }
            (PenStyle::Typewriter, PenEvent::Down { element, .. })
                if self.quick_text.from_brush && starts_stroke =>
            {
                let on_text = self
                    .current_pen
                    .bounds_on_doc(&engine_view.as_im())
                    .is_some_and(|b| b.contains_local_point(element.pos));
                if !on_text {
                    // back to the brush, and this same down already starts drawing
                    self.quick_text = QuickText::default();
                    widget_flags |= self.change_style_int(PenStyle::Brush, engine_view);
                }
                (false, widget_flags)
            }
            (
                PenStyle::Typewriter,
                PenEvent::KeyPressed {
                    keyboard_key: KeyboardKey::Escape,
                    ..
                },
            ) if self.quick_text.from_brush => {
                self.quick_text = QuickText::default();
                widget_flags |= self.change_style_int(PenStyle::Brush, engine_view);
                (true, widget_flags)
            }
            _ => (false, widget_flags),
        }
    }

    /// Handles the pen event in the global scope if the current pen has not handled it.
    ///
    /// Used to implement things like nudging the view, react to pressed buttons that weren't handled by th pen, ..
    fn handle_pen_event_global(
        &mut self,
        event: PenEvent,
        _now: Instant,
        engine_view: &mut EngineViewMut,
    ) -> (EventPropagation, WidgetFlags) {
        const MOVE_VIEW_FACTOR: f64 = 0.33;
        let mut widget_flags = WidgetFlags::default();

        let propagate = match event {
            PenEvent::Down { .. }
            | PenEvent::Up { .. }
            | PenEvent::Proximity { .. }
            | PenEvent::Text { .. }
            | PenEvent::Cancel => EventPropagation::Proceed,
            PenEvent::KeyPressed {
                keyboard_key,
                modifier_keys,
            } => match keyboard_key {
                KeyboardKey::NavUp => {
                    let nudge_amount = if modifier_keys.contains(&ModifierKey::KeyboardCtrl) {
                        engine_view.camera.size()[1]
                    } else {
                        engine_view.camera.size()[1] * MOVE_VIEW_FACTOR
                    };
                    widget_flags |= engine_view.camera.nudge_by(
                        nudge_amount,
                        NudgeDirection::North,
                        engine_view.document,
                    );
                    engine_view.store.regenerate_rendering_in_viewport_threaded(
                        engine_view.tasks_tx.clone(),
                        false,
                        engine_view.camera.viewport(),
                        engine_view.camera.image_scale(),
                    );

                    EventPropagation::Stop
                }
                KeyboardKey::NavDown => {
                    let nudge_amount = if modifier_keys.contains(&ModifierKey::KeyboardCtrl) {
                        engine_view.camera.size()[1]
                    } else {
                        engine_view.camera.size()[1] * MOVE_VIEW_FACTOR
                    };
                    widget_flags |= engine_view.camera.nudge_by(
                        nudge_amount,
                        NudgeDirection::South,
                        engine_view.document,
                    );
                    engine_view.store.regenerate_rendering_in_viewport_threaded(
                        engine_view.tasks_tx.clone(),
                        false,
                        engine_view.camera.viewport(),
                        engine_view.camera.image_scale(),
                    );

                    EventPropagation::Stop
                }
                KeyboardKey::NavLeft => {
                    let nudge_amount = if modifier_keys.contains(&ModifierKey::KeyboardCtrl) {
                        engine_view.camera.size()[0]
                    } else {
                        engine_view.camera.size()[0] * MOVE_VIEW_FACTOR
                    };
                    widget_flags |= engine_view.camera.nudge_by(
                        nudge_amount,
                        NudgeDirection::West,
                        engine_view.document,
                    );
                    engine_view.store.regenerate_rendering_in_viewport_threaded(
                        engine_view.tasks_tx.clone(),
                        false,
                        engine_view.camera.viewport(),
                        engine_view.camera.image_scale(),
                    );

                    EventPropagation::Stop
                }
                KeyboardKey::NavRight => {
                    let nudge_amount = if modifier_keys.contains(&ModifierKey::KeyboardCtrl) {
                        engine_view.camera.size()[0]
                    } else {
                        engine_view.camera.size()[0] * MOVE_VIEW_FACTOR
                    };
                    widget_flags |= engine_view.camera.nudge_by(
                        nudge_amount,
                        NudgeDirection::East,
                        engine_view.document,
                    );
                    engine_view.store.regenerate_rendering_in_viewport_threaded(
                        engine_view.tasks_tx.clone(),
                        false,
                        engine_view.camera.viewport(),
                        engine_view.camera.image_scale(),
                    );

                    EventPropagation::Stop
                }
                _ => EventPropagation::Proceed,
            },
        };

        (propagate, widget_flags)
    }

    fn handle_pen_progress(
        &mut self,
        progress: PenProgress,
        engine_view: &mut EngineViewMut,
    ) -> WidgetFlags {
        let mut widget_flags = WidgetFlags::default();

        match progress {
            PenProgress::Idle => {}
            PenProgress::InProgress => {}
            PenProgress::Finished => {
                // take the style override when pen is finished
                if self.pen_mode_state.take_style_override().is_some() {
                    widget_flags.refresh_ui = true;
                    widget_flags |= self.reinstall_pen_current_style(engine_view);
                }
            }
        }

        self.progress = progress;

        widget_flags
    }

    fn handle_changed_pen_style(&mut self, engine_view: &mut EngineViewMut) -> WidgetFlags {
        let mut widget_flags = WidgetFlags::default();
        let current_style = self
            .pen_mode_state
            .current_style_w_override(&engine_view.config.pens_config);

        self.backlog_policy = match current_style {
            PenStyle::Brush => BacklogPolicy::Limit(Duration::from_millis(4)),
            PenStyle::Shaper => BacklogPolicy::Limit(Duration::from_millis(8)),
            PenStyle::Typewriter => BacklogPolicy::Limit(Duration::from_millis(33)),
            PenStyle::Eraser => BacklogPolicy::Limit(Duration::from_millis(33)),
            PenStyle::Selector => BacklogPolicy::Limit(Duration::from_millis(33)),
            PenStyle::Tools => BacklogPolicy::Disable,
        };

        // Enable text preprocessing for typewriter
        widget_flags.enable_text_preprocessing = Some(current_style == PenStyle::Typewriter);
        widget_flags.redraw = true;

        widget_flags
    }
}

impl DrawableOnDoc for PenHolder {
    fn bounds_on_doc(&self, engine_view: &EngineView) -> Option<Aabb> {
        self.current_pen.bounds_on_doc(engine_view)
    }
    fn draw_on_doc(
        &self,
        cx: &mut piet_cairo::CairoRenderContext,
        engine_view: &EngineView,
    ) -> anyhow::Result<()> {
        cx.save().map_err(|e| anyhow::anyhow!("{e:?}"))?;

        self.current_pen.draw_on_doc(cx, engine_view)?;

        cx.restore().map_err(|e| anyhow::anyhow!("{e:?}"))?;
        Ok(())
    }
}

fn new_pen(pen_style: PenStyle) -> Pen {
    match pen_style {
        PenStyle::Brush => Pen::Brush(Brush::default()),
        PenStyle::Shaper => Pen::Shaper(Shaper::default()),
        PenStyle::Typewriter => Pen::Typewriter(Typewriter::default()),
        PenStyle::Eraser => Pen::Eraser(Eraser::default()),
        PenStyle::Selector => Pen::Selector(Selector::default()),
        PenStyle::Tools => Pen::Tools(Tools::default()),
    }
}

#[cfg(test)]
mod tests {
    use crate::Engine;
    use crate::pens::PenStyle;
    use p2d::math::Vector2;
    use rnote_compose::penevent::{KeyboardKey, PenEvent};
    use rnote_compose::penpath::Element;
    use std::time::{Duration, Instant};

    fn tap(engine: &mut Engine, pos: Vector2, at: Instant) {
        let element = Element::new(pos, 0.5);
        let modifier_keys = Default::default();
        let _ = engine.handle_pen_event(
            PenEvent::Down {
                element,
                modifier_keys,
            },
            None,
            at,
        );
        let _ = engine.handle_pen_event(
            PenEvent::Up {
                element,
                modifier_keys: Default::default(),
            },
            None,
            at + Duration::from_millis(50),
        );
    }

    #[test]
    fn double_tap_opens_text_without_leaving_a_dot() {
        let mut engine = Engine::default();
        let _ = engine.change_pen_style(PenStyle::Brush);
        let t = Instant::now();
        let pos = Vector2::new(100.0, 100.0);

        tap(&mut engine, pos, t);
        assert_eq!(engine.store.stroke_keys_as_rendered().len(), 1);
        tap(&mut engine, pos + Vector2::new(1.0, 1.0), t + Duration::from_millis(200));

        assert_eq!(engine.current_pen_style_w_override(), PenStyle::Typewriter);
        assert!(engine.store.stroke_keys_as_rendered().is_empty());

        let _ = engine.handle_pen_event(
            PenEvent::KeyPressed {
                keyboard_key: KeyboardKey::Escape,
                modifier_keys: Default::default(),
            },
            None,
            t + Duration::from_millis(400),
        );
        assert_eq!(engine.current_pen_style_w_override(), PenStyle::Brush);
    }

    #[test]
    fn two_dots_of_a_colon_stay_dots() {
        let mut engine = Engine::default();
        let _ = engine.change_pen_style(PenStyle::Brush);
        let t = Instant::now();

        tap(&mut engine, Vector2::new(100.0, 100.0), t);
        tap(&mut engine, Vector2::new(100.0, 112.0), t + Duration::from_millis(200));

        assert_eq!(engine.current_pen_style_w_override(), PenStyle::Brush);
        assert_eq!(engine.store.stroke_keys_as_rendered().len(), 2);
    }
}
