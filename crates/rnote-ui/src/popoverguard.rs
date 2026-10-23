//! Reliably closes popovers when clicking outside of them.
//!
//! Popover autohide is not dependable on every platform (e.g. on macOS popovers stay open when clicking on the
//! canvas), so popovers get closed by the window itself on any press outside of them.
//! Because opening another popover is such a press as well, at most one popover stays open.

// Imports
use gtk4::{GestureClick, PropagationPhase, prelude::*};

/// Installs the guard on the window.
pub(crate) fn install(window: &impl IsA<gtk4::Window>) {
    let window = window.upcast_ref::<gtk4::Window>();
    let press_gesture = GestureClick::builder()
        .button(0)
        .propagation_phase(PropagationPhase::Capture)
        .build();

    press_gesture.connect_pressed(|gesture, _, x, y| {
        let Some(window) = gesture.widget() else {
            return;
        };
        // presses inside a popover arrive on the popover's own surface and are left alone
        let on_window_surface = gesture
            .current_event()
            .and_then(|event| event.surface())
            .zip(window.native().and_then(|native| native.surface()))
            .is_some_and(|(event_surface, window_surface)| event_surface == window_surface);
        if !on_window_surface {
            return;
        }

        let picked = window.pick(x, y, gtk4::PickFlags::DEFAULT);
        for popover in visible_popovers(&window) {
            if picked
                .as_ref()
                .zip(popover.parent())
                .is_some_and(|(picked, owner)| picked == &owner || picked.is_ancestor(&owner))
            {
                // the press is on the widget owning the popover, which toggles it by itself
                continue;
            }
            popover.popdown();
        }
    });

    window.add_controller(press_gesture);
}

/// All currently visible popovers below the widget.
fn visible_popovers(root: &gtk4::Widget) -> Vec<gtk4::Popover> {
    let mut popovers = Vec::new();
    let mut stack = vec![root.clone()];

    while let Some(widget) = stack.pop() {
        if let Some(popover) = widget.downcast_ref::<gtk4::Popover>() {
            if popover.is_visible() {
                popovers.push(popover.clone());
            }
            // nested popovers belong to their open parent popover and close with it
            continue;
        }
        let mut child = widget.first_child();
        while let Some(c) = child {
            child = c.next_sibling();
            stack.push(c);
        }
    }

    popovers
}
