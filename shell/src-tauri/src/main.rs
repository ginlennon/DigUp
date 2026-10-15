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

mod adding;
mod control;
mod desktop;
mod editors;
mod fallback;
#[cfg(target_os = "linux")]
mod gtk_log;
mod helper;
#[cfg(target_os = "linux")]
mod notify;
mod opener;
mod options;
mod panel;
mod scope;
mod settings;
mod tools;
mod transcripts;
mod watcher;

use helper::{IndexService, Launch, ModelDownload, SearchService};
use options::{Command, Options, DEFAULT_HOTKEY};
use serde_json::{json, Value};
use settings::Settings;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, PixelUnit, State, WebviewUrl, WebviewWindow,
            WebviewWindowBuilder, WindowEvent, WindowSizeConstraints, Wry};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tauri_plugin_opener::OpenerExt;
use watcher::FolderWatcher;

/// How often the folders (and the code folders) are synced with no change seen. The watcher can miss changes: inotify drops events when its
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
    /// `digup download-model --transcripts`: the transcripts' model, fetched when they're turned on (transcripts.rs).
    transcript_model: ModelDownload,
    /// Its state for Settings, as `model_state` (transcripts::state), or {"state": "idle"} when none was asked for.
    transcript_state: Mutex<Value>,
    /// When the transcripts' model is in, the index helper starts over: one started without it has no transcriber.
    /// Set by turning transcripts on, and by a file the download fetched.
    transcripts_restart: AtomicBool,
    /// The transcripts' download was stopped on purpose (turned off, or replaced): its "the download stopped" is no
    /// failure.
    transcripts_cancelled: AtomicBool,
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
    /// The code editors installed, for code results.
    editors: editors::Editors,
    /// The search panel's size and place (panel.rs), and how many of its changes were saved later (the last saves).
    panel: Mutex<panel::Panel>,
    panel_saves: AtomicU64,
    /// GTK speaks Wayland: the panel can't place itself (panel.rs).
    wayland: bool,
    /// The folder the add window is for (adding.rs).
    adding: Mutex<Option<PathBuf>>,
    /// A folder just added, whose files go first: told to the next index helper that starts (`--first`), then
    /// forgotten.
    first: Mutex<Option<String>>,
    /// How indexing goes, and the folders added that it hasn't been through yet, for tools (tools.rs).
    progress: Mutex<tools::Progress>,
    /// Tools' requests on the session bus ("<identifier>.Tools"), while DigUp runs.
    #[cfg(target_os = "linux")]
    tools_bus: Mutex<Option<zbus::blocking::Connection>>,
    /// Notifications with buttons (a tool's add, with Undo).
    #[cfg(target_os = "linux")]
    notifier: notify::Notifier,
}

impl Shell {
    /// The folders searched: the launch arguments' in dev runs, else the settings'.
    fn folders(&self) -> Vec<String> {
        if !self.options.roots.is_empty() {
            return self.options.roots.iter().map(|root| root.display().to_string()).collect();
        }
        self.settings.lock().unwrap().folders.clone()
    }

    /// The code folders (code search; none: off).
    fn code_folders(&self) -> Vec<String> {
        self.settings.lock().unwrap().code_folders.clone()
    }

    /// Where code results open: the editor chosen in Settings (or the first one installed), else None: the file's
    /// default app (editors.rs).
    fn code_editor(&self) -> Option<editors::Editor> {
        let id = self.settings.lock().unwrap().code_editor.clone();
        editors::chosen(&id, &self.editors.installed())
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

    /// What the tray says while indexing is paused: why, when DigUp paused it by itself.
    fn paused_text(&self) -> String {
        self.settings.lock().unwrap().paused_why.clone().unwrap_or_else(|| "Paused".to_string())
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
            once: Vec::new(),
            env: helper_env(&self.options, !self.gpu_in_use()),
            log: Some(self.logs.join(log)),
            also_logs: Vec::new(),
            background: true,
        }
    }

    /// `search-service` for the folders and settings as they are now. (llama.cpp's own log, where a Vulkan error may
    /// be rather than on stderr, is one of its own, which it names when it's ready: helper.rs.)
    fn search_launch(&self) -> Launch {
        let settings = self.settings.lock().unwrap().clone();
        search_launch(&self.options, &settings, self.folders(), &self.logs, !self.search_gpu_in_use())
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
        args.extend(code_arguments(&settings));
        // Transcripts on the GPU, or with the small model on the CPU, or off (transcripts.rs).
        args.extend(transcripts::arguments(&settings, self.gpu_in_use()));
        args.extend(self.folders());
        let mut launch = self.launch(args, "index.log");
        launch.also_logs.extend(self.options.index_folder().map(|index| index.join("worker.log")));
        // A folder just added goes first, for a helper that starts now (one running already isn't started over).
        launch.once.extend(self.first.lock().unwrap().iter().flat_map(|folder| ["--first".to_string(), folder.clone()]));
        launch
    }

    /// A helper started (`IndexService::run`'s Ok(true)): it took the folder to index first, if there was one.
    fn index_started(&self, started: bool) {
        if started {
            if let Some(folder) = self.first.lock().unwrap().take() {
                log!("index: {folder} goes first");
            }
        }
    }

    /// whisper-cli is in this build, where the helper looks for it (transcripts.rs): without it Settings can't turn
    /// transcripts on.
    fn transcripts_installed(&self) -> bool {
        let chosen = std::env::var("DIGUP_WHISPER").ok();
        transcripts::whisper(&self.options.helper, chosen.as_deref(), std::env::var_os("PATH").as_deref()).is_some()
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

/// Code search's folders for both helpers: `--code-root` for each code folder, `--code-exclude` for what's skipped in
/// them. None: no code index is kept (one made earlier stays, unsearched).
fn code_arguments(settings: &Settings) -> Vec<String> {
    let roots = settings.code_folders.iter().flat_map(|folder| ["--code-root".to_string(), folder.clone()]);
    let skipped = settings.code_skipped.iter().flat_map(|folder| ["--code-exclude".to_string(), folder.clone()]);
    roots.chain(skipped).collect()
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
    args.extend(code_arguments(settings));
    args.extend(folders);
    Launch {
        program: options.helper.clone(),
        args,
        once: Vec::new(),
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
/// pass's seconds, the rest of long files, subfolders. For setup and the add window (`code`: for the code index).
#[tauri::command]
async fn estimate(shell: State<'_, Arc<Shell>>, folders: Vec<String>, code: Option<bool>) -> Result<Vec<Value>, String> {
    let helper = shell.options.helper.clone();
    // This index's costs, measured by indexing here.
    let index = shell.index_arguments();
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = std::process::Command::new(&helper);
        command.arg("estimate").args(&folders).arg("--json").args(index);
        if code == Some(true) {
            command.arg("--code");
        }
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
/// a moment (and whether VLC is there), the shortcut, the search panel's size, starting at login, and where DigUp
/// keeps things.
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
    let (on_cpu, search_on_cpu) = {
        let health = shell.health.lock().unwrap();
        (health.on_cpu, health.search_on_cpu)
    };
    Ok(json!({
        "status": status,
        // The GPU failed this session: everything, or only search, runs on the CPU (fallback.rs).
        "gpuFailed": on_cpu,
        "searchGpuFailed": search_on_cpu,
        "pausedWhy": settings.paused_why,
        // The saved folders. Dev runs search the folders they're given (--roots) instead: the window says so, and
        // what's changed is saved for later.
        "folders": settings.folders,
        "foldersFromLaunch": !shell.options.roots.is_empty(),
        "skipped": settings.skipped,
        "skipTypes": settings.skip_types,
        "paused": settings.paused,
        "gpu": settings.gpu,
        "momentPlayer": if settings.prefers_vlc() { "vlc" } else { "default" },
        // Code search: its folders, what's skipped there, and the editors to choose from with the one in use.
        "codeFolders": settings.code_folders,
        "codeSkipped": settings.code_skipped,
        "editors": shell.editors.installed(),
        "codeEditor": shell.code_editor().map_or(editors::DEFAULT_APP.to_string(), |editor| editor.id),
        "vlc": shell.apps.vlc().is_some(),
        // Transcripts of recordings: the setting, whether this build has whisper-cli, whether they'd run on the GPU
        // (else with the small model on the CPU), and their model's download.
        "transcripts": settings.transcripts,
        "transcribeMusic": settings.transcribe_music,
        "transcriber": shell.transcripts_installed(),
        "transcriptsOnGpu": shell.gpu_in_use(),
        "transcriptModel": shell.transcript_state.lock().unwrap().clone(),
        "hotkey": shortcut_text(&shell.hotkey()),
        // The search panel's width and height with results (and, X11, whether it was dragged somewhere).
        "panelSize": [settings.panel_width, settings.panel_height],
        "panelMoved": settings.panel_position.is_some(),
        "panelSizeDefault": settings.panel_width == panel::DEFAULT_WIDTH && settings.panel_height == panel::DEFAULT_HEIGHT
            && settings.panel_position.is_none(),
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
/// it on is also trying the GPU again after it failed this session. With transcripts on, their model for the GPU or
/// the CPU is fetched if it isn't here.
#[tauri::command]
async fn set_gpu(app: AppHandle, shell: State<'_, Arc<Shell>>, gpu: bool) -> Result<(), String> {
    shell.change_settings(|settings| settings.gpu = gpu)?;
    if gpu {
        shell.health.lock().unwrap().try_gpu_again();
    }
    restart_helpers_now(app.clone(), shell.inner().clone()).await?;
    fetch_transcript_model_if_on(&app);
    Ok(())
}

/// Settings' "Try the GPU again" after it failed this session (fallback.rs): the helpers start over on it.
#[tauri::command]
async fn try_gpu_again(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<(), String> {
    shell.health.lock().unwrap().try_gpu_again();
    set_status(&app, "Trying the GPU again…");
    restart_helpers_now(app.clone(), shell.inner().clone()).await?;
    fetch_transcript_model_if_on(&app);
    Ok(())
}

/// Settings → Indexing → Transcribe recordings. On: their model is fetched if it isn't here (its progress shows in
/// Settings), then the index helper starts over with them; a failed download turns them off again, saying why. Off
/// (also Settings' Cancel of the download): a download under way stops, and the helper starts over with `--transcripts
/// off`, which takes the index's transcripts out.
#[tauri::command]
async fn set_transcripts(app: AppHandle, shell: State<'_, Arc<Shell>>, on: bool) -> Result<(), String> {
    if on && !shell.transcripts_installed() {
        return Err("Transcripts aren't installed in this build (no whisper-cli)".into());
    }
    shell.change_settings(|settings| settings.transcripts = on)?;
    let shell = shell.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        if on {
            fetch_transcript_model(&app, true);
        } else {
            stop_transcript_download(&shell);
            transcript_state(&app, json!({"state": "idle"}));
            run_index(&app);
        }
        settings_changed(&app);
    })
    .await
    .map_err(|error| error.to_string())
}

/// "Also transcribe music": the index helper starts over with it (songs get transcripts, or theirs go).
#[tauri::command]
async fn set_transcribe_music(app: AppHandle, shell: State<'_, Arc<Shell>>, on: bool) -> Result<(), String> {
    shell.change_settings(|settings| settings.transcribe_music = on)?;
    tauri::async_runtime::spawn_blocking(move || {
        run_index(&app);
        settings_changed(&app);
    })
    .await
    .map_err(|error| error.to_string())
}

/// With transcripts on: their model for how indexing runs now (`fetch_transcript_model`), after the GPU switch.
fn fetch_transcript_model_if_on(app: &AppHandle) {
    if app.state::<Arc<Shell>>().settings.lock().unwrap().transcripts {
        fetch_transcript_model(app, false);
    }
}

/// Fetches the transcripts' model for how indexing runs now (whisper small for the CPU), unless it's here already
/// (then `digup download-model` says "done" at once). A download of the other one stops first. Once it's in, the index
/// helper starts over if `restart` asks (transcripts just turned on) or a file had to be fetched.
fn fetch_transcript_model(app: &AppHandle, restart: bool) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    stop_transcript_download(&shell);
    shell.transcripts_restart.store(restart, Ordering::SeqCst);
    transcript_state(app, json!({"state": "checking"}));
    let args = transcripts::download_arguments(shell.gpu_in_use(), shell.options.models.as_deref());
    if let Err(error) = shell.transcript_model.run(&shell.launch(args, "transcripts-model.log")) {
        transcript_model_event(app, json!({"event": "error", "message": error}));
    }
}

/// Stops the transcripts' download, if one runs, so that its end isn't taken for a failure.
fn stop_transcript_download(shell: &Shell) {
    if shell.transcript_model.is_running() {
        shell.transcripts_cancelled.store(true, Ordering::SeqCst);
        shell.transcript_model.stop();
    }
}

/// The transcripts' download state, kept for Settings and sent to it.
fn transcript_state(app: &AppHandle, state: Value) {
    *app.state::<Arc<Shell>>().transcript_state.lock().unwrap() = state.clone();
    let _ = app.emit_to("settings", "transcript-model", state);
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

/// The folder a query's `in:` names (scope.rs), among the folders searched and the code folders: what the panel's
/// chip searches in.
#[tauri::command]
fn resolve_folder(shell: State<'_, Arc<Shell>>, name: String) -> Result<scope::Folder, String> {
    let home = std::env::var("HOME").ok();
    let roots: Vec<String> = shell.folders().into_iter().chain(shell.code_folders()).collect();
    scope::resolve(&name, &roots, home.as_deref(), scope::subfolders, Path::is_dir)
}

// MARK: Adding a folder

/// The add window's folder as DigUp sees it (adding.rs), and whether indexing is paused (it would start on resume).
#[tauri::command]
fn add_folder_info(shell: State<'_, Arc<Shell>>) -> Result<Value, String> {
    let folder = shell.adding.lock().unwrap().clone().ok_or("No folder to add")?;
    Ok(json!({"look": look_at(&shell, &folder), "paused": shell.is_paused()}))
}

/// What DigUp makes of a folder to add, with the settings as they are now.
fn look_at(shell: &Shell, folder: &Path) -> adding::Look {
    // Its real path, as the settings and the index keep folders.
    let folder = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf());
    let home = std::env::var_os("HOME").map(|home| std::fs::canonicalize(&home).unwrap_or_else(|_| PathBuf::from(home)));
    let settings = shell.settings.lock().unwrap().clone();
    let mut look = adding::look(&folder, &settings, home.as_deref(), Path::is_dir, Path::exists);
    if !shell.options.roots.is_empty() && look.refused.is_none() {
        look.kind = adding::Kind::Refused;
        look.refused = Some("This DigUp searches the folders it was started with (--roots): add folders in a run \
                             without them.".into());
    }
    look
}

/// The add window's Start: the folder goes into the settings as chosen (adding.rs), its files are indexed first when
/// there's anything new, and the panel opens searching in it, saying how far indexing is. Off the main thread: an
/// index helper indexing takes up to two seconds to stop.
#[tauri::command]
async fn add_folder(app: AppHandle, shell: State<'_, Arc<Shell>>, choice: adding::Choice) -> Result<(), String> {
    let folder = shell.adding.lock().unwrap().clone().ok_or("No folder to add")?;
    let look = look_at(&shell, &folder);
    if let Some(why) = look.refused {
        return Err(why);
    }
    let mut index = false;
    shell.change_settings(|settings| index = adding::apply(settings, &look, &choice))?;
    log!("add: {} ({:?}{})", look.path, look.kind, if index { ", indexed first" } else { "" });
    if index {
        *shell.first.lock().unwrap() = Some(look.path.clone());
        shell.progress.lock().unwrap().added(&look.path, Instant::now());
    }
    *shell.adding.lock().unwrap() = None;
    let applied = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        if index {
            apply_folders(&applied);
        }
        settings_changed(&applied);
    })
    .await
    .map_err(|error| error.to_string())?;
    if let Some(window) = app.get_webview_window("add") {
        let _ = window.close();
    }
    show_panel(&app);
    let _ = app.emit_to("panel", "scope-to", json!({"path": look.path, "name": look.name, "ambiguous": false,
                                                    "indexing": index, "code": look.code}));
    Ok(())
}

/// The add window's Cancel (or Esc): it closes, and nothing changes.
#[tauri::command]
fn cancel_add(app: AppHandle, shell: State<'_, Arc<Shell>>) {
    *shell.adding.lock().unwrap() = None;
    if let Some(window) = app.get_webview_window("add") {
        let _ = window.close();
    }
}

// MARK: Tools adding folders (Linux: the session bus)

/// A tool's request to add a folder (tools.rs, over the session bus): the add window's rules and the tools' own, the
/// file count before anything starts, then added as the add window adds it, with what it starts unchecked left out,
/// indexed first, and said in a notification with Undo. Blocks while it counts and while the index helper stops.
#[cfg(target_os = "linux")]
fn tool_add(app: &AppHandle, folder: String, tool: String, max_files: u32) -> Value {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let tool = tools::tool_name(&tool);
    let refuse = |message: String| {
        log!("tool add: {tool} asked for {folder}: refused ({message})");
        json!({"ok": false, "message": message})
    };
    let asked = PathBuf::from(&folder);
    if !asked.is_absolute() {
        return refuse(format!("{folder} isn't an absolute path."));
    }
    if !shell.is_set_up() {
        return refuse("DigUp isn't set up yet: open it and choose your folders first.".into());
    }
    let look = look_at(&shell, &asked);
    if let Some(why) = look.refused.clone() {
        return refuse(why);
    }
    let path = PathBuf::from(&look.path);
    let home = std::env::var_os("HOME").map(|home| std::fs::canonicalize(&home).unwrap_or_else(|_| PathBuf::from(home)));
    let settings = shell.settings.lock().unwrap().clone();
    if let Some(why) = tools::refused(&path, home.as_deref(), &settings) {
        return refuse(why);
    }
    let shown = tools::shown(&path, home.as_deref());
    if look.kind == adding::Kind::Inside {
        let within = look.within.clone().unwrap_or_default();
        let how = if look.code { "code search" } else { "search" };
        let message = if within == look.path {
            format!("{shown} is one of DigUp's folders already (for {how}).")
        } else {
            let within = tools::shown(Path::new(&within), home.as_deref());
            format!("{shown} is searched already (it's in {within}, for {how}).")
        };
        return json!({"ok": true, "added": false, "path": look.path, "code": look.code, "message": message});
    }
    let cap = if max_files == 0 { tools::MAX_FILES } else { max_files };
    let counted = tools::count(&path, cap as u64, Instant::now() + tools::COUNT_TIME);
    if counted.over {
        let how_many = if counted.slow { "too many files to count quickly".to_string() }
                       else { format!("more than {cap} files") };
        return refuse(format!("{shown} has {how_many}: that's for DigUp's own Add a Folder, which shows the counts and \
                               lets you leave subfolders out (digup-shell --add-folder {}).", look.path));
    }
    let choice = adding::Choice { skipped: counted.left_out.clone(), documents: false, take_in: Vec::new() };
    let mut change = tools::Change::default();
    let saved = shell.change_settings(|settings| {
        let before = settings.clone();
        adding::apply(settings, &look, &choice);
        change = tools::Change::between(&before, settings);
    });
    if let Err(error) = saved {
        return refuse(error);
    }
    log!("tool add: {tool} added {} ({:?}, {} files, {} left out)", look.path, look.kind, counted.files,
         counted.left_out.len());
    *shell.first.lock().unwrap() = Some(look.path.clone());
    shell.progress.lock().unwrap().added(&look.path, Instant::now());
    apply_folders(app);
    settings_changed(app);
    let what = if look.code { "code search" } else { "search" };
    let mut message = format!("{tool} added {shown} to DigUp ({what}, {} files); its files are indexed first.",
                              counted.files);
    // Undo takes it out again; a click on the notification opens the panel searching in it.
    let body = format!("{} files, indexed now{}. Undo takes it out again.", counted.files,
                       if look.code { " for code search" } else { "" });
    let (undoing, path) = (app.clone(), look.path.clone());
    let opened = json!({"path": look.path, "name": look.name, "ambiguous": false, "indexing": true, "code": look.code});
    let shown_again = shown.clone();
    let then = move |key: String| match key.as_str() {
        "undo" => tool_undo(&undoing, &path, &shown_again, change),
        "default" => {
            show_panel(&undoing);
            let _ = undoing.emit_to("panel", "scope-to", opened);
        }
        _ => {}
    };
    let summary = format!("{tool} added {shown} to DigUp");
    if let Err(error) = shell.notifier.show(&summary, &body, &[("undo", "Undo")], then) {
        log_error!("digup-shell: {error}");
        message.push_str(" (DigUp couldn't show a notification: Settings → Folders takes it out again.)");
    }
    let indexing = if shell.is_paused() { "paused" } else { "started" };
    json!({"ok": true, "added": true, "path": look.path, "code": look.code, "files": counted.files,
           "skipped": counted.left_out, "indexing": indexing, "message": message})
}

/// The notification's Undo: the settings as they were before the tool's add (what's changed since stays), and
/// searching, watching and indexing follow; rows of its files leave the index with the next sync (as when it's taken
/// out in Settings). The last code folder taken out turns code search off, as in Settings.
#[cfg(target_os = "linux")]
fn tool_undo(app: &AppHandle, path: &str, shown: &str, change: tools::Change) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let mut turned_off = false;
    let mut undone = false;
    let saved = shell.change_settings(|settings| {
        let had_code = !settings.code_folders.is_empty();
        undone = change.undo(settings);
        turned_off = had_code && settings.code_folders.is_empty();
    });
    if let Err(error) = saved {
        return set_status(app, &error);
    }
    log!("tool add: undone for {path}");
    shell.progress.lock().unwrap().removed(path);
    let mut first = shell.first.lock().unwrap();
    if first.as_deref() == Some(path) {
        *first = None;
    }
    drop(first);
    if !undone {
        return;
    }
    let app = app.clone();
    let shown = shown.to_string();
    std::thread::spawn(move || {
        if turned_off {
            turn_off_code_search(&app);
        }
        apply_folders(&app);
        settings_changed(&app);
        let shell = app.state::<Arc<Shell>>();
        let _ = shell.notifier.show(&format!("{shown} is out of DigUp again"), "", &[], |_| {});
    });
}

/// For tools (tools.rs's `Status`): whether indexing is paused or under way, how far, and the folders just added
/// that it hasn't been through yet.
#[cfg(target_os = "linux")]
fn tool_status(app: &AppHandle) -> Value {
    let shell = app.state::<Arc<Shell>>();
    let mut status = shell.progress.lock().unwrap().json(shell.is_paused());
    status["ok"] = json!(true);
    status["setUp"] = json!(shell.is_set_up());
    status
}

/// The folder popover's "Add a folder…": the desktop's folder dialog (through the portal, as setup's), then the add
/// window for the folder picked. The panel steps away first, as the dialog takes the keyboard.
#[tauri::command]
async fn pick_folder_to_add(app: AppHandle) -> Result<(), String> {
    hide_panel(app.clone());
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.dialog().file().set_title("Add a Folder to DigUp").pick_folder(move |folder| {
        let _ = sender.send(folder);
    });
    match receiver.await.ok().flatten().and_then(|folder| folder.into_path().ok()) {
        Some(folder) => show_add(&app, folder).map_err(|error| error.to_string()),
        None => Ok(()),   // cancelled
    }
}

/// The folder popover's folders (Ctrl+O, scope.rs): the folders searched and, apart, the code folders, each with the
/// folders right inside it. Off the main thread: it lists folders on the disk.
#[tauri::command]
async fn panel_folders(shell: State<'_, Arc<Shell>>) -> Result<Value, String> {
    let shell = shell.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let settings = shell.settings.lock().unwrap().clone();
        json!({
            "folders": scope::choices(&shell.folders(), &settings.skipped, scope::subfolders),
            "code": scope::choices(&settings.code_folders, &settings.code_skipped, scope::subfolders),
        })
    })
    .await
    .map_err(|error| error.to_string())
}

/// What the panel needs to know of the settings: whether there are code folders (for `code:`'s hint).
#[tauri::command]
fn panel_info(shell: State<'_, Arc<Shell>>) -> Value {
    json!({"codeFolders": shell.code_folders().len()})
}

/// Settings → Code: the code folders and what's skipped in them. Saved, and both helpers and the watcher follow. The
/// last code folder taken out turns code search off, and its index is deleted (`turn_off_code_search`).
#[tauri::command]
async fn save_code_folders(app: AppHandle, shell: State<'_, Arc<Shell>>, folders: Vec<String>, skipped: Vec<String>)
                           -> Result<(), String> {
    let mut turned_off = false;
    shell.change_settings(|settings| {
        turned_off = !settings.code_folders.is_empty() && folders.is_empty();
        settings.code_folders = folders;
        settings.code_skipped = skipped;
    })?;
    tauri::async_runtime::spawn_blocking(move || {
        if turned_off {
            turn_off_code_search(&app);
        }
        apply_folders(&app);
        settings_changed(&app);
    })
    .await
    .map_err(|error| error.to_string())
}

/// Code search is off (its last folder was taken out): its index goes, as with the Mac app's "Turn Off Code Search"
/// (Engine.swift's `removeCodeIndexIfAsked`). Both helpers have it open, so they stop first; `apply_folders` starts
/// them again without code folders. Blocks while they stop: not on the main thread. (Another program's search helper
/// on this index, an MCP server's, reads the deleted file until it starts over.)
fn turn_off_code_search(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    shell.index.stop();
    shell.search.set_launch(shell.search_launch());
    shell.search.stop();
    let Some(index) = shell.options.index_folder() else { return };
    match delete_code_index(&index) {
        Ok(true) => log!("code search off: the code index was deleted"),
        Ok(false) => {}
        Err(error) => log_error!("digup-shell: can't delete the code index in {}: {error}", index.display()),
    }
}

/// Deletes the code index in the index folder (code.sqlite, and SQLite's -wal and -shm beside it): whether there was
/// one.
fn delete_code_index(index: &Path) -> std::io::Result<bool> {
    let mut deleted = false;
    for name in ["code.sqlite", "code.sqlite-wal", "code.sqlite-shm"] {
        match std::fs::remove_file(index.join(name)) {
            Ok(()) => deleted = true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(deleted)
}

/// Where code results open: an installed editor's id, or "default" (editors.rs). The panel asks for its Open titles
/// again each time it's shown.
#[tauri::command]
fn set_code_editor(app: AppHandle, shell: State<'_, Arc<Shell>>, editor: String) -> Result<(), String> {
    if editor != editors::DEFAULT_APP && !shell.editors.installed().iter().any(|installed| installed.id == editor) {
        return Err(format!("no such editor here: {editor}"));
    }
    shell.change_settings(|settings| settings.code_editor = editor)?;
    settings_changed(&app);
    Ok(())
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
        let (plan, _) = open_plan(&shell, &hit, &query);
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

/// What ↩ does with a result, for the panel's footer and Open button: "Open at p. 3", "Open at 0:06", else "Open";
/// code says its editor: "Open at line 12 in VS Code".
#[tauri::command]
async fn open_title(shell: State<'_, Arc<Shell>>, hit: opener::Hit) -> Result<String, String> {
    if hit.place().is_none() && hit.kind != "code" {
        return Ok("Open".into());
    }
    let shell = shell.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let (plan, editor) = open_plan(&shell, &hit, "");
        match editor {
            Some(name) => format!("{} in {name}", plan.title()),
            None => plan.title(),
        }
    })
    .await
    .map_err(|error| error.to_string())
}

/// How a result opens (opener.rs): code in the editor chosen in Settings (its name too), the rest in its default app,
/// or VLC for a recording at a moment when Settings say so.
fn open_plan(shell: &Shell, hit: &opener::Hit, query: &str) -> (opener::Plan, Option<String>) {
    if hit.kind == "code" {
        let editor = shell.code_editor();
        let plan = opener::code_plan(hit, editor.as_ref().map(editors::Editor::app).as_ref(),
                                     || shell.apps.for_file(&hit.path));
        return (plan, editor.map(|editor| editor.name));
    }
    (opener::plan(hit, query, shell.apps.for_hit(hit, shell.prefers_vlc()).as_ref()), None)
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
    app.state::<Arc<Shell>>().panel.lock().unwrap().hidden();
}

/// The panel grows to the person's height to show results, and shrinks back to its fields.
#[tauri::command]
fn panel_results(app: AppHandle, shell: State<'_, Arc<Shell>>, shown: bool) {
    let mut state = shell.panel.lock().unwrap();
    if state.show_results(shown) {
        if let Some(panel) = app.get_webview_window("panel") {
            size_panel(&panel, &mut state);
        }
    }
}

/// The person started dragging the panel (panel.js): the places it takes until it hides are theirs (X11), and the
/// focus GNOME takes away for the drag doesn't hide it (panel.rs). Its edges are heard from GTK (`hear_edge_presses`).
#[tauri::command]
fn panel_drag(shell: State<'_, Arc<Shell>>) {
    shell.panel.lock().unwrap().grab(panel::Grab::Move, Instant::now());
}

/// Settings' Reset Size: the panel's default size, and on X11 centered again.
#[tauri::command]
fn reset_panel_size(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<(), String> {
    let mut state = shell.panel.lock().unwrap();
    state.reset();
    if let Some(panel) = app.get_webview_window("panel") {
        size_panel(&panel, &mut state);
    }
    let (width, height, position) = (state.width, state.height, state.position);
    drop(state);
    shell.change_settings(|settings| {
        (settings.panel_width, settings.panel_height, settings.panel_position) = (width, height, position);
    })
}

/// Debug runs: the query the panel types in when it loads (with setup, it comes later as a "debug-query" event).
#[tauri::command]
fn debug_query(shell: State<'_, Arc<Shell>>) -> Option<String> {
    if shell.options.debug_setup {
        return None;
    }
    shell.options.debug_query.clone()
}

/// Debug runs: the filter the panel types in with the debug query (`--debug-filter`).
#[tauri::command]
fn debug_filter(shell: State<'_, Arc<Shell>>) -> Option<String> {
    shell.options.debug_filter.clone()
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
    #[cfg(target_os = "linux")]
    gtk_log::quiet_theme_warnings();
    let options = match Options::from_args() {
        Ok(options) => options,
        Err(error) => {
            eprintln!("digup-shell: {error}");
            std::process::exit(2);
        }
    };
    let context = tauri::generate_context!();
    // `--add-folder DIR --from-tool NAME --yes`: asks the running DigUp as a tool does, and says its answer; never
    // starts one (tools.rs).
    if let Some(request) = options.tool_request() {
        let (said, status) = match request {
            #[cfg(target_os = "linux")]
            Ok((folder, tool, max_files)) => {
                let answer = tools::ask_running(&context.config().identifier, &folder, &tool, max_files);
                (answer["message"].as_str().unwrap_or("DigUp gave no answer").to_string(),
                 if answer["ok"] == true { 0 } else { 1 })
            }
            #[cfg(not(target_os = "linux"))]
            Ok(_) => ("tools add folders over the session bus, on Linux only".to_string(), 1),
            Err(error) => {
                eprintln!("digup-shell: {error}");
                std::process::exit(2);
            }
        };
        println!("{said}");
        std::process::exit(status);
    }
    // `--quit`, `--pause`… with no DigUp running: answered without starting one (control.rs).
    #[cfg(target_os = "linux")]
    if let Some(command) = options.command.clone().filter(|command| !command.starts_app()) {
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
        .plugin(tauri_plugin_single_instance::init(|app, args, cwd| match Command::in_args(&args, &cwd) {
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
            hide_panel, panel_results, panel_drag, reset_panel_size, settings_info, save_folders, set_paused, set_gpu,
            set_starts_at_login, set_up_shortcut, turn_off, try_gpu_again, check_digup, set_moment_player, panel_info,
            panel_folders, add_folder_info, add_folder, cancel_add, pick_folder_to_add,
            save_code_folders, set_code_editor, set_transcripts, set_transcribe_music, debug_query, debug_filter,
            debug_report
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
    let panel = panel::Panel::new(settings.panel_width, settings.panel_height, settings.panel_position,
                                  cfg!(target_os = "linux"));
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
    let transcript_model = ModelDownload::new({
        let app = handle.clone();
        move |event| transcript_model_event(&app, event)
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
        transcript_model,
        transcript_state: Mutex::new(json!({"state": "idle"})),
        transcripts_restart: AtomicBool::new(false),
        transcripts_cancelled: AtomicBool::new(false),
        watcher: Mutex::new(None),
        status: Mutex::new(None),
        pause_item: Mutex::new(None),
        reloaded: Mutex::new(Instant::now()),
        debug_query_sent: AtomicBool::new(false),
        logs,
        apps: opener::Apps::new(),
        health: Mutex::new(fallback::Health::default()),
        editors: editors::Editors::new(),
        panel: Mutex::new(panel),
        panel_saves: AtomicU64::new(0),
        adding: Mutex::new(None),
        first: Mutex::new(None),
        progress: Mutex::new(tools::Progress::default()),
        #[cfg(target_os = "linux")]
        tools_bus: Mutex::new(None),
        #[cfg(target_os = "linux")]
        notifier: notify::Notifier::default(),
        wayland: cfg!(target_os = "linux")
            && panel::is_wayland(std::env::var("WAYLAND_DISPLAY").ok().as_deref(),
                                 std::env::var("GDK_BACKEND").ok().as_deref()),
    });
    app.manage(shell.clone());
    // Tools may ask to add a folder (an MCP server or the HTTP API with --allow-add-folders: tools.rs).
    #[cfg(target_os = "linux")]
    {
        let (adding, asking) = (handle.clone(), handle.clone());
        let bus = tools::ToolsBus {
            add: Arc::new(move |folder, tool, max_files| tool_add(&adding, folder, tool, max_files)),
            status: Arc::new(move || tool_status(&asking)),
        };
        match tools::serve(&app.config().identifier, bus) {
            Ok(connection) => *shell.tools_bus.lock().unwrap() = Some(connection),
            Err(error) => log_error!("digup-shell: tools can't reach this DigUp: {error}"),
        }
    }
    // Now with all it's started with.
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
    // Transcripts on: their model too, in case it's missing (a download that was under way when DigUp quit).
    fetch_transcript_model_if_on(&handle);
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
    if let Some(command) = shell.options.command.clone() {
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
        Command::AddFolder(folder) => {
            if let Err(error) = show_add(app, folder) {
                log_error!("digup-shell: can't open the add window: {error}");
            }
        }
    }
}

/// After setup or a change of folders: the search service, the watcher and indexing follow the new folders.
fn apply_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders = shell.folders();
    let settings = shell.settings.lock().unwrap().clone();
    for folder in &folders {
        let _ = app.asset_protocol_scope().allow_directory(folder, true);
    }
    // The running search service is told; one started later (after it died, or for the GPU switch) starts with them.
    shell.search.set_launch(shell.search_launch());
    let search = shell.clone();
    tauri::async_runtime::spawn(async move {
        let request = json!({"op": "folders", "roots": folders, "skipped": settings.skipped, "types": settings.skip_types,
                             "code_roots": settings.code_folders, "code_skipped": settings.code_skipped});
        let _ = search.search.ask(request).await;
    });
    watch_folders(app);
}

/// Watches the folders and the code folders, and indexes them now when the model is in.
fn watch_folders(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let folders: Vec<PathBuf> = shell.folders().iter().map(PathBuf::from).collect();
    if folders.is_empty() {
        set_status(app, "No folders chosen yet");
        return;
    }
    let code: Vec<PathBuf> = shell.code_folders().iter().map(PathBuf::from).collect();
    let changed = {
        let app = app.clone();
        move || run_index(&app)
    };
    let code_changed = {
        let app = app.clone();
        move || run_code_index(&app)
    };
    *shell.watcher.lock().unwrap() =
        Some(FolderWatcher::start(&folders, &code, shell.options.index_folder(), changed, code_changed));
    if shell.is_paused() {
        set_status(app, &shell.paused_text());
    }
    run_index(app);
}

/// Syncs every `RESYNC_EVERY` (when indexing would run at all: `run_index` checks), unless a helper is in the middle of
/// a pass: asking it would only send it crawling sooner, and the next round comes after it's done. A lingering one is
/// asked; with none running, one starts. The code index too, when there are code folders (`run_code_index` checks):
/// the watcher misses code changes the same ways, and leaves out folders past `CODE_WATCHES` (watcher.rs).
fn resync_now_and_then(app: AppHandle) {
    std::thread::spawn(move || loop {
        std::thread::sleep(RESYNC_EVERY);
        if !app.state::<Arc<Shell>>().index.is_busy() {
            run_index(&app);
            run_code_index(&app);
        }
    });
}

/// Has the index helper sync and index, once there's a model and a folder, unless indexing is paused.
fn run_index(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    if !shell.is_set_up() || shell.folders().is_empty() || !shell.model_ready() || shell.is_paused() {
        return;
    }
    match shell.index.run(&shell.index_launch()) {
        Ok(started) => shell.index_started(started),
        Err(error) => set_status(app, &format!("Indexing couldn't start: {error}")),
    }
}

/// Code changed (and has been quiet a while: watcher.rs): the index helper syncs the code index, under the same
/// conditions as `run_index`.
fn run_code_index(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    if !shell.is_set_up() || shell.folders().is_empty() || shell.code_folders().is_empty() || !shell.model_ready()
        || shell.is_paused() {
        return;
    }
    match shell.index.run_code(&shell.index_launch()) {
        Ok(started) => shell.index_started(started),
        Err(error) => set_status(app, &format!("Indexing couldn't start: {error}")),
    }
}

/// Pauses indexing (the index helper stops, and neither the watcher nor Index Now starts it) or resumes it. Blocks up
/// to two seconds while the helper stops: not on the main thread. `pause_for` pauses with a reason (fallback.rs).
fn pause(app: &AppHandle, paused: bool) -> Result<(), String> {
    pause_with(app, paused, None)
}

/// Indexing paused by DigUp itself, saying why (saved with the pause, so it's said after a restart too).
fn pause_for(app: &AppHandle, why: String) -> Result<(), String> {
    pause_with(app, true, Some(why))
}

fn pause_with(app: &AppHandle, paused: bool, why: Option<String>) -> Result<(), String> {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    shell.change_settings(|settings| {
        // A pause by hand on top of DigUp's own keeps its reason; resuming clears it.
        if !paused || why.is_some() || !settings.paused {
            settings.paused_why = why;
        }
        settings.paused = paused;
    })?;
    show_pause(app, paused);
    if paused {
        shell.index.stop();
        set_status(app, &shell.paused_text());
    } else {
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
    // Not a failure: transcripts stay on, and the next start picks the download up where it stopped.
    stop_transcript_download(&shell);
    shell.index.stop();
    shell.search.stop();
}

fn quit(app: &AppHandle) {
    stop_helpers(app);
    app.exit(0);
}

// MARK: Windows

fn make_panel(app: &AppHandle) -> tauri::Result<()> {
    let (width, height) = app.state::<Arc<Shell>>().panel.lock().unwrap().size();
    // Resizable: Tauri gives it a border to resize it by (panel.rs). What size it may take follows the results
    // (`size_panel`).
    let panel = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("index.html".into()))
        .title("DigUp")
        .inner_size(width, height)
        .min_inner_size(panel::MIN_WIDTH, panel::FIELD_HEIGHT)
        .max_inner_size(panel::MAX_SIDE, panel::FIELD_HEIGHT)
        .decorations(false)
        .transparent(true)
        .shadow(true)
        .resizable(true)
        .maximizable(false)
        .minimizable(false)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .visible(false)
        .build()?;
    #[cfg(target_os = "linux")]
    hear_edge_presses(&panel, app.clone());
    let app = app.clone();
    let window = panel.clone();
    panel.on_window_event(move |event| {
        let shell = app.state::<Arc<Shell>>();
        match event {
            // Like Spotlight: it steps away when you click elsewhere. Not when GNOME takes the keyboard away to move
            // or resize it (panel.rs).
            WindowEvent::Focused(false) => {
                let kept = shell.panel.lock().unwrap().keeps_through_focus_loss(Instant::now());
                if kept {
                    log!("panel: kept through a focus loss as it was moved or resized");
                } else if !shell.options.debug_show {
                    hide_panel(app.clone());
                }
            }
            // The person resizing it by its edge: saved once they stop.
            WindowEvent::Resized(size) => {
                let size = size.to_logical::<f64>(window.scale_factor().unwrap_or(1.0));
                if shell.panel.lock().unwrap().resized(size.width, size.height, Instant::now()) {
                    save_panel_later(&app);
                }
            }
            // X11 only (Wayland doesn't tell an app where its window is): where the person dragged it.
            WindowEvent::Moved(place) if !shell.wayland && shell.panel.lock().unwrap().moved(place.x, place.y) => {
                save_panel_later(&app);
            }
            _ => {}
        }
    });
    Ok(())
}

/// A press on the panel's edge never reaches the page: Tauri's handler on the web view starts the desktop's resize
/// from it and stops it there. The shell hears of it first (GTK's `event` signal comes before `button-press-event`),
/// with the same hit test, so the focus GNOME takes away for the resize doesn't hide the panel and the sizes that
/// follow are saved as the person's (panel.rs).
#[cfg(target_os = "linux")]
fn hear_edge_presses(panel: &WebviewWindow, app: AppHandle) {
    use gtk::prelude::{Cast, GtkWindowExt, WidgetExt};
    let _ = panel.with_webview(move |webview| {
        webview.inner().connect_event(move |view, event| {
            let window = view.toplevel().and_then(|toplevel| toplevel.downcast::<gtk::Window>().ok());
            let resizable = window.as_ref().is_some_and(|window| {
                !window.is_decorated() && window.is_resizable() && !window.is_maximized()
            });
            let pressed = event.event_type() == gtk::gdk::EventType::ButtonPress && event.button() == Some(1);
            if let (true, true, Some(surface), Some((x, y))) =
                (resizable, pressed, window.and_then(|window| window.window()), event.root_coords())
            {
                let (left, top) = surface.position();
                let size = (0.0, 0.0, surface.width() as f64, surface.height() as f64);
                let border = surface.scale_factor() as f64 * panel::EDGE;
                if panel::on_edge(size, x - left as f64, y - top as f64, border) {
                    app.state::<Arc<Shell>>().panel.lock().unwrap().grab(panel::Grab::Resize, Instant::now());
                }
            }
            gtk::glib::Propagation::Proceed
        });
    });
}

/// The panel takes the size it should have now, within the screen it's on, and may be resized only as that allows
/// (with nothing searched, in width only).
fn size_panel(panel: &WebviewWindow, state: &mut panel::Panel) {
    state.asking(Instant::now());
    let limits = state.limits();
    let logical = |pixels: f64| Some(PixelUnit::Logical(pixels.into()));
    let _ = panel.set_size_constraints(WindowSizeConstraints {
        min_width: logical(limits.min.0),
        min_height: logical(limits.min.1),
        // Given a height only, GTK would be told the widest width an i32 has.
        max_width: limits.max_height.and_then(|_| logical(panel::MAX_SIDE)),
        max_height: limits.max_height.and_then(logical),
    });
    let screen = panel.current_monitor().ok().flatten().map(|screen| {
        let size = screen.size().to_logical::<f64>(screen.scale_factor());
        (size.width, size.height)
    });
    let (width, height) = panel::fitted(state.size(), screen);
    let _ = panel.set_size(LogicalSize::new(width, height));
}

/// The person's size and place, saved half a second after the last change (a resize sends many).
fn save_panel_later(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>().inner().clone();
    let save = shell.panel_saves.fetch_add(1, Ordering::SeqCst) + 1;
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(500));
        if shell.panel_saves.load(Ordering::SeqCst) != save {
            return; // a later change saves it
        }
        let (width, height, position) = {
            let state = shell.panel.lock().unwrap();
            (state.width, state.height, state.position)
        };
        let saved = shell.change_settings(|settings| {
            (settings.panel_width, settings.panel_height, settings.panel_position) = (width, height, position);
        });
        match saved {
            Ok(()) => {
                log!("panel: {width}×{height} saved");
                settings_changed(&app);
            }
            Err(error) => log_error!("digup-shell: the panel's size: {error}"),
        }
    });
}

fn show_panel(app: &AppHandle) {
    let shell = app.state::<Arc<Shell>>();
    if !shell.is_set_up() {
        let _ = show_setup(app);
        return;
    }
    let Some(panel) = app.get_webview_window("panel") else { return };
    // Wayland: GNOME places it, and an app asking for a place is ignored there, so it isn't asked. It stays where it
    // was dragged while it's open; hidden and shown again, it's a new window to GNOME (in a check on GNOME 46 with
    // center-new-windows on, back in the middle). X11: where the person dragged it, while that's on a screen;
    // else on the screen with the pointer, centered, a fifth of the way down.
    if !shell.wayland {
        let (width, dragged) = {
            let state = shell.panel.lock().unwrap();
            (state.width, state.position)
        };
        let on_a_screen = |[x, y]: [i32; 2]| matches!(app.monitor_from_point(x as f64, y as f64), Ok(Some(_)));
        match dragged.filter(|&place| on_a_screen(place)) {
            Some([x, y]) => {
                let _ = panel.set_position(PhysicalPosition::new(x, y));
            }
            None => {
                if let Ok(pointer) = app.cursor_position() {
                    if let Ok(Some(screen)) = app.monitor_from_point(pointer.x, pointer.y) {
                        let width = (width * screen.scale_factor()) as i32;
                        let x = screen.position().x + (screen.size().width as i32 - width) / 2;
                        let y = screen.position().y + (screen.size().height as f64 * 0.2) as i32;
                        let _ = panel.set_position(PhysicalPosition::new(x, y));
                    }
                }
            }
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

/// The window that adds a folder on the spot (add.html, adding.rs): for this folder, or, already open, for this one
/// now. Before setup is done, setup comes first.
fn show_add(app: &AppHandle, folder: PathBuf) -> tauri::Result<()> {
    let shell = app.state::<Arc<Shell>>();
    if !shell.is_set_up() {
        return show_setup(app);
    }
    *shell.adding.lock().unwrap() = Some(folder);
    if let Some(window) = app.get_webview_window("add") {
        let _ = window.emit("add-folder", ());
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    WebviewWindowBuilder::new(app, "add", WebviewUrl::App("add.html".into()))
        .title("Add a Folder to DigUp")
        .inner_size(580.0, 560.0)
        .min_inner_size(460.0, 380.0)
        .maximizable(false)
        .center()
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
    if cfg!(debug_assertions) {
        log!("status: {text}");
    }
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
    app.state::<Arc<Shell>>().progress.lock().unwrap().event(&event, Instant::now());
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
        // The transcript pass, after everything else: an event a recording, as "file"'s.
        "transcript" => {
            say(&format!("Transcribing {} of {}", count("done"), count("total")));
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
            let why = format!("Indexing paused: {} kept failing", file.as_deref().unwrap_or("a file"));
            let app = app.clone();
            std::thread::spawn(move || {
                if let Err(error) = pause_for(&app, why) {
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
            set_status(app, &shell.paused_text());
        }
        run_index(app);
        // A search helper that started before the model was there has no encoder ("unavailable" sticks): it tries
        // again now. It does nothing when its encoder wasn't unavailable (the model was there all along).
        tauri::async_runtime::spawn(async move {
            let reply = shell.search.ask(json!({"op": "reload_encoder"})).await;
            if cfg!(debug_assertions) {
                log!("search: reload_encoder {reply:?}");
            }
        });
    }
}

/// The transcripts' download (`fetch_transcript_model`): its state to Settings. Once it's in, the index helper starts
/// over when it should (and transcripts are still on). Failed: transcripts are turned off again, and Settings says
/// why; one stopped on purpose is just over.
fn transcript_model_event(app: &AppHandle, event: Value) {
    if cfg!(debug_assertions) && event["event"] != "progress" {
        log!("transcript model: {event}");
    }
    let Some(state) = transcripts::state(&event) else { return };
    let shell = app.state::<Arc<Shell>>().inner().clone();
    if event["event"] == "file" {
        shell.transcripts_restart.store(true, Ordering::SeqCst);   // something new for the helper
    }
    match state["state"].as_str().unwrap_or_default() {
        "failed" if shell.transcripts_cancelled.swap(false, Ordering::SeqCst) => {}
        "failed" => {
            log_error!("digup-shell: the transcripts' model couldn't download: {}",
                       event["message"].as_str().unwrap_or("no reason given"));
            if let Err(error) = shell.change_settings(|settings| settings.transcripts = false) {
                log_error!("digup-shell: {error}");
            }
            transcript_state(app, state);
            run_index(app);
            settings_changed(app);
        }
        "ready" => {
            shell.transcripts_cancelled.store(false, Ordering::SeqCst);
            transcript_state(app, state);
            if shell.transcripts_restart.swap(false, Ordering::SeqCst) && shell.settings.lock().unwrap().transcripts {
                shell.index.stop();
                run_index(app);
            }
            settings_changed(app);
        }
        _ => transcript_state(app, state),
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
            command: None, offered: None, debug_setup: false, debug_query: None, debug_filter: None, debug_quit: false,
            debug_show: false, background: false, from_tool: None, yes: false, max_files: None,
        };
        assert!(helper_env(&options, false).is_empty());
        assert_eq!(helper_env(&options, true), [("DIGUP_GPU".to_string(), "0".to_string())]);
        let skipping = Settings { skipped: vec!["/a/b".into()], ..Settings::default() };
        let launch = search_launch(&options, &skipping, vec!["/a".into()], Path::new("/logs"), true);
        assert_eq!(launch.args, ["search-service", "--exclude", "/a/b", "/a"]);
        assert_eq!(launch.env, [("DIGUP_GPU".to_string(), "0".to_string())]);
        assert!(!launch.background);
    }

    #[test]
    fn turning_code_search_off_deletes_its_index() {
        let index = std::env::temp_dir().join(format!("digup-code-index-test-{}", std::process::id()));
        std::fs::create_dir_all(&index).unwrap();
        for name in ["index.sqlite", "index.sqlite-wal", "code.sqlite", "code.sqlite-wal", "code.sqlite-shm"] {
            std::fs::write(index.join(name), "").unwrap();
        }
        assert!(delete_code_index(&index).unwrap());
        let mut left: Vec<String> = std::fs::read_dir(&index).unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned()).collect();
        left.sort();
        assert_eq!(left, ["index.sqlite", "index.sqlite-wal"], "the main index stays");
        assert!(!delete_code_index(&index).unwrap(), "none left to delete");
        let _ = std::fs::remove_dir_all(index);
    }
}
