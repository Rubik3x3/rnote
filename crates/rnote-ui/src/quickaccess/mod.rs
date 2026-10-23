//! A customizable bar with buttons for often used tools, shapes and actions.

// Modules
mod items;

// Re-exports
pub(crate) use items::QuickItem;

// Imports
use crate::RnAppWindow;
use gettextrs::gettext;
use gtk4::{
    Align, ArrowType, Box, Button, CheckButton, CompositeTemplate, GestureClick, GestureLongPress,
    Image, Label, MenuButton, Orientation, Popover, PositionType, TemplateChild, Widget,
    glib::{self, clone},
    prelude::*,
    subclass::prelude::*,
};
use items::Group;
use std::cell::{Cell, RefCell};

/// The settings key storing the item ids.
const SETTINGS_KEY: &str = "quick-access-items";

/// Edits the item list, given the index of the item the edit was requested on.
type EditItems = fn(&mut Vec<QuickItem>, usize);

mod imp {
    use super::*;

    #[derive(Default, Debug, CompositeTemplate)]
    #[template(resource = "/com/github/flxzt/rnote/ui/quickaccessbar.ui")]
    pub(crate) struct RnQuickAccessBar {
        pub(crate) items: RefCell<Vec<QuickItem>>,
        pub(crate) appwindow: glib::WeakRef<RnAppWindow>,
        pub(crate) chooser_checks: RefCell<Vec<(QuickItem, CheckButton)>>,
        /// Set while the check buttons are synced with the items, to ignore their toggled signals.
        pub(crate) syncing: Cell<bool>,

        #[template_child]
        pub(crate) items_box: TemplateChild<Box>,
        #[template_child]
        pub(crate) separator: TemplateChild<gtk4::Separator>,
        #[template_child]
        pub(crate) add_menubutton: TemplateChild<MenuButton>,
        #[template_child]
        pub(crate) chooser_box: TemplateChild<Box>,
        #[template_child]
        pub(crate) reset_button: TemplateChild<Button>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for RnQuickAccessBar {
        const NAME: &'static str = "RnQuickAccessBar";
        type Type = super::RnQuickAccessBar;
        type ParentType = Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for RnQuickAccessBar {
        fn dispose(&self) {
            self.dispose_template();
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for RnQuickAccessBar {}
}

glib::wrapper! {
    pub(crate) struct RnQuickAccessBar(ObjectSubclass<imp::RnQuickAccessBar>)
        @extends Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for RnQuickAccessBar {
    fn default() -> Self {
        Self::new()
    }
}

impl RnQuickAccessBar {
    pub(crate) fn new() -> Self {
        glib::Object::new()
    }

    pub(crate) fn init(&self, appwindow: &RnAppWindow) {
        let imp = self.imp();
        imp.appwindow.set(Some(appwindow));

        self.build_chooser();
        imp.reset_button.connect_clicked(clone!(
            #[weak(rename_to=bar)]
            self,
            move |_| bar.set_items(default_items())
        ));

        let stored = appwindow
            .app()
            .app_settings()
            .map(|settings| {
                settings
                    .strv(SETTINGS_KEY)
                    .iter()
                    .filter_map(|id| QuickItem::from_id(id.as_str()))
                    .collect::<Vec<QuickItem>>()
            })
            .unwrap_or_else(default_items);
        self.set_items(stored);
    }

    /// Places the bar on the left or the right side of the canvas, its popovers open towards the canvas.
    pub(crate) fn set_side(&self, left: bool) {
        self.set_halign(if left { Align::Start } else { Align::End });
        self.imp().add_menubutton.set_direction(if left {
            ArrowType::Right
        } else {
            ArrowType::Left
        });
    }

    fn popover_position(&self) -> PositionType {
        if self.halign() == Align::Start {
            PositionType::Right
        } else {
            PositionType::Left
        }
    }

    /// Replaces the items, rebuilds the bar and stores them in the settings.
    pub(crate) fn set_items(&self, items: Vec<QuickItem>) {
        let imp = self.imp();
        imp.items.replace(items);
        self.rebuild_buttons();
        self.sync_chooser();

        if let Some(settings) = imp
            .appwindow
            .upgrade()
            .and_then(|appwindow| appwindow.app().app_settings())
        {
            let ids = imp
                .items
                .borrow()
                .iter()
                .map(|item| item.id())
                .collect::<Vec<&str>>();
            if let Err(e) = settings.set_strv(SETTINGS_KEY, ids) {
                tracing::error!("Saving quick access items failed, Err: {e:?}");
            }
        }
    }

    fn update_items(&self, f: impl FnOnce(&mut Vec<QuickItem>)) {
        let mut items = self.imp().items.borrow().clone();
        f(&mut items);
        self.set_items(items);
    }

    fn rebuild_buttons(&self) {
        let imp = self.imp();
        while let Some(child) = imp.items_box.first_child() {
            imp.items_box.remove(&child);
        }
        let items = imp.items.borrow().clone();
        imp.separator.set_visible(!items.is_empty());

        for (idx, item) in items.iter().copied().enumerate() {
            let button = Button::builder()
                .icon_name(item.icon_name())
                .tooltip_text(item.label())
                .css_classes(["flat"])
                .build();
            button.connect_clicked(clone!(
                #[weak(rename_to=bar)]
                self,
                move |_| {
                    if let Some(appwindow) = bar.imp().appwindow.upgrade() {
                        item.activate(&appwindow);
                    }
                }
            ));

            // right click, or a long press on touch screens, offers to reorder or remove the item
            let secondary_click = GestureClick::builder()
                .button(gtk4::gdk::BUTTON_SECONDARY)
                .build();
            secondary_click.connect_pressed(clone!(
                #[weak(rename_to=bar)]
                self,
                #[weak]
                button,
                move |gesture, _, _, _| {
                    gesture.set_state(gtk4::EventSequenceState::Claimed);
                    bar.show_item_menu(&button, idx);
                }
            ));
            button.add_controller(secondary_click);
            let long_press = GestureLongPress::new();
            long_press.connect_pressed(clone!(
                #[weak(rename_to=bar)]
                self,
                #[weak]
                button,
                move |gesture, _, _| {
                    gesture.set_state(gtk4::EventSequenceState::Claimed);
                    bar.show_item_menu(&button, idx);
                }
            ));
            button.add_controller(long_press);

            imp.items_box.append(&button);
        }
    }

    fn show_item_menu(&self, button: &Button, idx: usize) {
        let n_items = self.imp().items.borrow().len();
        let menu_box = Box::builder()
            .orientation(Orientation::Vertical)
            .spacing(2)
            .build();
        let popover = Popover::builder()
            .child(&menu_box)
            .position(self.popover_position())
            .build();

        let entries: [(&str, String, bool, EditItems); 3] = [
            (
                "go-up-symbolic",
                gettext("Move Up"),
                idx > 0,
                |items, idx| items.swap(idx, idx - 1),
            ),
            (
                "go-down-symbolic",
                gettext("Move Down"),
                idx + 1 < n_items,
                |items, idx| items.swap(idx, idx + 1),
            ),
            (
                "user-trash-symbolic",
                gettext("Remove"),
                true,
                |items, idx| {
                    items.remove(idx);
                },
            ),
        ];
        for (icon, label, sensitive, apply) in entries {
            let entry = Button::builder()
                .child(&icon_label_box(icon, &label))
                .css_classes(["flat"])
                .sensitive(sensitive)
                .build();
            entry.connect_clicked(clone!(
                #[weak(rename_to=bar)]
                self,
                #[weak]
                popover,
                move |_| {
                    popover.popdown();
                    bar.update_items(|items| apply(items, idx));
                }
            ));
            menu_box.append(&entry);
        }

        popover.set_parent(button);
        popover.connect_closed(|popover| {
            // unparent after the closing animation, the button might be rebuilt already
            glib::idle_add_local_once(clone!(
                #[weak]
                popover,
                move || popover.unparent()
            ));
        });
        popover.popup();
    }

    /// Builds the chooser with a check button per available item, grouped.
    fn build_chooser(&self) {
        let imp = self.imp();
        let mut checks = Vec::new();

        for group in Group::ALL {
            let header = Label::builder()
                .label(group.label())
                .xalign(0.0)
                .margin_top(6)
                .css_classes(["caption-heading", "dim-label"])
                .build();
            imp.chooser_box.append(&header);

            for item in QuickItem::all().into_iter().filter(|i| i.group() == group) {
                let check = CheckButton::builder()
                    .child(&icon_label_box(&item.icon_name(), &item.label()))
                    .build();
                check.connect_toggled(clone!(
                    #[weak(rename_to=bar)]
                    self,
                    move |check| {
                        if bar.imp().syncing.get() {
                            return;
                        }
                        let active = check.is_active();
                        bar.update_items(|items| {
                            items.retain(|i| *i != item);
                            if active {
                                items.push(item);
                            }
                        });
                    }
                ));
                imp.chooser_box.append(&check);
                checks.push((item, check));
            }
        }
        imp.chooser_checks.replace(checks);
    }

    fn sync_chooser(&self) {
        let imp = self.imp();
        imp.syncing.set(true);
        let items = imp.items.borrow();
        for (item, check) in imp.chooser_checks.borrow().iter() {
            check.set_active(items.contains(item));
        }
        imp.syncing.set(false);
    }
}

fn default_items() -> Vec<QuickItem> {
    [
        "shape-rectangle",
        "shape-ellipse",
        "shape-arrow",
        "shape-coord-system-2d",
        "function-graph",
    ]
    .into_iter()
    .filter_map(QuickItem::from_id)
    .collect()
}

fn icon_label_box(icon_name: &str, label: &str) -> Box {
    let content = Box::builder().spacing(8).build();
    content.append(&Image::from_icon_name(icon_name));
    content.append(&Label::builder().label(label).xalign(0.0).build());
    content
}
