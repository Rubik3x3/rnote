// Imports
use crate::appwindow::RnAppWindow;
use crate::canvas::RnCanvas;
use adw::prelude::*;
use gettextrs::gettext;
use gtk4::{Label, glib, glib::clone};
use rnote_compose::plot::{Expr, FunctionGraph, Range};
use std::cell::RefCell;

/// The dialog inputs, kept between invocations.
#[derive(Debug, Clone)]
struct Inputs {
    functions: String,
    x_min: f64,
    x_max: f64,
    y_min: f64,
    y_max: f64,
    unit: f64,
}

impl Default for Inputs {
    fn default() -> Self {
        Self {
            functions: String::from("x^2 - 2x - 3"),
            x_min: -5.0,
            x_max: 5.0,
            y_min: -5.0,
            y_max: 5.0,
            unit: 24.0,
        }
    }
}

impl Inputs {
    /// Builds the graph, or explains what is wrong with the inputs.
    fn to_graph(&self) -> Result<FunctionGraph, String> {
        let functions = self
            .functions
            .split(';')
            .map(str::trim)
            .filter(|f| !f.is_empty())
            .map(|f| Expr::parse(f).map_err(|e| format!("{f}: {e}")))
            .collect::<Result<Vec<Expr>, String>>()?;
        if functions.is_empty() {
            return Err(gettext("Enter at least one function"));
        }
        let x_range = Range::new(self.x_min, self.x_max)
            .map_err(|e| format!("{}: {e}", gettext("x range")))?;
        let y_range = Range::new(self.y_min, self.y_max)
            .map_err(|e| format!("{}: {e}", gettext("y range")))?;

        Ok(FunctionGraph {
            functions,
            x_range,
            y_range,
            unit: self.unit,
        })
    }
}

thread_local! {
    static LAST_INPUTS: RefCell<Inputs> = RefCell::new(Inputs::default());
}

fn spin_row(title: &str, value: f64, lower: f64, upper: f64) -> adw::SpinRow {
    let row = adw::SpinRow::with_range(lower, upper, 1.0);
    row.set_title(title);
    row.set_digits(1);
    row.set_value(value);
    row
}

/// Asks for functions and ranges, then inserts the graph into the canvas.
pub(crate) async fn dialog_insert_function_graph(appwindow: &RnAppWindow, canvas: &RnCanvas) {
    let inputs = LAST_INPUTS.with_borrow(Inputs::clone);

    let functions_row = adw::EntryRow::builder()
        .title(gettext("f(x) ="))
        .text(&inputs.functions)
        .build();
    let x_min_row = spin_row(&gettext("x Minimum"), inputs.x_min, -1000.0, 0.0);
    let x_max_row = spin_row(&gettext("x Maximum"), inputs.x_max, 0.0, 1000.0);
    let y_min_row = spin_row(&gettext("y Minimum"), inputs.y_min, -1000.0, 0.0);
    let y_max_row = spin_row(&gettext("y Maximum"), inputs.y_max, 0.0, 1000.0);
    let unit_row = spin_row(&gettext("Unit Size"), inputs.unit, 4.0, 500.0);
    unit_row.set_digits(0);
    unit_row.set_subtitle(&gettext("Distance between numbers"));

    let functions_group = adw::PreferencesGroup::builder()
        .description(gettext(
            "Separate several functions with ';'. E.g. 2x + 1; x^2; x^3 - x; ln(x); log(2, x); sqrt(x); sin(x)",
        ))
        .build();
    functions_group.add(&functions_row);
    let range_group = adw::PreferencesGroup::new();
    for row in [&x_min_row, &x_max_row, &y_min_row, &y_max_row, &unit_row] {
        range_group.add(row);
    }
    let error_label = Label::builder()
        .wrap(true)
        .xalign(0.0)
        .css_classes(["error", "caption"])
        .build();

    let content = gtk4::Box::builder()
        .orientation(gtk4::Orientation::Vertical)
        .spacing(12)
        .build();
    content.append(&functions_group);
    content.append(&range_group);
    content.append(&error_label);

    let dialog = adw::AlertDialog::builder()
        .heading(gettext("Graph Functions"))
        .extra_child(&content)
        .default_response("insert")
        .close_response("cancel")
        .build();
    dialog.add_responses(&[
        ("cancel", &gettext("Cancel")),
        ("insert", &gettext("Insert")),
    ]);
    dialog.set_response_appearance("insert", adw::ResponseAppearance::Suggested);

    let read_inputs = clone!(
        #[weak]
        functions_row,
        #[weak]
        x_min_row,
        #[weak]
        x_max_row,
        #[weak]
        y_min_row,
        #[weak]
        y_max_row,
        #[weak]
        unit_row,
        #[upgrade_or_default]
        move || Inputs {
            functions: functions_row.text().to_string(),
            x_min: x_min_row.value(),
            x_max: x_max_row.value(),
            y_min: y_min_row.value(),
            y_max: y_max_row.value(),
            unit: unit_row.value(),
        }
    );

    // validate while typing, so only valid graphs can be inserted
    let validate = clone!(
        #[weak]
        dialog,
        #[weak]
        error_label,
        #[strong]
        read_inputs,
        move || {
            let result = read_inputs().to_graph();
            dialog.set_response_enabled("insert", result.is_ok());
            error_label.set_label(result.err().as_deref().unwrap_or_default());
        }
    );
    functions_row.connect_changed(clone!(
        #[strong]
        validate,
        move |_| validate()
    ));
    for row in [&x_min_row, &x_max_row, &y_min_row, &y_max_row, &unit_row] {
        row.connect_value_notify(clone!(
            #[strong]
            validate,
            move |_| validate()
        ));
    }
    validate();

    let response = dialog.choose_future(Some(appwindow)).await;
    let inputs = read_inputs();
    LAST_INPUTS.with_borrow_mut(|last| *last = inputs.clone());

    if response != "insert" {
        return;
    }
    match inputs.to_graph() {
        Ok(graph) => {
            let widget_flags = canvas.engine_mut().insert_function_graph(&graph);
            appwindow.handle_widget_flags(widget_flags, canvas);
        }
        Err(e) => {
            appwindow.overlays().dispatch_toast_error(&e);
        }
    }
}
