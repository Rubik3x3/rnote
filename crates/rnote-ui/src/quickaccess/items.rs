//! The catalog of everything that can be placed on the quick access bar.
//!
//! To offer a new item, add a variant and fill in its id, group, icon, label and activation below.

// Imports
use crate::RnAppWindow;
use crate::penssidebar::shaperpage::shape_builder_type_icons_to_display_name;
use gettextrs::gettext;
use gtk4::{glib, prelude::*};
use rnote_compose::builders::ShapeBuilderType;

/// The groups in the item chooser.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Group {
    Tools,
    Shapes,
    Insert,
}

impl Group {
    pub(crate) const ALL: [Group; 3] = [Group::Tools, Group::Shapes, Group::Insert];

    pub(crate) fn label(self) -> String {
        match self {
            Self::Tools => gettext("Tools"),
            Self::Shapes => gettext("Shapes"),
            Self::Insert => gettext("Insert and Actions"),
        }
    }
}

/// A pen, selected through the `win.pen-style` action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PenItem {
    Brush,
    Eraser,
    Selector,
    Typewriter,
    Tools,
}

/// A window action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ActionItem {
    FunctionGraph,
    ImportFile,
    AddPage,
    Undo,
    Redo,
}

/// An item of the quick access bar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum QuickItem {
    Pen(PenItem),
    Shape(ShapeBuilderType),
    Action(ActionItem),
}

const SHAPES: [(ShapeBuilderType, &str); 13] = [
    (ShapeBuilderType::Line, "shape-line"),
    (ShapeBuilderType::Arrow, "shape-arrow"),
    (ShapeBuilderType::Rectangle, "shape-rectangle"),
    (ShapeBuilderType::Ellipse, "shape-ellipse"),
    (ShapeBuilderType::FociEllipse, "shape-foci-ellipse"),
    (ShapeBuilderType::Polyline, "shape-polyline"),
    (ShapeBuilderType::Polygon, "shape-polygon"),
    (ShapeBuilderType::QuadBez, "shape-quadbez"),
    (ShapeBuilderType::CubBez, "shape-cubbez"),
    (ShapeBuilderType::Grid, "shape-grid"),
    (ShapeBuilderType::CoordSystem2D, "shape-coord-system-2d"),
    (
        ShapeBuilderType::QuadrantCoordSystem2D,
        "shape-quadrant-coord-system-2d",
    ),
    (ShapeBuilderType::CoordSystem3D, "shape-coord-system-3d"),
];

impl QuickItem {
    /// Every available item, in the order shown in the chooser.
    pub(crate) fn all() -> Vec<QuickItem> {
        let pens = [
            PenItem::Brush,
            PenItem::Eraser,
            PenItem::Selector,
            PenItem::Typewriter,
            PenItem::Tools,
        ]
        .map(QuickItem::Pen);
        let shapes = SHAPES.map(|(shape, _)| QuickItem::Shape(shape));
        let actions = [
            ActionItem::FunctionGraph,
            ActionItem::ImportFile,
            ActionItem::AddPage,
            ActionItem::Undo,
            ActionItem::Redo,
        ]
        .map(QuickItem::Action);

        pens.into_iter().chain(shapes).chain(actions).collect()
    }

    /// The stable id, used to store the items in the settings.
    pub(crate) fn id(self) -> &'static str {
        match self {
            Self::Pen(PenItem::Brush) => "pen-brush",
            Self::Pen(PenItem::Eraser) => "pen-eraser",
            Self::Pen(PenItem::Selector) => "pen-selector",
            Self::Pen(PenItem::Typewriter) => "pen-typewriter",
            Self::Pen(PenItem::Tools) => "pen-tools",
            Self::Shape(shape) => SHAPES
                .iter()
                .find(|(s, _)| *s == shape)
                .map(|(_, id)| *id)
                .unwrap_or("shape-line"),
            Self::Action(ActionItem::FunctionGraph) => "function-graph",
            Self::Action(ActionItem::ImportFile) => "import-file",
            Self::Action(ActionItem::AddPage) => "add-page",
            Self::Action(ActionItem::Undo) => "undo",
            Self::Action(ActionItem::Redo) => "redo",
        }
    }

    pub(crate) fn from_id(id: &str) -> Option<Self> {
        Self::all().into_iter().find(|item| item.id() == id)
    }

    pub(crate) fn group(self) -> Group {
        match self {
            Self::Pen(_) => Group::Tools,
            Self::Shape(_) => Group::Shapes,
            Self::Action(_) => Group::Insert,
        }
    }

    pub(crate) fn icon_name(self) -> String {
        match self {
            Self::Pen(PenItem::Brush) => "pen-brush-symbolic".into(),
            Self::Pen(PenItem::Eraser) => "pen-eraser-symbolic".into(),
            Self::Pen(PenItem::Selector) => "pen-selector-symbolic".into(),
            Self::Pen(PenItem::Typewriter) => "pen-typewriter-symbolic".into(),
            Self::Pen(PenItem::Tools) => "pen-tools-symbolic".into(),
            Self::Shape(shape) => shape.to_icon_name(),
            Self::Action(ActionItem::FunctionGraph) => "function-graph-symbolic".into(),
            Self::Action(ActionItem::ImportFile) => "document-open-symbolic".into(),
            Self::Action(ActionItem::AddPage) => "list-add-symbolic".into(),
            Self::Action(ActionItem::Undo) => "edit-undo-symbolic".into(),
            Self::Action(ActionItem::Redo) => "edit-redo-symbolic".into(),
        }
    }

    pub(crate) fn label(self) -> String {
        match self {
            Self::Pen(PenItem::Brush) => gettext("Brush"),
            Self::Pen(PenItem::Eraser) => gettext("Eraser"),
            Self::Pen(PenItem::Selector) => gettext("Selector"),
            Self::Pen(PenItem::Typewriter) => gettext("Typewriter"),
            Self::Pen(PenItem::Tools) => gettext("Tools"),
            Self::Shape(shape) => shape_builder_type_icons_to_display_name(&shape.to_icon_name()),
            Self::Action(ActionItem::FunctionGraph) => gettext("Graph Functions"),
            Self::Action(ActionItem::ImportFile) => gettext("Import File"),
            Self::Action(ActionItem::AddPage) => gettext("Add Page"),
            Self::Action(ActionItem::Undo) => gettext("Undo"),
            Self::Action(ActionItem::Redo) => gettext("Redo"),
        }
    }

    pub(crate) fn activate(self, appwindow: &RnAppWindow) {
        match self {
            Self::Pen(pen) => {
                let style = match pen {
                    PenItem::Brush => "brush",
                    PenItem::Eraser => "eraser",
                    PenItem::Selector => "selector",
                    PenItem::Typewriter => "typewriter",
                    PenItem::Tools => "tools",
                };
                activate_win_action(appwindow, "pen-style", Some(&style.to_variant()));
            }
            Self::Shape(shape) => {
                appwindow
                    .engine_config()
                    .write()
                    .pens_config
                    .shaper_config
                    .builder_type = shape;
                appwindow
                    .overlays()
                    .penssidebar()
                    .shaper_page()
                    .set_shapebuildertype(shape);
                activate_win_action(appwindow, "pen-style", Some(&"shaper".to_variant()));
            }
            Self::Action(action) => {
                let name = match action {
                    ActionItem::FunctionGraph => "insert-function-graph",
                    ActionItem::ImportFile => "import-file",
                    ActionItem::AddPage => "add-page-to-doc",
                    ActionItem::Undo => "undo",
                    ActionItem::Redo => "redo",
                };
                activate_win_action(appwindow, name, None);
            }
        }
    }
}

fn activate_win_action(appwindow: &RnAppWindow, name: &str, target: Option<&glib::Variant>) {
    if let Err(e) = WidgetExt::activate_action(appwindow, &format!("win.{name}"), target) {
        tracing::error!("Activating quick access action '{name}' failed, Err: {e:?}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_roundtrip() {
        let all = QuickItem::all();
        for item in &all {
            assert_eq!(QuickItem::from_id(item.id()), Some(*item));
        }
        let mut ids = all.iter().map(|i| i.id()).collect::<Vec<_>>();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), all.len());
    }
}
