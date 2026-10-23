//! Dispatches application shortcuts with the primary modifier while the canvas has the focus.
//!
//! The canvas receives key presses before the window handles application shortcuts. Pens can consume them as
//! text, and on macOS the input method can swallow Command combinations entirely, so e.g. Command+Z would not
//! undo. Activating the shortcut's action before the canvas sees the key press avoids both.

// Imports
use crate::{RnAppWindow, RnCanvas};
use gtk4::{EventControllerKey, PropagationPhase, gio, glib, prelude::*};

/// Installs the guard on the window.
pub(crate) fn install(window: &RnAppWindow) {
    let key_controller = EventControllerKey::builder()
        .propagation_phase(PropagationPhase::Capture)
        .build();

    key_controller.connect_key_pressed(|controller, key, _, modifiers| {
        let Some(window) = controller
            .widget()
            .and_then(|w| w.downcast::<gtk4::ApplicationWindow>().ok())
        else {
            return glib::Propagation::Proceed;
        };
        if !modifiers.contains(crate::canvas::PRIMARY_MODIFIER_MASK) || !canvas_has_focus(&window) {
            return glib::Propagation::Proceed;
        }
        let Some(app) = window.application() else {
            return glib::Propagation::Proceed;
        };

        let accel = gtk4::accelerator_name(
            key.to_lower(),
            modifiers & gtk4::accelerator_get_default_mod_mask(),
        );
        let actions = app.actions_for_accel(&accel);
        let Some(detailed_name) = actions.first() else {
            return glib::Propagation::Proceed;
        };

        match gio::Action::parse_detailed_name(detailed_name) {
            Ok((name, target)) => {
                if let Err(e) = WidgetExt::activate_action(&window, &name, target.as_ref()) {
                    tracing::error!(
                        "Activating action '{name}' for accel '{accel}' failed, Err: {e:?}"
                    );
                    return glib::Propagation::Proceed;
                }
                glib::Propagation::Stop
            }
            Err(e) => {
                tracing::error!(
                    "Parsing detailed action name '{detailed_name}' failed, Err: {e:?}"
                );
                glib::Propagation::Proceed
            }
        }
    });

    window.add_controller(key_controller);
}

/// Whether the focus is on a canvas, and not e.g. in a text entry where shortcuts like copy belong to the entry.
fn canvas_has_focus(window: &gtk4::ApplicationWindow) -> bool {
    let mut widget = gtk4::prelude::GtkWindowExt::focus(window);
    while let Some(w) = widget {
        if w.is::<RnCanvas>() {
            return true;
        }
        widget = w.parent();
    }
    false
}
