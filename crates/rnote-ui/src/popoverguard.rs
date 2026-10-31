//! Reliably closes popovers, dialogs and helper windows when clicking outside of them.
//!
//! Popover autohide is not dependable on every platform (e.g. on macOS popovers stay open when clicking on the
//! canvas), so popovers get closed by the window itself on any press outside of them.
//! Because opening another popover is such a press as well, at most one popover stays open.
//! The same holds for popovers opened inside other popovers.
//!
//! Dialogs presented inside the window are closed by a press next to them, like pressing Escape would.
//! Non-modal helper windows like the keyboard shortcuts are closed by a press on the window.

// Imports
use adw::prelude::*;
use gtk4::{EventSequenceState, GestureClick, PropagationPhase};

/// Installs the guard on the window.
pub(crate) fn install(window: &impl IsA<gtk4::Window>) {
    let window = window.upcast_ref::<gtk4::Window>();
    let press_gesture = GestureClick::builder()
        .button(0)
        .propagation_phase(PropagationPhase::Capture)
        .build();

    press_gesture.connect_pressed(|gesture, _, x, y| {
        let Some(window) = gesture.widget().and_downcast::<gtk4::Window>() else {
            return;
        };
        let Some(event_surface) = gesture.current_event().and_then(|event| event.surface()) else {
            return;
        };
        let on_window_surface = window
            .native()
            .and_then(|native| native.surface())
            .is_some_and(|window_surface| window_surface == event_surface);

        if !on_window_surface {
            // presses inside a popover arrive on the popover's own surface,
            // they only close the popovers that were opened from inside it
            if let Some(popover) = all_visible_popovers(window.upcast_ref())
                .into_iter()
                .find(|p| p.surface().is_some_and(|s| s == event_surface))
                && let Some((ex, ey)) = gesture.current_event().and_then(|e| e.position())
            {
                let (tx, ty) = popover.surface_transform();
                let picked = popover.pick(ex - tx, ey - ty, gtk4::PickFlags::DEFAULT);
                if let Some(child) = popover.child() {
                    close_popovers_outside(&child, picked.as_ref());
                }
            }
            return;
        }

        let picked = window.pick(x, y, gtk4::PickFlags::DEFAULT);

        // helper windows on top of this one
        for toplevel in gtk4::Window::list_toplevels() {
            if let Ok(toplevel) = toplevel.downcast::<gtk4::Window>()
                && toplevel.is_visible()
                && !toplevel.is_modal()
                && toplevel
                    .transient_for()
                    .is_some_and(|parent| parent == window)
            {
                toplevel.close();
            }
        }

        // the dialog presented inside the window
        if let Some(dialog) = window
            .downcast_ref::<adw::ApplicationWindow>()
            .and_then(|w| w.visible_dialog())
        {
            let inside = picked.as_ref().is_some_and(|p| {
                p == dialog.upcast_ref::<gtk4::Widget>() || p.is_ancestor(&dialog)
            });
            if !inside {
                close_popovers_outside(dialog.upcast_ref(), None);
                dialog.close();
                gesture.set_state(EventSequenceState::Claimed);
                return;
            }
        }

        close_popovers_outside(window.upcast_ref(), picked.as_ref());
    });

    window.add_controller(press_gesture);
}

/// Closes the visible popovers below the root, except the one the press toggles itself.
fn close_popovers_outside(root: &gtk4::Widget, picked: Option<&gtk4::Widget>) {
    for popover in visible_popovers(root) {
        if picked
            .zip(popover.parent())
            .is_some_and(|(picked, owner)| picked == &owner || picked.is_ancestor(&owner))
        {
            // the press is on the widget owning the popover, which toggles it by itself
            continue;
        }
        popover.popdown();
    }
}

/// The currently visible popovers below the widget, without the ones nested in them.
fn visible_popovers(root: &gtk4::Widget) -> Vec<gtk4::Popover> {
    collect_popovers(root, false)
}

/// All currently visible popovers below the widget, including nested ones.
fn all_visible_popovers(root: &gtk4::Widget) -> Vec<gtk4::Popover> {
    collect_popovers(root, true)
}

fn collect_popovers(root: &gtk4::Widget, nested: bool) -> Vec<gtk4::Popover> {
    let mut popovers = Vec::new();
    let mut stack = vec![root.clone()];

    while let Some(widget) = stack.pop() {
        if let Some(popover) = widget.downcast_ref::<gtk4::Popover>() {
            if !popover.is_visible() {
                continue;
            }
            popovers.push(popover.clone());
            if !nested {
                // nested popovers belong to their open parent popover and close with it
                continue;
            }
        }
        let mut child = widget.first_child();
        while let Some(c) = child {
            child = c.next_sibling();
            stack.push(c);
        }
    }

    popovers
}
