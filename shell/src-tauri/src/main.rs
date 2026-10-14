// DigUp's shell for Windows and Linux (tried out on the Mac first): the tray icon, the hotkey, the search panel and the
// setup window. The work is DigUp's helper, `digup`, run as processes speaking JSON lines (helper.rs): `search-service`
// answers the panel, `index-service` keeps the index current, `download-model` fetches the model, `estimate` sizes up
// folders. The Mac app (Sources/DigUpApp) is the reference for behavior.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

/// A log line on stdout after the time of day ("14:03:27.512 index: {…}"), so a run's lines can be lined up with the
/// helpers' logs and with what was done by hand. Defined before the modules so they have it too.
macro_rules! log {
    ($($arg:tt)*) => { println!("{} {}", $crate::time_of_day(), format_args!($($arg)*)) };
}

/// The same on stderr, for problems.
macro_rules! log_error {
    ($($arg:tt)*) => { eprintln!("{} {}", $crate::time_of_day(), format_args!($($arg)*)) };
}

mod control;
mod desktop;
mod fallback;
mod helper;
mod opener;
mod options;
mod scope;
mod settings;
mod watcher;

use helper::{IndexService, Launch, ModelDownload, SearchService};
use options::{Command, Options, DEFAULT_HOTKEY};
use serde_json::{json, Value};
use settings::Settings;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, State, WebviewUrl, WebviewWindowBuilder, WindowEvent, Wry};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tauri_plugin_opener::OpenerExt;
use watcher::FolderWatcher;

const PANEL_WIDTH: f64 = 780.0;
const FIELD_HEIGHT: f64 = 56.0;

/// How often the folders are synced with no change seen. The watcher can miss changes: inotify drops events when its
/// queue overflows and stops adding watches at fs.inotify.max_user_watches (a big home folder gets there), a network or
/// FUSE folder may send none, and a folder that wasn't there when the watcher started (a drive plugged in later, with
/// files changed elsewhere) isn't watched at all. A sync of ~500 unchanged files takes the helper ~70 ms, and with
/// nothing to read it exits right after, so this is cheap.
const RESYNC_EVERY: Duration = Duration::from_secs(5 * 60);

/// What the commands and events share.
struct Shell {
    options: Options,
    settings: Mutex<Settings>,
    settings_path: PathBuf,
    search: SearchService,
    index: IndexService,
    model: ModelDownload,
    /// The model for the setup window and the tray: {"state": "checking|downloading|waiting|ready|failed", …}.
    model_state: Mutex<Value>,
    watcher: Mutex<Option<FolderWatcher>>,
    /// The tray menu's first line: what's going on.
    status: Mutex<Option<MenuItem<Wry>>>,
    /// The tray's Pause Indexing / Resume Indexing and Index Now, which follow the pause.
    pause_item: Mutex<Option<(MenuItem<Wry>, MenuItem<Wry>)>>,
    /// When the search service last reloaded the index (while indexing, at most every few seconds).
    reloaded: Mutex<Instant>,
    /// Debug runs with setup: the panel's query waits until the first index is in.
    debug_query_sent: AtomicBool,
    logs: PathBuf,
    /// The files' default apps, for opening at a page or moment.
    apps: opener::Apps,
    /// The helpers' troubles this session, and what was done about them (fallback.rs).
    health: Mutex<fallback::Health>,
}

impl Shell {
    /// The folders searched: the launch arguments' in dev runs, else the settings'.
    fn folders(&self) -> Vec<String> {
        if !self.options.roots.is_empty() {
            return self.options.roots.iter().map(|root| root.display().to_string()).collect();
        }
        self.settings.lock().unwrap().folders.clone()
    }

    fn is_set_up(&self) -> bool {
        !self.options.roots.is_empty() || self.settings.lock().unwrap().set_up
    }

    fn hotkey(&self) -> String {
        let chosen = self.settings.lock().unwrap().hotkey.clone();
        self.options.hotkey.clone().unwrap_or(if chosen.is_empty() { DEFAULT_HOTKEY.to_string() } else { chosen })
    }

    fn prefers_vlc(&self) -> bool {
        self.settings.lock().unwrap().prefers_vlc()
    }

    fn is_paused(&self) -> bool {
        self.settings.lock().unwrap().paused
    }

    /// The model may use the GPU: Settings allow it, the shell wasn't started with DIGUP_GPU=0 (which the helpers get
    /// too), and it hasn't failed this session (fallback.rs).
    fn gpu_in_use(&self) -> bool {
        let allowed = self.settings.lock().unwrap().gpu && std::env::var("DIGUP_GPU").map_or(true, |value| value != "0");
        allowed && !self.health.lock().unwrap().on_cpu
    }

    /// search-service's encoder may use the GPU: as `gpu_in_use`, unless it couldn't start there.
    fn search_gpu_in_use(&self) -> bool {
        self.gpu_in_use() && !self.health.lock().unwrap().search_on_cpu
    }

    /// A background helper (indexing, the download), below the person's own programs for the processor.
    fn launch(&self, args: Vec<String>, log: &str) -> Launch {
        Launch {
            program: self.options.helper.clone(),
            args,
            env: helper_env(&self.options, !self.gpu_in_use()),
            log: Some(self.logs.join(log)),
            also_logs: Vec::new(),
            background: true,
        }
    }

    /// `search-service` for the folders and settings as they are now.
    fn search_launch(&self) -> Launch {
        let settings = self.settings.lock().unwrap().clone();
        let mut launch = search_launch(&self.options, &settings, self.folders(), &self.logs, !self.search_gpu_in_use());
        // llama.cpp's own log: a Vulkan error may be there rather than on stderr.
        launch.also_logs.extend(self.options.index_folder().map(|index| index.join("worker-query.log")));
        launch
    }

    fn index_arguments(&self) -> Vec<String> {
        self.options.index.iter().flat_map(|index| ["--index".to_string(), index.display().to_string()]).collect()
    }

    /// `index-service` for the folders as they are now.
    fn index_launch(&self) -> Launch {
        let settings = self.settings.lock().unwrap().clone();
        let mut args = vec!["index-service".to_string(), "--backfill".to_string()];
        args.extend(self.index_arguments());
        for folder in &settings.skipped {
            args.extend(["--exclude".to_string(), folder.clone()]);
        }
        for extension in &settings.skip_types {
            args.extend(["--exclude-ext".to_string(), extension.clone()]);
        }
        args.extend(self.folders());
        let mut launch = self.launch(args, "index.log");
        launch.also_logs.extend(self.options.index_folder().map(|index| index.join("worker.log")));
        launch
    }

    fn model_ready(&self) -> bool {
        self.model_state.lock().unwrap()["state"] == "ready"
    }

    /// Saves the settings after `change`.
    fn change_settings(&self, change: impl FnOnce(&mut Settings)) -> Result<(), String> {
        let mut settings = self.settings.lock().unwrap();
        change(&mut settings);
        settings.save(&self.settings_path).map_err(|error| format!("can't save the settings: {error}"))
    }
}

/// What every helper is started with: where the model is, and the CPU only (DIGUP_GPU=0) when the GPU is switched off
/// or failed this session (`cpu`).
fn helper_env(options: &Options, cpu: bool) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> =
        options.models.iter().map(|models| ("DIGUP_MODELS".to_string(), models.display().to_string())).collect();
    if cpu {
        env.push(("DIGUP_GPU".to_string(), "0".to_string()));
    }
    env
}

/// `search-service` for these folders, with what's skipped in them, on the CPU only when `cpu`. Not a background
/// helper: it answers typing.
fn search_launch(options: &Options, settings: &Settings, folders: Vec<String>, logs: &Path, cpu: bool) -> Launch {
    let mut args = vec!["search-service".to_string()];
    args.extend(options.index.iter().flat_map(|index| ["--index".to_string(), index.display().to_string()]));
    for folder in &settings.skipped {
        args.extend(["--exclude".to_string(), folder.clone()]);
    }
    for extension in &settings.skip_types {
        args.extend(["--exclude-ext".to_string(), extension.clone()]);
    }
    args.extend(folders);
    Launch {
        program: options.helper.clone(),
        args,
        env: helper_env(options, cpu),
        log: Some(logs.join("search.log")),
        also_logs: Vec::new(),
        background: false,
    }
}

/// "14:03:27.512", for `log!`: the local time where libc's localtime_r can say it (Linux, the Mac), else UTC.
fn time_of_day() -> String {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let millis = now.subsec_millis();
    #[cfg(unix)]
    {
        let seconds = now.as_secs() as libc::time_t;
        // SAFETY: localtime_r only reads the time and writes the tm it's given (zeroes are a valid tm).
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        if !unsafe { libc::localtime_r(&seconds, &mut tm) }.is_null() {
            return format!("{:02}:{:02}:{:02}.{millis:03}", tm.tm_hour, tm.tm_min, tm.tm_sec);
        }
    }
    let seconds = now.as_secs() % 86_400;
    format!("{:02}:{:02}:{:02}.{millis:03}", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

// MARK: Commands

/// The panel's questions for `search-service`.
#[tauri::command]
async fn ask(shell: State<'_, Arc<Shell>>, request: Value) -> Result<Value, String> {
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default();
    if !["search", "similar", "embed_ahead", "text", "render", "prewarm", "status"].contains(&op) {
        return Err(format!("not a question the panel asks: {op}"));
    }
    shell.search.ask(request).await
}

/// What indexing these folders would take, one answer per folder (`digup estimate --json`): files by kind, the first
/// pass's seconds, the rest of long files, subfolders. For setup.
#[tauri::command]
async fn estimate(shell: State<'_, Arc<Shell>>, folders: Vec<String>) -> Result<Vec<Value>, String> {
    let helper = shell.options.helper.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = std::process::Command::new(&helper);
        command.arg("estimate").args(&folders).arg("--json");
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let output = command.output().map_err(|error| format!("can't run {}: {error}", helper.display()))?;
        Ok(String::from_utf8_lossy(&output.stdout).lines().filter_map(|line| serde_json::from_str(line).ok()).collect())
    })
    .await
    .map_err(|error| error.to_string())?
}

/// What the setup window starts from: the folders it offers, the hotkey, the model, the folders already chosen.
#[tauri::command]
fn setup_info(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Value {
    let offered: Vec<PathBuf> = match &shell.options.offered {
        Some(folders) => folders.clone(),
        None => {
            let paths = app.path();
            [paths.document_dir(), paths.picture_dir(), paths.video_dir(), paths.audio_dir(), paths.desktop_dir(),
             paths.download_dir()]
                .into_iter()
                .filter_map(Result::ok)
                .filter(|folder| folder.is_dir())
                .collect()
        }
    };
    json!({
        "offered": offered.iter().map(|folder| folder.display().to_string()).collect::<Vec<_>>(),
        "chosen": shell.folders(),
        "hotkey": shortcut_text(&shell.hotkey()),
        "model": shell.model_state.lock().unwrap().clone(),
        "auto": shell.options.debug_setup,
    })
}

/// Folders chosen in the system's folder picker (none when it's cancelled).
#[tauri::command]
async fn pick_folders(app: AppHandle, title: Option<String>) -> Vec<String> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.dialog().file().set_title(title.unwrap_or_else(|| "Add Folders".into())).pick_folders(move |folders| {
        let _ = sender.send(folders);
    });
    let picked = receiver.await.ok().flatten().unwrap_or_default();
    picked.into_iter().filter_map(|folder| folder.into_path().ok()).map(|path| path.display().to_string()).collect()
}

/// Setup's last step: the folders are saved and indexing starts (once the model is in).
#[tauri::command]
fn finish_setup(app: AppHandle, shell: State<'_, Arc<Shell>>, folders: Vec<String>) -> Result<(), String> {
    {
        let mut settings = shell.settings.lock().unwrap();
        settings.folders = folders;
        settings.set_up = true;
        settings.save(&shell.settings_path).map_err(|error| format!("can't save the settings: {error}"))?;
    }
    apply_folders(&app);
    if let Some(window) = app.get_webview_window("setup") {
        let _ = window.close();
    }
    Ok(())
}

/// What the settings window shows: the folders and what's skipped, the pause, the GPU switch, where recordings open at
/// a moment (and whether VLC is there), the shortcut, starting at login, and where DigUp keeps things.
#[tauri::command]
async fn settings_info(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<Value, String> {
    let settings = shell.settings.lock().unwrap().clone();
    let gnome = desktop::is_gnome(std::env::var("XDG_CURRENT_DESKTOP").ok().as_deref());
    // gsettings is three small processes: not on the main thread.
    let shortcut = match gnome {
        true => tauri::async_runtime::spawn_blocking(desktop::gnome_shortcut).await.ok().flatten(),
        false => None,
    };
    let path = |folder: Option<PathBuf>| folder.map(|folder| folder.display().to_string());
    let status = shell.status.lock().unwrap().as_ref().and_then(|status| status.text().ok());
    let launcher = desktop::launcher();
    let (on_cpu, search_on_cpu, paused_why) = {
        let health = shell.health.lock().unwrap();
        (health.on_cpu, health.search_on_cpu, health.paused_why.clone())
    };
    Ok(json!({
        "status": status,
        // The GPU failed this session: everything, or only search, runs on the CPU (fallback.rs).
        "gpuFailed": on_cpu,
        "searchGpuFailed": search_on_cpu,
        "pausedWhy": paused_why,
        // The saved folders. Dev runs search the folders they're given (--roots) instead: the window says so, and
        // what's changed is saved for later.
        "folders": settings.folders,
        "foldersFromLaunch": !shell.options.roots.is_empty(),
        "skipped": settings.skipped,
        "skipTypes": settings.skip_types,
        "paused": settings.paused,
        "gpu": settings.gpu,
        "momentPlayer": if settings.prefers_vlc() { "vlc" } else { "default" },
        "vlc": shell.apps.vlc().is_some(),
        "hotkey": shortcut_text(&shell.hotkey()),
        "gnome": gnome,
        "shortcut": shortcut,
        // What our GNOME shortcut should run: when it runs something else (an older build), it can be set up again.
        "shortcutCommand": desktop::shortcut_command(&launcher),
        "startsAtLogin": desktop::starts_at_login(),
        "version": app.package_info().version.to_string(),
        "paths": {
            "index": path(shell.options.index_folder()),
            "models": path(shell.options.models_folder()),
            "logs": shell.logs.display().to_string(),
            "settings": shell.settings_path.display().to_string(),
        },
    }))
}

/// Settings' folders, skipped folders and skipped types: saved, and searching, watching and indexing follow them.
/// (Off the main thread: an index helper indexing the old folders takes up to two seconds to stop.)
#[tauri::command]
async fn save_folders(app: AppHandle, shell: State<'_, Arc<Shell>>, folders: Vec<String>, skipped: Vec<String>,
                      skip_types: String) -> Result<(), String> {
    shell.change_settings(|settings| {
        settings.folders = folders;
        settings.skipped = skipped;
        settings.skip_types = settings::extensions(&skip_types);
    })?;
    tauri::async_runtime::spawn_blocking(move || {
        apply_folders(&app);
        settings_changed(&app);
    })
    .await
    .map_err(|error| error.to_string())
}

/// Pause Indexing / Resume Indexing (the tray's and Settings'): kept in the settings, so a pause outlasts a restart.
#[tauri::command]
async fn set_paused(app: AppHandle, paused: bool) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || pause(&app, paused)).await.map_err(|error| error.to_string())?
}

/// The GPU switch: the helpers start over with it (DIGUP_GPU=0 when it's off), the search service at once. Switching
/// it on is also trying the GPU again after it failed this session.
#[tauri::command]
async fn set_gpu(app: AppHandle, shell: State<'_, Arc<Shell>>, gpu: bool) -> Result<(), String> {
    shell.change_settings(|settings| settings.gpu = gpu)?;
    if gpu {
        shell.health.lock().unwrap().try_gpu_again();
    }
    restart_helpers_now(app, shell.inner().clone()).await
}

/// Settings' "Try the GPU again" after it failed this session (fallback.rs): the helpers start over on it.
#[tauri::command]
async fn try_gpu_again(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<(), String> {
    shell.health.lock().unwrap().try_gpu_again();
    set_status(&app, "Trying the GPU again…");
    restart_helpers_now(app, shell.inner().clone()).await
}

/// The helpers start over as they're launched now, and the search service is warmed again, so the next search doesn't
/// wait for its start.
async fn restart_helpers_now(app: AppHandle, shell: Arc<Shell>) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || restart_helpers(&app)).await.map_err(|error| error.to_string())?;
    let _ = shell.search.ask(json!({"op": "status"})).await;
    Ok(())
}

/// The helpers start over as they're launched now (the GPU switch, the CPU fallback): the search service at once, a
/// running index helper too (it keeps the model where it loaded it). Blocks while they stop: not on the main thread.
fn restart_helpers(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    shell.search.set_launch(shell.search_launch());
    shell.search.stop();
    shell.index.stop();
    run_index(app);
    settings_changed(app);
}

/// Settings → About's "Check DigUp": `digup doctor --json` for this index and model, with the helpers' environment
/// (the GPU as they use it): {"ok", "checks": [{"name", "ok", "essential", "detail", "fix"?}], "seconds"}.
#[tauri::command]
async fn check_digup(shell: State<'_, Arc<Shell>>) -> Result<Value, String> {
    let shell = shell.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = std::process::Command::new(&shell.options.helper);
        command.arg("doctor").arg("--json").args(shell.index_arguments())
            .envs(helper_env(&shell.options, !shell.gpu_in_use()))
            .stdin(std::process::Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let output = command.output().map_err(|error| format!("can't run {}: {error}", shell.options.helper.display()))?;
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .find(|answer| answer.get("checks").is_some())
            .ok_or_else(|| {
                let said = String::from_utf8_lossy(&output.stderr);
                format!("digup doctor didn't answer: {}", said.lines().last().unwrap_or("no output"))
            })
    })
    .await
    .map_err(|error| error.to_string())?
}

/// Where recordings open at a moment: "vlc" (when it's installed) or "default" (the default app). The panel asks for
/// its Open titles again each time it's shown.
#[tauri::command]
fn set_moment_player(app: AppHandle, shell: State<'_, Arc<Shell>>, player: String) -> Result<(), String> {
    if player != "vlc" && player != "default" {
        return Err(format!("no such choice: {player}"));
    }
    shell.change_settings(|settings| settings.moment_player = player)?;
    settings_changed(&app);
    Ok(())
}

/// Starting at login: the autostart entry is written or removed.
#[tauri::command]
fn set_starts_at_login(app: AppHandle, on: bool) -> Result<(), String> {
    if !cfg!(target_os = "linux") {
        return Err("starting at login is set up on Linux only so far".into());
    }
    let result = desktop::set_starts_at_login(on, &desktop::launcher());
    settings_changed(&app);
    result
}

/// Writes the GNOME shortcut for the hotkey (see desktop.rs), running this program with `--toggle`.
#[tauri::command]
async fn set_up_shortcut(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<(), String> {
    let hotkey = shell.hotkey();
    let command = desktop::shortcut_command(&desktop::launcher());
    tauri::async_runtime::spawn_blocking(move || desktop::set_up_gnome_shortcut(&hotkey, &command))
        .await
        .map_err(|error| error.to_string())??;
    settings_changed(&app);
    Ok(())
}

/// Settings' "Turn DigUp off": it doesn't start at login any more (and, if asked, our GNOME shortcut goes, the
/// person's others stay), then it quits. Something that can't be undone that way leaves DigUp running, to say so.
#[tauri::command]
async fn turn_off(app: AppHandle, remove_shortcut: bool) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        if cfg!(target_os = "linux") {
            desktop::set_starts_at_login(false, &desktop::launcher())?;
        }
        if remove_shortcut {
            desktop::remove_gnome_shortcut()?;
        }
        Ok::<(), String>(())
    })
    .await
    .map_err(|error| error.to_string())??;
    quit(&app);
    Ok(())
}

/// The folder a query's `in:` names (scope.rs), among the folders searched: what the panel's chip searches in.
#[tauri::command]
fn resolve_folder(shell: State<'_, Arc<Shell>>, name: String) -> Result<scope::Folder, String> {
    let home = std::env::var("HOME").ok();
    scope::resolve(&name, &shell.folders(), home.as_deref(), scope::subfolders, Path::is_dir)
}

/// Opens a result in its default app.
#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    hide_panel(app.clone());
    app.opener().open_path(path, None::<&str>).map_err(|error| error.to_string())
}

/// Opens a result at its page, moment or line when its default app can be told it (opener.rs), else the plain way.
#[tauri::command]
async fn open_hit(app: AppHandle, shell: State<'_, Arc<Shell>>, hit: opener::Hit, query: String) -> Result<(), String> {
    hide_panel(app.clone());
    let shell = shell.inner().clone();
    let path = hit.path.clone();
    let opened = tauri::async_runtime::spawn_blocking(move || {
        let plan = opener::plan(&hit, &query, shell.apps.for_hit(&hit, shell.prefers_vlc()).as_ref());
        if cfg!(debug_assertions) {
            log!("open: {} → {plan:?}", hit.path);
        }
        plan != opener::Plan::Plain && opener::run(&plan).map_err(|error| log_error!("digup-shell: {error}")).is_ok()
    })
    .await
    .unwrap_or(false);
    if opened {
        return Ok(());
    }
    app.opener().open_path(path, None::<&str>).map_err(|error| error.to_string())
}

/// What ↩ does with a result, for the panel's footer and Open button: "Open at p. 3", "Open at 0:06", else "Open".
#[tauri::command]
async fn open_title(shell: State<'_, Arc<Shell>>, hit: opener::Hit) -> Result<String, String> {
    if hit.place().is_none() {
        return Ok("Open".into());
    }
    let shell = shell.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        opener::plan(&hit, "", shell.apps.for_hit(&hit, shell.prefers_vlc()).as_ref()).title()
    })
    .await
    .map_err(|error| error.to_string())
}

/// Shows a result in the file manager, selected.
#[tauri::command]
fn reveal(app: AppHandle, path: String) -> Result<(), String> {
    hide_panel(app.clone());
    app.opener().reveal_item_in_dir(path).map_err(|error| error.to_string())
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
}

/// The panel grows to show results and shrinks back to its field.
#[tauri::command]
fn panel_height(app: AppHandle, height: f64) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.set_size(LogicalSize::new(PANEL_WIDTH, height.clamp(FIELD_HEIGHT, 640.0)));
    }
}

/// Debug runs: the query the panel types in when it loads (with setup, it comes later as a "debug-query" event).
#[tauri::command]
fn debug_query(shell: State<'_, Arc<Shell>>) -> Option<String> {
    if shell.options.debug_setup {
        return None;
    }
    shell.options.debug_query.clone()
}

/// Debug runs: what the page showed for the debug query, printed (and the shell quits, if asked).
#[tauri::command]
fn debug_report(app: AppHandle, shell: State<'_, Arc<Shell>>, report: Value) {
    println!("{report}");
    if shell.options.debug_quit {
        quit(&app);
    }
}

fn main() {
    let options = match Options::from_args() {
        Ok(options) => options,
        Err(error) => {
            eprintln!("digup-shell: {error}");
            std::process::exit(2);
        }
    };
    let context = tauri::generate_context!();
    // `--quit`, `--pause`… with no DigUp running: answered without starting one (control.rs).
    #[cfg(target_os = "linux")]
    if let Some(command) = options.command.filter(|command| !command.starts_app()) {
        let identifier = context.config().identifier.clone();
        if !control::is_running(&identifier) {
            let (said, status) = control::when_not_running(command, options.settings_file(&identifier).as_deref());
            println!("{said}");
            std::process::exit(status);
        }
    }
    let app = tauri::Builder::default()
        // A second launch hands over its arguments: `--toggle` and the like do what they say (`act`); without one it
        // shows the panel, unless it's the login's (--background).
        .plugin(tauri_plugin_single_instance::init(|app, args, _| match Command::in_args(&args) {
            Some(command) => act(app, command),
            None if !args.iter().any(|arg| arg == "--background") => show_panel(app),
            None => {}
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _, event| {
                    if event.state == ShortcutState::Pressed {
                        toggle_panel(app);
                    }
                })
                .build(),
        )
        .setup(move |app| setup(app, options))
        .invoke_handler(tauri::generate_handler![
            ask, estimate, setup_info, pick_folders, finish_setup, resolve_folder, open_path, open_hit, open_title, reveal,
            hide_panel, panel_height, settings_info, save_folders, set_paused, set_gpu, set_starts_at_login, set_up_shortcut,
            turn_off, try_gpu_again, check_digup, set_moment_player, debug_query, debug_report
        ])
        .build(context)
        .expect("DigUp couldn't start");
    app.run(|app, event| match event {
        tauri::RunEvent::Exit => stop_helpers(app),
        // Closing the setup window isn't quitting: DigUp lives in the tray.
        tauri::RunEvent::ExitRequested { code: None, api, .. } => api.prevent_exit(),
        _ => {}
    });
}

fn setup(app: &mut tauri::App, options: Options) -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(target_os = "macos")]
    app.set_activation_policy(tauri::ActivationPolicy::Accessory); // the menu bar only, no Dock icon

    let handle = app.handle().clone();
    let logs = app.path().app_log_dir()?;
    std::fs::create_dir_all(&logs)?;
    let settings_path = match &options.settings {
        Some(path) => path.clone(),
        None => app.path().app_config_dir()?.join("settings.json"),
    };
    let settings = Settings::load(&settings_path);
    let roots: Vec<String> = if options.roots.is_empty() {
        settings.folders.clone()
    } else {
        options.roots.iter().map(|root| root.display().to_string()).collect()
    };
    let search = SearchService::new(
        search_launch(&options, &settings, roots, &logs, !settings.gpu),
        {
            let app = handle.clone();
            move |event| search_event(&app, event)
        },
    );
    let index = IndexService::new({
        let app = handle.clone();
        move |event| index_event(&app, event)
    });
    let model = ModelDownload::new({
        let app = handle.clone();
        move |event| model_event(&app, event)
    });
    // Previews show files from the chosen folders (and the helper's renders, once it says where the index is).
    for root in &settings.folders {
        let _ = app.asset_protocol_scope().allow_directory(root, true);
    }
    for root in &options.roots {
        let _ = app.asset_protocol_scope().allow_directory(root, true);
    }
    let shell = Arc::new(Shell {
        options,
        settings: Mutex::new(settings),
        settings_path,
        search,
        index,
        model,
        model_state: Mutex::new(json!({"state": "checking"})),
        watcher: Mutex::new(None),
        status: Mutex::new(None),
        pause_item: Mutex::new(None),
        reloaded: Mutex::new(Instant::now()),
        debug_query_sent: AtomicBool::new(false),
        logs,
        apps: opener::Apps::new(),
        health: Mutex::new(fallback::Health::default()),
    });
    app.manage(shell.clone());
    // Now with all it's started with (the logs it's watched by too).
    shell.search.set_launch(shell.search_launch());

    make_panel(&handle)?;
    // No tray (a session without a taskbar, a Linux desktop without one): the hotkey and the panel still work.
    if let Err(error) = make_tray(&handle, &shell) {
        log_error!("digup-shell: no tray icon: {error}");
    }
    let hotkey = shell.hotkey();
    if let Err(error) = app.global_shortcut().register(hotkey.as_str()) {
        set_status(&handle, &format!("The shortcut {} is taken", shortcut_text(&hotkey)));
        log_error!("digup-shell: can't use {hotkey} as the shortcut: {error}");
    }

    // The search service starts now (the first search is then quick); the model is checked (and fetched if it's
    // missing: on first launch that runs while setup is open, as on the Mac); indexing waits for both.
    let warm = shell.clone();
    tauri::async_runtime::spawn(async move {
        let _ = warm.search.ask(json!({"op": "status"})).await;
    });
    let mut download = vec!["download-model".to_string()];
    if let Some(models) = &shell.options.models {
        download.extend(["--to".to_string(), models.display().to_string()]);
    }
    if let Err(error) = shell.model.run(&shell.launch(download, "model.log")) {
        model_event(&handle, json!({"event": "error", "message": error}));
    }
    if shell.is_set_up() {
        watch_folders(&handle);
    } else {
        show_setup(&handle)?;
    }
    resync_now_and_then(handle.clone());
    if shell.options.debug_show {
        show_panel(&handle);
    }
    // Started with a command (`--settings`, `--show`… when DigUp wasn't running): done once it's up.
    if let Some(command) = shell.options.command {
        act(&handle, command);
    }
    Ok(())
}

/// What a command says (`digup-shell --toggle` and the like, options.rs): from a second launch, or this one's own.
fn act(app: &AppHandle, command: Command) {
    match command {
        Command::Toggle => toggle_panel(app),
        Command::Show => show_panel(app),
        Command::Hide => hide_panel(app.clone()),
        Command::Pause | Command::Resume => {
            let app = app.clone();
            // Stopping the index helper takes up to two seconds: not on the thread that handed the command over.
            tauri::async_runtime::spawn_blocking(move || {
                if let Err(error) = pause(&app, command == Command::Pause) {
                    set_status(&app, &error);
                }
            });
        }
        Command::Settings => {
            let _ = show_settings(app);
        }
        Command::Quit => quit(app),
        Command::IndexNow => run_index(app),
    }
}

/// After setup or a change of folders: the search service, the watcher and indexing follow the new folders.
fn apply_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders = shell.folders();
    let (skipped, types) = {
        let settings = shell.settings.lock().unwrap();
        (settings.skipped.clone(), settings.skip_types.clone())
    };
    for folder in &folders {
        let _ = app.asset_protocol_scope().allow_directory(folder, true);
    }
    // The running search service is told; one started later (after it died, or for the GPU switch) starts with them.
    shell.search.set_launch(shell.search_launch());
    let search = shell.clone();
    tauri::async_runtime::spawn(async move {
        let _ = search.search.ask(json!({"op": "folders", "roots": folders, "skipped": skipped, "types": types})).await;
    });
    watch_folders(app);
}

/// Watches the folders, and indexes them now when the model is in.
fn watch_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders: Vec<PathBuf> = shell.folders().iter().map(PathBuf::from).collect();
    if folders.is_empty() {
        set_status(app, "No folders chosen yet");
        return;
    }
    let changed = {
        let app = app.clone();
        move || run_index(&app)
    };
    *shell.watcher.lock().unwrap() = Some(FolderWatcher::start(&folders, shell.options.index_folder(), changed));
    if shell.is_paused() {
        set_status(app, "Paused");
    }
    run_index(app);
}

/// Syncs every `RESYNC_EVERY` (when indexing would run at all: `run_index` checks), unless a helper is in the middle of
/// a pass: asking it would only send it crawling sooner, and the next round comes after it's done. A lingering one is
/// asked; with none running, one starts.
fn resync_now_and_then(app: AppHandle) {
    std::thread::spawn(move || loop {
        std::thread::sleep(RESYNC_EVERY);
        if !app.state::<Arc<Shell>>().index.is_busy() {
            run_index(&app);
        }
    });
}

/// Has the index helper sync and index, once there's a model and a folder, unless indexing is paused.
fn run_index(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    if !shell.is_set_up() || shell.folders().is_empty() || !shell.model_ready() || shell.is_paused() {
        return;
    }
    if let Err(error) = shell.index.run(&shell.index_launch()) {
        set_status(app, &format!("Indexing couldn't start: {error}"));
    }
}

/// Pauses indexing (the index helper stops, and neither the watcher nor Index Now starts it) or resumes it. Blocks up
/// to two seconds while the helper stops: not on the main thread.
fn pause(app: &AppHandle, paused: bool) -> Result<(), String> {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    shell.change_settings(|settings| settings.paused = paused)?;
    show_pause(app, paused);
    if paused {
        shell.index.stop();
        // Paused by the shell itself (fallback.rs): it says why.
        let why = shell.health.lock().unwrap().paused_why.clone();
        set_status(app, why.as_deref().unwrap_or("Paused"));
    } else {
        shell.health.lock().unwrap().paused_why = None;
        set_status(app, if shell.folders().is_empty() { "No folders chosen yet" } else { "Looking for changes…" });
        run_index(app);
    }
    settings_changed(app);
    Ok(())
}

/// The tray follows the pause: Pause Indexing or Resume Indexing, and Index Now only while it isn't paused.
fn show_pause(app: &AppHandle, paused: bool) {
    if let Some((pause, index)) = app.state::<Arc<Shell>>().pause_item.lock().unwrap().as_ref() {
        let _ = pause.set_text(if paused { "Resume Indexing" } else { "Pause Indexing" });
        let _ = index.set_enabled(!paused);
    }
}

/// The settings window shows what changed (also from the tray).
fn settings_changed(app: &AppHandle) {
    let _ = app.emit_to("settings", "settings-changed", ());
}

fn stop_helpers(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    shell.model.stop();
    shell.index.stop();
    shell.search.stop();
}

fn quit(app: &AppHandle) {
    stop_helpers(app);
    app.exit(0);
}

// MARK: Windows

fn make_panel(app: &AppHandle) -> tauri::Result<()> {
    let panel = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("index.html".into()))
        .title("DigUp")
        .inner_size(PANEL_WIDTH, FIELD_HEIGHT)
        .decorations(false)
        .transparent(true)
        .shadow(true)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .visible(false)
        .build()?;
    let app = app.clone();
    panel.on_window_event(move |event| {
        // Like Spotlight: it steps away when you click elsewhere.
        if let WindowEvent::Focused(false) = event {
            if !app.state::<Arc<Shell>>().options.debug_show {
                hide_panel(app.clone());
            }
        }
    });
    Ok(())
}

fn show_panel(app: &AppHandle) {
    if !app.state::<Arc<Shell>>().is_set_up() {
        let _ = show_setup(app);
        return;
    }
    let Some(panel) = app.get_webview_window("panel") else { return };
    // On the screen with the pointer, centered, a fifth of the way down.
    if let Ok(pointer) = app.cursor_position() {
        if let Ok(Some(screen)) = app.monitor_from_point(pointer.x, pointer.y) {
            let width = (PANEL_WIDTH * screen.scale_factor()) as i32;
            let x = screen.position().x + (screen.size().width as i32 - width) / 2;
            let y = screen.position().y + (screen.size().height as f64 * 0.2) as i32;
            let _ = panel.set_position(PhysicalPosition::new(x, y));
        }
    }
    let _ = panel.show();
    let _ = panel.set_focus();
    let _ = panel.emit("panel-shown", ());
}

fn toggle_panel(app: &AppHandle) {
    match app.get_webview_window("panel") {
        Some(panel) if panel.is_visible().unwrap_or(false) => hide_panel(app.clone()),
        _ => show_panel(app),
    }
}

/// The setup window (first launch, and Choose Folders… later). Debug runs that click through it keep it hidden.
fn show_setup(app: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window("setup") {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    let hidden = app.state::<Arc<Shell>>().options.debug_setup;
    WebviewWindowBuilder::new(app, "setup", WebviewUrl::App("setup.html".into()))
        .title("Set Up DigUp")
        .inner_size(720.0, 600.0)
        .resizable(false)
        .maximizable(false)
        .center()
        .visible(!hidden)
        .build()?;
    Ok(())
}

/// The settings window (the tray's Settings…).
fn show_settings(app: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("DigUp Settings")
        .inner_size(640.0, 680.0)
        .min_inner_size(520.0, 420.0)
        .maximizable(false)
        .center()
        .build()?;
    Ok(())
}

/// "CommandOrControl+Shift+Space" as people read it here: "Ctrl+Shift+Space", or "⇧⌘Space" on a Mac.
fn shortcut_text(accelerator: &str) -> String {
    let parts: Vec<&str> = accelerator.split('+').collect();
    if cfg!(target_os = "macos") {
        let mut text = String::new();
        for (name, sign) in [("Ctrl", "⌃"), ("Control", "⌃"), ("Alt", "⌥"), ("Option", "⌥"), ("Shift", "⇧"),
                             ("CommandOrControl", "⌘"), ("CmdOrCtrl", "⌘"), ("Cmd", "⌘"), ("Command", "⌘"),
                             ("Super", "⌘")] {
            if parts.iter().any(|part| part.eq_ignore_ascii_case(name)) && !text.contains(sign) {
                text.push_str(sign);
            }
        }
        return text + parts.last().copied().unwrap_or_default();
    }
    parts
        .iter()
        .map(|part| match *part {
            "CommandOrControl" | "CmdOrCtrl" | "Control" => "Ctrl",
            "Super" => "Win",
            other => other,
        })
        .collect::<Vec<_>>()
        .join("+")
}

// MARK: The tray

fn make_tray(app: &AppHandle, shell: &Arc<Shell>) -> tauri::Result<()> {
    let status = MenuItem::with_id(app, "status", "Starting…", false, None::<&str>)?;
    let search = MenuItem::with_id(app, "search", "Search…", true, Some(shell.hotkey().as_str()))?;
    let folders = MenuItem::with_id(app, "folders", "Choose Folders…", true, None::<&str>)?;
    let paused = shell.is_paused();
    let index = MenuItem::with_id(app, "index", "Index Now", !paused, None::<&str>)?;
    let pause_item =
        MenuItem::with_id(app, "pause", if paused { "Resume Indexing" } else { "Pause Indexing" }, true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit DigUp", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(
        app,
        &[&status, &separator, &search, &folders, &index, &pause_item, &PredefinedMenuItem::separator(app)?,
          &settings, &quit_item],
    )?;
    // A Mac's menu bar takes a template (it colors it); trays elsewhere show the app's own small icon.
    #[cfg(target_os = "macos")]
    let icon = tauri::include_image!("icons/tray-template.png");
    #[cfg(not(target_os = "macos"))]
    let icon = tauri::include_image!("icons/tray.png");
    TrayIconBuilder::with_id("digup")
        .icon(icon)
        .icon_as_template(cfg!(target_os = "macos"))
        .tooltip("DigUp")
        .menu(&menu)
        .show_menu_on_left_click(cfg!(target_os = "macos"))
        .on_menu_event(|app, event| match event.id().as_ref() {
            "search" => show_panel(app),
            "folders" => {
                let _ = show_setup(app);
            }
            "index" => run_index(app),
            "pause" => {
                let (app, paused) = (app.clone(), !app.state::<Arc<Shell>>().is_paused());
                tauri::async_runtime::spawn_blocking(move || {
                    if let Err(error) = pause(&app, paused) {
                        set_status(&app, &error);
                    }
                });
            }
            "settings" => {
                let _ = show_settings(app);
            }
            "quit" => quit(app),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            // Windows and Linux: a click opens the panel, the menu is on the other button.
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                if !cfg!(target_os = "macos") {
                    toggle_panel(tray.app_handle());
                }
            }
        })
        .build(app)?;
    *shell.status.lock().unwrap() = Some(status);
    *shell.pause_item.lock().unwrap() = Some((pause_item, index));
    Ok(())
}

fn set_status(app: &AppHandle, text: &str) {
    if let Some(status) = app.state::<Arc<Shell>>().status.lock().unwrap().as_ref() {
        let _ = status.set_text(text);
    }
    let _ = app.emit("status", text);
}

// MARK: The helpers' events

fn search_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) {
        log!("search: {event}");
    }
    if event["event"] == "ready" {
        if let Some(index) = event["index"].as_str() {
            let _ = app.asset_protocol_scope().allow_directory(Path::new(index).join("previews"), false);
        }
    }
    let shell = app.state::<Arc<Shell>>().inner().clone();
    // A crash on the GPU counts towards going to the CPU (the next search starts it again by itself).
    if event["event"] == "exit" {
        let code = event["code"].as_i64().map(|code| code as i32);
        let signal = event["signal"].as_i64().map(|signal| signal as i32);
        let ending = fallback::ending(code, signal, false, event["gpu_error"].as_str());
        if ending != fallback::Ending::Fine {
            let gpu = shell.search_gpu_in_use();
            let next = shell.health.lock().unwrap().search_ended(&ending, gpu, Instant::now());
            log_error!("digup-shell: the search helper ended: {ending:?} → {next:?}");
            if next == fallback::Next::UseCpu {
                use_cpu(app);
            }
        }
    }
    // Its query encoder can't start on the GPU: it starts over on the CPU, once (keyword search goes on meanwhile).
    if event["event"] == "encoder" && event["state"] == "unavailable" {
        let gpu = shell.search_gpu_in_use();
        if shell.health.lock().unwrap().encoder_unavailable(gpu, shell.model_ready()) {
            log_error!("digup-shell: the query encoder can't start on the GPU ({}): search uses the CPU",
                       event["error"].as_str().unwrap_or("no reason given"));
            shell.search.set_launch(shell.search_launch());
            // Stopped off this thread: it's the one reading that helper's output. The next search starts it anew.
            let stopping = shell.clone();
            std::thread::spawn(move || stopping.search.stop());
            settings_changed(app);
        }
    }
    let _ = app.emit("helper", json!({"from": "search", "event": event}));
}

fn index_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) {
        log!("index: {event}");
    }
    let count = |key: &str| event[key].as_u64().unwrap_or(0);
    // Paused: a stopping helper's last lines don't take the tray's "Paused" away.
    let paused = app.state::<Arc<Shell>>().is_paused();
    let say = |text: &str| if !paused { set_status(app, text) };
    match event["event"].as_str().unwrap_or_default() {
        "file" => {
            say(&format!("Indexing {} of {}", count("done"), count("total")));
            reload(app, false);
        }
        "rest" => {
            say(&format!("Reading the rest of {} long files", count("files")));
            reload(app, false);
        }
        "idle" => {
            // On the CPU after the GPU failed: said here too, as "Up to date" stays up longest.
            let cpu = if app.state::<Arc<Shell>>().health.lock().unwrap().on_cpu { " · on the CPU" } else { "" };
            say(&format!("Up to date · {} files{cpu}", count("searchable")));
            reload(app, true);
            // A debug run through setup searches once the first index is in.
            let shell = app.state::<Arc<Shell>>();
            if let Some(query) = &shell.options.debug_query {
                if shell.options.debug_setup && !shell.debug_query_sent.swap(true, Ordering::SeqCst) {
                    let _ = app.emit_to("panel", "debug-query", query.clone());
                }
            }
        }
        "waiting" => say("Waiting for the model"),
        "error" => say(&format!("Indexing: {}", event["message"].as_str().unwrap_or("error"))),
        "exit" => {
            reload(app, true);
            // A sync asked for while it was on its way out still has to happen.
            if event["again"] == true {
                run_index(app);
            }
            // The shell's own last word of it (helper.rs): how it ended.
            if event["ended"] == true {
                index_ended(app, &event);
            }
        }
        _ => {}
    }
    let _ = app.emit("helper", json!({"from": "index", "event": event}));
}

/// What the tray says once the helpers have gone to the CPU.
const GPU_PROBLEM: &str = "GPU problem — indexing on the CPU";

/// The index helper is gone: one its watchdog ended is started again (at most 3 times in 10 minutes, then indexing
/// pauses, saying which file), one that crashed too, and the GPU's second failure sends the helpers to the CPU
/// (fallback.rs).
fn index_ended(app: &AppHandle, event: &Value) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let code = event["code"].as_i64().map(|code| code as i32);
    let signal = event["signal"].as_i64().map(|signal| signal as i32);
    let ending = fallback::ending(code, signal, event["fatal"] == true, event["gpu_error"].as_str());
    if ending == fallback::Ending::Fine {
        return;
    }
    // Read before the next helper starts: it takes the note away.
    let stopped = match ending {
        fallback::Ending::Watchdog => shell.options.index_folder().and_then(|index| fallback::stopped_file(&index)),
        _ => None,
    };
    let gpu = shell.gpu_in_use();
    let next = shell.health.lock().unwrap().index_ended(&ending, gpu, Instant::now());
    log_error!("digup-shell: the index helper ended: {ending:?}{} → {next:?}",
               stopped.as_ref().map(|(path, why)| format!(" ({path} {why})")).unwrap_or_default());
    match next {
        fallback::Next::Nothing => {}
        fallback::Next::Restart => run_index(app),
        fallback::Next::Pause => {
            let file = stopped.map(|(path, _)| Path::new(&path).file_name().map_or(path.clone(), |name| {
                name.to_string_lossy().into_owned()
            }));
            shell.health.lock().unwrap().paused_why =
                Some(format!("Indexing paused: {} kept failing", file.as_deref().unwrap_or("a file")));
            let app = app.clone();
            std::thread::spawn(move || {
                if let Err(error) = pause(&app, true) {
                    set_status(&app, &error);
                }
            });
        }
        fallback::Next::UseCpu => use_cpu(app),
        fallback::Next::GiveUp => set_status(app, "Indexing stopped: DigUp's helper kept crashing (see index.log)"),
    }
}

/// The GPU failed twice in ten minutes: every helper starts over on the CPU, for the rest of this session.
fn use_cpu(app: &AppHandle) {
    app.state::<Arc<Shell>>().health.lock().unwrap().on_cpu = true;
    log_error!("digup-shell: the GPU failed twice in 10 minutes: the helpers use the CPU until DigUp restarts");
    set_status(app, GPU_PROBLEM);
    let app = app.clone();
    // Not on the thread that read the helper's output (stopping the other helper takes a moment).
    std::thread::spawn(move || restart_helpers(&app));
}

fn model_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) && event["event"] != "progress" {
        log!("model: {event}");
    }
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let state = match event["event"].as_str().unwrap_or_default() {
        "progress" => {
            let (bytes, total) = (event["all_bytes"].as_f64().unwrap_or(0.0), event["all_total"].as_f64().unwrap_or(1.0));
            set_status(app, &format!("Downloading the model · {:.0}%", 100.0 * bytes / total.max(1.0)));
            json!({"state": "downloading", "bytes": bytes, "total": total})
        }
        "file" => json!({"state": "downloading", "from": event["from"]}),
        "verifying" => json!({"state": "checking"}),
        "waiting" => json!({"state": "waiting"}),
        "retry" => json!({"state": "downloading", "problem": event["message"]}),
        "done" => json!({"state": "ready"}),
        "error" => {
            set_status(app, "The model couldn't download");
            json!({"state": "failed", "message": event["message"]})
        }
        _ => return,
    };
    let ready = state["state"] == "ready";
    *shell.model_state.lock().unwrap() = state.clone();
    let _ = app.emit("model", state);
    if ready {
        if shell.folders().is_empty() {
            set_status(app, "No folders chosen yet");
        } else if shell.is_paused() {
            set_status(app, "Paused");
        }
        run_index(app);
    }
}

/// Has the search service read the index again: at once when indexing settles, else at most every three seconds.
fn reload(app: &AppHandle, now: bool) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    {
        let mut reloaded = shell.reloaded.lock().unwrap();
        if !now && reloaded.elapsed() < Duration::from_secs(3) {
            return;
        }
        *reloaded = Instant::now();
    }
    tauri::async_runtime::spawn(async move {
        let reply = shell.search.ask(json!({"op": "reload"})).await;
        if cfg!(debug_assertions) {
            log!("search: reload {reply:?}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortcuts_as_people_read_them() {
        if cfg!(target_os = "linux") {
            assert_eq!(shortcut_text(DEFAULT_HOTKEY), "Ctrl+Alt+Space");
        }
        if !cfg!(target_os = "macos") {
            assert_eq!(shortcut_text("CommandOrControl+Shift+Space"), "Ctrl+Shift+Space");
        }
    }

    #[test]
    fn log_lines_say_the_time() {
        let time = time_of_day();
        let parts: Vec<&str> = time.split([':', '.']).collect();
        assert_eq!(parts.iter().map(|part| part.len()).collect::<Vec<_>>(), [2, 2, 2, 3], "{time}");
        assert!(parts.iter().all(|part| part.parse::<u32>().is_ok()), "{time}");
        assert!(parts[0].parse::<u32>().unwrap() < 24 && parts[1].parse::<u32>().unwrap() < 60);
    }

    #[test]
    fn helpers_use_the_cpu_when_told() {
        let options = Options {
            helper: "digup".into(), index: None, models: None, roots: Vec::new(), hotkey: None, settings: None,
            command: None, offered: None, debug_setup: false, debug_query: None, debug_quit: false, debug_show: false,
            background: false,
        };
        assert!(helper_env(&options, false).is_empty());
        assert_eq!(helper_env(&options, true), [("DIGUP_GPU".to_string(), "0".to_string())]);
        let skipping = Settings { skipped: vec!["/a/b".into()], ..Settings::default() };
        let launch = search_launch(&options, &skipping, vec!["/a".into()], Path::new("/logs"), true);
        assert_eq!(launch.args, ["search-service", "--exclude", "/a/b", "/a"]);
        assert_eq!(launch.env, [("DIGUP_GPU".to_string(), "0".to_string())]);
        assert!(!launch.background);
    }
}
