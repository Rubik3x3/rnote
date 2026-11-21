//! Renders a transcription (Markdown lines with LaTeX math) to a PNG with the local TeX install,
//! so the "Preview" of the Transcription tab shows the formulas as they will look.
//! Used by `transcription::build_page`.

// Imports
use std::path::PathBuf;
use std::process::Command;

/// Where TeX usually lives on macOS and Linux. Apps opened from the Dock don't get the shell's
/// PATH, so `latex` is searched there too.
const TEX_DIRS: [&str; 4] = [
    "/Library/TeX/texbin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
];

/// Finds a TeX program by name in PATH or in [TEX_DIRS].
fn find_program(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .chain(TEX_DIRS.iter().map(PathBuf::from))
        .map(|dir| dir.join(name))
        .find(|p| p.is_file())
}

/// Whether `latex` and `dvipng` are installed, i.e. the preview can work.
pub(crate) fn available() -> bool {
    find_program("latex").is_some() && find_program("dvipng").is_some()
}

/// Renders `text` and returns the path of a transparent PNG, in a temp dir reused on every call.
/// `dark` draws white text for a dark theme; `dpi` sets the resolution (higher on HiDPI screens).
/// Blocking (~1 s), run it off the main thread. The error is the first LaTeX error, for the user.
pub(crate) fn render(text: &str, dark: bool, dpi: u32) -> Result<PathBuf, String> {
    let latex = find_program("latex").ok_or("latex is not installed")?;
    let dvipng = find_program("dvipng").ok_or("dvipng is not installed")?;
    let dir = std::env::temp_dir().join(format!("rnote-preview-{}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    std::fs::write(dir.join("t.tex"), to_latex_document(text)).map_err(|e| e.to_string())?;

    let out = run(Command::new(latex)
        .args(["-interaction=nonstopmode", "-halt-on-error", "t.tex"])
        .current_dir(&dir))?;
    if !out.status.success() {
        let log = String::from_utf8_lossy(&out.stdout);
        let error = log
            .lines()
            .skip_while(|l| !l.starts_with('!'))
            .take(2)
            .collect::<Vec<_>>()
            .join(" ");
        return Err(format!("LaTeX: {error}"));
    }
    let fg = if dark { "rgb 1 1 1" } else { "rgb 0 0 0" };
    let out = run(Command::new(dvipng)
        .args(["-T", "tight", "-bg", "Transparent", "-fg", fg, "-D"])
        .arg(dpi.to_string())
        .args(["-o", "t.png", "t.dvi"])
        .current_dir(&dir))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).into_owned());
    }
    Ok(dir.join("t.png"))
}

/// Runs a TeX program with the TeX dirs in PATH: latex and dvipng call helpers like `mktexpk`
/// (to create missing fonts) by name, and apps opened from the Dock have a minimal PATH.
fn run(cmd: &mut Command) -> Result<std::process::Output, String> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let dirs = TEX_DIRS
        .iter()
        .map(PathBuf::from)
        .chain(std::env::split_paths(&path));
    let path = std::env::join_paths(dirs).map_err(|e| e.to_string())?;
    cmd.env("PATH", path).output().map_err(|e| e.to_string())
}

/// Wraps the converted body in a document as wide as the sidebar text. Only base LaTeX packages,
/// and a very tall page so everything is on page 1 (dvipng then crops it with `-T tight`).
fn to_latex_document(text: &str) -> String {
    format!(
        // fleqn: formulas aligned left like the text, centered ones look scattered once cropped
        "\\documentclass[fleqn]{{article}}\n\
         \\usepackage[paperwidth=9cm,paperheight=500cm,margin=2mm]{{geometry}}\n\
         \\usepackage[utf8]{{inputenc}}\n\
         \\usepackage{{amsmath,amssymb}}\n\
         \\pagestyle{{empty}}\\setlength{{\\parindent}}{{0pt}}\\setlength{{\\parskip}}{{4pt}}\\setlength{{\\mathindent}}{{1em}}\n\
         \\begin{{document}}\n{}\n\\end{{document}}\n",
        to_latex_body(text)
    )
}

/// Converts Markdown-ish lines with math into LaTeX: math (`$..$`, `$$..$$`, `\[..\]`, `\(..\)`)
/// is copied as is, the text around it is escaped, every line break is kept and `#` headings
/// become bold.
pub(crate) fn to_latex_body(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while !rest.is_empty() {
        // the next math opening, the longest delimiter first so "$$" isn't read as "$"
        let next = ["$$", "\\[", "\\(", "$"]
            .iter()
            .filter_map(|open| rest.find(open).map(|i| (i, *open)))
            .min_by_key(|(i, open)| (*i, std::cmp::Reverse(open.len())));
        let Some((start, open)) = next else {
            out.push_str(&escape_text(rest));
            break;
        };
        let close = match open {
            "\\[" => "\\]",
            "\\(" => "\\)",
            _ => open,
        };
        let body_start = start + open.len();
        let Some(len) = rest[body_start..].find(close) else {
            // unclosed math: show it as text rather than break the whole preview
            out.push_str(&escape_text(rest));
            break;
        };
        out.push_str(&escape_text(&rest[..start]));
        out.push_str(&rest[start..body_start + len + close.len()]);
        rest = &rest[body_start + len + close.len()..];
    }
    out
}

/// Escapes LaTeX's special characters in plain text and keeps line breaks.
fn escape_text(text: &str) -> String {
    let mut out = String::new();
    for (i, line) in text.split('\n').enumerate() {
        if i > 0 {
            out.push_str("\\par\n");
        }
        let (heading, line) = match line.trim_start().strip_prefix('#') {
            Some(h) => (true, h.trim_start_matches('#').trim_start()),
            None => (false, line),
        };
        if heading {
            out.push_str("\\textbf{");
        }
        for c in line.chars() {
            match c {
                '\\' => out.push_str("\\textbackslash{}"),
                '{' | '}' | '%' | '&' | '#' | '_' | '$' => {
                    out.push('\\');
                    out.push(c);
                }
                '^' => out.push_str("\\^{}"),
                '~' => out.push_str("\\~{}"),
                _ => out.push(c),
            }
        }
        if heading {
            out.push('}');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn math_is_kept_and_text_escaped() {
        assert_eq!(
            to_latex_body("50% de $x_1^2$ y\n$$\\frac{m}{s}$$"),
            "50\\% de $x_1^2$ y\\par\n$$\\frac{m}{s}$$"
        );
        assert_eq!(to_latex_body("a \\[x\\] b"), "a \\[x\\] b");
        // an unclosed $ is text, not the start of math
        assert_eq!(to_latex_body("cuesta $5"), "cuesta \\$5");
        assert_eq!(to_latex_body("# Título"), "\\textbf{Título}");
    }
}
