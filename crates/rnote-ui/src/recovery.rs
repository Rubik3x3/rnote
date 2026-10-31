//! Keeps documents safe against crashes and accidental overwrites.
//!
//! - Documents are autosaved shortly after every change. Documents without a file, or that could not be saved,
//!   are written to recovery files instead, which are offered for recovery on the next start.
//! - When the app panics, the open documents are saved as recovery files and the panic is logged.
//! - Before a file gets overwritten for the first time in a session, its previous version is backed up.

// Imports
use crate::{RnAppWindow, RnCanvas};
use adw::prelude::*;
use gettextrs::gettext;
use gtk4::{glib, glib::clone, subclass::prelude::*};
use rnote_compose::penevent::PenProgress;
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tracing::{debug, error, warn};

/// How long the document must be left alone before it is autosaved.
const AUTOSAVE_IDLE_DELAY: Duration = Duration::from_millis(1500);
/// Number of backups that are kept.
const BACKUPS_MAX: usize = 60;
/// Number of crash logs that are kept.
const CRASH_LOGS_MAX: usize = 20;

/// Metadata stored next to a recovery file.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct RecoveryMeta {
    /// The title of the document.
    title: String,
    /// The file the document belongs to, if any.
    original_path: Option<PathBuf>,
    /// Unix time of the save.
    saved_at: u64,
}

#[derive(Debug, Clone)]
struct RecoveryEntry {
    id: String,
    meta: RecoveryMeta,
}

/// The directory where Rnote keeps recovery files, backups and crash logs.
pub(crate) fn data_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        glib::home_dir().join("Library/Application Support/Rnote")
    } else {
        glib::user_data_dir().join("rnote")
    }
}

fn recovery_dir() -> PathBuf {
    data_dir().join("recovery")
}

fn backups_dir() -> PathBuf {
    data_dir().join("backups")
}

fn crash_logs_dir() -> PathBuf {
    data_dir().join("crash-logs")
}

fn recovery_file(id: &str) -> PathBuf {
    recovery_dir().join(format!("{id}.rnote"))
}

fn recovery_meta_file(id: &str) -> PathBuf {
    recovery_dir().join(format!("{id}.json"))
}

fn new_id() -> String {
    format!(
        "{}-{:08x}",
        chrono::Local::now().format("%Y%m%d-%H%M%S"),
        glib::random_int()
    )
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

fn title_for(original_path: Option<&Path>) -> String {
    original_path
        .and_then(|p| p.file_stem())
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| gettext("Draft"))
}

/// Removes the oldest files of the directory, keeping `keep` files.
fn prune_dir(dir: &Path, keep: usize) {
    let Ok(read_dir) = std::fs::read_dir(dir) else {
        return;
    };
    let mut files = read_dir
        .filter_map(|e| e.ok())
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .filter(|(_, p)| p.is_file())
        .collect::<Vec<_>>();
    if files.len() <= keep {
        return;
    }
    files.sort_by_key(|(modified, _)| std::cmp::Reverse(*modified));
    for (_, path) in files.into_iter().skip(keep) {
        if let Err(e) = std::fs::remove_file(&path) {
            warn!("Removing old file `{}` failed, Err: {e:?}", path.display());
        }
    }
}

impl RnCanvas {
    /// The id of the recovery file of the document, created when needed.
    fn recovery_id(&self) -> String {
        self.imp()
            .recovery_id
            .borrow_mut()
            .get_or_insert_with(new_id)
            .clone()
    }

    /// Writes the recovery file of the document.
    pub(crate) async fn save_recovery(&self) -> anyhow::Result<()> {
        let imp = self.imp();
        if imp.recovery_save_in_progress.get() {
            return Ok(());
        }
        imp.recovery_save_in_progress.set(true);

        let id = self.recovery_id();
        let generation = imp.recovery_generation.get();
        let original_path = self.output_file().and_then(|f| f.path());
        let meta = RecoveryMeta {
            title: title_for(original_path.as_deref()),
            original_path,
            saved_at: unix_now(),
        };
        let bytes_receiver = self.engine_ref().save_as_rnote_bytes(format!("{id}.rnote"));

        let result = async {
            let bytes = bytes_receiver.await??;
            let meta_bytes = serde_json::to_vec_pretty(&meta)?;
            let dir = recovery_dir();
            blocking::unblock(move || std::fs::create_dir_all(dir)).await?;
            crate::utils::atomic_save_to_file_future(recovery_file(&id), bytes).await?;
            crate::utils::atomic_save_to_file_future(recovery_meta_file(&id), meta_bytes).await?;
            anyhow::Ok(())
        }
        .await;

        imp.recovery_save_in_progress.set(false);
        if imp.recovery_generation.get() != generation {
            // The document was saved or closed in the meantime
            remove_recovery_files(&id);
        } else if result.is_ok() {
            debug!("Saved recovery file `{id}`");
        }
        result
    }

    /// Removes the recovery file, called once the document is safely saved or intentionally closed.
    pub(crate) fn discard_recovery(&self) {
        let imp = self.imp();
        imp.recovery_generation
            .set(imp.recovery_generation.get().wrapping_add(1));
        if let Some(id) = imp.recovery_id.borrow().as_deref() {
            remove_recovery_files(id);
        }
    }

    /// Copies the file to the backups, once per session and file, before it gets overwritten.
    pub(crate) async fn backup_before_overwrite(&self, path: &Path) {
        if self
            .imp()
            .backed_up_file
            .borrow()
            .as_deref()
            .is_some_and(|p| p == path)
        {
            return;
        }
        self.imp().backed_up_file.replace(Some(path.to_path_buf()));

        let path = path.to_path_buf();
        let result = blocking::unblock(move || -> anyhow::Result<()> {
            if !path.is_file() {
                return Ok(());
            }
            let dir = backups_dir();
            std::fs::create_dir_all(&dir)?;
            let stem = path
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default();
            let target = dir.join(format!(
                "{stem} {}.rnote",
                chrono::Local::now().format("%Y-%m-%d %H.%M.%S")
            ));
            std::fs::copy(&path, &target)?;
            prune_dir(&dir, BACKUPS_MAX);
            Ok(())
        })
        .await;
        if let Err(e) = result {
            error!("Backing up the file before overwriting it failed, Err: {e:?}");
        }
    }

    /// Saves the document synchronously as a new recovery file, while the app is going down.
    fn emergency_save(&self) -> anyhow::Result<()> {
        let imp = self.imp();
        let id = format!("{}-emergency", new_id());
        let original_path = imp
            .output_file
            .try_borrow()
            .ok()
            .and_then(|f| f.as_ref().and_then(|f| f.path()));

        let bytes = match imp.engine.try_borrow() {
            Ok(engine) => engine.save_as_rnote_bytes_blocking(&format!("{id}.rnote"))?,
            Err(_) => {
                // The panic happened while the engine was borrowed mutably, which is the usual case for panics
                // during input handling.
                //
                // SAFETY: The process aborts right after the panic hook, the mutable borrow is never used again.
                // Panics leave the engine data structures in a valid state, so reading it is sound in practice.
                // The result goes to a new recovery file, so a broken save never replaces anything.
                let engine = unsafe { &*imp.engine.as_ptr() };
                engine.save_as_rnote_bytes_blocking(&format!("{id}.rnote"))?
            }
        };
        let meta = RecoveryMeta {
            title: title_for(original_path.as_deref()),
            original_path,
            saved_at: unix_now(),
        };

        std::fs::create_dir_all(recovery_dir())?;
        rnote_engine::utils::atomic_save_to_file(recovery_file(&id), bytes)?;
        rnote_engine::utils::atomic_save_to_file(
            recovery_meta_file(&id),
            serde_json::to_vec_pretty(&meta)?,
        )?;
        Ok(())
    }
}

fn remove_recovery_files(id: &str) {
    for path in [recovery_file(id), recovery_meta_file(id)] {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => error!(
                "Removing recovery file `{}` failed, Err: {e:?}",
                path.display()
            ),
        }
    }
}

impl RnAppWindow {
    /// Schedules an autosave of the document once it is left alone for a moment.
    ///
    /// Called on every change, so it only records the time when a save is already scheduled.
    pub(crate) fn schedule_autosave(&self, canvas: &RnCanvas) {
        canvas
            .imp()
            .last_modified
            .set(Some(std::time::Instant::now()));
        if canvas.imp().autosave_source.borrow().is_none() {
            self.arm_autosave(canvas, AUTOSAVE_IDLE_DELAY);
        }
    }

    fn arm_autosave(&self, canvas: &RnCanvas, delay: Duration) {
        let source = glib::timeout_add_local_once(
            delay,
            clone!(
                #[weak(rename_to=appwindow)]
                self,
                #[weak]
                canvas,
                move || {
                    // the source is done once it fired
                    canvas.imp().autosave_source.take();

                    let idle = canvas
                        .imp()
                        .last_modified
                        .get()
                        .map(|t| t.elapsed())
                        .unwrap_or(Duration::MAX);
                    if idle < AUTOSAVE_IDLE_DELAY {
                        appwindow.arm_autosave(&canvas, AUTOSAVE_IDLE_DELAY - idle);
                        return;
                    }
                    // never save in the middle of a stroke
                    let drawing = canvas
                        .imp()
                        .engine
                        .try_borrow()
                        .map(|e| e.penholder.current_pen_progress() == PenProgress::InProgress)
                        .unwrap_or(true);
                    if drawing {
                        appwindow.arm_autosave(&canvas, AUTOSAVE_IDLE_DELAY);
                        return;
                    }
                    appwindow.autosave_now(&canvas);
                }
            ),
        );
        canvas.imp().autosave_source.replace(Some(source));
    }

    /// Saves the document right away, to its file when autosaving is enabled, else to a recovery file.
    pub(crate) fn autosave_now(&self, canvas: &RnCanvas) {
        if let Some(source) = canvas.imp().autosave_source.take() {
            source.remove();
        }
        if !canvas.unsaved_changes() {
            return;
        }
        let save_to_file = self.autosave()
            && self
                .app()
                .app_settings_with_key("autosave-on-change")
                .is_none_or(|s| s.boolean("autosave-on-change"));

        glib::spawn_future_local(clone!(
            #[weak(rename_to=appwindow)]
            self,
            #[weak]
            canvas,
            async move {
                if save_to_file && let Some(output_file) = canvas.output_file() {
                    match canvas.save_document_to_file(&output_file).await {
                        Ok(true) => return,
                        Ok(false) => {
                            // another save is running, try again afterwards
                            appwindow.schedule_autosave(&canvas);
                            return;
                        }
                        Err(e) => {
                            error!("Autosaving document failed, Err: {e:?}");
                            appwindow.overlays().dispatch_toast_error(&gettext(
                                "Autosaving the document failed, a recovery copy is kept instead",
                            ));
                        }
                    }
                }
                if let Err(e) = canvas.save_recovery().await {
                    error!("Saving the recovery file failed, Err: {e:?}");
                    appwindow
                        .overlays()
                        .dispatch_toast_error(&gettext("Saving the recovery copy failed"));
                }
            }
        ));
    }

    /// Saves all documents with pending changes right away, e.g. when the window loses focus.
    pub(crate) fn autosave_all_now(&self) {
        for wrapper in self.get_all_tabs() {
            let canvas = wrapper.canvas();
            if canvas.imp().autosave_source.borrow().is_some() {
                self.autosave_now(&canvas);
            }
        }
    }

    /// Stops pending autosaves and removes the recovery file, when the document is closed intentionally.
    pub(crate) fn finish_document(&self, canvas: &RnCanvas) {
        if let Some(source) = canvas.imp().autosave_source.take() {
            source.remove();
        }
        canvas.discard_recovery();
    }
}

thread_local! {
    /// The canvases of this thread, to save them when the app panics.
    static CANVASES: RefCell<Vec<glib::WeakRef<RnCanvas>>> = const { RefCell::new(Vec::new()) };
}

pub(crate) fn register_canvas(canvas: &RnCanvas) {
    CANVASES.with(|canvases| {
        let mut canvases = canvases.borrow_mut();
        canvases.retain(|c| c.upgrade().is_some());
        canvases.push(canvas.downgrade());
    });
}

/// Installs a panic hook that logs the panic and saves the open documents as recovery files.
pub(crate) fn install_panic_hook() {
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let backtrace = std::backtrace::Backtrace::force_capture();
        let saved = emergency_save_all();
        let log = format!(
            "Rnote {} crashed at {}\nthread: {}\n{info}\nsaved documents: {saved}\n\nbacktrace:\n{backtrace}\n",
            crate::config::APP_VERSION,
            chrono::Local::now().to_rfc3339(),
            std::thread::current().name().unwrap_or("<unnamed>"),
        );
        let dir = crash_logs_dir();
        let path = dir.join(format!(
            "crash-{}.log",
            chrono::Local::now().format("%Y%m%d-%H%M%S")
        ));
        if std::fs::create_dir_all(&dir)
            .and_then(|_| std::fs::write(&path, &log))
            .is_ok()
        {
            eprintln!("The crash was logged to `{}`", path.display());
            prune_dir(&dir, CRASH_LOGS_MAX);
        }
        default_hook(info);
    }));
}

/// Saves the documents with unsaved changes, returns how many were saved.
fn emergency_save_all() -> usize {
    CANVASES
        .try_with(|canvases| {
            let Ok(canvases) = canvases.try_borrow() else {
                return 0;
            };
            canvases
                .iter()
                .filter_map(|c| c.upgrade())
                .filter(|c| c.imp().unsaved_changes.get())
                .filter(|c| match c.emergency_save() {
                    Ok(()) => true,
                    Err(e) => {
                        eprintln!("Emergency save failed, Err: {e:?}");
                        false
                    }
                })
                .count()
        })
        .unwrap_or(0)
}

fn recovery_entries() -> Vec<RecoveryEntry> {
    let Ok(read_dir) = std::fs::read_dir(recovery_dir()) else {
        return vec![];
    };
    let mut entries = read_dir
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|ext| ext == "rnote"))
        .filter_map(|p| {
            let id = p.file_stem()?.to_string_lossy().to_string();
            let meta = std::fs::read(recovery_meta_file(&id))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<RecoveryMeta>(&bytes).ok())
                .unwrap_or_else(|| RecoveryMeta {
                    title: gettext("Draft"),
                    original_path: None,
                    saved_at: p
                        .metadata()
                        .and_then(|m| m.modified())
                        .ok()
                        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                        .map(|d| d.as_secs())
                        .unwrap_or_default(),
                });
            Some(RecoveryEntry { id, meta })
        })
        .collect::<Vec<_>>();
    entries.sort_by_key(|e| e.meta.saved_at);
    entries
}

static RECOVERY_OFFERED: AtomicBool = AtomicBool::new(false);

/// Offers to recover the documents that were left unsaved by a previous session. Only once per process.
pub(crate) fn offer_recovery(appwindow: &RnAppWindow) {
    if RECOVERY_OFFERED.swap(true, Ordering::Relaxed) {
        return;
    }
    let entries = recovery_entries();
    if entries.is_empty() {
        return;
    }

    glib::spawn_future_local(clone!(
        #[weak]
        appwindow,
        async move {
            let list = entries
                .iter()
                .map(|e| {
                    let time = chrono::DateTime::from_timestamp(e.meta.saved_at as i64, 0)
                        .map(|t| {
                            t.with_timezone(&chrono::Local)
                                .format("%d/%m %H:%M")
                                .to_string()
                        })
                        .unwrap_or_default();
                    format!("• {} ({time})", e.meta.title)
                })
                .collect::<Vec<_>>()
                .join("\n");
            let dialog = adw::AlertDialog::builder()
                .heading(gettext("Recover Unsaved Documents?"))
                .body(
                    gettext("Rnote was closed before these documents were saved:") + "\n\n" + &list,
                )
                .close_response("later")
                .default_response("recover")
                .build();
            dialog.add_responses(&[
                ("discard", &gettext("Discard")),
                ("later", &gettext("Not Now")),
                ("recover", &gettext("Recover")),
            ]);
            dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
            dialog.set_response_appearance("recover", adw::ResponseAppearance::Suggested);

            match dialog.choose_future(Some(&appwindow)).await.as_str() {
                "recover" => {
                    for entry in entries {
                        if let Err(e) = recover_entry(&appwindow, &entry).await {
                            error!("Recovering document `{}` failed, Err: {e:?}", entry.id);
                            appwindow
                                .overlays()
                                .dispatch_toast_error(&gettext("Recovering a document failed"));
                        }
                    }
                }
                "discard" => {
                    // moved to the backups instead of deleting them, in case they are needed after all
                    let result = blocking::unblock(move || -> anyhow::Result<()> {
                        let dir = backups_dir();
                        std::fs::create_dir_all(&dir)?;
                        for entry in entries {
                            let target = dir.join(format!(
                                "{} (recovered {}).rnote",
                                entry.meta.title, entry.id
                            ));
                            std::fs::rename(recovery_file(&entry.id), target)?;
                            remove_recovery_files(&entry.id);
                        }
                        prune_dir(&dir, BACKUPS_MAX);
                        Ok(())
                    })
                    .await;
                    if let Err(e) = result {
                        error!("Discarding recovery files failed, Err: {e:?}");
                    }
                }
                _ => {}
            }
        }
    ));
}

async fn recover_entry(appwindow: &RnAppWindow, entry: &RecoveryEntry) -> anyhow::Result<()> {
    let path = recovery_file(&entry.id);
    let bytes = blocking::unblock(move || std::fs::read(path)).await?;
    let original_path = entry
        .meta
        .original_path
        .clone()
        .filter(|p| p.parent().is_some_and(|parent| parent.is_dir()));

    // reuse the initial empty tab
    let (wrapper, new_tab) = match appwindow.active_tab_wrapper() {
        Some(active)
            if active.canvas().empty()
                && active.canvas().output_file().is_none()
                && !active.canvas().unsaved_changes() =>
        {
            (active, false)
        }
        _ => (appwindow.new_canvas_wrapper(), true),
    };
    let canvas = wrapper.canvas();
    let widget_flags = canvas.load_in_rnote_bytes(bytes, original_path).await?;
    canvas.imp().recovery_id.replace(Some(entry.id.clone()));
    if new_tab {
        appwindow.append_wrapper_new_tab(&wrapper);
    }
    appwindow.handle_widget_flags(widget_flags, &canvas);
    // the recovered state is newer than the file, if there is one
    canvas.set_unsaved_changes(true);
    canvas.set_empty(false);
    appwindow.refresh_titles(&canvas);
    Ok(())
}
