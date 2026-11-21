//! The "Transcription" sidebar tab: turns the handwriting of the selection (or of what is visible)
//! into Markdown text with LaTeX math, so it can be copied and pasted into an AI chat.
//!
//! Everything runs offline with a local vision model served by Ollama (https://ollama.com).
//! Built by `RnSidebar::init`.

// Imports
use crate::RnAppWindow;
use base64::Engine as _;
use gettextrs::gettext;
use gtk4::{
    Align, Box, Button, Label, Orientation, ScrolledWindow, TextView, WrapMode, gdk, gio, glib,
    glib::clone, prelude::*,
};
use std::process::Command;

/// Ollama's default local address.
const OLLAMA_URL: &str = "http://127.0.0.1:11434";

/// Installed models are tried in this order (prefix of the model name). Models made for reading
/// documents come first; gemma4 also reads images and is the fallback.
const PREFERRED_MODELS: [&str; 6] = [
    "qwen2.5vl",
    "qwen3-vl",
    "gemma4:e4b",
    "gemma4",
    "llama3.2-vision",
    "minicpm-v",
];

const PROMPT: &str = "Transcribe the handwritten notes in this image exactly as written. \
Output Markdown. Write every formula, symbol and equation in LaTeX: $...$ inline and $$...$$ \
for formulas on their own line. Keep the reading order (top to bottom, left to right) and the \
original language. Write normal text as plain Markdown lines, not inside \\text{}. \
Keep boxed results as \\boxed{}. Do not explain, solve, correct or add anything. Write [?] for parts you \
cannot read. Output only the transcription.";

/// Builds the tab content. `appwindow` gives access to the active canvas.
pub(crate) fn build_page(appwindow: &RnAppWindow) -> gtk4::Widget {
    let page = Box::builder()
        .orientation(Orientation::Vertical)
        .spacing(8)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();

    let hint = Label::builder()
        .label(gettext(
            "Converts the selection, or what is visible if nothing is selected, into text and LaTeX. Runs offline with Ollama.",
        ))
        .wrap(true)
        .xalign(0.0)
        .css_classes(["dim-label", "caption"])
        .build();
    let buttons = Box::builder().spacing(6).build();
    let transcribe = Button::builder()
        .label(gettext("Transcribe"))
        .css_classes(["suggested-action", "pill"])
        .hexpand(true)
        .build();
    let copy = Button::builder()
        .icon_name("edit-copy-symbolic")
        .tooltip_text(gettext("Copy All"))
        .build();
    let clear = Button::builder()
        .icon_name("user-trash-symbolic")
        .tooltip_text(gettext("Clear"))
        .build();
    buttons.append(&transcribe);
    buttons.append(&copy);
    buttons.append(&clear);

    let status = Label::builder()
        .xalign(0.0)
        .wrap(true)
        .css_classes(["caption"])
        .build();
    let text_view = TextView::builder()
        .wrap_mode(WrapMode::WordChar)
        .monospace(true)
        .top_margin(8)
        .bottom_margin(8)
        .left_margin(8)
        .right_margin(8)
        .build();
    let scroller = ScrolledWindow::builder()
        .child(&text_view)
        .vexpand(true)
        .valign(Align::Fill)
        .css_classes(["card"])
        .build();

    page.append(&hint);
    page.append(&buttons);
    page.append(&status);
    page.append(&scroller);

    copy.connect_clicked(clone!(
        #[weak]
        text_view,
        move |_| {
            let buffer = text_view.buffer();
            let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);
            gdk::Display::default()
                .unwrap()
                .clipboard()
                .set_text(&text);
        }
    ));
    clear.connect_clicked(clone!(
        #[weak]
        text_view,
        move |_| text_view.buffer().set_text("")
    ));
    transcribe.connect_clicked(clone!(
        #[weak]
        appwindow,
        #[weak]
        text_view,
        #[weak]
        status,
        move |button| {
            let Some(canvas) = appwindow.active_tab_canvas() else {
                return;
            };
            let receiver = canvas.engine_ref().export_for_transcription();
            button.set_sensitive(false);
            status.set_label(&gettext("Transcribing…"));
            glib::spawn_future_local(clone!(
                #[weak]
                button,
                async move {
                    let result = match receiver.await {
                        Ok(Ok(Some(png))) => gio::spawn_blocking(move || transcribe_png(&png))
                            .await
                            .unwrap_or_else(|_| Err("transcription thread panicked".into())),
                        Ok(Ok(None)) => Err(gettext("There is nothing to transcribe here.")),
                        Ok(Err(e)) => Err(format!("{e:?}")),
                        Err(e) => Err(format!("{e:?}")),
                    };
                    match result {
                        Ok((model, text)) => {
                            let buffer = text_view.buffer();
                            let mut end = buffer.end_iter();
                            if end.offset() > 0 {
                                buffer.insert(&mut end, "\n\n");
                            }
                            buffer.insert(&mut end, text.trim());
                            status.set_label(&format!("{} ({model})", gettext("Done")));
                        }
                        Err(e) => status.set_label(&e),
                    }
                    button.set_sensitive(true);
                }
            ));
        }
    ));

    page.upcast()
}

/// Sends the PNG to the local model. Blocking, run it off the main thread.
/// Returns the used model name and the transcription, or an error message for the user.
fn transcribe_png(png: &[u8]) -> Result<(String, String), String> {
    let tags = curl(&["-s", "--max-time", "5", &format!("{OLLAMA_URL}/api/tags")])
        .map_err(|_| gettext("Ollama is not running. Open the Ollama app and try again."))?;
    let installed: Vec<String> = tags["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| m["name"].as_str().map(String::from))
        .collect();
    let model = pick_model(&installed).ok_or_else(|| {
        gettext("No local vision model installed. Run in a terminal: ollama pull qwen2.5vl:7b")
    })?;

    let mut body = serde_json::json!({
        "model": model,
        "stream": false,
        // a cap, small vision models sometimes repeat a line forever
        "options": { "temperature": 0, "num_predict": 2048 },
        "messages": [{
            "role": "user",
            "content": PROMPT,
            "images": [base64::engine::general_purpose::STANDARD.encode(png)],
        }],
    });
    // the body goes through a file: a base64 image is too long for a command line argument
    let body_file = std::env::temp_dir().join(format!("rnote-transcribe-{}.json", std::process::id()));
    if model.starts_with("gemma") {
        // gemma thinks by default, which is much slower and doesn't help to read.
        // Not sent to other models: Ollama rejects it for models without thinking.
        body["think"] = serde_json::Value::Bool(false);
    }
    std::fs::write(&body_file, body.to_string()).map_err(|e| e.to_string())?;
    let reply = curl(&[
        "-s",
        "--max-time",
        "300",
        "-H",
        "Content-Type: application/json",
        "-d",
        &format!("@{}", body_file.display()),
        &format!("{OLLAMA_URL}/api/chat"),
    ]);
    let _ = std::fs::remove_file(&body_file);
    let reply = reply?;
    if let Some(err) = reply["error"].as_str() {
        return Err(err.to_string());
    }
    let text = reply["message"]["content"]
        .as_str()
        .ok_or_else(|| format!("unexpected answer from Ollama: {reply}"))?;
    Ok((model, strip_code_fence(text)))
}

/// Runs curl (always present on macOS and Linux, saves adding an HTTP client) and parses its JSON output.
fn curl(args: &[&str]) -> Result<serde_json::Value, String> {
    let out = Command::new("curl")
        .args(args)
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("curl failed: {}", out.status));
    }
    serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())
}

/// The first installed model from [PREFERRED_MODELS].
fn pick_model(installed: &[String]) -> Option<String> {
    PREFERRED_MODELS
        .iter()
        .find_map(|p| installed.iter().find(|m| m.starts_with(p)).cloned())
}

/// Models sometimes wrap the whole answer in ```markdown ... ```, which is noise when pasting.
fn strip_code_fence(text: &str) -> String {
    let t = text.trim();
    if let Some(inner) = t.strip_prefix("```").and_then(|r| r.strip_suffix("```")) {
        // drop the language tag on the first line
        return inner
            .split_once('\n')
            .map_or(inner, |(_, rest)| rest)
            .trim()
            .to_string();
    }
    t.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefers_document_models() {
        let installed = ["gemma4:e2b-it-qat", "qwen2.5vl:7b", "gemma4:e4b-it-qat"].map(String::from);
        assert_eq!(pick_model(&installed).as_deref(), Some("qwen2.5vl:7b"));
        let installed = ["gemma4:e2b-it-qat", "gemma4:e4b-it-qat"].map(String::from);
        assert_eq!(pick_model(&installed).as_deref(), Some("gemma4:e4b-it-qat"));
        assert_eq!(pick_model(&["tinyllama:latest".into()]), None);
    }

    #[test]
    fn code_fences_are_removed() {
        assert_eq!(strip_code_fence("```markdown\n$x^2$\n```"), "$x^2$");
        assert_eq!(strip_code_fence("hola $x$"), "hola $x$");
    }
}
